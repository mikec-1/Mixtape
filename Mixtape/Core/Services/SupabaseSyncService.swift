// Syncs track/album/artist metadata between SwiftData and Supabase.
// Push: upsert locally modified rows. Pull: fetch rows updated since the last pull and merge.
// Conflicts: last write wins on updated_at. Artwork travels separately as JPEGs in the `artwork`
// bucket (see Artwork Sync below).

import Foundation
import SwiftData
import Supabase
import Combine
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import OSLog

@MainActor
public final class SupabaseSyncService: ObservableObject, SyncServiceProtocol {

    // MARK: - Published State

    @Published private(set) public var syncState: SyncState = .idle

    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        $syncState.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    // A provider, not a value: building the SupabaseClient is slow, and doing it in `AppDependencies.init`
    // blocked the first frame. `@autoclosure` defers it to the first network call.
    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    /// Never stored; the context belongs to whichever account's store is open. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    private let libraryService: LibraryService
    private let deviceID:       String

    // MARK: - Private State

    private var currentUser:    AppUser?

    /// Last token given to the realtime socket, so waking from background can reapply it.
    private var realtimeToken:  String?
    private var backgroundTask: Task<Void, Never>?
    private var isSyncing = false

    /// A sync requested while one was running. Dropping it lost data: the running sync may be past `pullAll`,
    /// so its rows weren't included. Requests are coalesced into one follow-up instead.
    private var syncRequestedWhileBusy = false

    /// Signs the user out as soon as this device's `devices` row is deleted (force logout from the web).
    private var revocationChannel: RealtimeChannelV2?
    private var revocationTask:    Task<Void, Never>?

    /// Listens on this user's library rows so edits from other devices arrive without waiting for the timer.
    private var libraryChannel: RealtimeChannelV2?
    private var libraryTask:    Task<Void, Never>?

    /// Coalesces a burst of remote events (a 200-song import is 200 events) into one pull.
    private var remotePullTask: Task<Void, Never>?

    /// Local edits are pushed quickly too, so other devices don't get minute-old news.
    private var localPushTask:      Task<Void, Never>?
    private var localChangeWatch:   AnyCancellable?

    /// Called when this device is revoked remotely. AppDependencies wires it to sign-out. Main actor.
    public var onDeviceRevoked: (() async -> Void)?
    /// Realtime has credentials, so other channels (continuity) may subscribe.
    public var onRealtimeReady: ((UUID) -> Void)?
    /// The server refused an unconfirmed bulk change and the local copy went back to the server's.
    public var onBulkRefused: (() -> Void)?

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
        // The websocket has its own credentials. `tracks` and `playlists` are RLS-protected, and an unauthenticated
        // socket still reports subscribed but never delivers.
        if !accessToken.isEmpty {
            realtimeToken = accessToken
            await client.realtimeV2.setAuth(accessToken)
        }
        // Before the three listeners below race each other onto a cold socket.
        await client.connectRealtimeSocket()
        syncState   = .pendingChanges(count: pendingCount())
        Task {
            // Check for revocation before re-registering: if the row we registered is gone, the web revoked us while
            // we were offline, and registerDevice() would resurrect it. The flag clears on explicit sign-out, so a
            // fresh login re-registers.
            if wasDeviceRegistered(userID: user.id),
               await !deviceRowStillExists(userID: user.id) {
                MixLog.sync.debug("Device row was revoked while offline, signing out.")
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
        // The timer only stops the next run; this stops one already in its artwork loops.
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

    /// True when this sync wrote to the local store. A no-change sync doesn't need `libraryService.refresh()`.
    private var didWriteLocally = false

    /// Set by `cancelAllWork()`, cleared when a sync starts. Lives on the service because `sync()` is called
    /// from many places, each with its own Task.
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

    /// The backlog sweeps (pending uploads, artwork scans, deleted-audio prune) fetch whole tables, some
    /// against `.externalStorage` artwork. Run them when the sync did something, otherwise on a ten-minute
    /// floor, since backlog can appear without a sync noticing (backfilled artwork, half-failed uploads).
    private func shouldSweepBacklog(hadPendingWork: Bool) -> Bool {
        if hadPendingWork || didWriteLocally || artworkBacklog { return true }
        guard let last = lastBacklogSweep else { return true }
        return Date().timeIntervalSince(last) >= 600
    }

    /// When the device heartbeat was last written. See `heartbeatDevice`.
    private var lastHeartbeat: Date?


    /// True when whatever is running should stop at its next opportunity.
    private var shouldStopWork: Bool { Task.isCancelled || abortRequested || currentUser == nil }

    /// Stops the background timer and any sync part-way through its loops, e.g. so "Clear Everything"
    /// doesn't keep uploading covers for deleted songs.
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

    /// Runs a sync, then one more if something asked while it was busy. A loop, not recursion, so a trickle
    /// of events can't build a stack.
    private func runSyncLoop() async throws {
        repeat {
            syncRequestedWhileBusy = false
            try await runSync()
            // A request alone isn't a reason to repeat: `refresh()` fires the library's own change notification, so
            // an unconditional repeat would sync forever.
            guard syncRequestedWhileBusy, !shouldStopWork, pendingCount() > 0 else { return }
        } while true
    }

    private func runSync() async throws {
        guard let user = currentUser, !isSyncing else { return }
        abortRequested = false
        didWriteLocally = false
        isSyncing = true
        syncState = .syncing
        // Only show "Syncing" when there's real work. Armed here and raised by `announceWork()` once there are
        // pending rows, a pull returned something, or an artwork sweep has a file to move.
        announcedActivity = false
        let hadPendingWork = pendingCount() > 0
        // A first pull always has work, and Home reads the banner to say "loading" instead of "empty".
        if hadPendingWork || !hasPulledOnce(userID: user.id) { announceWork() }
        defer {
            isSyncing = false
            if announcedActivity {
                libraryService.endActivity()
                announcedActivity = false
            }
        }

        MixLog.sync.debug("▶︎ Sync started")
        // A clear from another device needs the same consequences as a local one (mixes, recommended artists,
        // the landing). `UserDataReset.announce` is only called locally, so the pull announces remote ones.
        let liveBeforePull = libraryService.tracks.filter { !$0.isDeleted }.count

        do {
            // Phases, not spans: they only give the hang watchdog a name to print.
            // A device that has never pulled pushes nothing until it has: its local state may be stale or a
            // leftover from another account, and pushing it first is how a fresh install overwrote Liked Songs.
            if hasPulledOnce(userID: user.id) {
                let bulk = Self.bulk
                try await mixPhase("sync/push")        { try await pushAll(userID: user.id) }
                Self.markBulkCarried(at: bulk?.at)
            }
            try await mixPhase("sync/pull")            { try await pullAll(userID: user.id) }
            let sweep = shouldSweepBacklog(hadPendingWork: hadPendingWork)
            if sweep {
                artworkDownloadsLeft = Self.artworkDownloadBudget
                artworkBacklog = false
                // Before the refresh below, so a new device doesn't first show playlists wearing borrowed covers.
                try await mixPhase("sync/download-playlist-artwork") {
                    try await downloadPendingPlaylistArtworks(userID: user.id)
                }
            }
            // Show what the pull brought now. The sweeps below take minutes on a new device, and the library
            // used to stay empty until they finished.
            if didWriteLocally {
                await mixPhase("sync/refresh") { await libraryService.refreshOffMain() }
                didWriteLocally = false
            }
            if sweep {
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
                // Off the main actor. Safe here, unlike the write paths: everything this sync wrote is committed, and
                // `LibrarySnapshotReader` reads through a fresh context that sees it.
                await mixPhase("sync/refresh") { await libraryService.refreshOffMain() }
            } else {
                MixLog.sync.debug("Nothing changed locally, skipping refresh")
            }
            let liveAfterPull = libraryService.tracks.filter { !$0.isDeleted }.count
            if liveBeforePull > 0 && liveAfterPull == 0 {
                MixLog.sync.debug("Library emptied by a remote clear, resetting derived state")
                UserDataReset.announce(.everything)
            }
            syncState = .upToDate(lastSynced: Date())
            MixLog.sync.debug("Sync complete")
            // Cumulative over the session; a sync is just a regular moment to print it. Console category "hangs".
            MainThreadActivity.shared.logReport("after sync")
        } catch {
            syncState = .error(error.localizedDescription)
            MixLog.sync.error("Sync failed: \(error)")
            throw error
        }
    }

    // MARK: - Tombstone Pruning

    /// Clears deletion markers every device has pulled. At most daily, after a successful sync. The server
    /// decides what's safe (`prune_sync_tombstones` migration). Best-effort: leftover tombstones only cost bandwidth.
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
            // Logged at zero too, so "nothing to prune" differs from "never ran".
            MixLog.sync.debug("Pruned \(removed) tombstone\(removed == 1 ? "" : "s")")
        } catch {
            // Includes "function does not exist" before the migration is applied, which is fine.
            MixLog.sync.error("tombstone prune skipped: \(error)")
        }
    }

