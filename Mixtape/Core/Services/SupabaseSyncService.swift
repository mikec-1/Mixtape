// SupabaseSyncService.swift
// Mixtape — Core/Services
//
// Syncs track/album/artist metadata between the local SwiftData store
// and the Supabase PostgreSQL backend.
//
// Strategy:
//   Push  — upsert all locally modified records to the server.
//   Pull  — fetch server records updated since the last pull; merge into local DB.
//   Conflict — Last-Write-Wins on updated_at. The most recently modified copy wins.
//
// Artwork travels separately from the rows, as compressed JPEGs in the
// `artwork` bucket — see the Artwork Sync section near the bottom.

import Foundation
import SwiftData
import Supabase
import Combine
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class SupabaseSyncService: ObservableObject, SyncServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var syncState: SyncState = .idle

    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        $syncState.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    // Held as a provider rather than a value: building the SupabaseClient costs
    // ~1.3 s and, taken eagerly in `AppDependencies.init`, that whole second sat
    // on the main thread before the first frame. `@autoclosure` keeps every call
    // site written exactly as before while moving the work to first real use —
    // which is a network call, and so already off the launch path.
    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    private let libraryService: LibraryService
    private let deviceID:       String

    // MARK: - Private State

    private var currentUser:    AppUser?

    /// The last token handed to the realtime socket, so waking from the
    /// background can re-apply it rather than reconnecting anonymously.
    private var realtimeToken:  String?
    private var backgroundTask: Task<Void, Never>?
    private var isSyncing = false

    /// A sync that was asked for while one was already running.
    ///
    /// Dropping it is not safe. The run in flight may already be past its
    /// `pullAll` when the request arrives, so the rows that prompted the
    /// request are not in it — and the drop is silent, leaving the device
    /// showing "Syncing" and then settling `upToDate` without the new data.
    /// That is the mix on iOS that only appeared after a pull-to-refresh: the
    /// realtime event did arrive, its pull was just swallowed by the minute
    /// timer's run. Requests are coalesced into one follow-up instead.
    private var syncRequestedWhileBusy = false

    /// Realtime listener that signs the user out the instant this device's row
    /// is deleted from the `devices` table (a "force logout" from the web).
    private var revocationChannel: RealtimeChannelV2?
    private var revocationTask:    Task<Void, Never>?

    /// Realtime listener on this user's own library rows. What makes an edit
    /// made on the phone appear on the Mac without waiting for the minute timer.
    private var libraryChannel: RealtimeChannelV2?
    private var libraryTask:    Task<Void, Never>?

    /// Coalesces a burst of remote events into one pull. Importing a playlist of
    /// two hundred songs arrives as two hundred events; it must not become two
    /// hundred syncs.
    private var remotePullTask: Task<Void, Never>?

    /// The other half of "instant": a local edit has to reach the server
    /// quickly too, or the other device gets the news promptly and the news is
    /// a minute old.
    private var localPushTask:      Task<Void, Never>?
    private var localChangeWatch:   AnyCancellable?

    /// Invoked when this device is revoked remotely. Wired by AppDependencies to
    /// the auth service's sign-out. Runs on the main actor.
    public var onDeviceRevoked: (() async -> Void)?
    /// Realtime has its credentials — the moment other channels (continuity) may subscribe.
    public var onRealtimeReady: ((UUID) -> Void)?

    // MARK: - Init

    public init(
        client:         @autoclosure @escaping () -> SupabaseClient,
        libraryService: LibraryService,
        deviceID:       String
    ) {
        self.clientProvider = client
        self.libraryService = libraryService
        self.deviceID       = deviceID
    }

    // MARK: - Lifecycle

    public func onSignIn(user: AppUser, accessToken: String) async {
        currentUser = user
        // The websocket carries its own credentials, separate from the REST
        // client's. `tracks` and `playlists` are RLS-protected, so an
        // unauthenticated socket is handed nothing — and says nothing about it:
        // the channel still reports itself subscribed and simply never
        // delivers. This token is what makes the subscription real.
        //
        // `accessToken` has been a parameter of this method since it was
        // written and was never used, which is exactly how the gap survived.
        if !accessToken.isEmpty {
            realtimeToken = accessToken
            await client.realtimeV2.setAuth(accessToken)
        }
        // Before the three listeners below race each other onto a cold socket.
        await client.connectRealtimeSocket()
        syncState   = .pendingChanges(count: pendingCount())
        Task {
            // Revocation check BEFORE re-registering: if this install had
            // previously registered its device row and the row is now gone, the
            // device was revoked from the web while we were offline/asleep.
            // Without this check, registerDevice() would silently resurrect the
            // deleted row and the "Sign out" on the web devices page would only
            // ever work while the app happened to be running.
            // The flag is cleared on explicit sign-out, so a fresh interactive
            // login after a revocation correctly re-registers.
            if wasDeviceRegistered(userID: user.id),
               await !deviceRowStillExists(userID: user.id) {
                print("[Sync] 🔒 Device row was revoked while offline — signing out.")
                clearDeviceRegisteredFlag(userID: user.id)
                await onDeviceRevoked?()
                return
            }
            // Register this device, then kick off an immediate first sync.
            await registerDevice(userID: user.id)
            try? await sync()
        }
        startRevocationListener(userID: user.id)
        startLibraryListener(userID: user.id)
        onRealtimeReady?(user.id)
        startLocalChangeWatch()
    }

    public func onSignOut() async {
        // Stopping the timer only prevents the *next* run. A sync already
        // part-way through its artwork loops kept downloading covers for the
        // account that just signed out, forever, because nothing told it to
        // stop.
        cancelAllWork()
        await stopRevocationListener()
        await stopLibraryListener()
        if let user = currentUser { clearDeviceRegisteredFlag(userID: user.id) }
        currentUser = nil
        syncState   = .idle
    }

    // MARK: - Device-registered flag (per user, for the offline-revocation check)

    private func deviceRegisteredKey(userID: UUID) -> String {
        "mix.deviceRegistered.\(userID.uuidString).\(deviceID)"
    }
    private func wasDeviceRegistered(userID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: deviceRegisteredKey(userID: userID))
    }
    private func markDeviceRegistered(userID: UUID) {
        UserDefaults.standard.set(true, forKey: deviceRegisteredKey(userID: userID))
    }
    private func clearDeviceRegisteredFlag(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: deviceRegisteredKey(userID: userID))
    }

    // MARK: - Sync

    /// True when this sync has written something to the local store.
    ///
    /// A steady-state sync — every table "0 new, 0 updated" — used to end with a
    /// full `libraryService.refresh()` anyway, and that refresh is ~1.9 s of
    /// main-thread work. Once a minute, forever, for nothing. The published
    /// arrays cannot have gone stale if no local row changed, so the refresh is
    /// only owed when one did.
    private var didWriteLocally = false

    /// Set by `cancelAllWork()`, cleared when a fresh sync starts.
    ///
    /// The per-song loops can't be stopped by cancelling a task handle, because
    /// `sync()` is called from a dozen places that each make their own — so the
    /// stop signal lives on the service instead of on any one caller's Task.
    private var abortRequested = false

    /// Whether this sync has raised the activity banner. See `runSync`.
    private var announcedActivity = false

    /// Raises the banner, once, and only if nothing else already owns it.
    private func announceWork() {
        guard !announcedActivity, libraryService.activity == .idle else { return }
        announcedActivity = true
        libraryService.beginActivity("Syncing")
    }

    /// When the backlog sweeps last ran to completion. See `shouldSweepBacklog`.
    private var lastBacklogSweep: Date?

    /// Ten full-table fetches is not a thing to do once a minute.
    ///
    /// The backlog sweeps — pending file uploads, the eight artwork scans, and
    /// the deleted-audio prune — all answer "is there leftover work?", and each
    /// one asks by materialising whole rows. Three of the artwork scans test
    /// `artworkData != nil`, a query against an `.externalStorage` attribute:
    /// the same shape the `library-fetch breakdown` line measures at 400 ms for
    /// a single table, and it pulls the blobs in for whatever matches. The idle
    /// tick ran the lot every 60 seconds to print a column of zeroes.
    ///
    /// They run whenever the sync did anything at all, and otherwise on a
    /// ten-minute floor rather than never. The floor is not politeness: a
    /// backlog can appear without any sync noticing — artwork attached by a
    /// backfill, or an upload that failed halfway and left `fileUploaded ==
    /// false` on an otherwise-synced row — so a tick that is a complete no-op
    /// would strand it until the next local edit.
    private func shouldSweepBacklog(hadPendingWork: Bool) -> Bool {
        if hadPendingWork || didWriteLocally { return true }
        guard let last = lastBacklogSweep else { return true }
        return Date().timeIntervalSince(last) >= 600
    }

    /// When the device heartbeat was last written. See `heartbeatDevice`.
    private var lastHeartbeat: Date?


    /// True when whatever is running should stop at its next opportunity.
    private var shouldStopWork: Bool { Task.isCancelled || abortRequested || currentUser == nil }

    /// Stop everything in flight: the background timer, and any sync already
    /// part-way through its loops.
    ///
    /// "Clear Everything" deleted the library and then sat there while a sync
    /// that started before it went on uploading covers for two thousand songs
    /// that no longer existed. Stopping the timer was never enough — it only
    /// prevents the *next* run.
    public func cancelAllWork() {
        stopBackgroundSync()
        abortRequested = true
    }

    public func sync() async throws {
        guard currentUser != nil else { return }
        if isSyncing {
            syncRequestedWhileBusy = true
            return
        }
        try await runSyncLoop()
    }

    /// Runs a sync, then runs one more if anything asked while it was busy.
    ///
    /// Loops rather than recurses so a steady trickle of remote events can't
    /// build a stack, and re-checks each time round: a request that arrives
    /// during the follow-up gets its own follow-up.
    private func runSyncLoop() async throws {
        repeat {
            syncRequestedWhileBusy = false
            try await runSync()
            // A request is not on its own a reason to go round again. The
            // library's own change notification fires during `refresh()`, so an
            // unconditional repeat is a sync that re-triggers itself forever.
            guard syncRequestedWhileBusy, !shouldStopWork, pendingCount() > 0 else { return }
        } while true
    }

    private func runSync() async throws {
        guard let user = currentUser, !isSyncing else { return }
        abortRequested = false
        didWriteLocally = false
        isSyncing = true
        syncState = .syncing
        // The banner says "Syncing" when there is something to sync, not when a
        // timer fired. A change arriving from another device is still the case
        // that must announce — the user has done nothing and has no reason to
        // expect the screen to move, and an unexplained rearrangement reads as
        // a fault — but an idle tick that finds nothing has nothing to explain.
        //
        // So it is armed here and raised by `announceWork()` at the first point
        // that knows there is real work: pending local rows, a pull that
        // returned something, or an artwork sweep with a file to move.
        announcedActivity = false
        let hadPendingWork = pendingCount() > 0
        if hadPendingWork { announceWork() }
        defer {
            isSyncing = false
            if announcedActivity {
                libraryService.endActivity()
                announcedActivity = false
            }
        }

        print("[Sync] ▶︎ Sync started")
        // Nine full table scans for one debug line used to live here, on the
        // main actor, once a minute. Even behind `#if DEBUG` that is what the
        // user runs, and on the phone it measured up to 722 ms of a frozen main
        // thread per sync — three of the scans carry an `artworkData != nil`
        // clause against an external-storage attribute. `logArtworkCounts` is
        // still below for a session that genuinely needs the numbers; nothing
        // calls it by default.
        // A clear that arrives from another device has to have the same
        // consequences here as one typed here: the pages built *from* the
        // library (this week's mixes, recommended artists, the landing) are
        // still holding the old taste otherwise. `UserDataReset.announce` is
        // only ever called by the local destructive commands, so the pull has
        // to speak for the remote one.
        let liveBeforePull = libraryService.tracks.filter { !$0.isDeleted }.count

        do {
            // Phases, not spans: they measure nothing, they only give the hang
            // watchdog a name to print. Every multi-second stall on the phone so
            // far has landed outside every span, during a sync, and come out of
            // the log as a bare number of milliseconds.
            try await mixPhase("sync/push")            { try await pushAll(userID: user.id) }
            try await mixPhase("sync/pull")            { try await pullAll(userID: user.id) }
            if shouldSweepBacklog(hadPendingWork: hadPendingWork) {
                try await mixPhase("sync/upload-files")     { try await uploadPendingFiles(userID: user.id) }
                try await mixPhase("sync/upload-artwork")   { try await uploadPendingArtworks(userID: user.id) }
                try await mixPhase("sync/download-artwork") { try await downloadPendingArtworks(userID: user.id) }
                await mixPhase("sync/prune-deleted-audio")  { await pruneAudioForDeletedTracks() }
                lastBacklogSweep = Date()
            }
            await mixPhase("sync/heartbeat")           { await heartbeatDevice(userID: user.id) }
            await mixPhase("sync/prune-tombstones")    { await pruneTombstonesIfDue(userID: user.id) }
            await mixPhase("sync/reconcile")           { await reconcileTrackCounts(userID: user.id) }
            if didWriteLocally {
                // Off the main actor: the three bulk fetches are ~700-1400 ms of
                // main-thread time per sync, and nothing about them needs the
                // main actor. Safe here in a way it is not on the write paths —
                // those read back inside the user action that saved, whereas
                // everything this sync wrote is committed by now, and
                // `LibrarySnapshotReader` reads through a fresh scratch context
                // that therefore sees it.
                await mixPhase("sync/refresh") { await libraryService.refreshOffMain() }
            } else {
                print("[Sync] Nothing changed locally — skipping refresh")
            }
            let liveAfterPull = libraryService.tracks.filter { !$0.isDeleted }.count
            if liveBeforePull > 0 && liveAfterPull == 0 {
                print("[Sync] Library emptied by a remote clear — resetting derived state")
                UserDataReset.announce(.everything)
            }
            syncState = .upToDate(lastSynced: Date())
            print("[Sync] ✅ Sync complete")
            // Cumulative, not per-sync: the question A3 asks is where the main
            // actor's time goes over a session, and a sync is simply the most
            // regular moment at which to ask it. Console, subsystem = the
            // bundle id, category "hangs".
            MainThreadActivity.shared.logReport("after sync")
        } catch {
            syncState = .error(error.localizedDescription)
            print("[Sync] ❌ Sync failed: \(error)")
            throw error
        }
    }

    // MARK: - Tombstone Pruning

    /// Clears out deletion markers every device has already pulled.
    ///
    /// Once a day at most, and only after a sync that otherwise succeeded — the
    /// server decides what's safe to remove (see the `prune_sync_tombstones`
    /// migration), this only decides how often to ask. Best-effort throughout:
    /// tombstones piling up is a bandwidth cost, never a correctness one, so a
    /// failure here must not fail the sync that just worked.
    private func pruneTombstonesIfDue(userID: UUID) async {
        let key = "mix.sync.tombstonePrune.\(userID.uuidString)"
        let last = UserDefaults.standard.object(forKey: key) as? Date
        if let last, Date().timeIntervalSince(last) < 86_400 { return }

        do {
            let removed: Int = try await client
                .rpc("prune_sync_tombstones")
                .execute()
                .value
            UserDefaults.standard.set(Date(), forKey: key)
            // Logged even at zero. "Nothing to prune" and "the prune never ran"
            // look identical from the outside otherwise, and they call for
            // completely different investigations.
            print("[Sync] 🧹 Pruned \(removed) tombstone\(removed == 1 ? "" : "s")")
        } catch {
            // Includes "function does not exist" on a project that hasn't had
            // the migration applied yet, which is a perfectly fine state to be
            // in — the pulls page correctly either way.
            print("[Sync] tombstone prune skipped: \(error)")
        }
    }

    // MARK: - Deleted Audio

    /// A song deleted on another device has to lose its bytes here too.
    ///
    /// The pull applies the tombstone — `isSoftDeleted` goes true and the row
    /// leaves every list — but the file it named stayed on disk forever. A
    /// *local* delete has always removed it (`LibraryService.deleteTracksBody`);
    /// a synced one never did, which is where the orphans being cleaned by hand
    /// came from.
    ///
    /// A sweep rather than a hook inside the pull, so it also clears the
    /// backlog: every tombstone this device applied before this existed still
    /// has its file. After the first run there is nothing left to find and the
    /// fetch costs one predicate.
    ///
    /// Only rows whose deletion is already **synced**. A deletion this device
    /// still owes the server keeps its `localPath`, because `isPushable` reads
    /// that field to decide the row is ours — clearing it would strand the
    /// tombstone here and the song would live on everywhere else.
    ///
    /// `localPath` is cleared as the file goes, so a row is swept once and
    /// nothing is left pointing at a path that no longer resolves. If the
    /// server later hands back a live, newer row the song does come back, minus
    /// its audio — which is the same state as any track pulled from another
    /// device, and the download path already knows how to fill it in.
    private func pruneAudioForDeletedTracks() async {
        let synced = SyncStatus.synced.rawValue
        var paths: [String] = []
        do {
            let rows = try context.fetch(
                FetchDescriptor<TrackEntity>(predicate: #Predicate {
                    $0.isSoftDeleted && $0.localPath != "" && $0.syncStatus == synced
                }))
            guard !rows.isEmpty else { return }
            paths = rows.map(\.localPath)
            for row in rows { row.localPath = "" }
            try context.save()
        } catch {
            print("[Sync] deleted-audio sweep skipped: \(error)")
            return
        }

        // Off the actor: a first run against a long backlog is hundreds of
        // `fileExists` + `removeItem` pairs, and none of it needs the main thread.
        let doomed = paths
        await Task.detached(priority: .utility) {
            for path in doomed { AudioPaths.removeAllCopies(ofLocalPath: path) }
        }.value

        didWriteLocally = true
        print("[Sync] \u{1F5D1} Removed audio for \(paths.count) deleted track\(paths.count == 1 ? "" : "s")")
    }

    // MARK: - Count Reconcile

    private struct TrackIDRow: Decodable, Sendable {
        let id: UUID
    }

    private var didReconcileThisLaunch = false

    /// Do the two sides actually hold the same songs?
    ///
    /// Every count divergence so far — 2103 vs 2102, 2130 vs 2129 — has been
    /// invisible from inside a sync. The push silently filters rows it cannot
    /// send (`isPushable`), the pull silently skips rows it will not insert,
    /// and both report success. Nothing ever compared the two libraries, so a
    /// row that never made the crossing stayed lost and the only symptom was a
    /// header counting one more song than it could show.
    ///
    /// This names it, and says *why* for the local-only side: most of those
    /// rows are held back on purpose — a shadow row minted for a shared
    /// playlist must never be pushed — and the interesting case is the row that
    /// should have gone and didn't.
    ///
    /// It repairs only what is safely repairable:
    ///   • a live local row `isPushable` accepts but the server lacks is a lost
    ///     push; re-marking it modified means the next push sends it;
    ///   • rows the server has and this device does not are fetched by id and
    ///     adopted, because no ordinary pull will ever deliver them (see
    ///     `adoptMissingTracks`).
    ///
    /// Always once per launch, and hourly after that. It reads every track id
    /// in the account, which is cheap per row and still not something to do
    /// once a minute — but a purely time-based gate means a device that has
    /// just been told it is short a song sits on that answer for an hour, and
    /// relaunching (the one thing anybody does when a count looks wrong)
    /// changes nothing.
    private func reconcileTrackCounts(userID: UUID) async {
        let key = "mix.sync.trackReconcile.\(userID.uuidString)"
        if didReconcileThisLaunch,
           let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < 3_600 { return }
        didReconcileThisLaunch = true

        var serverIDs = Set<UUID>()
        do {
            let client   = self.client
            let pageSize = Self.pullPageSize
            var offset   = 0
            while true {
                // Id only, and no `sync_device_id` filter: the pull skips our
                // own writes because it has nothing to learn from them, but the
                // question here is what the server holds, whoever wrote it.
                let page: [TrackIDRow] = try await Task.detached(priority: .utility) {
                    try await client
                        .from("tracks")
                        .select("id")
                        .eq("user_id", value: userID.uuidString)
                        .eq("is_deleted", value: false)
                        .order("id")
                        .range(from: offset, to: offset + pageSize - 1)
                        .execute()
                        .value
                }.value
                serverIDs.formUnion(page.map(\.id))
                offset += page.count
                if page.count < pageSize { break }
            }
        } catch {
            // Never fails the sync: this is a diagnostic that happens to repair.
            print("[Sync] reconcile skipped: \(error)")
            return
        }
        UserDefaults.standard.set(Date(), forKey: key)

        // From the published array, not a fetch.
        //
        // An id-only fetch was the first attempt and it still cost
        // `Main thread hang: 692 ms — in [sync/reconcile]` on the Mac — the
        // `library-fetch breakdown` line puts a live-tracks fetch at ~517 ms
        // whatever you ask it for, because the predicate and the sort are the
        // expense, not the columns. The library is already holding exactly this
        // list in memory, so the right number of fetches here is zero.
        let localIDs = Set(libraryService.tracks.filter { !$0.isDeleted }.map(\.id))

        let missingHere     = serverIDs.subtracting(localIDs)
        let missingOnServer = localIDs.subtracting(serverIDs)
        guard !missingHere.isEmpty || !missingOnServer.isEmpty else {
            print("[Sync] \u{2696} Reconcile: \(localIDs.count) tracks, both sides agree")
            return
        }

        print("[Sync] \u{2696} Reconcile: local \(localIDs.count), server \(serverIDs.count) — \(missingHere.count) missing here, \(missingOnServer.count) missing on the server")

        var lost: [TrackEntity] = []
        var heldBack: [String: Int] = [:]
        let strayRows = missingOnServer.isEmpty ? [] : (try? context.fetch(
            FetchDescriptor<TrackEntity>(
                predicate: #Predicate { missingOnServer.contains($0.id) }))) ?? []
        for row in strayRows {
            if Self.isPushable(row) {
                lost.append(row)
            } else {
                heldBack["\(row.resolvedOrigin)", default: 0] += 1
            }
        }
        for (reason, count) in heldBack.sorted(by: { $0.key < $1.key }) {
            print("[Sync]    \(count) held back on purpose (\(reason))")
        }
        // Capped: the point is to identify the divergence, not to print a
        // library into the console the first time a device runs this.
        for row in lost.prefix(10) {
            print("[Sync]    never pushed: \(row.title) — \(row.artistName)")
        }
        if !lost.isEmpty {
            for row in lost where row.syncStatus == SyncStatus.synced.rawValue {
                row.syncStatus          = SyncStatus.modified.rawValue
                row.syncLocalModifiedAt = Date()
            }
            try? context.save()
            print("[Sync]    re-queued \(lost.count) for the next push")
        }

        if !missingHere.isEmpty {
            await adoptMissingTracks(ids: Array(missingHere), userID: userID)
        }

        // A repair deserves a verification, but not on every sync from here on
        // if it failed to stick: five minutes, not one hour and not immediately.
        UserDefaults.standard.set(Date().addingTimeInterval(-3_300), forKey: key)
    }

    /// Fetches specific server rows this device does not have, by id.
    ///
    /// Clearing the pull watermark was the obvious repair and it is worthless
    /// here: the pull asks for rows *this device did not write*
    /// (`sync_device_id.neq`), because a row we pushed is one we already have —
    /// except when we don't. A full re-read of a 2113-row table came back with
    /// 171 rows and inserted none of them, and the one missing song was in the
    /// 1942 the filter had thrown away. No watermark can recover a row this
    /// device originally wrote; only asking for it by id can.
    ///
    /// Chunked, because a `?id=in.(…)` URL has a length limit, and capped —
    /// if hundreds of rows are missing the problem is not one this should be
    /// quietly papering over on every sync.
    private func adoptMissingTracks(ids: [UUID], userID: UUID) async {
        let wanted = Array(ids.prefix(500))
        if wanted.count < ids.count {
            print("[Sync]    \(ids.count) rows missing locally — adopting the first \(wanted.count)")
        }
        var adopted = 0, revived = 0
        for chunk in stride(from: 0, to: wanted.count, by: 100).map({
            Array(wanted[$0 ..< min($0 + 100, wanted.count)])
        }) {
            do {
                let client = self.client
                let values = chunk.map(\.uuidString)
                let rows: [TrackRow] = try await Task.detached(priority: .utility) {
                    try await client
                        .from("tracks")
                        .select()
                        .eq("user_id", value: userID.uuidString)
                        .in("id", values: values)
                        .execute()
                        .value
                }.value

                let local = existingTracks(ids: rows.map(\.id))
                for row in rows where !row.isDeleted {
                    if let existing = local[row.id] {
                        // Present but soft-deleted: the server says live, and it
                        // is newer by construction — this device never learned
                        // of the deletion being reversed.
                        row.apply(to: existing)
                        revived += 1
                    } else {
                        context.insert(TrackEntity(from: row))
                        adopted += 1
                    }
                }
                try context.save()
            } catch {
                print("[Sync]    adopt failed: \(error)")
                return
            }
        }
        if adopted + revived > 0 {
            didWriteLocally = true
            print("[Sync]    adopted \(adopted) missing track\(adopted == 1 ? "" : "s"), revived \(revived)")
        }
    }

    /// Generic single-entity push (protocol requirement; caller supplies a complete row struct).
    public func push<T: Codable>(_ entity: T, table: String) async throws {
        guard currentUser != nil else { return }
        try await client.from(table).upsert(entity).execute()
    }

    // MARK: - Device Registration

    /// Upserts this install into the `devices` table so it appears on the web
    /// /devices page. Reuses the stable `deviceID` (same one used for sync
    /// attribution). Best-effort: a failure never blocks sync.
    private func registerDevice(userID: UUID) async {
        let row = DeviceRow(
            userID:     userID,
            deviceID:   deviceID,
            platform:   Self.platformName,
            name:       Self.deviceName,
            appVersion: Self.appVersion,
            lastSeenAt: Date()
        )
        do {
            try await client.from("devices")
                .upsert(row, onConflict: "user_id,device_id")
                .execute()
            markDeviceRegistered(userID: userID)
        } catch {
            print("[Sync] device register failed: \(error)")
        }
    }

    /// Per-sync "still alive" ping. Unlike `registerDevice` this only UPDATEs
    /// the existing row — it never re-creates it — so a device revoked from the
    /// web while a sync was in flight can't resurrect its own row. If the row
    /// is gone (and we know we had registered), treat it as a revocation.
    private func heartbeatDevice(userID: UUID) async {
        // A network write a minute, forever, to move a `last_seen_at` column
        // that nothing reads at that resolution. Five minutes is plenty for a
        // liveness column, and revocation does not depend on it — the devices
        // row being deleted arrives instantly through `startRevocationListener`,
        // and this check is only the fallback for when Realtime is down.
        if let last = lastHeartbeat, Date().timeIntervalSince(last) < 300 { return }
        lastHeartbeat = Date()
        struct Beat: Encodable {
            let lastSeenAt: Date
            let appVersion: String
            enum CodingKeys: String, CodingKey {
                case lastSeenAt = "last_seen_at"
                case appVersion = "app_version"
            }
        }
        struct Row: Decodable { let device_id: String }
        do {
            let rows: [Row] = try await client.from("devices")
                .update(Beat(lastSeenAt: Date(), appVersion: Self.appVersion))
                .eq("user_id", value: userID)
                .eq("device_id", value: deviceID)
                .select("device_id")
                .execute()
                .value
            if rows.isEmpty, wasDeviceRegistered(userID: userID) {
                print("[Sync] 🔒 Device row gone during heartbeat — revoked, signing out.")
                clearDeviceRegisteredFlag(userID: userID)
                await onDeviceRevoked?()
            }
        } catch {
            // Network/query error — never force a logout on a failed heartbeat.
            print("[Sync] device heartbeat failed: \(error)")
        }
    }

    // MARK: - Remote Revocation (force logout)

    /// Subscribes to realtime DELETE events on this device's `devices` row.
    /// When the row is removed (e.g. revoked from the web /devices page), the
    /// app signs out immediately. Best-effort: if Realtime is unavailable, the
    /// next background sync still won't recreate access — this just makes it
    /// instant rather than waiting on token expiry.
    private func startRevocationListener(userID: UUID) {
        // Teardown of the previous listener is handed to the *new* task rather
        // than done inline, because it has to be awaited: `client.channel(_:)`
        // hands back the cached channel while the topic is still registered, so
        // creating the replacement before the old one is removed would return
        // the already-subscribed channel. Registering `postgresChange` on that
        // logs "callbacks after subscribe()" and silently never delivers an
        // event — i.e. remote revocation would stop working after a re-sign-in.
        let previousTask    = revocationTask
        let previousChannel = revocationChannel
        revocationChannel = nil
        previousTask?.cancel()

        revocationTask = Task { [weak self] in
            guard let self else { return }

            if let previousChannel {
                await client.removeChannel(previousChannel)
            }
            guard !Task.isCancelled else { return }

            let channel = client.channel("device-revocation-\(deviceID)")
            revocationChannel = channel

            // NOTE: we deliberately do NOT use a server-side `filter:` here.
            // Realtime's postgres_changes filtering on DELETE is unreliable (the
            // filter is evaluated against replica-identity columns and often
            // drops events), so we subscribe to all DELETEs on `devices` — RLS
            // already scopes these to the signed-in user — and match our own
            // row client-side.
            let deletions = channel.postgresChange(
                DeleteAction.self,
                schema: "public",
                table:  "devices"
            )

            await client.join(channel, label: "revocation listener")
            print("[Sync] 👂 Revocation listener subscribed (device \(deviceID))")

            for await deletion in deletions {
                guard !Task.isCancelled else { break }

                // The DELETE payload only reliably carries the primary key (the
                // `devices` table's replica identity is the default PK), so we
                // can't read device_id off `oldRecord`. Instead: any DELETE on
                // `devices` is — thanks to RLS — one of *this user's* devices.
                // Re-check whether our own row still exists; if it's gone, this
                // device was the one revoked.
                let oldDeviceID = deletion.oldRecord["device_id"]?.stringValue
                print("[Sync] 👂 devices DELETE received (device_id=\(oldDeviceID ?? "nil")) — verifying our row")
                if oldDeviceID != nil && oldDeviceID != deviceID { continue }

                if await deviceRowStillExists(userID: userID) {
                    print("[Sync] 👂 our device row still present — not us, ignoring")
                    continue
                }

                print("[Sync] 🔒 This device revoked remotely — signing out.")
                await onDeviceRevoked?()
                break
            }
        }
    }

    /// Returns true if this install's `devices` row is still present. Used to
    /// confirm a remote revocation actually removed *us*.
    private func deviceRowStillExists(userID: UUID) async -> Bool {
        struct Row: Decodable { let device_id: String }
        do {
            let rows: [Row] = try await client.from("devices")
                .select("device_id")
                .eq("user_id", value: userID)
                .eq("device_id", value: deviceID)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            // On a query error, don't force a logout — fail safe (stay signed in).
            print("[Sync] device existence check failed: \(error)")
            return true
        }
    }

    private func stopRevocationListener() async {
        revocationTask?.cancel()
        revocationTask = nil
        if let channel = revocationChannel {
            // `removeChannel`, not `unsubscribe`: only the former evicts the
            // topic from the client's channel cache, so a later listener gets a
            // fresh channel instead of this one.
            await client.removeChannel(channel)
            revocationChannel = nil
        }
    }

    private struct DeviceRow: Encodable {
        let userID:     UUID
        let deviceID:   String
        let platform:   String
        let name:       String
        let appVersion: String
        let lastSeenAt: Date

        enum CodingKeys: String, CodingKey {
            case userID     = "user_id"
            case deviceID   = "device_id"
            case platform
            case name
            case appVersion = "app_version"
            case lastSeenAt = "last_seen_at"
        }
    }

    static var platformName: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    // MARK: - Realtime Library Changes

    /// Subscribes to this user's `tracks` and `playlists` rows so a change made
    /// on another device lands here in about a second.
    ///
    /// Only those two tables: `pullAll` fetches everything anyway, so albums and
    /// artists would only be extra ways of being told the same thing — and both
    /// of them only ever change alongside a track.
    ///
    /// Teardown is handed to the *new* task rather than done inline, for the
    /// same reason as the revocation listener: `client.channel(_:)` returns the
    /// cached channel while the topic is still registered, and registering
    /// `postgresChange` on an already-subscribed channel silently delivers
    /// nothing.
    private func startLibraryListener(userID: UUID) {
        let previousTask    = libraryTask
        let previousChannel = libraryChannel
        libraryChannel = nil
        previousTask?.cancel()

        libraryTask = Task { [weak self] in
            guard let self else { return }

            if let previousChannel {
                await client.removeChannel(previousChannel)
            }
            guard !Task.isCancelled else { return }

            let channel = client.channel("library-changes-\(deviceID)")
            libraryChannel = channel

            // No server-side `filter:` — RLS already scopes these to the signed
            // in user, and Realtime's filtering is evaluated against
            // replica-identity columns, which drops DELETE events (the same trap
            // documented on the revocation listener above).
            let trackChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "tracks")
            let playlistChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "playlists")

            await client.join(channel, label: "library listener")
            // Worth printing loudly: if `tracks` and `playlists` are not in the
            // `supabase_realtime` publication, this still says "subscribed" and
            // then never delivers a single event — the failure mode is silence,
            // not an error.
            print("[Sync] 👂 Library listener subscribed (device \(deviceID)) — status \(channel.status)")

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await action in trackChanges {
                        guard !Task.isCancelled else { break }
                        await self?.handleRemoteChange(action, table: "tracks")
                    }
                }
                group.addTask { [weak self] in
                    for await action in playlistChanges {
                        guard !Task.isCancelled else { break }
                        await self?.handleRemoteChange(action, table: "playlists")
                    }
                }
            }
        }
    }

    private func stopLibraryListener() async {
        libraryTask?.cancel()
        libraryTask = nil
        remotePullTask?.cancel()
        remotePullTask = nil
        localPushTask?.cancel()
        localPushTask = nil
        localChangeWatch = nil
        if let channel = libraryChannel {
            await client.removeChannel(channel)
            libraryChannel = nil
        }
    }

    /// Decides whether an event is worth a pull, then schedules one.
    ///
    /// Our own writes come back to us — every push we make is an event on this
    /// channel — so anything stamped with this device's id is dropped. Without
    /// that, one edit here would push, hear itself, and pull straight back.
    private func handleRemoteChange(_ action: AnyAction, table: String) async {
        let origin: String?
        switch action {
        case .insert(let a): origin = a.record["sync_device_id"]?.stringValue
        case .update(let a): origin = a.record["sync_device_id"]?.stringValue
        case .delete:
            // Dropped outright, not pulled.
            //
            // A DELETE payload carries only the replica identity, so there is no
            // device to check — but there is also nothing to fetch. Rows are
            // never hard-deleted on the server except by `prune_sync_tombstones`,
            // whose whole contract is that it only removes tombstones every
            // device has already pulled. A vanished tombstone is therefore never
            // news, and pulling on one costs a full sync to learn nothing.
            // Ordinary deletion travels as a soft delete, which arrives as an
            // UPDATE and is handled above.
            return
        }
        guard origin != deviceID else { return }
        // Logged once per burst, not once per row. A single edit on the other
        // device is one Realtime event *per row it touched*, so a 20-song mix
        // legitimately arrives as 20+ events; printing each one buried
        // everything else in the console and read like an echo storm.
        if pullBurstStart == nil {
            print("[Sync] 📡 Remote change on \(table) — scheduling pull")
        }
        scheduleRemotePull()
    }

    /// Start of the current burst, cleared when its pull fires.
    private var pullBurstStart: Date?

    /// Longest a burst may hold the pull off. See `scheduleRemotePull`.
    private static let pullBurstCap: Duration = .milliseconds(1500)

    /// One pull per burst.
    private func scheduleRemotePull() {
        // Not while one is running: the sync in flight *is* the body of
        // `remotePullTask`, so cancelling it here kills the push half way
        // through — which is what produced a wall of
        // "Sync failed: CancellationError()" and a mix that arrived with two
        // songs missing. Hand the request to the loop instead.
        if isSyncing { syncRequestedWhileBusy = true; return }

        // Trailing debounce with a ceiling.
        //
        // Every event re-arms the 800 ms timer, so a burst only pulls once the
        // other device goes quiet. That is right for a two-row edit and wrong
        // for a twenty-row one: the Mac pushes tracks, then albums, then
        // artists, then playlists, then a second pass of artwork updates, and
        // each wave reset the timer. The phone sat waiting through all of it —
        // 15-20 s to see a change the Mac saw in 3-4 s, purely because the
        // Mac's bursts are the bigger ones. The cap bounds that: keep
        // coalescing, but never hold the first event longer than
        // `pullBurstCap`.
        let now = Date()
        let burstStart = pullBurstStart ?? now
        pullBurstStart = burstStart
        let elapsed = Duration.seconds(now.timeIntervalSince(burstStart))
        let wait = min(.milliseconds(800), max(.zero, Self.pullBurstCap - elapsed))

        remotePullTask?.cancel()
        remotePullTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pullBurstStart = nil
            try? await self.sync()
        }
    }

    /// Pushes local edits shortly after they settle, instead of on the minute.
    ///
    /// Driven off the library's own change notification because that is the one
    /// signal every mutation already goes through. It fires during our own
    /// `refresh()` too, which would loop — hence both guards: never while a sync
    /// is running, and never when there is nothing pending to send.
    private func startLocalChangeWatch() {
        // `localChanges`, not `objectWillChange`: the latter also fires for the
        // library republishing itself, which is the tail of every sync — so
        // this watch used to hear its own sync finish and schedule another
        // push. See `LibraryService.localChanges`. The `isSyncing` guard in
        // `scheduleLocalPush` stays as the belt to this braces.
        localChangeWatch = libraryService.localChanges
            .sink { [weak self] _ in self?.scheduleLocalPush() }
    }

    private func scheduleLocalPush() {
        guard currentUser != nil else { return }
        // Before the cancel, not inside the task — the whole point is to not
        // cancel, and a guard on the far side of `localPushTask?.cancel()` runs
        // in the task that has already been killed.
        //
        // This is what produced the wall of "Sync failed: CancellationError()".
        // A sync ends in `libraryService.refresh()`, `refresh()` fires
        // `objectWillChange`, and this watch is subscribed to it — so the sync
        // in flight repeatedly cancelled the very task running it, restarted,
        // and cancelled itself again. Same rule as `scheduleRemotePull`: while
        // a sync is running, hand the request to the loop and leave the task
        // alone.
        //
        // `pendingCount()` is checked *here* as well as in the task, because
        // the flag it would otherwise set makes the running sync start another
        // one the moment it finishes. The library republishes itself at the
        // tail of every sync, this watch hears it, and with nothing pending
        // that was still enough to queue a fresh round — which is where the
        // runs of back-to-back "Sync started" with "0 new, 0 updated" came
        // from. A pull request still sets the flag unconditionally in
        // `scheduleRemotePull`, since a pull is warranted whether or not this
        // device has anything to send.
        if isSyncing {
            if pendingCount() > 0 { syncRequestedWhileBusy = true }
            return
        }
        localPushTask?.cancel()
        localPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.isSyncing { self.syncRequestedWhileBusy = true; return }
            guard self.pendingCount() > 0 else { return }
            try? await self.sync()
        }
    }

    /// Re-establishes the listeners after the app has been asleep.
    ///
    /// The websocket does not survive being backgrounded, and a channel that
    /// looks subscribed but isn't delivers silence rather than an error — so
    /// coming back to the foreground rebuilds both listeners and takes one pull
    /// to cover whatever was missed while away.
    public func resumeRealtime() {
        guard let user = currentUser else { return }
        Task { [weak self] in
            guard let self else { return }
            // Awaited, not fired off beside the subscribe. `setAuth` in a
            // detached task let `subscribe()` win the race, and a socket that
            // subscribes before it has credentials is handed nothing by RLS
            // while still reporting itself subscribed — the same silent failure
            // `onSignIn` documents, arrived at from the other direction.
            //
            // This is why the phone and the Mac behaved differently: the Mac
            // keeps the subscription `onSignIn` made, because it is rarely
            // backgrounded. iOS comes through here on every single foreground.
            if let realtimeToken { await client.realtimeV2.setAuth(realtimeToken) }
            await client.connectRealtimeSocket()
            startRevocationListener(userID: user.id)
            startLibraryListener(userID: user.id)
            onRealtimeReady?(user.id)
            scheduleRemotePull()
        }
    }

    // MARK: - Background Sync

    public func startBackgroundSync(intervalSeconds: TimeInterval) {
        stopBackgroundSync()
        backgroundTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                try? await sync()
            }
        }
    }

    public func stopBackgroundSync() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    // MARK: - Conflict Resolution

    public func resolveConflict(entityID: UUID, resolution: ConflictResolution) async throws {
        switch resolution {
        case .localWins:
            // Re-mark as pending so it gets re-pushed on the next sync.
            markPending(entityID: entityID)
            try context.save()
        case .serverWins:
            // Will be overwritten on the next pull — nothing to do locally.
            break
        }
        try? await sync()
    }

    // MARK: - Push

    /// Encode-and-send, off the main actor.
    ///
    /// This class is `@MainActor`, so the body of every push ran on the thread
    /// that draws — including the JSON encoding of the rows, which for a
    /// twenty-three song push is not small.
    ///
    /// It used `nonisolated async` for this, which was correct under SE-0338 and
    /// is wrong under Swift 6.2's SE-0461: a `nonisolated async` function now
    /// runs **on the caller's actor**, so this never left the main thread.
    /// `Task.detached` inherits no isolation either way, so that is what the
    /// hop is built out of now. Same correction as `LibrarySnapshotReader.read()`
    /// and `compressArtwork`.
    private func upsert<T: Encodable & Sendable>(
        _ rows: [T],
        into table: String,
        onConflict: String? = nil
    ) async throws {
        let client = self.client
        try await Task.detached(priority: .utility) {
            let query = client.from(table)
            if let onConflict {
                try await query.upsert(rows, onConflict: onConflict).execute()
            } else {
                try await query.upsert(rows).execute()
            }
        }.value
    }

    private func pushAll(userID: UUID) async throws {
        try await pushTracks(userID: userID)
        try await pushAlbums(userID: userID)
        try await pushArtists(userID: userID)
        try await pushPlaylists(userID: userID)
        try await pushPlayHistory(userID: userID)
    }

    private func pushTracks(userID: UUID) async throws {
        let pending = try fetchPendingTracks()
        guard !pending.isEmpty else { return }

        print("[Sync] ↑ Pushing \(pending.count) track(s): \(pending.map(\.title).joined(separator: ", "))")
        // FIX: SwiftData may cache entity.isDeleted=false even after softDelete() sets it to true.
        // Explicitly force isDeleted=true for any entity whose syncStatus is "deleted" so the
        // correct tombstone always reaches the server.
        // The moment these rows become visible to the user's other devices, which
        // for a first push is not the same thing as when they were saved.
        let now = Date()
        let rows = pending.map { entity -> TrackRow in
            var row = TrackRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            // Stamp *this* device, not the one that created the row.
            //
            // `TrackRow.init(entity:)` copies `entity.syncDeviceID`, which is
            // the device the song was first saved on. The only consumer of this
            // column is the realtime echo guard in `handleRemoteChange`, and the
            // question it asks is "did I write this?" — so it has to mean the
            // last writer. Copying the creator meant a device pushing an edit to
            // something another device made never recognised its own write and
            // pulled straight back: 19 `📡 Remote change` events in one burst
            // after a single playlist delete.
            row.syncDeviceID = deviceID

            // Every other device pulls incrementally: "rows changed since my last
            // pull". A row carries `updated_at = syncLocalModifiedAt`, the day it
            // was saved — fine for an edit, wrong for a row the server has never
            // held. A song saved last week and first pushed today would arrive
            // stamped last week, behind a cursor those devices moved past days
            // ago, and would simply never be handed over. That is not
            // hypothetical: it is precisely the shape of every online track that
            // sat unpushed while the filter above excluded it.
            //
            // `.localOnly` is exactly "has never reached the server" — a row that
            // has been pushed before is `.modified`, and keeps its real edit time
            // so Last-Write-Wins still means what it says.
            if entity.syncStatus == SyncStatus.localOnly.rawValue {
                row.updatedAt = now
            }
            return row
        }
        // No explicit `onConflict:` — the table's own primary key is the right
        // target, and naming it here would make this line fail outright against a
        // database that hasn't had `20260812120000_tracks_per_user_key` applied
        // yet. Left implicit, it targets whichever key the table actually has and
        // starts keying per-user the moment that migration lands.
        try await upsert(rows, into: "tracks")

        // Hard-delete confirmed deletions from SwiftData so the pull can't re-insert them.
        // Update non-deleted entities to "synced".
        var hardDeletedCount = 0
        var deletedAudioKeys = Set<String>()
        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                if let key = entity.remoteKey, !key.isEmpty { deletedAudioKeys.insert(key) }
                context.delete(entity)
                hardDeletedCount += 1
            } else {
                // Match the timestamp actually sent for a first push, so this
                // device and the server agree on when the row last changed.
                // Left alone, the next pull reads the stamp above as news and
                // rewrites the row with its own unchanged contents.
                if entity.syncStatus == SyncStatus.localOnly.rawValue {
                    entity.syncLocalModifiedAt = now
                }
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
        // The tombstone row has to survive until every device has pulled it, but
        // the audio it points at doesn't — nobody is coming back for a song the
        // user deleted, and the blob is the expensive half by several orders of
        // magnitude. Done after the save so the fetch below sees the real state.
        await deleteOrphanedAudio(keys: deletedAudioKeys)
        if hardDeletedCount > 0 {
            print("[Sync] ↑ Pushed \(pending.count) track(s), hard-deleted \(hardDeletedCount) confirmed deletion(s)")
        } else {
            print("[Sync] ↑ Pushed \(pending.count) track(s)")
        }
    }

    /// Remove uploaded audio for tracks the user has deleted.
    ///
    /// Deleting a song used to leave its file in Storage forever: the only thing
    /// that ever removed a blob was "Clear Everything", and
    /// `FileStorageProtocol.delete(remoteKey:)` had no callers at all. A library
    /// churned through over a year could be paying for gigabytes of audio no row
    /// points at any more.
    ///
    /// Only called for keys whose tombstone has just been accepted by the server,
    /// so the deletion is committed rather than pending.
    private func deleteOrphanedAudio(keys: Set<String>) async {
        guard !keys.isEmpty else { return }

        // Remote paths are content-addressed (`<userID>/<sha256>.<ext>`), so two
        // library rows can share one blob — the same file imported twice, or a
        // song deleted and re-added before this ran. Pulling the file out from
        // under a track that still exists would leave it playable only on
        // whichever device happens to still hold a local copy, which is a far
        // worse failure than an orphaned file, so anything still referenced stays.
        var orphans: [String] = []
        for key in keys {
            let descriptor = FetchDescriptor<TrackEntity>(
                predicate: #Predicate { $0.remoteKey == key && !$0.isSoftDeleted }
            )
            // On a throw, assume the blob is still in use: skipping a delete
            // costs storage, a wrong delete costs the audio.
            let stillReferenced = (try? context.fetchCount(descriptor)) ?? 1
            if stillReferenced == 0 { orphans.append(key) }
        }
        guard !orphans.isEmpty else { return }

        do {
            try await storageRemove(bucket: "audio", paths: orphans)
            print("[Sync] 🗑 Removed \(orphans.count) orphaned audio file(s) from Storage")
        } catch {
            // Not fatal, and not retried: the tombstone is already gone locally,
            // so this key won't come round again. Logged so a persistent failure
            // is visible rather than silently accumulating files.
            print("[Sync] orphaned audio cleanup failed for \(orphans.count) file(s): \(error)")
        }
    }

    private func pushAlbums(userID: UUID) async throws {
        let pending = try fetchPendingAlbums()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> AlbumRow in
            var row = AlbumRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            row.syncDeviceID = deviceID
            return row
        }
        try await upsert(rows, into: "albums")

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                context.delete(entity)
            } else {
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
    }

    private func pushArtists(userID: UUID) async throws {
        let pending = try fetchPendingArtists()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> ArtistRow in
            var row = ArtistRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            row.syncDeviceID = deviceID
            return row
        }
        try await upsert(rows, into: "artists")

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                context.delete(entity)
            } else {
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
    }

    /// Nearly append-only, so this is the simplest push in the file: send what
    /// hasn't been sent, mark it sent. The one edit a row ever gets is its
    /// final `seconds_played`, which re-pends it here and upserts over the
    /// version already up there. Nothing is ever deleted remotely — a pruned
    /// local row is just a row this device stopped keeping, and deleting it
    /// upstream would erase a play the other devices still count.
    private func pushPlayHistory(userID: UUID) async throws {
        let pending = try fetchPendingPlayHistory()
        guard !pending.isEmpty else { return }

        // Chunked, unlike the other pushes: those send what changed since the
        // last sync, this one sends a backlog the first time — as much as the
        // local history keeps — and a single request that size is a
        // timeout rather than a sync.
        for chunk in stride(from: 0, to: pending.count, by: 500) {
            let slice = Array(pending[chunk..<min(chunk + 500, pending.count)])
            var rows = slice.map { PlayHistoryRow(entity: $0, userID: userID) }
            for i in rows.indices { rows[i].syncDeviceID = deviceID }
            try await upsert(rows, into: "play_history")

            for entity in slice {
                entity.syncStatus       = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
            try context.save()
        }
        print("[Sync] ↑ Play history: \(pending.count)")
    }

    private func pushPlaylists(userID: UUID) async throws {
        let pending = try fetchPendingPlaylists()
        guard !pending.isEmpty else { return }

        let rows = pending.map { entity -> PlaylistRow in
            var row = PlaylistRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            row.syncDeviceID = deviceID
            return row
        }
        try await upsert(rows, into: "playlists", onConflict: "id,user_id")

        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                // System playlists (Favourites, All Songs) can never be hard-deleted locally.
                if entity.id == Playlist.favouritesID || entity.id == Playlist.allSongsID {
                    entity.syncStatus       = SyncStatus.synced.rawValue
                    entity.syncLastSyncedAt = Date()
                } else {
                    context.delete(entity)
                }
            } else {
                entity.syncStatus       = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
        print("[Sync] ↑ Playlists: pushed \(pending.count)")
    }

    // MARK: - File Upload
    //
    // Uploads local audio files that haven't been uploaded yet.
    // After each successful upload the track is marked modified so pushTracks
    // syncs the new remoteKey and fileUploaded=true back to the server.

    private func uploadPendingFiles(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingUpload()
        guard !tracks.isEmpty else { return }

        var uploadedAny = false

        var missingFileCount = 0

        for entity in tracks {
            // Bailing out mid-run matters here more than anywhere else in sync:
            // these loops are per-song, and after "Clear Everything" they were
            // still uploading covers for a library that no longer existed.
            guard !shouldStopWork else { return }
            // Verify the local file still exists (it might have been cleared).
            guard let localURL = Self.uploadSourceURL(for: entity) else {
                missingFileCount += 1
                print("[SupabaseSyncService] ⚠️ Local file missing for \"\(entity.title)\" at \(entity.localPath) — skipping upload")
                continue
            }

            let ext        = localURL.pathExtension.lowercased()
            let remotePath = SupabaseFileStorageService.remotePath(
                userID:   userID,
                fileHash: entity.fileHash,
                ext:      ext
            )

            // Check file size on disk before we try to load it.
            let diskSize: Int64
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path(percentEncoded: false))
                diskSize = (attrs[.size] as? Int64) ?? 0
            } catch {
                print("[SupabaseSyncService] ⚠️ Can't stat \"\(entity.title)\": \(error) — skipping")
                continue
            }
            guard diskSize > 0 else {
                print("[SupabaseSyncService] ⚠️ \"\(entity.title)\" is 0 bytes on disk — skipping upload")
                continue
            }
            // If we stored a file size at import time, do a quick sanity check.
            if entity.fileSize > 0 && diskSize < entity.fileSize / 2 {
                print("[SupabaseSyncService] ⚠️ \"\(entity.title)\" disk size (\(diskSize)) is less than half of stored size (\(entity.fileSize)) — file may be truncated, skipping")
                continue
            }

            do {
                // Read file off the main thread — large lossless files can be 100+ MB.
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: localURL)
                }.value

                // Guard against empty or obviously-truncated reads before hitting the network.
                guard data.count > 0 else {
                    print("[SupabaseSyncService] ⚠️ Data read for \"\(entity.title)\" returned 0 bytes — skipping upload")
                    continue
                }
                if diskSize > 0 && Int64(data.count) < diskSize / 2 {
                    print("[SupabaseSyncService] ⚠️ Data read for \"\(entity.title)\" (\(data.count) bytes) is far smaller than file (\(diskSize) bytes) — skipping upload")
                    continue
                }

                let ct = SupabaseFileStorageService.contentType(for: ext)
                try await storageUpload(bucket: "audio", path: remotePath,
                                        data: data, contentType: ct)

                entity.remoteKey           = remotePath
                entity.fileUploaded        = true
                entity.syncStatus          = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[SupabaseSyncService] ✅ Uploaded \"\(entity.title)\" (\(data.count / 1024)KB) → \(remotePath)")

            } catch {
                // Log and skip — will retry on the next sync cycle.
                print("[SupabaseSyncService] ❌ Upload failed for \"\(entity.title)\": \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            // Push again so the server records the updated remoteKey + fileUploaded=true.
            try await pushTracks(userID: userID)
            print("[SupabaseSyncService] ✅ File sync complete — \(tracks.count) file(s) processed")
        } else if missingFileCount > 0 {
            print("[SupabaseSyncService] ⚠️ \(missingFileCount)/\(tracks.count) pending track(s) have missing local files — they cannot be uploaded until the source file is present")
        } else {
            print("[SupabaseSyncService] No pending file uploads")
        }
    }

    /// Where a track's audio actually is on this device.
    ///
    /// `localPath` was once always Documents-relative, and stopped being so as
    /// the audio moved between directories. Resolving it the one way meant every
    /// track imported before a move pointed at a path that no longer existed, so
    /// it was skipped for upload on every single sync — its audio never reached
    /// the server, and no other device (and no re-install) could ever get it
    /// back. The file was on disk the whole time. `AudioPaths` knows them all.
    private static func uploadSourceURL(for entity: TrackEntity) -> URL? {
        AudioPaths.resolve(localPath: entity.localPath)
    }

    /// Tracks whose audio still has to go up.
    ///
    /// Online songs are excluded outright, whatever their row happens to say.
    /// Their audio isn't the user's file — it's something the resolver produced
    /// and can produce again on any device in a few seconds. Uploading it spent
    /// the user's storage quota on a copy nobody needed, and worse, it made the
    /// row look like an imported file from then on, so the app stopped resolving
    /// the song and started insisting on a download that might never arrive.
    private func fetchTracksNeedingUpload() throws -> [TrackEntity] {
        try context.fetch(
            FetchDescriptor<TrackEntity>(
                predicate: #Predicate {
                    $0.fileUploaded == false &&
                    $0.localPath != "" &&
                    $0.isSoftDeleted == false
                }
            )
        ).filter { !$0.resolvedOrigin.isOutsideLibraryStorage }
    }

    // MARK: - Pull

    /// How many rows to ask for at a time.
    ///
    /// PostgREST answers with at most `max-rows` — 1000 on Supabase — whether or
    /// not the query asks for a limit, and it does so *silently*: a truncated
    /// page is indistinguishable from a complete one. Every pull here used to
    /// take that page as the whole answer and then move the last-pull date to
    /// now, which wrote off everything past the cut for good. Deleted rows are
    /// what made it visible: with a thousand old tombstones at the front of the
    /// ordering, a sync could report "0 new, 0 updated, 1000 skipped" while real
    /// songs sat behind them, unseen and now permanently skipped.
    private static let pullPageSize = 500

    /// Reads every row changed since `since`, a page at a time.
    ///
    /// `handle` is called once per page rather than once with everything, so a
    /// large library is never all in memory at once. The caller only advances
    /// its last-pull date after this returns, so a page that fails leaves the
    /// window open and the next sync asks again.
    ///
    /// Ordering is `updated_at` **and then `id`**: `range` pagination needs a
    /// total order, and timestamps tie. Two rows written in the same millisecond
    /// could otherwise swap places between requests, which shows up as one of
    /// them appearing on both pages and the other on neither.
    ///
    /// - Returns: how many rows were read in total.
    @discardableResult
    private func pullPages<Row: Decodable & Sendable>(
        from table: String,
        userID: UUID,
        since: String,
        handle: ([Row]) throws -> Void
    ) async throws -> Int {
        let client = self.client
        let deviceID = self.deviceID
        let pageSize = Self.pullPageSize
        var offset = 0
        while true {
            // The request *and the JSON decode* go off the actor.
            //
            // This read as free — it is one `await` on a network call — and it
            // was not. Under Swift 6.2 (SE-0461) a `nonisolated async` function
            // runs on its caller's actor, and every step of the Supabase chain
            // is one, so decoding a page of rows happened on the thread that
            // draws. That is the `Main thread hang: 2390 ms — in [sync/pull]`.
            //
            // `handle` stays on the main actor deliberately: it writes through
            // `mainContext`, which cannot move.
            let page: [Row] = try await Task.detached(priority: .utility) {
                try await client
                    .from(table)
                    .select()
                    .eq("user_id", value: userID.uuidString)
                    .gt("updated_at", value: since)
                    // Not our own writes.
                    //
                    // The echo guard only ever covered Realtime *events*; the
                    // pull had no filter, so every push came straight back —
                    // "↑ Pushed 24 track(s)" followed by
                    // "↓ Tracks: 0 new, 24 updated", 20 albums and 18 artists,
                    // each one re-applied and each round triggering another
                    // full `library-refresh`. A row this device wrote is a row
                    // this device already has.
                    //
                    // Spelled as an `or` rather than `neq` on purpose: in SQL
                    // `sync_device_id <> 'x'` is NULL for a NULL column, which
                    // would quietly drop every legacy row that predates the
                    // field. A row we wrote and another device later changed
                    // carries *their* id, so it still arrives.
                    .or("sync_device_id.is.null,sync_device_id.neq.\(deviceID)")
                    .order("updated_at")
                    .order("id")
                    .range(from: offset, to: offset + pageSize - 1)
                    .execute()
                    .value
            }.value

            try handle(page)
            offset += page.count

            // A short page is the end of the data. A full one might not be.
            if page.count < pageSize { return offset }
        }
    }

    private func pullAll(userID: UUID) async throws {
        try await pullTracks(userID: userID)
        try await pullAlbums(userID: userID)
        try await pullArtists(userID: userID)
        try await pullPlaylists(userID: userID)
        try await pullPlayHistory(userID: userID)
    }

    private func pullTracks(userID: UUID) async throws {
        let since = lastPullDate(table: "tracks", userID: userID)

        var inserted = 0, updated = 0, skipped = 0
        let total = try await pullPages(from: "tracks", userID: userID, since: since) { (rows: [TrackRow]) in
            let local = existingTracks(ids: rows.map(\.id))
            for row in rows {
                if let existing = local[row.id] {
                    // CRITICAL: Never overwrite a locally-pending deletion with a stale server record.
                    // Check BOTH isSoftDeleted (SwiftData flag) and syncStatus — a SwiftData caching issue
                    // can sometimes leave syncStatus readable but isSoftDeleted stale, so both guards are needed.
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                        // ...but only against a deletion this device still owes
                        // the server, or one the server already agrees with.
                        //
                        // Skipping unconditionally made a local tombstone
                        // permanent: the server's live row could never undelete
                        // it, so the song stayed in this device's "skipped"
                        // count forever — and once `prunePlaylistsOfDeletedTracks`
                        // saw a playlist holding that id, it dropped it and
                        // *pushed the shortened playlist back*. That is how a
                        // 24-song mix became 22 songs on both devices.
                        let deletionPending = existing.syncStatus != SyncStatus.synced.rawValue
                        if row.isDeleted || (deletionPending && existing.syncLocalModifiedAt >= row.updatedAt) {
                            skipped += 1
                            continue
                        }
                        // Fall through: the server's row is live and newer, so
                        // `apply(to:)` clears `isSoftDeleted` and the song comes
                        // back.
                    }
                    // A tombstone older than the local row's own import is not news —
                    // it is the record of a deletion this track has already outlived.
                    //
                    // Track ids are deterministic for anything saved from Discover
                    // (`OnlineTrack.stableID` hashes title + artist), so deleting a
                    // song and saving it again reuses the id the server has a
                    // tombstone under. Incremental pulls never revisit that row, so
                    // nothing goes wrong until a full re-sync asks for every record
                    // ever written and hands the tombstone back — at which point the
                    // unconditional branch below deleted a song the user had been
                    // playing for days, and the only visible trace was a playlist
                    // header counting more songs than it could show.
                    //
                    // Pushing it back is what stops the same re-sync doing it again:
                    // the server row is still `is_deleted` until this device says
                    // otherwise.
                    if row.isDeleted, existing.dateImported > row.updatedAt {
                        if existing.syncStatus == SyncStatus.synced.rawValue {
                            existing.syncStatus = SyncStatus.modified.rawValue
                            existing.syncLocalModifiedAt = Date()
                        }
                        skipped += 1
                        continue
                    }
                    // Last-Write-Wins — but always apply a server deletion regardless of timestamp
                    // to prevent clock-skew from blocking deletes from other devices.
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        row.apply(to: existing)
                        updated += 1
                    }
                } else {
                    // Don't create a local entity for a server record that's already deleted —
                    // there's nothing useful to do with it and it would be invisible to the UI anyway.
                    guard !row.isDeleted else { skipped += 1; continue }
                    context.insert(TrackEntity(from: row))
                    inserted += 1
                }
            }
            // Saved per page rather than once at the end: an interrupted pull
            // should leave the pages it did read on disk.
            try context.save()
        }

        guard total > 0 else {
            print("[Sync] ↓ Tracks: nothing new since last pull")
            setLastPullDate(table: "tracks", userID: userID)
            return
        }

        setLastPullDate(table: "tracks", userID: userID)
        if inserted + updated > 0 { didWriteLocally = true; announceWork() }
        print("[Sync] ↓ Tracks: \(inserted) new, \(updated) updated, \(skipped) skipped")
    }

    private func pullAlbums(userID: UUID) async throws {
        let since = lastPullDate(table: "albums", userID: userID)

        var inserted = 0, updated = 0
        let total = try await pullPages(from: "albums", userID: userID, since: since) { (rows: [AlbumRow]) in
            let local = existingAlbums(ids: rows.map(\.id))
            for row in rows {
                if let existing = local[row.id] {
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue { continue }
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        row.apply(to: existing)
                        updated += 1
                    }
                } else {
                    guard !row.isDeleted else { continue }
                    context.insert(AlbumEntity(from: row))
                    inserted += 1
                }
            }
            try context.save()
        }
        if inserted + updated > 0 { didWriteLocally = true; announceWork() }
        if total > 0 {
            print("[Sync] ↓ Albums: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "albums", userID: userID)
    }

    private func pullArtists(userID: UUID) async throws {
        let since = lastPullDate(table: "artists", userID: userID)

        var inserted = 0, updated = 0
        let total = try await pullPages(from: "artists", userID: userID, since: since) { (rows: [ArtistRow]) in
            let local = existingArtists(ids: rows.map(\.id))
            // `ArtistEntity.name` is `@Attribute(.unique)`, so an insert that
            // collides with a name already here is not an insert — SwiftData
            // upserts it, and the row that was there loses everything the new
            // one doesn't carry, artwork included. Two devices that each made
            // their own row for the same artist is enough to trigger it, and
            // the result was a cover downloaded on every launch and wiped
            // again by the next pull, forever.
            let byName = existingArtists(names: rows.map(\.name))
            for row in rows {
                if let existing = local[row.id] ?? byName[row.name] {
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue { continue }
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        row.apply(to: existing)
                        updated += 1
                    }
                } else {
                    guard !row.isDeleted else { continue }
                    context.insert(ArtistEntity(from: row))
                    inserted += 1
                }
            }
            try context.save()
        }
        if inserted + updated > 0 { didWriteLocally = true; announceWork() }
        if total > 0 {
            print("[Sync] ↓ Artists: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "artists", userID: userID)
    }

    /// Insert-only, and deliberately unfiltered by track: a play for a song
    /// this device hasn't pulled yet still counts, and the stats aggregator
    /// already ignores ids it can't resolve. Filtering here would silently drop
    /// the history of anything that syncs after it.
    private func pullPlayHistory(userID: UUID) async throws {
        let since = lastPullDate(table: "play_history", userID: userID)

        var inserted = 0
        let total = try await pullPages(from: "play_history", userID: userID, since: since) { (rows: [PlayHistoryRow]) in
            let known = existingPlayHistoryIDs(ids: rows.map(\.id))
            for row in rows where !row.isDeleted && !known.contains(row.id) {
                context.insert(row.entity())
                inserted += 1
            }
            try context.save()
        }
        if inserted > 0 {
            didWriteLocally = true
            announceWork()
            print("[Sync] ↓ Play history: \(inserted) new")
        }
        if total > 0 { setLastPullDate(table: "play_history", userID: userID) }
    }

    private func pullPlaylists(userID: UUID) async throws {
        let since = lastPullDate(table: "playlists", userID: userID)

        var inserted = 0, updated = 0, skipped = 0
        var favouritesTrackIDs: [UUID]? = nil   // set if Favourites was updated

        let total = try await pullPages(from: "playlists", userID: userID, since: since) { (rows: [PlaylistRow]) in
            let local = existingPlaylists(ids: rows.map(\.id))
            for row in rows {
                if let existing = local[row.id] {
                    // All Songs is a locally-derived smart playlist. Never pull it.
                    if row.id == Playlist.allSongsID {
                        skipped += 1
                        continue
                    }

                    // Never overwrite a locally-pending deletion with a stale
                    // server record — but only a deletion this device still owes
                    // the server, or one the server already agrees with. This is
                    // the same correction `pullTracks` above already carries, and
                    // it was missing here for the same reason it mattered there:
                    // a playlist id is not always random.
                    //
                    // A saved mix takes a *deterministic* id derived from the mix
                    // and its track list (`PersonalMix.savedPlaylistID`), so both
                    // devices mint the same uuid for the same mix. Skipping
                    // unconditionally therefore made one device's old deletion
                    // permanent: save a mix on the Mac and the phone — which had
                    // saved and deleted that same mix at some point — silently
                    // dropped the row on every pull, forever, across restarts.
                    // The songs still arrived (they sync on their own table),
                    // which is why the count moved while the mix never appeared.
                    let deletionPending = existing.syncStatus != SyncStatus.synced.rawValue
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                        if row.isDeleted || (deletionPending && existing.syncLocalModifiedAt >= row.updatedAt) {
                            skipped += 1
                            continue
                        }
                        // Fall through: the server's row is live and newer, so
                        // `apply(to:)` clears `isSoftDeleted` and the playlist
                        // comes back.
                    }
                    // LWW — but always apply server deletion regardless of timestamp.
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        // `apply(to:)` drops the local blob when the other
                        // device deleted the cover. Nothing downstream hears
                        // about that on its own, which is why a cover deleted
                        // on the phone vanished from the playlist page here and
                        // stayed in the sidebar: the page asks the library,
                        // the sidebar draws a cached image.
                        let hadCover = existing.artworkData != nil
                        row.apply(to: existing)
                        if hadCover != (existing.artworkData != nil) {
                            libraryService.noteCoverChanged(playlistID: existing.id)
                        }
                        updated += 1
                        if row.id == Playlist.favouritesID {
                            favouritesTrackIDs = row.trackIDs
                        }
                    }
                } else {
                    guard !row.isDeleted else { skipped += 1; continue }
                    if row.id == Playlist.allSongsID { skipped += 1; continue }
                    context.insert(PlaylistEntity(from: row))
                    inserted += 1
                    if row.id == Playlist.favouritesID {
                        favouritesTrackIDs = row.trackIDs
                    }
                }
            }
            try context.save()
        }

        setLastPullDate(table: "playlists", userID: userID)
        guard total > 0 else { return }

        // Rebuild FavoriteEntity records if Favourites track_ids changed.
        // This keeps heart state consistent across devices without a separate sync.
        if let ids = favouritesTrackIDs {
            let favRepo = FavoriteRepository()
            try favRepo.rebuildFromIDs(ids, deviceID: deviceID)
        }

        if inserted + updated > 0 { didWriteLocally = true; announceWork() }
        print("[Sync] ↓ Playlists: \(inserted) new, \(updated) updated, \(skipped) skipped")
    }

    // MARK: - Pending Count

    /// The exact number of rows this device owes the server. Drives the
    /// user-visible pending count, so it pays for the Swift-side filters —
    /// `isPushable` in particular, which is why a stuck non-pushable row reads
    /// as zero here rather than sitting in the UI forever.
    private func pendingCount() -> Int {
        let tracks    = (try? fetchPendingTracks())?.count    ?? 0
        let albums    = (try? fetchPendingAlbums())?.count    ?? 0
        let artists   = (try? fetchPendingArtists())?.count   ?? 0
        let playlists = (try? fetchPendingPlaylists())?.count ?? 0
        let plays     = (try? fetchPendingPlayHistory())?.count ?? 0
        return tracks + albums + artists + playlists + plays
    }

    // A cheap `fetchCount` version of the above lived here and was wrong on
    // exactly this library. It skipped the Swift-side `isPushable` filter, so
    // the stuck non-pushable rows cause F found made it permanently true — which
    // meant `hadPendingWork` was permanently true, the backlog gate never
    // engaged once, and the eight artwork scans went on running every minute
    // while the log said the gate was in place. The exact count is four fetches
    // of a set that is nearly always empty; that is the cheap option here.

    // MARK: - SwiftData Helpers

    private func fetchPendingPlaylists() throws -> [PlaylistEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.syncStatus != synced })
        ).filter { $0.id != Playlist.allSongsID }
    }

    private func fetchPlaylistEntity(id: UUID) throws -> PlaylistEntity? {
        try context.fetch(
            FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchPendingPlayHistory() throws -> [PlayHistoryEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<PlayHistoryEntity>(predicate: #Predicate { $0.syncStatus != synced })
        )
    }

    private func existingPlayHistoryIDs(ids: [UUID]) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<PlayHistoryEntity>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        return Set((try? context.fetch(descriptor))?.map(\.id) ?? [])
    }

    private func fetchPendingTracks() throws -> [TrackEntity] {
        let synced = SyncStatus.synced.rawValue
        // Which rows are *ours to write* is decided in Swift rather than in the
        // predicate: it needs `resolvedOrigin`, which falls back to reading a
        // legacy row's shape when `originRaw` predates the column, and none of
        // that survives translation into a #Predicate.
        return try context.fetch(
            FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.syncStatus != synced })
        ).filter(Self.isPushable)
    }

    /// Whether a pending track is this user's to push.
    ///
    /// The one row that must never go up is the shadow minted for a song in a
    /// *shared* playlist this user doesn't own: it carries the original owner's
    /// track id, so upserting it into our `tracks` table violates the RLS USING
    /// policy (42501) and takes the whole sync down with it.
    ///
    /// That exclusion used to be spelled "has no file, so don't push it", which
    /// was only ever a stand-in for "isn't ours" — and it swept up every song
    /// saved from Discover, because an online row is *defined* by having no
    /// bytes: no localPath, no remoteKey, and no syncServerID until a push it
    /// was being excluded from finally happened. Those rows sat on the device
    /// that saved them while their playlists synced perfectly, so a second
    /// device showed a playlist counting 16 songs and listing none of them.
    private static func isPushable(_ entity: TrackEntity) -> Bool {
        switch entity.resolvedOrigin {
        case .unresolvableShare:
            return false
        case .online:
            // Metadata only, and that metadata is the entire point: `source_ref`
            // is what lets another device resolve the audio for itself.
            return true
        case .localFile:
            // Never reached — watched-folder rows are derived and never saved —
            // but the answer has to be no. Pushing one would give every other
            // device a row pointing at a path that exists on this machine only.
            return false
        case .imported:
            // A genuine local import always has a localPath; a previously-synced
            // track keeps its syncServerID, so metadata-only edits still sync.
            // `remoteKey` is the third way in, and it matters for a song this
            // device once uploaded and no longer keeps a local copy of: no
            // localPath, and syncServerID is only ever set by a push that may
            // never have happened. Those rows were being filtered out of their
            // own corrections.
            return entity.localPath != "" || entity.syncServerID != nil || entity.remoteKey != nil
        }
    }

    private func fetchPendingAlbums() throws -> [AlbumEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<AlbumEntity>(predicate: #Predicate { $0.syncStatus != synced })
        )
    }

    private func fetchPendingArtists() throws -> [ArtistEntity] {
        let synced = SyncStatus.synced.rawValue
        return try context.fetch(
            FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.syncStatus != synced })
        )
    }

    // MARK: - Batch lookups for pulls
    //
    // A pull page is up to `pullPageSize` rows and every one of them has to be
    // matched against the local store. Doing that with `fetchTrackEntity(id:)`
    // inside the loop is one round trip per row — a thousand fetches to apply a
    // thousand-row page. These do it in one, and the loops index the result.
    //
    // Rows within a page are unique by primary key, and every page is saved
    // before the next is read, so nothing inserted by the loop needs to be
    // visible to its own lookup table.

    private func existingTracks(ids: [UUID]) -> [UUID: TrackEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<TrackEntity>(predicate: #Predicate { ids.contains($0.id) })
        // Only the id is prefetched: the pull reads a handful of scalars off
        // each row and never its cover, and asking for the full row here pulled
        // every artwork blob in the library into memory on every sync — 232 MB
        // of the launch footprint, for a comparison of timestamps.
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func existingAlbums(ids: [UUID]) -> [UUID: AlbumEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<AlbumEntity>(predicate: #Predicate { ids.contains($0.id) })
        // Only the id is prefetched: the pull reads a handful of scalars off
        // each row and never its cover, and asking for the full row here pulled
        // every artwork blob in the library into memory on every sync — 232 MB
        // of the launch footprint, for a comparison of timestamps.
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func existingArtists(ids: [UUID]) -> [UUID: ArtistEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<ArtistEntity>(predicate: #Predicate { ids.contains($0.id) })
        // Only the id is prefetched: the pull reads a handful of scalars off
        // each row and never its cover, and asking for the full row here pulled
        // every artwork blob in the library into memory on every sync — 232 MB
        // of the launch footprint, for a comparison of timestamps.
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    /// The same lookup by the other unique key. Used to catch a pulled row
    /// whose id is new but whose name is already spoken for.
    private func existingArtists(names: [String]) -> [String: ArtistEntity] {
        guard !names.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<ArtistEntity>(predicate: #Predicate { names.contains($0.name) })
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.name, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func existingPlaylists(ids: [UUID]) -> [UUID: PlaylistEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<PlaylistEntity>(predicate: #Predicate { ids.contains($0.id) })
        // Only the id is prefetched: the pull reads a handful of scalars off
        // each row and never its cover, and asking for the full row here pulled
        // every artwork blob in the library into memory on every sync — 232 MB
        // of the launch footprint, for a comparison of timestamps.
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func fetchTrackEntity(id: UUID) throws -> TrackEntity? {
        try context.fetch(
            FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchAlbumEntity(id: UUID) throws -> AlbumEntity? {
        try context.fetch(
            FetchDescriptor<AlbumEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func fetchArtistEntity(id: UUID) throws -> ArtistEntity? {
        try context.fetch(
            FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func markPending(entityID: UUID) {
        if let entity = try? fetchTrackEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        } else if let entity = try? fetchAlbumEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        } else if let entity = try? fetchArtistEntity(id: entityID) {
            entity.syncStatus = SyncStatus.modified.rawValue
        }
    }

    // MARK: - Delete All Server Data

    /// Wipes every track/album/artist row AND every audio file for the current
    /// user from Supabase. DB rows are soft-deleted (is_deleted = true, updated_at = now())
    /// so that every other device's incremental pull picks up the change and clears
    /// its local library automatically on the next sync cycle.
    public func deleteAllServerData() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        let uid = userID.uuidString
        let now = iso8601Now()

        print("[Sync] 🗑  Soft-deleting all server data for user \(uid)…")

        // 1. Soft-delete DB rows — set is_deleted = true and bump updated_at so
        //    other devices' incremental pull picks up the change.
        //
        //    Live rows only. Without the `is_deleted = false` filter this also
        //    re-stamps `updated_at` on every tombstone the account has ever
        //    accumulated, however old — a deletion from two years ago becomes
        //    "deleted today". Nothing needs that: the original stamp is still
        //    newer than any un-synced device's last-pull date, so the signal has
        //    already been sent. What it does instead is reset the clock the
        //    tombstone pruner reads, so a library that wipes now and then can
        //    never prune anything and pays to pull its whole deletion history on
        //    every sync forever.
        let wipe = WipePayload(updatedAt: now)
        try await client.from("tracks")   .update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        print("[Sync] 🗑  Soft-deleted tracks")
        try await client.from("albums")   .update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        print("[Sync] 🗑  Soft-deleted albums")
        try await client.from("artists")  .update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        print("[Sync] 🗑  Soft-deleted artists")
        try await client.from("playlists").update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        print("[Sync] 🗑  Soft-deleted playlists")

        // 2. Hard-delete audio files from Storage (non-fatal if this fails).
        //    Files don't need a deletion signal — once is_deleted propagates, the
        //    library is empty and the orphaned files are unreachable.
        let folder = userID.uuidString.lowercased()
        do {
            let files = try await storageList(bucket: "audio", path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await storageRemove(bucket: "audio", paths: paths)
                print("[Sync] 🗑  Deleted \(paths.count) audio file(s) from Storage")
            } else {
                print("[Sync] 🗑  No audio files in Storage for this user")
            }
        } catch {
            print("[Sync] ⚠️  Storage delete failed (non-fatal): \(error)")
        }

        print("[Sync] 🗑  Server wipe complete")
    }

    // MARK: - Reset

    /// Soft-deletes all tracks, albums, and artists for this user on the server.
    /// Playlists are left intact (their trackID arrays will be emptied locally).
    /// Also hard-deletes audio files from Storage.
    /// Hard-deletes the account's play history on the server.
    ///
    /// Hard, not soft, unlike the library wipes above: a tombstone exists so
    /// other devices learn a row is gone, and every device that could learn it
    /// is being told the same thing by the same button. Plays are also the one
    /// table with no local edits to lose.
    public func deleteAllServerPlayHistory() async throws {
        guard let userID = currentUser?.id else { return }
        try await client.from("play_history")
            .delete()
            .eq("user_id", value: userID.uuidString)
            .execute()
        print("[Sync] 🗑  Deleted server play history for \(userID.uuidString)")
    }

    public func deleteAllServerTracks() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        try await client.from("tracks") .update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        try await client.from("albums") .update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        try await client.from("artists").update(wipe).eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        print("[Sync] 🗑  Soft-deleted all server tracks/albums/artists for \(uid)")

        // Remove audio files from Storage (non-fatal).
        let folder = uid.lowercased()
        do {
            let files = try await storageList(bucket: "audio", path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await storageRemove(bucket: "audio", paths: paths)
                print("[Sync] 🗑  Deleted \(paths.count) audio file(s) from Storage")
            }
        } catch {
            print("[Sync] ⚠️  Storage delete failed (non-fatal): \(error)")
        }
    }

    /// Soft-deletes all user-created playlists on the server.
    /// The two system playlists (All Songs, Favourites) are left untouched.
    public func deleteAllServerUserPlaylists() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        // Exclude the two system playlists by their stable UUIDs.
        try await client.from("playlists")
            .update(wipe)
            .eq("user_id", value: uid)
            // Already-deleted rows are left alone — see the note in
            // `deleteAllServerData`.
            .eq("is_deleted", value: false)
            .neq("id", value: Playlist.favouritesID.uuidString.lowercased())
            .neq("id", value: Playlist.allSongsID.uuidString.lowercased())
            .execute()
        print("[Sync] 🗑  Soft-deleted all server user playlists for \(uid)")
    }

    /// Clears the stored pull timestamps so the next sync performs a full pull
    /// from the beginning of time. Call this after clearing the local library.
    ///
    /// Takes the user explicitly because `currentUser` is the wrong answer at
    /// both call sites: on sign-out it has already been set to nil, and on an
    /// account switch the incoming user isn't set until the async sign-in lands
    /// a beat later. So this silently reset nobody, and a freshly-emptied store
    /// went on pulling incrementally against a months-old timestamp — the server
    /// still had every row, the client just stopped asking for them.
    public func resetSyncTimestamps(for explicitUserID: UUID? = nil) {
        guard let userID = explicitUserID ?? currentUser?.id else { return }
        for table in ["tracks", "albums", "artists", "playlists"] {
            UserDefaults.standard.removeObject(forKey: lastPullDateKey(table: table, userID: userID))
        }
        print("[SupabaseSyncService] Sync timestamps reset — next pull will fetch all server records")
    }

    // MARK: - Last Pull Timestamps (per table per user, stored in UserDefaults)

    private func lastPullDateKey(table: String, userID: UUID) -> String {
        "mix.sync.\(table).lastPull.\(userID.uuidString)"
    }

    /// How far back of an already-pulled window each pull re-reads.
    ///
    /// `updated_at` is stamped by the pushing device, so a device whose clock
    /// runs slow can write a row with a timestamp below our watermark and be
    /// missed forever. The overlap is the guard against that — but it was 24
    /// hours, which meant every sync re-fetched and re-decoded every row
    /// touched in the last day only to discard it: a steady
    /// "0 new, 0 updated, 218 skipped" on tracks, 16 on playlists, and two
    /// artists reported as updated on every single sync with nothing actually
    /// changing. Five minutes covers real device clock drift and costs
    /// essentially nothing.
    private static let pullOverlap: TimeInterval = 300

    /// Returns a very old date if we've never pulled, so the first pull fetches everything.
    private func lastPullDate(table: String, userID: UUID) -> String {
        let key = lastPullDateKey(table: table, userID: userID)
        if let stored = UserDefaults.standard.string(forKey: key) {
            // Apply a 24-hour overlap window to catch clock-skewed pushes from other devices.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: stored) {
                return f.string(from: date.addingTimeInterval(-Self.pullOverlap))
            }
            return stored
        }
        return "1970-01-01T00:00:00.000Z"
    }

    private func setLastPullDate(table: String, userID: UUID) {
        let key = lastPullDateKey(table: table, userID: userID)
        UserDefaults.standard.set(iso8601Now(), forKey: key)
    }

    private func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Artwork Sync

    private func uploadPendingArtworks(userID: UUID) async throws {
        try await uploadPendingTrackArtworks(userID: userID)
        try await uploadPendingAlbumArtworks(userID: userID)
        try await uploadPendingArtistArtworks(userID: userID)
        try await uploadPendingPlaylistArtworks(userID: userID)
    }

    /// Playlist covers, which travel by path rather than by column.
    ///
    /// Tracks, albums and artists each carry an `artwork_key` on their row, so
    /// the other device learns where the image is from the row itself. The
    /// playlists table has no such column, and adding one means a migration —
    /// so this leg uses the fact that the path is already knowable: both
    /// devices have the user id and the playlist id, and
    /// `<userID>/playlists/<playlistID>.jpg` is built from nothing else. The
    /// local `artworkKey` is only a note to self that the file has been sent.
    private func uploadPendingPlaylistArtworks(userID: UUID) async throws {
        try await deletePendingPlaylistArtworks(userID: userID)

        let playlists = try fetchPlaylistsNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(playlists.count) playlist(s) needing artwork upload")
        guard !playlists.isEmpty else { return }

        var uploadedAny = false
        for entity in playlists {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for playlist artwork: \(entity.name)")
                continue
            }

            let remotePath = Self.playlistArtworkPath(userID: userID, playlistID: entity.id)
            do {
                try await storageUpload(bucket: "artwork", path: remotePath,
                                        data: compressed, contentType: "image/jpeg")

                entity.artworkKey = remotePath
                // Ours is now the file in the bucket, so the next listing must
                // not read as "someone changed this".
                entity.artworkRemoteStamp = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded playlist artwork: \(entity.name) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for playlist artwork (\(entity.name)): \(error)")
            }
        }

        // No re-push, unlike the other three: `artworkKey` never leaves this
        // device, so the row the server holds hasn't changed.
        if uploadedAny {
            try context.save()
        }
    }

    /// Removes covers the user threw away from the bucket.
    ///
    /// The counterpart of the upload, and the reason a deletion sticks. Deleting
    /// a cover clears the local blob but the object stays in
    /// `<userID>/playlists/`, and `downloadPendingPlaylistArtworks` lists that
    /// folder — so without this the very next sync hands the deleted picture
    /// back, which reads as the delete having silently failed.
    private func deletePendingPlaylistArtworks(userID: UUID) async throws {
        let doomed = try context.fetch(
            FetchDescriptor<PlaylistEntity>(
                predicate: #Predicate { $0.artworkNeedsRemoteDelete == true }
            )
        )
        guard !doomed.isEmpty else { return }

        var changed = false
        for entity in doomed {
            guard !shouldStopWork else { return }
            let path = Self.playlistArtworkPath(userID: userID, playlistID: entity.id)
            do {
                try await storageRemove(bucket: "artwork", paths: [path])
                print("[Sync] 🗑️ Removed playlist artwork: \(entity.name)")
            } catch {
                // A cover that was never uploaded has nothing to remove, and the
                // flag must still come down or every sync retries the same
                // missing path forever.
                print("[Sync] Playlist artwork remove failed (treating as gone): \(error)")
            }
            entity.artworkNeedsRemoteDelete = false
            changed = true
        }
        if changed { try context.save() }
    }

    private func uploadPendingTrackArtworks(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(tracks.count) track(s) needing artwork upload")
        guard !tracks.isEmpty else { return }

        var uploadedAny = false
        for entity in tracks {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for track artwork: \(entity.title)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/tracks/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await storageUpload(bucket: "artwork", path: remotePath,
                                        data: compressed, contentType: "image/jpeg")

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded track artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for track artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushTracks(userID: userID)
        }
    }

    private func uploadPendingAlbumArtworks(userID: UUID) async throws {
        let albums = try fetchAlbumsNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(albums.count) album(s) needing artwork upload")
        guard !albums.isEmpty else { return }

        var uploadedAny = false
        for entity in albums {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for album artwork: \(entity.title)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/albums/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await storageUpload(bucket: "artwork", path: remotePath,
                                        data: compressed, contentType: "image/jpeg")

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded album artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for album artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushAlbums(userID: userID)
        }
    }

    private func uploadPendingArtistArtworks(userID: UUID) async throws {
        let artists = try fetchArtistsNeedingArtworkUpload()
        print("[Sync] 🖼️ Found \(artists.count) artist(s) needing artwork upload")
        guard !artists.isEmpty else { return }

        var uploadedAny = false
        for entity in artists {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                print("[Sync] ⚠️ Compression failed for artist artwork: \(entity.name)")
                continue
            }

            let remotePath = "\(userID.uuidString.lowercased())/artists/\(entity.id.uuidString.lowercased()).jpg"
            do {
                try await storageUpload(bucket: "artwork", path: remotePath,
                                        data: compressed, contentType: "image/jpeg")

                entity.artworkKey = remotePath
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                print("[Sync] ✅ Uploaded artist artwork: \(entity.name) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                print("[Sync] ❌ Upload failed for artist artwork (\(entity.name)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushArtists(userID: userID)
        }
    }

    /// How many artwork objects one sync run may ask the bucket for.
    ///
    /// A library of a few thousand rows with no covers uploaded yet would
    /// otherwise fire a few thousand requests every single run. Whatever the
    /// budget doesn't reach this time is picked up by the next sync.
    private static let artworkDownloadBudget = 150

    /// Remaining requests in this run, shared by all four artwork kinds.
    private var artworkDownloadsLeft = 0

    /// Whether this run put anything in the disk cache worth trimming for.
    private var artworkCacheGrew = false

    /// A cover: from the disk cache if it's there, from the bucket if it isn't.
    ///
    /// `nil` means the run is out of requests, not that the cover is missing —
    /// callers stop asking. Only a miss spends one: the budget exists to keep a
    /// coverless library from firing thousands of requests per run, and a read
    /// off this device's own disk is none of those. That's what makes signing
    /// back in fast instead of fifteen sync runs slow.
    ///
    /// ponytail: a cache hit is unbounded, so a returning user restores every
    /// cover in one pass — each row still awaits, so the UI fills in rather
    /// than freezing. Cap it like the download budget if that pass ever bites.
    private func artwork(at key: String, stamp: Date? = nil) async throws -> Data? {
        if let hit = await Task.detached(priority: .utility, operation: {
            ArtworkDiskCache.data(for: key, stamp: stamp)
        }).value {
            return hit
        }
        guard artworkDownloadsLeft > 0 else { return nil }
        artworkDownloadsLeft -= 1
        let data = try await storageDownload(bucket: "artwork", path: key)
        ArtworkDiskCache.store(data, for: key, stamp: stamp)
        artworkCacheGrew = true
        return data
    }

    /// A dead pointer: the row names a bucket object that isn't there.
    ///
    /// It will 404 identically on every future sync, so the key is cleared and
    /// the row drops out of `fetch…NeedingArtworkDownload`. Nothing is lost —
    /// the row has no local artwork either, and the moment it gets some, the
    /// upload pass (`artworkKey == nil && artworkData != nil`) writes the
    /// object and sets a key that does resolve.
    private func isMissingObject(_ error: Error) -> Bool {
        guard let storage = error as? StorageError else { return false }
        return storage.statusCode == "404" || storage.error == "not_found"
    }

    // MARK: - Storage, off the main actor

    // Same rule as `pullPages`: every step of the Supabase chain is a
    // `nonisolated async` function, and under Swift 6.2 (SE-0461) those run on
    // the *caller's* actor rather than the generic executor. These are called
    // from a `@MainActor` class, so the request, the response and the image
    // bytes were all being handled on the thread that draws — the
    // `Main thread hang: 1517 ms — in [sync/download-artwork]` on launch.
    // `Task.detached` around a closure that carries no isolation of its own is
    // what actually gets off.

    private func storageDownload(bucket: String, path: String) async throws -> Data {
        let client = self.client
        return try await Task.detached(priority: .utility) {
            try await client.storage.from(bucket).download(path: path)
        }.value
    }

    private func storageUpload(bucket: String, path: String,
                               data: Data, contentType: String) async throws {
        let client = self.client
        try await Task.detached(priority: .utility) {
            _ = try await client.storage.from(bucket).upload(
                path, data: data,
                options: FileOptions(contentType: contentType, upsert: true))
        }.value
        // A cover this device sent is a cover it will otherwise fetch back from
        // the bucket the next time the store is dropped. Playlists are left out
        // on purpose — see `ArtworkDiskCache`.
        if bucket == "artwork", !path.contains("/playlists/") {
            ArtworkDiskCache.store(data, for: path)
            artworkCacheGrew = true
        }
    }

    private func storageList(bucket: String, path: String,
                             limit: Int? = nil) async throws -> [FileObject] {
        let client = self.client
        return try await Task.detached(priority: .utility) {
            if let limit {
                return try await client.storage.from(bucket)
                    .list(path: path, options: SearchOptions(limit: limit))
            }
            return try await client.storage.from(bucket).list(path: path)
        }.value
    }

    private func storageRemove(bucket: String, paths: [String]) async throws {
        let client = self.client
        try await Task.detached(priority: .utility) {
            _ = try await client.storage.from(bucket).remove(paths: paths)
        }.value
    }

    private func downloadPendingArtworks(userID: UUID) async throws {
        artworkDownloadsLeft = Self.artworkDownloadBudget
        defer {
            if artworkCacheGrew {
                artworkCacheGrew = false
                Task.detached(priority: .background) { ArtworkDiskCache.trim() }
            }
        }
        try await downloadPendingTrackArtworks(userID: userID)
        try await downloadPendingAlbumArtworks(userID: userID)
        try await downloadPendingArtistArtworks(userID: userID)
        try await downloadPendingPlaylistArtworks(userID: userID)
    }

    /// The other side of `uploadPendingPlaylistArtworks`.
    ///
    /// Because there's no key on the row, this asks the bucket what's actually
    /// in `<userID>/playlists/` — one request — instead of guessing a path per
    /// coverless playlist and collecting a 404 for each. Plenty of playlists
    /// legitimately have no cover, so guessing would mean the same failures on
    /// every sync, forever.
    private func downloadPendingPlaylistArtworks(userID: UUID) async throws {
        let playlists = try fetchPlaylistsNeedingArtworkDownload()
        guard !playlists.isEmpty else { return }

        let folder = "\(userID.uuidString.lowercased())/playlists"
        let remote: [String: Date?]
        do {
            let files = try await storageList(bucket: "artwork", path: folder, limit: 1000)
            // The listing is the only thing that knows when each cover was last
            // written, and one call covers every playlist — so it decides what
            // to fetch, rather than the rows guessing.
            remote = Dictionary(files.map { ($0.name, $0.updatedAt) },
                                uniquingKeysWith: { a, _ in a })
        } catch {
            print("[Sync] ❌ Could not list playlist artwork in \(folder): \(error)")
            return
        }

        let wanted = playlists.filter { entity in
            guard let stamp = remote["\(entity.id.uuidString.lowercased()).jpg"] else { return false }
            // No cover here yet, or the bucket's is not the one we last took.
            // A missing date on either side falls back to fetching once.
            guard entity.artworkData != nil, let local = entity.artworkRemoteStamp,
                  let stamp else { return true }
            return stamp > local
        }
        print("[Sync] 🖼️ Found \(wanted.count) playlist(s) needing artwork download")
        guard !wanted.isEmpty else { return }

        var downloadedAny = false
        for entity in wanted {
            guard !shouldStopWork else { return }
            let key = Self.playlistArtworkPath(userID: userID, playlistID: entity.id)
            let stamp = remote["\(entity.id.uuidString.lowercased()).jpg"] ?? nil
            do {
                guard let data = try await artwork(at: key, stamp: stamp) else {
                    print("[Sync] ⏸ Artwork download budget spent — the rest wait for the next sync")
                    break
                }

                entity.artworkData  = data
                // Set so the upload pass doesn't turn round and send back what
                // it just received.
                entity.artworkKey = key
                entity.artworkRemoteStamp = stamp ?? Date()
                libraryService.noteCoverChanged(playlistID: entity.id)
                downloadedAny = true
                print("[Sync] ↓ Downloaded playlist artwork: \(entity.name) (\(data.count / 1024)KB) from \(key)")
            } catch {
                print("[Sync] ❌ Download failed for playlist artwork (\(entity.name)) from \(key): \(error)")
            }
        }

        // The `libraryService.refresh()` at the end of `sync()` is what puts
        // these on screen.
        if downloadedAny {
            didWriteLocally = true
            try context.save()
        }
    }

    static func playlistArtworkPath(userID: UUID, playlistID: UUID) -> String {
        "\(userID.uuidString.lowercased())/playlists/\(playlistID.uuidString.lowercased()).jpg"
    }

    private func downloadPendingTrackArtworks(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(tracks.count) track(s) needing artwork download")
        guard !tracks.isEmpty else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in tracks {
            guard !shouldStopWork else { return }
            guard let key = entity.artworkKey, !key.isEmpty else { continue }
            do {
                guard let data = try await artwork(at: key) else {
                    print("[Sync] ⏸ Artwork download budget spent — the rest wait for the next sync")
                    break
                }

                entity.artworkData = data
                // Name the row, so the refresh at the end of this sync drops
                // this cover's cached image and nothing else's.
                libraryService.noteArtworkChanged(.track(entity.id))
                downloadedAny = true
                print("[Sync] ↓ Downloaded track artwork: \(entity.title) (\(data.count / 1024)KB) from \(key)")
            } catch {
                if isMissingObject(error) {
                    entity.artworkKey = nil
                    // The dead key has to travel, or the next pull copies it
                    // back off the remote row and the 404 returns forever.
                    entity.syncStatus = SyncStatus.modified.rawValue
                    entity.syncLocalModifiedAt = Date()
                    downloadedAny = true
                    missingCount += 1
                } else {
                    print("[Sync] ❌ Download failed for track artwork (\(entity.title)) from \(key): \(error)")
                }
            }
        }

        if missingCount > 0 {
            print("[Sync] 🧹 \(missingCount) track cover(s) had no object in the bucket — keys cleared, they won't be retried")
        }

        if downloadedAny {
            didWriteLocally = true
            try context.save()
        }

        if missingCount > 0 {
            try await pushTracks(userID: userID)
        }
    }

    private func downloadPendingAlbumArtworks(userID: UUID) async throws {
        let albums = try fetchAlbumsNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(albums.count) album(s) needing artwork download")
        guard !albums.isEmpty else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in albums {
            guard !shouldStopWork else { return }
            guard let key = entity.artworkKey, !key.isEmpty else { continue }
            do {
                guard let data = try await artwork(at: key) else {
                    print("[Sync] ⏸ Artwork download budget spent — the rest wait for the next sync")
                    break
                }

                entity.artworkData = data
                // Name the row, so the refresh at the end of this sync drops
                // this cover's cached image and nothing else's.
                libraryService.noteArtworkChanged(.album(entity.id))
                downloadedAny = true
                print("[Sync] ↓ Downloaded album artwork: \(entity.title) (\(data.count / 1024)KB) from \(key)")
            } catch {
                if isMissingObject(error) {
                    entity.artworkKey = nil
                    // The dead key has to travel, or the next pull copies it
                    // back off the remote row and the 404 returns forever.
                    entity.syncStatus = SyncStatus.modified.rawValue
                    entity.syncLocalModifiedAt = Date()
                    downloadedAny = true
                    missingCount += 1
                } else {
                    print("[Sync] ❌ Download failed for album artwork (\(entity.title)) from \(key): \(error)")
                }
            }
        }

        if missingCount > 0 {
            print("[Sync] 🧹 \(missingCount) album cover(s) had no object in the bucket — keys cleared, they won't be retried")
        }

        if downloadedAny {
            didWriteLocally = true
            try context.save()
        }

        if missingCount > 0 {
            try await pushAlbums(userID: userID)
        }
    }

    private func downloadPendingArtistArtworks(userID: UUID) async throws {
        let artists = try fetchArtistsNeedingArtworkDownload()
        print("[Sync] 🖼️ Found \(artists.count) artist(s) needing artwork download")
        guard !artists.isEmpty else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in artists {
            guard !shouldStopWork else { return }
            guard let key = entity.artworkKey, !key.isEmpty else { continue }
            do {
                guard let data = try await artwork(at: key) else {
                    print("[Sync] ⏸ Artwork download budget spent — the rest wait for the next sync")
                    break
                }

                entity.artworkData = data
                // Name the row, so the refresh at the end of this sync drops
                // this cover's cached image and nothing else's.
                libraryService.noteArtworkChanged(.artist(entity.id))
                downloadedAny = true
                print("[Sync] ↓ Downloaded artist artwork: \(entity.name) (\(data.count / 1024)KB) from \(key)")
            } catch {
                if isMissingObject(error) {
                    entity.artworkKey = nil
                    // The dead key has to travel, or the next pull copies it
                    // back off the remote row and the 404 returns forever.
                    entity.syncStatus = SyncStatus.modified.rawValue
                    entity.syncLocalModifiedAt = Date()
                    downloadedAny = true
                    missingCount += 1
                } else {
                    print("[Sync] ❌ Download failed for artist artwork (\(entity.name)) from \(key): \(error)")
                }
            }
        }

        if missingCount > 0 {
            print("[Sync] 🧹 \(missingCount) artist cover(s) had no object in the bucket — keys cleared, they won't be retried")
        }

        if downloadedAny {
            didWriteLocally = true
            try context.save()
        }

        if missingCount > 0 {
            try await pushArtists(userID: userID)
        }
    }

    /// Counts for the sync log, taken as `fetchCount` rather than by loading
    /// every row: the old form pulled all tracks, albums and artists — and with
    /// them every external-storage artwork blob — into memory on every single
    /// sync, purely to print three numbers.
    private func logArtworkCounts() {
        mixMainActivity("sync/artwork-counts") { logArtworkCountsBody() }
    }

    private func logArtworkCountsBody() {
        func counts<T: PersistentModel>(_ type: T.Type,
                                        label: String,
                                        hasArt: Predicate<T>,
                                        hasKey: Predicate<T>) {
            let total = (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
            let art   = (try? context.fetchCount(FetchDescriptor<T>(predicate: hasArt))) ?? -1
            let key   = (try? context.fetchCount(FetchDescriptor<T>(predicate: hasKey))) ?? -1
            print("[Sync Debug] \(label) - Total: \(total), with artworkData: \(art), with artworkKey: \(key)")
        }
        counts(TrackEntity.self,  label: "Tracks",
               hasArt: #Predicate { $0.artworkData != nil },
               hasKey: #Predicate { $0.artworkKey  != nil })
        counts(AlbumEntity.self,  label: "Albums",
               hasArt: #Predicate { $0.artworkData != nil },
               hasKey: #Predicate { $0.artworkKey  != nil })
        counts(ArtistEntity.self, label: "Artists",
               hasArt: #Predicate { $0.artworkData != nil },
               hasKey: #Predicate { $0.artworkKey  != nil })
    }

    /// Runs a fetch whose predicate includes an `artworkData` nil-check.
    ///
    /// The point of pushing that clause down is that the store can answer it
    /// without reading the blob, where the Swift-side `filter` it replaces had
    /// to fault in every cover just to discard most of them. `legacy` is the
    /// pre-push-down descriptor, kept as a fallback in case a given store can't
    /// evaluate the clause against an external-storage attribute — the results
    /// are identical either way, only the cost differs.
    /// The artwork scan measured a **4096 ms main-thread hang** while reporting
    /// zero rows to download, so the two branches are spanned separately and the
    /// slow one announces itself. The suspicion worth confirming: `artworkData == nil`
    /// is a predicate on a binary blob, and if SwiftData cannot translate it the
    /// `legacy` path fetches every row carrying an artwork key and filters in
    /// memory — which materialises every artwork blob in the library. That would
    /// also be a candidate for the unexplained launch-time blob loader.
    private func fetchTolerantly<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        legacy: FetchDescriptor<T>,
        label: String,
        fallback: (T) -> Bool
    ) throws -> [T] {
        if let rows = mixMainActivity("sync/artwork-scan ▸ \(label) fast", { try? context.fetch(descriptor) }) {
            return rows
        }
        print("[Sync] ⚠️ artwork scan fell back to the in-memory filter for \(label) — every blob is being loaded")
        return try mixMainActivity("sync/artwork-scan ▸ \(label) legacy") {
            try context.fetch(legacy).filter(fallback)
        }
    }

    private func fetchTracksNeedingArtworkUpload() throws -> [TrackEntity] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false && $0.artworkData != nil
            }
        )
        let legacy = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkKey == nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "tracks/upload") { $0.artworkData != nil }
    }

    private func fetchAlbumsNeedingArtworkUpload() throws -> [AlbumEntity] {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false && $0.artworkData != nil
            }
        )
        let legacy = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.artworkKey == nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "albums/upload") { $0.artworkData != nil }
    }

    private func fetchArtistsNeedingArtworkUpload() throws -> [ArtistEntity] {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false && $0.artworkData != nil
            }
        )
        let legacy = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.artworkKey == nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "artists/upload") { $0.artworkData != nil }
    }

    private func fetchPlaylistsNeedingArtworkUpload() throws -> [PlaylistEntity] {
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate {
                $0.artworkKey == nil && $0.isSoftDeleted == false && $0.artworkData != nil
            }
        )
        let legacy = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { $0.artworkKey == nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "playlists/upload") { $0.artworkData != nil }
    }

    /// Every coverless playlist, since without a key on the row there's nothing
    /// local that says whether a remote cover exists — the bucket listing in
    /// `downloadPendingPlaylistArtworks` is what narrows this down.
    private func fetchPlaylistsNeedingArtworkDownload() throws -> [PlaylistEntity] {
        let none = PlaylistCoverKind.none.rawValue
        // Two kinds of candidate: no cover at all, and a cover another device
        // has since changed (`artworkStale`). The second is what makes an *edit*
        // cross rather than only a first cover — a device that already has a
        // picture otherwise looks satisfied forever.
        //
        // `.none` is excluded outright: the user deleted that cover, and a
        // leftover object in the bucket is not a reason to put it back.
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate {
                $0.isSoftDeleted == false && $0.coverKindRaw != none
            }
        )
        let legacy = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "playlists/download") { $0.coverKindRaw != none }
    }

    private func fetchTracksNeedingArtworkDownload() throws -> [TrackEntity] {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false && $0.artworkData == nil
            }
        )
        let legacy = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.artworkKey != nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "tracks/download") { $0.artworkData == nil }
    }

    private func fetchAlbumsNeedingArtworkDownload() throws -> [AlbumEntity] {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false && $0.artworkData == nil
            }
        )
        let legacy = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.artworkKey != nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "albums/download") { $0.artworkData == nil }
    }

    private func fetchArtistsNeedingArtworkDownload() throws -> [ArtistEntity] {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate {
                $0.artworkKey != nil && $0.isSoftDeleted == false && $0.artworkData == nil
            }
        )
        let legacy = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.artworkKey != nil && $0.isSoftDeleted == false }
        )
        return try fetchTolerantly(descriptor, legacy: legacy, label: "artists/download") { $0.artworkData == nil }
    }

    // MARK: - Artwork Compression Helper

    /// Off the main thread, via `Task.detached`.
    ///
    /// This class is main-actor isolated and an artwork burst runs this ~40 times
    /// in a row: a decode, a resample and a JPEG encode per cover, all of which
    /// were happening on the thread that draws. That is the multi-second freeze
    /// while the phone uploads covers.
    ///
    /// It was written as `nonisolated async`, on the SE-0338 rule that such a
    /// function does not inherit its caller's actor. Swift 6.2 reversed that
    /// (SE-0461): a `nonisolated async` function now runs on the caller's actor,
    /// so this stayed on the main thread. `Task.detached` never inherits
    /// isolation, in either language mode.
    private func compressArtwork(data: Data, maxDimension: CGFloat = ImageDownsampler.artworkMaxDimension) async -> Data? {
        await Task.detached(priority: .utility) {
            Self.compressArtworkSynchronously(data: data, maxDimension: maxDimension)
        }.value
    }

    private nonisolated static func compressArtworkSynchronously(data: Data, maxDimension: CGFloat) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let outputData = NSMutableData()
        let type = "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, type, 1, nil) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]

        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputData as Data
    }
}

// MARK: - Helpers

/// Payload used by deleteAllServerData() to soft-delete all rows for a user.
private struct WipePayload: Encodable {
    let isDeleted: Bool   = true
    let updatedAt: String
    enum CodingKeys: String, CodingKey {
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
    }
}