    // MARK: - Deleted Audio

    /// A song deleted on another device loses its file here too; the pull only applied the tombstone.
    /// A sweep rather than a pull hook, so it also clears old tombstones.
    /// Only rows whose deletion is already synced: an unpushed delete keeps its `localPath` because
    /// `isPushable` uses it to decide the row is ours. `localPath` is cleared as the file goes, so each row
    /// is swept once. A newer live row from the server brings the song back without audio, like any
    /// synced track.
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
            MixLog.sync.error("deleted-audio sweep skipped: \(error)")
            return
        }

        // Off the actor: the first run can be hundreds of `fileExists` + `removeItem` pairs.
        let doomed = paths
        await Task.detached(priority: .utility) {
            for path in doomed { AudioPaths.removeAllCopies(ofLocalPath: path) }
        }.value

        didWriteLocally = true
        MixLog.sync.debug("Removed audio for \(paths.count) deleted track\(paths.count == 1 ? "" : "s")")
    }

    // MARK: - Count Reconcile

    private struct TrackIDRow: Decodable, Sendable {
        let id: UUID
        let isDeleted: Bool
        let updatedAt: Date
        enum CodingKeys: String, CodingKey {
            case id
            case isDeleted = "is_deleted"
            case updatedAt = "updated_at"
        }
    }

    private var didReconcileThisLaunch = false

    /// Checks both sides hold the same songs. The push filters rows it can't send (`isPushable`) and the pull
    /// skips rows it won't insert, both silently, so lost rows only showed as an off-by-one count. Logs the
    /// difference and why (most local-only rows, like shared-playlist shadow rows, are held back on purpose).
    /// Repairs: a live row `isPushable` accepts but the server lacks is re-marked modified; server rows
    /// missing here are fetched by id (`adoptMissingTracks`). Once per launch, then hourly.
    private func reconcileTrackCounts(userID: UUID) async {
        let key = "mix.sync.trackReconcile.\(userID.uuidString)"
        if didReconcileThisLaunch,
           let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < 3_600 { return }
        didReconcileThisLaunch = true

        var serverIDs = Set<UUID>()
        var serverTombstones: [UUID: Date] = [:]
        do {
            let client   = self.client
            let pageSize = Self.pullPageSize
            var offset   = 0
            while true {
                // Ids only, and no `sync_device_id` filter: this asks what the server holds, whoever wrote it.
                // Tombstones too, so a deletion this device never pulled isn't mistaken for a row it never pushed.
                let page: [TrackIDRow] = try await Task.detached(priority: .utility) {
                    try await client
                        .from("tracks")
                        .select("id,is_deleted,updated_at")
                        .eq("user_id", value: userID.uuidString)
                        .order("id")
                        .range(from: offset, to: offset + pageSize - 1)
                        .execute()
                        .value
                }.value
                for row in page {
                    if row.isDeleted { serverTombstones[row.id] = row.updatedAt } else { serverIDs.insert(row.id) }
                }
                offset += page.count
                if page.count < pageSize { break }
            }
        } catch {
            // Never fails the sync: this is a diagnostic that happens to repair.
            MixLog.sync.error("reconcile skipped: \(error)")
            return
        }
        UserDefaults.standard.set(Date(), forKey: key)

        // From the published array, not a fetch; even an id-only fetch hung the main thread.
        let localIDs = Set(libraryService.tracks.filter { !$0.isDeleted }.map(\.id))

        let missingHere     = serverIDs.subtracting(localIDs)
        let missingOnServer = localIDs.subtracting(serverIDs)
        guard !missingHere.isEmpty || !missingOnServer.isEmpty else {
            MixLog.sync.debug("Reconcile: \(localIDs.count) tracks, both sides agree")
            return
        }

        MixLog.sync.debug("Reconcile: local \(localIDs.count), server \(serverIDs.count), \(missingHere.count) missing here, \(missingOnServer.count) missing on the server")

        var lost: [TrackEntity] = []
        var heldBack: [String: Int] = [:]
        let strayRows = missingOnServer.isEmpty ? [] : (try? context.fetch(
            FetchDescriptor<TrackEntity>(
                predicate: #Predicate { missingOnServer.contains($0.id) }))) ?? []
        var deletedThere: [UUID] = []
        for row in strayRows {
            // Deleted on the server after this row was imported: take the deletion instead of undoing it.
            // Same rule as `pullTracks`.
            if let deletedAt = serverTombstones[row.id], row.dateImported <= deletedAt {
                deletedThere.append(row.id)
            } else if Self.isPushable(row) {
                lost.append(row)
            } else {
                heldBack["\(row.resolvedOrigin)", default: 0] += 1
            }
        }
        for (reason, count) in heldBack.sorted(by: { $0.key < $1.key }) {
            MixLog.sync.debug("   \(count) held back on purpose (\(reason))")
        }
        // Capped; this identifies the divergence, it doesn't print the library.
        for row in lost.prefix(10) {
            MixLog.sync.debug("   never pushed: \(row.title), \(row.artistName)")
        }
        if !lost.isEmpty {
            for row in lost where row.syncStatus == SyncStatus.synced.rawValue {
                row.syncStatus          = SyncStatus.modified.rawValue
                row.syncLocalModifiedAt = Date()
            }
            try? context.save()
            MixLog.sync.debug("   re-queued \(lost.count) for the next push")
        }

        if !deletedThere.isEmpty {
            do {
                let rows: [TrackRow] = try await fetchRows("tracks", ids: deletedThere, userID: userID)
                let local = existingTracks(ids: rows.map(\.id))
                for row in rows where row.isDeleted { if let existing = local[row.id] { row.apply(to: existing) } }
                try context.save()
                didWriteLocally = true
                MixLog.sync.debug("   applied \(rows.count) server deletion(s) this device missed")
            } catch {
                MixLog.sync.error("   applying server deletions failed: \(error)")
            }
        }

        if !missingHere.isEmpty {
            await adoptMissingTracks(ids: Array(missingHere), userID: userID)
        }

        // After a repair, check again in five minutes.
        UserDefaults.standard.set(Date().addingTimeInterval(-3_300), forKey: key)
    }

    /// Fetches specific server rows this device lacks, by id. Clearing the pull watermark can't do it: the pull
    /// excludes rows this device wrote (`sync_device_id.neq`), so a row we pushed but lost is never pulled again.
    /// Chunked for URL length and capped: hundreds missing is a bug to fix, not paper over.
    private func adoptMissingTracks(ids: [UUID], userID: UUID) async {
        let wanted = Array(ids.prefix(500))
        if wanted.count < ids.count {
            MixLog.sync.debug("   \(ids.count) rows missing locally, adopting the first \(wanted.count)")
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
                        // Present but soft-deleted here: the server's live row is newer, so the deletion was reversed.
                        row.apply(to: existing)
                        revived += 1
                    } else {
                        context.insert(TrackEntity(from: row))
                        adopted += 1
                    }
                }
                try context.save()
            } catch {
                MixLog.sync.error("   adopt failed: \(error)")
                return
            }
        }
        if adopted + revived > 0 {
            didWriteLocally = true
            MixLog.sync.debug("   adopted \(adopted) missing track\(adopted == 1 ? "" : "s"), revived \(revived)")
        }
    }

    /// Generic single-entity push (protocol requirement; caller supplies a full row).
    public func push<T: Codable>(_ entity: T, table: String) async throws {
        guard currentUser != nil else { return }
        try await client.from(table).upsert(entity).execute()
    }

    // MARK: - Device Registration

    /// Upserts this install into `devices` so it shows on the web /devices page, using the stable `deviceID`.
    /// Best-effort.
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
            MixLog.sync.error("device register failed: \(error)")
        }
    }

    /// Per-sync liveness ping. Only UPDATEs, so a device revoked mid-sync can't recreate its row. A missing row
    /// (when we had registered) is treated as revocation.
    private func heartbeatDevice(userID: UUID) async {
        // Every five minutes at most. Revocation arrives instantly via `startRevocationListener`; this is the
        // fallback for when Realtime is down.
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
                MixLog.sync.debug("Device row gone during heartbeat, revoked, signing out.")
                clearDeviceRegisteredFlag(userID: userID)
                await onDeviceRevoked?()
            }
        } catch {
            // Network/query error; never log out on a failed heartbeat.
            MixLog.sync.error("device heartbeat failed: \(error)")
        }
    }

    // MARK: - Remote Revocation (force logout)

    /// Listens for DELETE on this device's `devices` row and signs out immediately. Best-effort: without
    /// Realtime the next sync still won't recreate access, this just makes it instant.
    private func startRevocationListener(userID: UUID) {
        // The new task tears down the old listener, awaited, because `client.channel(_:)` returns the cached
        // channel while the topic is registered, and `postgresChange` on a subscribed channel never delivers.
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

            // No server-side `filter:`: DELETE filtering runs on replica-identity columns and drops events. RLS
            // scopes DELETEs to this user, and we match our row client-side.
            let deletions = channel.postgresChange(
                DeleteAction.self,
                schema: "public",
                table:  "devices"
            )

            await client.join(channel, label: "revocation listener")
            MixLog.sync.debug("Revocation listener subscribed (device \(deviceID))")

            for await deletion in deletions {
                guard !Task.isCancelled else { break }

                // DELETE payloads only carry the primary key, so `device_id` may be missing. Any `devices` DELETE is one
                // of this user's, so check whether our own row still exists.
                let oldDeviceID = deletion.oldRecord["device_id"]?.stringValue
                MixLog.sync.debug("devices DELETE received (device_id=\(oldDeviceID ?? "nil")), verifying our row")
                if oldDeviceID != nil && oldDeviceID != deviceID { continue }

                if await deviceRowStillExists(userID: userID) {
                    MixLog.sync.debug("our device row still present, not us, ignoring")
                    continue
                }

                MixLog.sync.debug("This device revoked remotely, signing out.")
                await onDeviceRevoked?()
                break
            }
        }
    }

    /// True if this install's `devices` row still exists, to confirm a revocation was for us.
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
            // On a query error, stay signed in.
            MixLog.sync.error("device existence check failed: \(error)")
            return true
        }
    }

    private func stopRevocationListener() async {
        revocationTask?.cancel()
        revocationTask = nil
        if let channel = revocationChannel {
            // `removeChannel`, not `unsubscribe`: only it evicts the topic from the channel cache.
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

    /// Every install's name on this account, by device id, for the stats page's device
    /// split. Empty offline or signed out, and the split falls back to "Other devices".
    public func deviceNames() async -> [String: String] {
        guard let userID = currentUser?.id else { return [:] }
        struct Row: Decodable { let device_id: String; let name: String? }
        do {
            let rows: [Row] = try await client.from("devices")
                .select("device_id,name")
                .eq("user_id", value: userID)
                .execute()
                .value
            return Dictionary(rows.compactMap { row in row.name.map { (row.device_id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        } catch {
            MixLog.sync.error("device names fetch failed: \(error)")
            return [:]
        }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    // MARK: - Realtime Library Changes

    /// Subscribes to this user's `tracks` and `playlists` so other devices' changes land in about a second.
    /// Only those two: `pullAll` fetches everything, and albums/artists only change with tracks.
    /// Teardown happens in the new task, same as the revocation listener.
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

            // No `filter:`; RLS scopes them, and filtering drops DELETEs (see the revocation listener).
            let trackChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "tracks")
            let playlistChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "playlists")
            let feedbackChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "suggestion_feedback")

            await client.join(channel, label: "library listener")
            // If the tables aren't in the `supabase_realtime` publication this still says "subscribed" and never delivers.
            MixLog.sync.debug("Library listener subscribed (device \(deviceID)), status \(String(describing: channel.status))")

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
                group.addTask {
                    // Small row, so every event (our own echoes too) just re-reads it.
                    for await _ in feedbackChanges {
                        guard !Task.isCancelled else { break }
                        await SuggestionFeedback.pull(userID: userID)
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

    /// Decides whether an event needs a pull and schedules one. Events stamped with this device's id are our
    /// own pushes echoing back and are dropped.
    private func handleRemoteChange(_ action: AnyAction, table: String) async {
        let origin: String?
        switch action {
        case .insert(let a): origin = a.record["sync_device_id"]?.stringValue
        case .update(let a): origin = a.record["sync_device_id"]?.stringValue
        case .delete:
            // DELETEs are ignored: server rows are only hard-deleted by `prune_sync_tombstones`, which removes
            // tombstones every device already pulled. Normal deletes arrive as UPDATEs.
            return
        }
        guard origin != deviceID else { return }
        // Logged once per burst; one edit is one event per touched row.
        if pullBurstStart == nil {
            MixLog.sync.debug("Remote change on \(table), scheduling pull")
        }
        scheduleRemotePull()
    }

    /// Start of the current burst, cleared when its pull fires.
    private var pullBurstStart: Date?

    /// Longest a burst may hold the pull off. See `scheduleRemotePull`.
    private static let pullBurstCap: Duration = .milliseconds(1500)

    /// One pull per burst.
    private func scheduleRemotePull() {
        // Not while a sync runs: that sync is `remotePullTask`, and cancelling it aborts the push midway.
        // Hand the request to the loop instead.
        if isSyncing { syncRequestedWhileBusy = true; return }

        // Trailing debounce with a ceiling: each event re-arms the 800ms timer so a burst pulls once, but the
        // first event is never held longer than `pullBurstCap` (the Mac pushes in several waves that kept
        // resetting it).
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

    /// Pushes local edits shortly after they settle, driven by the library's change signal. Guarded against
    /// running during a sync or with nothing pending, since our own `refresh()` fires it too.
    private func startLocalChangeWatch() {
        // `localChanges`, not `objectWillChange`, which also fires when the library republishes at the end of
        // every sync. The `isSyncing` guard in `scheduleLocalPush` is a backup.
        localChangeWatch = libraryService.localChanges
            .sink { [weak self] _ in self?.scheduleLocalPush() }
    }

    private func scheduleLocalPush() {
        guard currentUser != nil else { return }
        // Checked before the cancel, not inside the task: a sync ends in `refresh()`, which fires this watch,
        // and cancelling here would kill the sync running it. While syncing, hand off to the loop.
        // `pendingCount()` is checked here too, or the republish at the end of every sync queues an empty round.
        // Pulls still set the flag unconditionally in `scheduleRemotePull`.
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

    /// Rebuilds both listeners after the app wakes and pulls once to cover the gap. The websocket doesn't
    /// survive backgrounding, and a dead channel is silent rather than an error.
    public func resumeRealtime() {
        guard let user = currentUser else { return }
        Task { [weak self] in
            guard let self else { return }
            // Awaited: if `setAuth` races `subscribe()`, the socket subscribes without credentials and RLS sends
            // nothing. iOS comes through here on every foreground; the Mac rarely does.
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
            // Overwritten on the next pull; nothing to do locally.
            break
        }
        try? await sync()
    }

    // MARK: - Push

    /// Encodes and sends off the main actor. Under Swift 6.2 (SE-0461) `nonisolated async` runs on the
    /// caller's actor, so the hop is a `Task.detached`. Same as `LibrarySnapshotReader.read()` and `compressArtwork`.
    private func upsert<T: Encodable & Sendable>(
        _ rows: [T],
        into table: String,
        onConflict: String? = nil
    ) async throws {
        let client = self.client
        let bulk = Self.bulk?.reason
        try await Task.detached(priority: .utility) {
            let query = client.from(table)
            let upsert = if let onConflict {
                try query.upsert(rows, onConflict: onConflict)
            } else {
                try query.upsert(rows)
            }
            try await (bulk.map { upsert.setHeader(name: Self.bulkHeader, value: $0) } ?? upsert).execute()
        }.value
    }

    // MARK: - Bulk guard
    // The server refuses a write that likes, unlikes, deletes or restores more than 50 songs at once
    // (supabase/migrations/20261002010000_library_guardrails.sql) unless it carries this header. Only actions
    // the user just confirmed open the window, so background code can never mass-change a library.

    nonisolated static let bulkHeader = "x-mixtape-bulk"
    private nonisolated static let bulkKey = "mix.sync.bulk"

    /// Call right before the write the user confirmed (an import's likes, Clear Library, a multi-select remove).
    /// Open for 15 minutes so every push of an import carries it, then until one successful push has, so an
    /// offline change or a relaunch still lands. A day at most.
    // ponytail: not per account; switching before the push lets the other account's next push through once.
    nonisolated public static func allowBulk(_ reason: String) {
        UserDefaults.standard.set(["reason": reason, "at": Date().timeIntervalSince1970], forKey: bulkKey)
    }

    nonisolated static var bulk: (reason: String, at: Double)? {
        guard let d = UserDefaults.standard.dictionary(forKey: bulkKey),
              let reason = d["reason"] as? String, let at = d["at"] as? Double else { return nil }
        let age = Date().timeIntervalSince1970 - at
        guard age < 15 * 60 || (d["carried"] == nil && age < 86_400) else { return nil }
        return (reason, at)
    }

    /// A push that started with this confirmation succeeded. Ignored if a newer one opened meanwhile.
    private nonisolated static func markBulkCarried(at: Double?) {
        guard let at, var d = UserDefaults.standard.dictionary(forKey: bulkKey), d["at"] as? Double == at else { return }
        d["carried"] = true
        UserDefaults.standard.set(d, forKey: bulkKey)
    }

    private func isBulkRefusal(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "MXBLK"
    }

    /// Server rows by id, chunked for URL length.
    private func fetchRows<Row: Decodable & Sendable>(_ table: String, ids: [UUID], userID: UUID) async throws -> [Row] {
        let client = self.client
        var out: [Row] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let values = ids[start ..< min(start + 100, ids.count)].map(\.uuidString)
            out += try await Task.detached(priority: .utility) {
                try await client.from(table).select()
                    .eq("user_id", value: userID.uuidString)
                    .in("id", values: values)
                    .execute().value
            }.value
        }
        return out
    }

    private func pushAll(userID: UUID) async throws {
        try await pushTracks(userID: userID)
        try await pushAlbums(userID: userID)
        try await pushArtists(userID: userID)
        try await pushPlaylists(userID: userID)
        try await pushPlayHistory(userID: userID)
    }

    private func pushTracks(userID: UUID) async throws {
        var pending = try fetchPendingTracks()
        guard !pending.isEmpty else { return }

        MixLog.sync.debug("↑ Pushing \(pending.count) track(s): \(pending.map(\.title).joined(separator: ", "))")
        // SwiftData can keep isDeleted=false after softDelete(), so rows with a deleted syncStatus are forced
        // to tombstones below. `now` is when these rows become visible to other devices, not when they were saved.
        let now = Date()
        var rows = pending.map { entity -> TrackRow in
            var row = TrackRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            // Stamp this device, not the creator (`TrackRow.init(entity:)` copies that). The echo guard in
            // `handleRemoteChange` asks "did I write this?", so it has to be the last writer.
            row.syncDeviceID = deviceID

            // Other devices pull rows changed since their last pull. A never-pushed row stamped with its save date
            // would land behind their cursor and never arrive. `.localOnly` means never on the server; pushed rows
            // are `.modified` and keep their real edit time for last-write-wins.
            if entity.syncStatus == SyncStatus.localOnly.rawValue {
                row.updatedAt = now
            }
            return row
        }
        // No explicit `onConflict:`, so it targets whatever key the table has, before or after
        // `20260812120000_tracks_per_user_key`.
        do {
            try await upsert(rows, into: "tracks")
        } catch where isBulkRefusal(error) {
            // Only the songs that would be deleted or restored take the server's copy, so they aren't retried
            // every sync. The rest (edits, new songs) go through.
            let server: [TrackRow] = try await fetchRows("tracks", ids: pending.map(\.id), userID: userID)
            let byID = Dictionary(server.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let refused = Set(rows.filter { row in byID[row.id].map { $0.isDeleted != row.isDeleted } ?? false }.map(\.id))
            MixLog.sync.error("↑ Server refused deleting or restoring \(refused.count) song(s) without confirmation, keeping its copy")
            for entity in pending where refused.contains(entity.id) {
                byID[entity.id]?.apply(to: entity)
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
            try context.save()
            didWriteLocally = true
            onBulkRefused?()
            pending.removeAll { refused.contains($0.id) }
            rows.removeAll { refused.contains($0.id) }
            if !rows.isEmpty { try await upsert(rows, into: "tracks") }
        }

        // Hard-delete confirmed deletions so the pull can't re-insert them; mark the rest synced.
        var hardDeletedCount = 0
        var deletedAudioKeys = Set<String>()
        for entity in pending {
            if entity.syncStatus == SyncStatus.deleted.rawValue {
                if let key = entity.remoteKey, !key.isEmpty { deletedAudioKeys.insert(key) }
                context.delete(entity)
                hardDeletedCount += 1
            } else {
                // Match the timestamp sent for a first push, or the next pull treats it as news.
                if entity.syncStatus == SyncStatus.localOnly.rawValue {
                    entity.syncLocalModifiedAt = now
                }
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
        }
        try context.save()
        // The tombstone stays until every device pulls it, but the audio can go. After the save so the fetch sees it.
        await deleteOrphanedAudio(keys: deletedAudioKeys)
        if hardDeletedCount > 0 {
            MixLog.sync.debug("↑ Pushed \(pending.count) track(s), hard-deleted \(hardDeletedCount) confirmed deletion(s)")
        } else {
            MixLog.sync.debug("↑ Pushed \(pending.count) track(s)")
        }
    }

    /// Deletes uploaded audio for deleted tracks, only for keys whose tombstone the server just accepted.
    private func deleteOrphanedAudio(keys: Set<String>) async {
        guard !keys.isEmpty else { return }

        // Remote paths are content-addressed (`<userID>/<sha256>.<ext>`), so rows can share a blob. Anything still
        // referenced stays: a wrong delete loses audio, an orphan only costs storage.
        var orphans: [String] = []
        for key in keys {
            let descriptor = FetchDescriptor<TrackEntity>(
                predicate: #Predicate { $0.remoteKey == key && !$0.isSoftDeleted }
            )
            // On error assume it's still in use.
            let stillReferenced = (try? context.fetchCount(descriptor)) ?? 1
            if stillReferenced == 0 { orphans.append(key) }
        }
        guard !orphans.isEmpty else { return }

        do {
            try await storageRemove(bucket: "audio", paths: orphans)
            MixLog.sync.debug("Removed \(orphans.count) orphaned audio file(s) from Storage")
        } catch {
            // Not fatal or retried (the tombstone is gone locally); logged so repeated failures show.
            MixLog.sync.error("orphaned audio cleanup failed for \(orphans.count) file(s): \(error)")
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

    /// Nearly append-only: send unsent rows, mark them sent. The only edit is the final `seconds_played`,
    /// which re-pends the row. Never deleted remotely; a pruned local row is still a play other devices count.
    private func pushPlayHistory(userID: UUID) async throws {
        let pending = try fetchPendingPlayHistory()
        guard !pending.isEmpty else { return }

        // Chunked: the first push sends the whole local history backlog.
        for chunk in stride(from: 0, to: pending.count, by: 500) {
            let slice = Array(pending[chunk..<min(chunk + 500, pending.count)])
            var rows = slice.map { PlayHistoryRow(entity: $0, userID: userID) }
            for i in rows.indices {
                rows[i].syncDeviceID = deviceID
                rows[i].platform = Self.platformName
            }
            try await upsert(rows, into: "play_history")

            for entity in slice {
                entity.syncStatus       = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
            }
            try context.save()
        }
        MixLog.sync.debug("↑ Play history: \(pending.count)")
    }

    private func pushPlaylists(userID: UUID) async throws {
        var pending = try fetchPendingPlaylists()
        guard !pending.isEmpty else { return }

        // Merge track lists with what other devices pushed since this one last synced. Only the
        // track list merges; the other fields stay last write wins.
        let live = pending.filter { $0.syncStatus != SyncStatus.deleted.rawValue && $0.id != Playlist.allSongsID }
        let serverRows: [PlaylistRow] = live.isEmpty ? [] : try await fetchRows("playlists", ids: live.map(\.id), userID: userID)
        var mergedLikes: [UUID]? = nil
        for server in serverRows where !server.isDeleted {
            guard let entity = live.first(where: { $0.id == server.id }) else { continue }
            let local = entity.trackIDsData.toUUIDArray()
            let merged: [UUID]
            if let base = entity.syncBaseTrackIDsData?.toUUIDArray() {
                merged = mergeTrackIDs(base: base, local: local, server: server.trackIDs)
            } else if server.syncDeviceID == deviceID || server.updatedAt <= (entity.syncServerModifiedAt ?? .distantPast) {
                merged = local
            } else {
                // No base yet and another device changed it since: theirs wins.
                merged = server.trackIDs
            }
            guard merged != local else { continue }
            MixLog.sync.debug("↑ Playlist \(entity.name): merged with server, \(local.count) → \(merged.count)")
            entity.trackIDsData = merged.toData()
            if entity.id == Playlist.favouritesID { mergedLikes = merged }
        }
        if let mergedLikes {
            try context.save()
            try FavoriteRepository().rebuildFromIDs(mergedLikes, deviceID: deviceID)
            didWriteLocally = true
        }

        var rows = pending.map { entity -> PlaylistRow in
            var row = PlaylistRow(entity: entity, userID: userID)
            if entity.syncStatus == SyncStatus.deleted.rawValue { row.isDeleted = true }
            row.syncDeviceID = deviceID
            return row
        }
        do {
            try await upsert(rows, into: "playlists", onConflict: "id,user_id")
        } catch where isBulkRefusal(error) {
            // Only Liked Songs is guarded. It goes back to the server's list and the other playlists go through.
            MixLog.sync.error("↑ Server refused a bulk Liked Songs change, keeping its copy")
            let server: [PlaylistRow] = try await fetchRows("playlists", ids: [Playlist.favouritesID], userID: userID)
            if let likes = server.first, let entity = pending.first(where: { $0.id == Playlist.favouritesID }) {
                likes.apply(to: entity)
                entity.syncStatus = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt = Date()
                try context.save()
                try FavoriteRepository().rebuildFromIDs(likes.trackIDs, deviceID: deviceID)
            }
            didWriteLocally = true
            onBulkRefused?()
            pending.removeAll { $0.id == Playlist.favouritesID }
            rows.removeAll { $0.id == Playlist.favouritesID }
            if !rows.isEmpty { try await upsert(rows, into: "playlists", onConflict: "id,user_id") }
        }

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
                entity.syncStatus           = SyncStatus.synced.rawValue
                entity.syncLastSyncedAt     = Date()
                entity.syncBaseTrackIDsData = entity.trackIDsData
            }
        }
        try context.save()
        MixLog.sync.debug("↑ Playlists: pushed \(pending.count)")
    }

    // MARK: - File Upload
    // Uploads local audio that hasn't been uploaded. Each success marks the track modified so pushTracks
    // syncs the new remoteKey and fileUploaded=true.

    private func uploadPendingFiles(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingUpload()
        guard !tracks.isEmpty else { return }

        var uploadedAny = false
        // A re-rendered edit's earlier upload, removed once the row points at the new one.
        var replaced = Set<String>()

        var missingFileCount = 0

        for entity in tracks {
            // Per-song loops, so check for a stop (e.g. after "Clear Everything").
            guard !shouldStopWork else { return }
            // Verify the local file still exists (it might have been cleared).
            guard let localURL = Self.uploadSourceURL(for: entity) else {
                missingFileCount += 1
                MixLog.sync.warning("[SupabaseSyncService] Local file missing for \"\(entity.title)\" at \(entity.localPath), skipping upload")
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
                MixLog.sync.error("[SupabaseSyncService] Can't stat \"\(entity.title)\": \(error), skipping")
                continue
            }
            guard diskSize > 0 else {
                MixLog.sync.warning("[SupabaseSyncService] \"\(entity.title)\" is 0 bytes on disk, skipping upload")
                continue
            }
            // If we stored a file size at import time, do a quick sanity check.
            if entity.fileSize > 0 && diskSize < entity.fileSize / 2 {
                MixLog.sync.warning("[SupabaseSyncService] \"\(entity.title)\" disk size (\(diskSize)) is less than half of stored size (\(entity.fileSize)), file may be truncated, skipping")
                continue
            }

            do {
                // Read off the main thread; lossless files can be 100+ MB.
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: localURL)
                }.value

                // Guard against empty or obviously-truncated reads before hitting the network.
                guard data.count > 0 else {
                    MixLog.sync.warning("[SupabaseSyncService] Data read for \"\(entity.title)\" returned 0 bytes, skipping upload")
                    continue
                }
                if diskSize > 0 && Int64(data.count) < diskSize / 2 {
                    MixLog.sync.warning("[SupabaseSyncService] Data read for \"\(entity.title)\" (\(data.count) bytes) is far smaller than file (\(diskSize) bytes), skipping upload")
                    continue
                }

                let ct = SupabaseFileStorageService.contentType(for: ext)
                try await storageUpload(bucket: "audio", path: remotePath,
                                        data: data, contentType: ct)

                if let old = entity.remoteKey, !old.isEmpty, old != remotePath { replaced.insert(old) }
                entity.remoteKey           = remotePath
                entity.fileUploaded        = true
                entity.syncStatus          = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                uploadedAny = true
                MixLog.sync.debug("[SupabaseSyncService] Uploaded \"\(entity.title)\" (\(data.count / 1024)KB) → \(remotePath)")

            } catch {
                // Log and skip; retried next sync.
                MixLog.sync.error("[SupabaseSyncService] Upload failed for \"\(entity.title)\": \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            // Push again so the server records the updated remoteKey + fileUploaded=true.
            try await pushTracks(userID: userID)
            await deleteOrphanedAudio(keys: replaced)
            MixLog.sync.debug("[SupabaseSyncService] File sync complete, \(tracks.count) file(s) processed")
        } else if missingFileCount > 0 {
            MixLog.sync.warning("[SupabaseSyncService] \(missingFileCount)/\(tracks.count) pending track(s) have missing local files, they cannot be uploaded until the source file is present")
        } else {
            MixLog.sync.debug("[SupabaseSyncService] No pending file uploads")
        }
    }

    /// Where a track's audio actually is. `localPath` hasn't always been Documents-relative, and resolving it
    /// one way meant older tracks were never uploaded. `AudioPaths` knows every location.
    private static func uploadSourceURL(for entity: TrackEntity) -> URL? {
        AudioPaths.resolve(localPath: entity.localPath)
    }

    /// Tracks whose audio still has to be uploaded. Online songs are excluded: the resolver can reproduce them
    /// anywhere, and uploading made the row look like an imported file that needs a download.
    private func fetchTracksNeedingUpload() throws -> [TrackEntity] {
        try context.fetch(
            FetchDescriptor<TrackEntity>(
                predicate: #Predicate {
                    $0.fileUploaded == false &&
                    $0.localPath != "" &&
                    $0.isSoftDeleted == false
                }
            )
        ).filter { !$0.resolvedOrigin.isOutsideLibraryStorage || Self.isStudioEdit($0) }
    }

    /// Studio edits upload their file: other devices can't make stems to rebuild them.
    private static func isStudioEdit(_ entity: TrackEntity) -> Bool {
        entity.resolvedOrigin == .edit
            && entity.editData.flatMap { try? JSONDecoder().decode(SongEdit.self, from: $0) }?.isStudio == true
    }

    // MARK: - Pull

    /// PostgREST silently caps responses at `max-rows` (1000 on Supabase), so a truncated page looks complete.
    /// Pulls page explicitly; taking the first page as everything used to skip rows for good.
    private static let pullPageSize = 500

    /// Reads every row changed since `since`, one page at a time via `handle`. The caller advances its
    /// last-pull date only after this returns, so a failed page is asked for again.
    /// Ordered by `updated_at` then `id`: `range` paging needs a total order and timestamps tie.
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
            // The request and JSON decode run off the actor (under SE-0461 the Supabase chain runs on the caller's
            // actor). `handle` stays on main: it writes through `mainContext`.
            let page: [Row] = try await Task.detached(priority: .utility) {
                try await client
                    .from(table)
                    .select()
                    .eq("user_id", value: userID.uuidString)
                    .gt("updated_at", value: since)
                    // Skip our own writes, which this device already has. An `or` rather than `neq`: in SQL `<>` is NULL for
                    // a NULL column and would drop legacy rows. A row we wrote that another device changed carries their id.
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
        await SuggestionFeedback.pull(userID: userID)
    }

    private func pullTracks(userID: UUID) async throws {
        let since = lastPullDate(table: "tracks", userID: userID)

        var inserted = 0, updated = 0, skipped = 0
        let total = try await pullPages(from: "tracks", userID: userID, since: since) { (rows: [TrackRow]) in
            let local = existingTracks(ids: rows.map(\.id))
            for row in rows {
                if let existing = local[row.id] {
                    // Never overwrite a locally pending deletion with a stale server row. Check both flags; SwiftData can
                    // leave one stale.
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                        // ...but only a deletion this device still owes the server, or one the server agrees with. Skipping
                        // unconditionally made local tombstones permanent, and `prunePlaylistsOfDeletedTracks` then pushed
                        // shortened playlists back.
                        let deletionPending = existing.syncStatus != SyncStatus.synced.rawValue
                        if row.isDeleted || (deletionPending && existing.syncLocalModifiedAt >= row.updatedAt) {
                            skipped += 1
                            continue
                        }
                        // Fall through: the server row is live and newer, so `apply(to:)` undeletes it.
                    }
                    // A tombstone older than the local row's import is a deletion this track already outlived. Discover ids
                    // are deterministic (`OnlineTrack.stableID`), so re-saving a deleted song reuses a tombstoned id, and a
                    // full re-sync would delete it again. Pushing it back clears the server's `is_deleted`.
                    if row.isDeleted, existing.dateImported > row.updatedAt {
                        if existing.syncStatus == SyncStatus.synced.rawValue {
                            existing.syncStatus = SyncStatus.modified.rawValue
                            existing.syncLocalModifiedAt = Date()
                        }
                        skipped += 1
                        continue
                    }
                    // Last write wins, but always apply a server deletion so clock skew can't block it.
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        row.apply(to: existing)
                        updated += 1
                    }
                } else {
                    // No local row for a server row that's already deleted.
                    guard !row.isDeleted else { skipped += 1; continue }
                    context.insert(TrackEntity(from: row))
                    inserted += 1
                }
            }
            // Saved per page so an interrupted pull keeps what it read.
            try context.save()
        }

        guard total > 0 else {
            MixLog.sync.debug("↓ Tracks: nothing new since last pull")
            setLastPullDate(table: "tracks", userID: userID)
            return
        }

        setLastPullDate(table: "tracks", userID: userID)
        if inserted + updated > 0 { didWriteLocally = true; announceWork() }
        MixLog.sync.debug("↓ Tracks: \(inserted) new, \(updated) updated, \(skipped) skipped")
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
            MixLog.sync.debug("↓ Albums: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "albums", userID: userID)
    }

    private func pullArtists(userID: UUID) async throws {
        let since = lastPullDate(table: "artists", userID: userID)

        var inserted = 0, updated = 0
        let total = try await pullPages(from: "artists", userID: userID, since: since) { (rows: [ArtistRow]) in
            let local = existingArtists(ids: rows.map(\.id))
            // `ArtistEntity.name` is unique, so a colliding insert silently replaces the existing row and drops its
            // artwork. Match existing rows by name first.
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
            MixLog.sync.debug("↓ Artists: \(inserted) new, \(updated) updated")
        }
        setLastPullDate(table: "artists", userID: userID)
    }

    /// Insert-only and unfiltered by track: a play for a not-yet-pulled song still counts, and the stats
    /// aggregator ignores ids it can't resolve.
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
            MixLog.sync.debug("↓ Play history: \(inserted) new")
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

                    // Same pending-deletion rule as `pullTracks`. A saved mix has a deterministic id
                    // (`PersonalMix.savedPlaylistID`), so an old deletion on one device would otherwise hide the same mix
                    // saved later on another, forever.
                    let deletionPending = existing.syncStatus != SyncStatus.synced.rawValue
                    if existing.isSoftDeleted || existing.syncStatus == SyncStatus.deleted.rawValue {
                        if row.isDeleted || (deletionPending && existing.syncLocalModifiedAt >= row.updatedAt) {
                            skipped += 1
                            continue
                        }
                        // Fall through: the server row is live and newer, so `apply(to:)` undeletes it.
                    }
                    // Last write wins, but always apply a server deletion.
                    if row.isDeleted || row.updatedAt > existing.syncLocalModifiedAt {
                        // `apply(to:)` drops the local blob when the other device deleted the cover; note it so the sidebar's
                        // cached image goes too.
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
        MixLog.sync.debug("↓ Playlists: \(inserted) new, \(updated) updated, \(skipped) skipped")
    }

    // MARK: - Pending Count

    /// The exact number of rows this device owes the server; drives the visible pending count. Applies the
    /// Swift-side `isPushable` filter so a stuck non-pushable row reads as zero, not pending forever.
    private func pendingCount() -> Int {
        let tracks    = (try? fetchPendingTracks())?.count    ?? 0
        let albums    = (try? fetchPendingAlbums())?.count    ?? 0
        let artists   = (try? fetchPendingArtists())?.count   ?? 0
        let playlists = (try? fetchPendingPlaylists())?.count ?? 0
        let plays     = (try? fetchPendingPlayHistory())?.count ?? 0
        return tracks + albums + artists + playlists + plays
    }

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
        // Which rows are ours to write is decided in Swift: it needs `resolvedOrigin`, which a #Predicate can't express.
        return try context.fetch(
            FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.syncStatus != synced })
        ).filter(Self.isPushable)
    }

    /// Whether a pending track is this user's to push. The one row that must never go up is the shadow
    /// minted for a song in someone else's shared playlist: it carries the owner's track id, so upserting it
    /// violates RLS (42501) and fails the whole sync.
    private static func isPushable(_ entity: TrackEntity) -> Bool {
        switch entity.resolvedOrigin {
        case .unresolvableShare:
            return false
        case .online:
            // Metadata only; `source_ref` lets another device resolve the audio itself.
            return true
        case .localFile:
            // Never reached (watched-folder rows aren't saved), but pushing one would point other devices at a
            // path that exists only here.
            return false
        case .edit:
            // The recipe syncs; other devices rebuild a quick edit from their own original
            // and stream a studio edit's uploaded file.
            return true
        case .imported:
            // A local import has a localPath; a synced track keeps its syncServerID; an uploaded song with no
            // local copy still has its remoteKey. Any of those means metadata edits should sync.
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
    // Batch lookups for a pull page, so matching a thousand rows is one fetch, not a thousand. Pages are
    // saved before the next is read, so rows the loop inserts needn't be in these tables.

    private func existingTracks(ids: [UUID]) -> [UUID: TrackEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<TrackEntity>(predicate: #Predicate { ids.contains($0.id) })
        // Only the id: fetching the full row pulled every artwork blob into memory just to compare timestamps.
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func existingAlbums(ids: [UUID]) -> [UUID: AlbumEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<AlbumEntity>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    private func existingArtists(ids: [UUID]) -> [UUID: ArtistEntity] {
        guard !ids.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<ArtistEntity>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        return Dictionary((try? context.fetch(descriptor))?.map { ($0.id, $0) } ?? [],
                          uniquingKeysWith: { first, _ in first })
    }

    /// The same lookup by name, the other unique key, to catch a new id whose name is already taken.
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

    /// Wipes every track/album/artist row and audio file for this user on the server. Rows are soft-deleted
    /// (is_deleted, updated_at = now) so other devices clear their libraries on their next pull.
    public func deleteAllServerData() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        let uid = userID.uuidString
        let now = iso8601Now()

        MixLog.sync.debug("Soft-deleting all server data for user \(uid)…")

        // 1. Soft-delete live rows only. Re-stamping old tombstones resets the clock the tombstone pruner reads,
        // so a library that wipes now and then could never prune.
        let wipe = WipePayload(updatedAt: now)
        try await client.from("tracks")   .update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        MixLog.sync.debug("Soft-deleted tracks")
        try await client.from("albums")   .update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        MixLog.sync.debug("Soft-deleted albums")
        try await client.from("artists")  .update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        MixLog.sync.debug("Soft-deleted artists")
        try await client.from("playlists").update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        MixLog.sync.debug("Soft-deleted playlists")

        // 2. Hard-delete audio from Storage (non-fatal). Once is_deleted propagates the files are unreachable anyway.
        let folder = userID.uuidString.lowercased()
        do {
            let files = try await storageList(bucket: "audio", path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await storageRemove(bucket: "audio", paths: paths)
                MixLog.sync.debug("Deleted \(paths.count) audio file(s) from Storage")
            } else {
                MixLog.sync.debug("No audio files in Storage for this user")
            }
        } catch {
            MixLog.sync.error("Storage delete failed (non-fatal): \(error)")
        }

        MixLog.sync.debug("Server wipe complete")
    }

    // MARK: - Reset

    /// Hard-deletes the account's play history on the server. Hard, not soft: every device is being told the
    /// same thing by the same button, and plays have no local edits to lose.
    public func deleteAllServerPlayHistory() async throws {
        guard let userID = currentUser?.id else { return }
        try await client.from("play_history")
            .delete()
            .eq("user_id", value: userID.uuidString)
            .execute()
        MixLog.sync.debug("Deleted server play history for \(userID.uuidString)")
    }

    public func deleteAllServerTracks() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        try await client.from("tracks") .update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        try await client.from("albums") .update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        try await client.from("artists").update(wipe).setHeader(name: Self.bulkHeader, value: "clear").eq("user_id", value: uid).eq("is_deleted", value: false).execute()
        MixLog.sync.debug("Soft-deleted all server tracks/albums/artists for \(uid)")

        // Remove audio files from Storage (non-fatal).
        let folder = uid.lowercased()
        do {
            let files = try await storageList(bucket: "audio", path: folder)
            let paths = files.compactMap { f -> String? in
                f.name.isEmpty ? nil : "\(folder)/\(f.name)"
            }
            if !paths.isEmpty {
                try await storageRemove(bucket: "audio", paths: paths)
                MixLog.sync.debug("Deleted \(paths.count) audio file(s) from Storage")
            }
        } catch {
            MixLog.sync.error("Storage delete failed (non-fatal): \(error)")
        }
    }

    /// Soft-deletes all user playlists on the server; All Songs and Favourites are left alone.
    public func deleteAllServerUserPlaylists() async throws {
        guard let userID = currentUser?.id else {
            throw NSError(domain: "SyncService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let uid  = userID.uuidString
        let wipe = WipePayload(updatedAt: iso8601Now())

        // Exclude the two system playlists by their stable UUIDs.
        try await client.from("playlists")
            .update(wipe).setHeader(name: Self.bulkHeader, value: "clear")
            .eq("user_id", value: uid)
            // Live rows only; see `deleteAllServerData`.
            .eq("is_deleted", value: false)
            .neq("id", value: Playlist.favouritesID.uuidString.lowercased())
            .neq("id", value: Playlist.allSongsID.uuidString.lowercased())
            .execute()
        MixLog.sync.debug("Soft-deleted all server user playlists for \(uid)")
    }

    /// Clears the stored pull timestamps so the next sync pulls everything. Call after clearing the local library.
    /// Takes the user explicitly: on sign-out `currentUser` is already nil, and on an account switch the new
    /// user isn't set yet.
    public func resetSyncTimestamps(for explicitUserID: UUID? = nil) {
        guard let userID = explicitUserID ?? currentUser?.id else { return }
        for table in ["tracks", "albums", "artists", "playlists"] {
            UserDefaults.standard.removeObject(forKey: lastPullDateKey(table: table, userID: userID))
        }
        MixLog.sync.debug("[SupabaseSyncService] Sync timestamps reset, next pull will fetch all server records")
    }

    // MARK: - Last Pull Timestamps (per table per user, stored in UserDefaults)

    private func hasPulledOnce(userID: UUID) -> Bool {
        UserDefaults.standard.object(forKey: lastPullDateKey(table: "playlists", userID: userID)) != nil
    }

    private func lastPullDateKey(table: String, userID: UUID) -> String {
        "mix.sync.\(table).lastPull.\(userID.uuidString)"
    }

    /// How far back of the already-pulled window each pull re-reads. `updated_at` comes from the pushing
    /// device's clock, so a slow clock can write below our watermark; five minutes covers real drift without
    /// re-fetching a day of rows on every sync.
    private static let pullOverlap: TimeInterval = 300

    /// A very old date if we've never pulled, so the first pull fetches everything.
    private func lastPullDate(table: String, userID: UUID) -> String {
        let key = lastPullDateKey(table: table, userID: userID)
        if let stored = UserDefaults.standard.string(forKey: key) {
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

    /// Playlist covers travel by path, not by column. The playlists table has no `artwork_key`, but both
    /// devices can build `<userID>/playlists/<playlistID>.jpg`. The local `artworkKey` only notes the upload happened.
    private func uploadPendingPlaylistArtworks(userID: UUID) async throws {
        try await deletePendingPlaylistArtworks(userID: userID)

        let playlists = try fetchPlaylistsNeedingArtworkUpload()
        MixLog.sync.debug("Found \(playlists.count) playlist(s) needing artwork upload")
        guard !playlists.isEmpty else { return }

        var uploadedAny = false
        for entity in playlists {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                MixLog.sync.error("Compression failed for playlist artwork: \(entity.name)")
                continue
            }

            let remotePath = Self.playlistArtworkPath(userID: userID, playlistID: entity.id)
            do {
                try await storageUpload(bucket: "artwork", path: remotePath,
                                        data: compressed, contentType: "image/jpeg")

                entity.artworkKey = remotePath
                // Ours is now the bucket's copy, so the next listing mustn't read as a remote change.
                entity.artworkRemoteStamp = Date()
                uploadedAny = true
                MixLog.sync.debug("Uploaded playlist artwork: \(entity.name) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                MixLog.sync.error("Upload failed for playlist artwork (\(entity.name)): \(error)")
            }
        }

        // No re-push: `artworkKey` never leaves this device, so the server row hasn't changed.
        if uploadedAny {
            try context.save()
        }
    }

    /// Removes covers the user deleted from the bucket. Without this the next sync lists the folder and
    /// hands the deleted cover back.
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
                MixLog.sync.debug("Removed playlist artwork: \(entity.name)")
            } catch {
                // A cover that was never uploaded has nothing to remove; clear the flag anyway or every sync retries it.
                MixLog.sync.error("Playlist artwork remove failed (treating as gone): \(error)")
            }
            entity.artworkNeedsRemoteDelete = false
            changed = true
        }
        if changed { try context.save() }
    }

    private func uploadPendingTrackArtworks(userID: UUID) async throws {
        let tracks = try fetchTracksNeedingArtworkUpload()
        MixLog.sync.debug("Found \(tracks.count) track(s) needing artwork upload")
        guard !tracks.isEmpty else { return }

        var uploadedAny = false
        for entity in tracks {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                MixLog.sync.error("Compression failed for track artwork: \(entity.title)")
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
                MixLog.sync.debug("Uploaded track artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                MixLog.sync.error("Upload failed for track artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushTracks(userID: userID)
        }
    }

    private func uploadPendingAlbumArtworks(userID: UUID) async throws {
        let albums = try fetchAlbumsNeedingArtworkUpload()
        MixLog.sync.debug("Found \(albums.count) album(s) needing artwork upload")
        guard !albums.isEmpty else { return }

        var uploadedAny = false
        for entity in albums {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                MixLog.sync.error("Compression failed for album artwork: \(entity.title)")
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
                MixLog.sync.debug("Uploaded album artwork: \(entity.title) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                MixLog.sync.error("Upload failed for album artwork (\(entity.title)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushAlbums(userID: userID)
        }
    }

    private func uploadPendingArtistArtworks(userID: UUID) async throws {
        let artists = try fetchArtistsNeedingArtworkUpload()
        MixLog.sync.debug("Found \(artists.count) artist(s) needing artwork upload")
        guard !artists.isEmpty else { return }

        var uploadedAny = false
        for entity in artists {
            guard !shouldStopWork else { return }
            guard let rawData = entity.artworkData else { continue }

            guard let compressed = await compressArtwork(data: rawData) else {
                MixLog.sync.error("Compression failed for artist artwork: \(entity.name)")
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
                MixLog.sync.debug("Uploaded artist artwork: \(entity.name) (\(compressed.count / 1024)KB) -> \(remotePath)")
            } catch {
                MixLog.sync.error("Upload failed for artist artwork (\(entity.name)): \(error)")
            }
        }

        if uploadedAny {
            try context.save()
            try await pushArtists(userID: userID)
        }
    }

    /// Max artwork requests per sync run, so a coverless library doesn't fire thousands at once. The rest
    /// come on the next sync (`artworkBacklog`), not the ten-minute floor.
    private static let artworkDownloadBudget = 300

    /// Bucket requests in flight at once. One at a time, a new device took minutes per budget; at 8 Storage
    /// answered 429 "too many connections" for about one in six.
    private static let artworkConcurrency = 4

    /// Remaining requests in this run, shared by all four artwork kinds.
    private var artworkDownloadsLeft = 0

    /// This run ran out of budget with covers still to fetch.
    private var artworkBacklog = false

    /// Whether this run put anything in the disk cache worth trimming for.
    private var artworkCacheGrew = false

    /// Covers for `keys`, from the disk cache if present, otherwise from the bucket. A key missing from the
    /// result was out of budget, not missing. Only bucket fetches spend the budget.
    /// ponytail: cache hits are unbounded, so a returning user restores every cover in one pass. Cap it like
    /// the download budget if that ever bites.
    private func artworks(at keys: [String], stamps: [String: Date] = [:]) async -> [String: Result<Data, Error>] {
        var seen = Set<String>()
        var queue = keys.filter { !$0.isEmpty && seen.insert($0).inserted }[...]
        var out: [String: Result<Data, Error>] = [:]
        let client = self.client
        while !queue.isEmpty, !shouldStopWork {
            let chunk = queue.prefix(Self.artworkConcurrency)
            queue = queue.dropFirst(chunk.count)
            let mayDownload = artworkDownloadsLeft > 0
            var throttled = false
            await withTaskGroup(of: (String, Result<Data, Error>?, Bool).self) { group in
                for key in chunk {
                    let stamp = stamps[key]
                    group.addTask {
                        await Self.fetchArtwork(client: client, key: key, stamp: stamp, mayDownload: mayDownload)
                    }
                }
                for await (key, result, fromBucket) in group {
                    if fromBucket { artworkDownloadsLeft -= 1 }
                    guard let result else { artworkBacklog = true; continue }
                    // Throttled, not missing: try again later in this run. The budget bounds the retries.
                    if case .failure(let error) = result, isThrottled(error) {
                        queue.append(key)
                        throttled = true
                        continue
                    }
                    if fromBucket, case .success = result { artworkCacheGrew = true }
                    out[key] = result
                }
            }
            if throttled { try? await Task.sleep(for: .seconds(1)) }
        }
        return out
    }

    private func isThrottled(_ error: Error) -> Bool {
        (error as? StorageError)?.statusCode == "429"
    }

    /// One cover, off the main actor. Nil when it isn't cached and `mayDownload` is false.
    @concurrent
    private nonisolated static func fetchArtwork(client: SupabaseClient, key: String, stamp: Date?,
                                                 mayDownload: Bool) async -> (String, Result<Data, Error>?, Bool) {
        if let hit = ArtworkDiskCache.data(for: key, stamp: stamp) { return (key, .success(hit), false) }
        guard mayDownload else { return (key, nil, false) }
        do {
            let data = try await client.storage.from("artwork").download(path: key)
            ArtworkDiskCache.store(data, for: key, stamp: stamp)
            return (key, .success(data), true)
        } catch {
            return (key, .failure(error), true)
        }
    }

    /// The row names a bucket object that isn't there. It'll 404 on every sync, so the key is cleared and the
    /// row stops being a download candidate; if it gets local artwork later, the upload pass writes a fresh key.
    private func isMissingObject(_ error: Error) -> Bool {
        guard let storage = error as? StorageError else { return false }
        return storage.statusCode == "404" || storage.error == "not_found"
    }

    // MARK: - Storage, off the main actor

    // Off the main actor via `Task.detached`: under SE-0461 the Supabase chain runs on the caller's actor,
    // and the download was hanging the main thread on launch. Same rule as `pullPages`. Downloads go
    // through `fetchArtwork`.

    private func storageUpload(bucket: String, path: String,
                               data: Data, contentType: String) async throws {
        let client = self.client
        try await Task.detached(priority: .utility) {
            _ = try await client.storage.from(bucket).upload(
                path, data: data,
                options: FileOptions(contentType: contentType, upsert: true))
        }.value
        // Cache covers we sent so a dropped store doesn't fetch them back. Playlists are left out; see `ArtworkDiskCache`.
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

    /// Playlist covers aren't here: `runSync` fetches them first, before the library is shown.
    private func downloadPendingArtworks(userID: UUID) async throws {
        defer {
            if artworkCacheGrew {
                artworkCacheGrew = false
                Task.detached(priority: .background) { ArtworkDiskCache.trim() }
            }
        }
        try await downloadPendingTrackArtworks(userID: userID)
        try await downloadPendingAlbumArtworks(userID: userID)
        try await downloadPendingArtistArtworks(userID: userID)
        if artworkBacklog {
            MixLog.sync.debug("⏸ Artwork download budget spent, the rest come on the next sync")
        }
    }

    /// The other side of `uploadPendingPlaylistArtworks`. With no key on the row, one listing of
    /// `<userID>/playlists/` says what exists, instead of guessing a path (and a 404) per coverless playlist.
    private func downloadPendingPlaylistArtworks(userID: UUID) async throws {
        let playlists = try fetchPlaylistsNeedingArtworkDownload()
        guard !playlists.isEmpty else { return }

        let folder = "\(userID.uuidString.lowercased())/playlists"
        let remote: [String: Date?]
        do {
            let files = try await storageList(bucket: "artwork", path: folder, limit: 1000)
            // The listing is the only thing that knows when each cover was written, so it decides what to fetch.
            remote = Dictionary(files.map { ($0.name, $0.updatedAt) },
                                uniquingKeysWith: { a, _ in a })
        } catch {
            MixLog.sync.error("Could not list playlist artwork in \(folder): \(error)")
            return
        }

        let wanted = playlists.filter { entity in
            guard let stamp = remote["\(entity.id.uuidString.lowercased()).jpg"] else { return false }
            // No cover yet, or the bucket's differs from the one we last took. A missing date fetches once.
            guard entity.artworkData != nil, let local = entity.artworkRemoteStamp,
                  let stamp else { return true }
            return stamp > local
        }
        MixLog.sync.debug("Found \(wanted.count) playlist(s) needing artwork download")
        guard !wanted.isEmpty else { return }

        var stamps: [String: Date] = [:]
        for entity in wanted {
            let stamp = remote["\(entity.id.uuidString.lowercased()).jpg"] ?? nil
            stamps[Self.playlistArtworkPath(userID: userID, playlistID: entity.id)] = stamp
        }
        let fetched = await artworks(at: wanted.map { Self.playlistArtworkPath(userID: userID, playlistID: $0.id) },
                                     stamps: stamps)
        guard !shouldStopWork else { return }

        var downloadedAny = false
        for entity in wanted {
            let key = Self.playlistArtworkPath(userID: userID, playlistID: entity.id)
            switch fetched[key] {
            case .success(let data)?:
                entity.artworkData  = data
                // So the upload pass doesn't send back what it just received.
                entity.artworkKey = key
                entity.artworkRemoteStamp = stamps[key] ?? Date()
                libraryService.noteCoverChanged(playlistID: entity.id)
                downloadedAny = true
            case .failure(let error)?:
                MixLog.sync.error("Download failed for playlist artwork (\(entity.name)) from \(key): \(error)")
            case nil:
                continue
            }
        }

        // The next refresh in `runSync` puts these on screen.
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
        MixLog.sync.debug("Found \(tracks.count) track(s) needing artwork download")
        guard !tracks.isEmpty else { return }

        let fetched = await artworks(at: tracks.compactMap(\.artworkKey))
        guard !shouldStopWork else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in tracks {
            guard let key = entity.artworkKey, let result = fetched[key] else { continue }
            switch result {
            case .success(let data):
                entity.artworkData = data
                // Only this row's cached image gets dropped in the end-of-sync refresh.
                libraryService.noteArtworkChanged(.track(entity.id))
                downloadedAny = true
            case .failure(let error) where isMissingObject(error):
                entity.artworkKey = nil
                // The cleared key has to sync, or the next pull copies the dead one back.
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                downloadedAny = true
                missingCount += 1
            case .failure(let error):
                MixLog.sync.error("Download failed for track artwork (\(entity.title)) from \(key): \(error)")
            }
        }

        if missingCount > 0 {
            MixLog.sync.debug("\(missingCount) track cover(s) had no object in the bucket, keys cleared, they won't be retried")
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
        MixLog.sync.debug("Found \(albums.count) album(s) needing artwork download")
        guard !albums.isEmpty else { return }

        let fetched = await artworks(at: albums.compactMap(\.artworkKey))
        guard !shouldStopWork else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in albums {
            guard let key = entity.artworkKey, let result = fetched[key] else { continue }
            switch result {
            case .success(let data):
                entity.artworkData = data
                libraryService.noteArtworkChanged(.album(entity.id))
                downloadedAny = true
            case .failure(let error) where isMissingObject(error):
                entity.artworkKey = nil
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                downloadedAny = true
                missingCount += 1
            case .failure(let error):
                MixLog.sync.error("Download failed for album artwork (\(entity.title)) from \(key): \(error)")
            }
        }

        if missingCount > 0 {
            MixLog.sync.debug("\(missingCount) album cover(s) had no object in the bucket, keys cleared, they won't be retried")
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
        MixLog.sync.debug("Found \(artists.count) artist(s) needing artwork download")
        guard !artists.isEmpty else { return }

        let fetched = await artworks(at: artists.compactMap(\.artworkKey))
        guard !shouldStopWork else { return }

        var downloadedAny = false
        var missingCount = 0
        for entity in artists {
            guard let key = entity.artworkKey, let result = fetched[key] else { continue }
            switch result {
            case .success(let data):
                entity.artworkData = data
                libraryService.noteArtworkChanged(.artist(entity.id))
                downloadedAny = true
            case .failure(let error) where isMissingObject(error):
                entity.artworkKey = nil
                entity.syncStatus = SyncStatus.modified.rawValue
                entity.syncLocalModifiedAt = Date()
                downloadedAny = true
                missingCount += 1
            case .failure(let error):
                MixLog.sync.error("Download failed for artist artwork (\(entity.name)) from \(key): \(error)")
            }
        }

        if missingCount > 0 {
            MixLog.sync.debug("\(missingCount) artist cover(s) had no object in the bucket, keys cleared, they won't be retried")
        }

        if downloadedAny {
            didWriteLocally = true
            try context.save()
        }

        if missingCount > 0 {
            try await pushArtists(userID: userID)
        }
    }

    /// Counts for the sync log via `fetchCount`, so the artwork blobs aren't loaded to print three numbers.
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
            MixLog.sync.debug("[Sync Debug] \(label) - Total: \(total), with artworkData: \(art), with artworkKey: \(key)")
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

    /// Runs a fetch whose predicate includes an `artworkData` nil-check, so the store can answer without
    /// reading the blob. `legacy` is the old Swift-filter descriptor, a fallback if the store can't evaluate
    /// that clause; results match, only cost differs. Both branches are spanned so a slow one shows up.
    private func fetchTolerantly<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        legacy: FetchDescriptor<T>,
        label: String,
        fallback: (T) -> Bool
    ) throws -> [T] {
        if let rows = mixMainActivity("sync/artwork-scan ▸ \(label) fast", { try? context.fetch(descriptor) }) {
            return rows
        }
        MixLog.sync.warning("artwork scan fell back to the in-memory filter for \(label), every blob is being loaded")
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

    /// Every coverless playlist; the bucket listing in `downloadPendingPlaylistArtworks` narrows it down.
    private func fetchPlaylistsNeedingArtworkDownload() throws -> [PlaylistEntity] {
        let none = PlaylistCoverKind.none.rawValue
        // Two kinds of candidate: no cover, or a cover another device changed (`artworkStale`), so edits cross
        // too. `.none` is excluded: the user deleted that cover.
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

    /// Off the main thread via `Task.detached`. An artwork burst runs this ~40 times (decode, resample, JPEG
    /// encode each). Under Swift 6.2 (SE-0461) `nonisolated async` would inherit the main actor.
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
