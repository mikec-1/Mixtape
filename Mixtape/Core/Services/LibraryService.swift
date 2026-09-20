// LibraryService.swift
// Mixtape — Core/Services
//
// Single source of truth for the in-memory library.
// Reads from the SwiftData repositories and vends @Published collections
// that ViewModels can observe.

import Foundation
import SwiftData
import Combine
import OSLog

@MainActor
public final class LibraryService: ObservableObject {

    // MARK: - Published Library State

    @Published public private(set) var tracks:    [Track]    = [] {
        didSet {
            revision &+= 1
            trackRevision &+= 1
            rebuildTrackCoverIndex()
            rebuildTrackIndex()
            // Dropped, not rebuilt. Building one normalises every title in the
            // library through four regexes, and `tracks` is replaced by every
            // refresh — including the once-a-minute sync tail, which no import
            // follows. Paid for on the first read instead, which is a save or
            // an import asking "do I already own this?".
            cachedRecordingIndex = nil
        }
    }

    // MARK: - Offline Filter

    /// Whether there is a network. Nothing is hidden on account of it — a song
    /// that can't play offline is drawn grey and says so when tapped, the way
    /// Spotify does. Screens read it to decide how to draw, and the Downloaded
    /// filter switches itself on when it goes true.
    @Published public var offlineOnly: Bool = false

    /// The Downloaded filter: a user choice, not a network fact. While true the
    /// *display* accessors below hide songs with no file on this device.
    /// `tracks` itself is never filtered: sync, the smart-playlist generators
    /// and the Spotify push all read it, and a generator that ran against a
    /// filtered library would rewrite real playlists with whatever happened to
    /// be downloaded. See [[mixtape-offline-mode]].
    @Published public var downloadedOnly: Bool = false {
        // The memo caches that key on `revision` have no other way to hear that
        // the same ids now resolve to a shorter list.
        didSet {
            guard oldValue != downloadedOnly else { return }
            revision &+= 1
            trackRevision &+= 1
        }
    }

    /// What is playable with no network — supplied by `AppDependencies` rather
    /// than held, so the library keeps no reference to the download manager.
    public var offlinePlayableIDs: () -> Set<UUID> = { [] }

    /// `tracks`, minus what can't play, when offline. Every list that exists to
    /// be looked at reads this; everything that computes reads `tracks`.
    public var displayTracks: [Track] {
        guard downloadedOnly else { return tracks }
        let playable = offlinePlayableIDs()
        return tracks.filter { playable.contains($0.id) }
    }

    /// `track(id:)` for the same display lists — nil while offline for a song
    /// that isn't here. Playback still uses `track(id:)`, which never lies.
    public func displayTrack(id: UUID) -> Track? {
        guard let t = track(id: id) else { return nil }
        guard downloadedOnly else { return t }
        return offlinePlayableIDs().contains(id) ? t : nil
    }

    /// Bumped every time `tracks` or `playlists` is replaced.
    ///
    /// Views that derive an expensive list from the library — a playlist
    /// filtered and sorted, a Home shelf — cache that result and compare this
    /// number to decide whether the cache still stands. Comparing the arrays
    /// themselves would cost more than recomputing, and comparing `count`
    /// misses an edit that leaves the count alone.
    ///
    /// Favourites count as a playlist edit, which is why this watches both:
    /// toggling a heart never touches `tracks`.
    ///
    /// Deliberately not `@Published`: it changes in lockstep with them, so
    /// a second announcement would only double the work it exists to avoid.
    public private(set) var revision: UInt64 = 0

    /// Bumped only when `tracks` is replaced.
    ///
    /// For the caches whose input is the track array and an explicit list of
    /// ids — a playlist page's resolved, filtered, sorted rows — and nothing
    /// else. Those were keyed on `revision`, which meant any playlist write
    /// invalidated them, and playing a song is a playlist write: `playAndMark`
    /// records a last-played date and calls `refreshPlaylists()`. On a 2000-song
    /// playlist that turned one press into a re-resolve, re-filter and re-sort
    /// of every row before the resolver was even called — measured at 1.5 s in
    /// the `press → resolve` leg, and only ever reported on big playlists,
    /// because that is the only size at which the work is visible.
    ///
    /// A change to which songs a playlist *contains* still invalidates them:
    /// the id list is part of the same cache key.
    public private(set) var trackRevision: UInt64 = 0
    @Published public private(set) var albums:    [Album]    = []
    @Published public private(set) var artists:   [Artist]   = []
    /// Playlists, with Favourites always pinned at index 0.
    @Published public private(set) var playlists: [Playlist] = [] {
        didSet { revision &+= 1 }
    }

    // MARK: - Dependencies

    private let trackRepo:    TrackRepository
    private let albumRepo:    AlbumRepository
    private let artistRepo:   ArtistRepository
    private let playlistRepo: PlaylistRepository
    private let favoriteRepo: FavoriteRepository
    private let deviceID:     String

    /// Reads the library on its own context, off the main actor. See
    /// `refreshOffMain()`.
    ///
    /// Optional so the tests and previews that build a `LibraryService` from
    /// repositories alone keep working — without one, `refreshOffMain()` is the
    /// synchronous `refresh()`.
    ///
    /// Where the thread comes from is decided by `LibrarySnapshotReader` itself
    /// — see the note there on why it is no longer a `@ModelActor`. Building it
    /// here on the main actor is fine: it holds nothing but the container.
    private let snapshotReader = LibrarySnapshotReader()

    // MARK: - Local change signal

    /// Fires when something *changed the library*, as opposed to when the
    /// library merely re-published what it already had.
    ///
    /// `objectWillChange` cannot tell those apart, and one subscriber badly
    /// needs it to: `SupabaseSyncService.startLocalChangeWatch` uses the
    /// library's change notification as its "there is something to push"
    /// trigger. But a sync *ends* in `refresh()`, and `refresh()` republishes
    /// four arrays — so the sync's own tail looked exactly like a fresh local
    /// edit. That fed back into the push scheduler and produced the wall of
    /// `Sync failed: CancellationError()` the user reported on 2026-09-01.
    ///
    /// Guarding it on the sync side fixed the symptom; this removes the false
    /// signal at the source. Anything that wants "the user changed something"
    /// should listen here, and only view invalidation should use
    /// `objectWillChange`.
    public let localChanges = PassthroughSubject<Void, Never>()

    /// Non-zero while a refresh pass is republishing. Nested rather than a
    /// Bool: `loadForDisplay` can have a pass in flight when another begins.
    private var refreshDepth = 0

    /// Forwards `objectWillChange` to `localChanges`, minus the republishes.
    private var localChangeForward: AnyCancellable?

    private func startLocalChangeForwarding() {
        localChangeForward = objectWillChange
            .sink { [weak self] _ in
                guard let self, self.refreshDepth == 0 else { return }
                self.localChanges.send()
            }
    }

    /// Called for each track just *before* it leaves the library, while it is
    /// still in `tracks`.
    ///
    /// The library owns the row, the audio file and the tombstone; it doesn't own
    /// the offline copy, the download queue, or what's currently playing. Those
    /// belong to `DownloadManager` and `PlaybackEngine`, both of which hold a
    /// reference to this service — so the wiring goes the other way, as a hook
    /// `AppDependencies` installs, the same shape as `PlaybackEngine.onlineRouter`.
    ///
    /// Before rather than after because `DownloadManager.removeDownloads(for:)`
    /// starts by looking each track up here: called on rows already tombstoned it
    /// finds nothing and quietly does nothing, which is how a deleted song keeps
    /// its download.
    /// Takes the whole selection, not one song: everything behind it writes to
    /// disk or republishes, and a per-song hook made deleting a large import
    /// thousands of those on the main thread.
    public var onTracksWillDelete: ((Set<UUID>) -> Void)?

    /// A playlist that arrived from outside has just been created — an import,
    /// a Spotify transfer, a saved or restored share. Same wiring shape and the
    /// same reason as `onTracksWillDelete`: what happens next is
    /// `DownloadManager`'s business, and the library must not learn about it.
    ///
    /// Deliberately *not* "a new playlist appeared". Playlists appear in bulk
    /// the first time an account syncs, and treating those as imports would
    /// download the user's whole library behind their back — the exact failure
    /// `DownloadManager.loadKeepOffline` was written to stop happening twice.
    /// Only callers that pass `imported: true` fire this.
    public var onPlaylistImported: ((UUID) -> Void)?

    // MARK: - Init

    public init(
        trackRepo:    TrackRepository,
        albumRepo:    AlbumRepository,
        artistRepo:   ArtistRepository,
        playlistRepo: PlaylistRepository,
        favoriteRepo: FavoriteRepository,
        deviceID:     String
    ) {
        self.trackRepo    = trackRepo
        self.albumRepo    = albumRepo
        self.artistRepo   = artistRepo
        self.playlistRepo = playlistRepo
        self.favoriteRepo = favoriteRepo
        self.deviceID     = deviceID

        startLocalChangeForwarding()
        ensureSystemPlaylists()
        observePinChanges()
    }

    /// Brings a freshly-opened store up to what the rest of the app assumes is
    /// in it, and republishes everything read from the old one.
    ///
    /// Called at launch and again whenever `ModelStore` opens a different
    /// account's file. A first sign-in on this device lands on an empty store,
    /// and Favourites has to exist before anything tries to draw it.
    public func storeDidOpen() {
        ensureSystemPlaylists()
        // Every cover was keyed on a row in the file just closed.
        noteAllArtworkChanged()
        refresh()
    }

    private func ensureSystemPlaylists() {
        try? playlistRepo.ensureFavourites(deviceID: deviceID)
        // Deliberately not seeded. All Songs is derived now — `refresh()` fills
        // it from what holds each song (see `heldTrackIDs`) — so a seed here
        // would only list rows the next refresh removes again.
        _ = try? playlistRepo.ensureAllSongs(deviceID: deviceID)
    }

    /// Pinned playlists sort to the top of `playlists`, but that ordering is
    /// decided here, once, in `refreshPlaylists`. `PlaylistMetadataService`
    /// redrawing its own observers is not enough to move a row — so a pin
    /// toggle has to come back through here.
    private func observePinChanges() {
        pinObserver = NotificationCenter.default.addObserver(
            forName: .mixPlaylistPinsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPlaylists() }
        }
    }

    private var pinObserver: NSObjectProtocol?

    deinit {
        if let pinObserver { NotificationCenter.default.removeObserver(pinObserver) }
    }

    /// Rescues imported originals that an earlier build swept into the purgeable
    /// `Library/Caches/Music/` folder.
    ///
    /// A track that has never been uploaded has no copy on the server, so the
    /// file in the cache is the only one that exists — and the OS is free to
    /// evict it at any time. Playback kept working off the cache copy, so this
    /// was invisible right up until the file vanished. Only the library database
    /// can say which files those are, which is why the move happens here rather
    /// than in the path layer.
    /// Deliberately not called from `init` any more.
    ///
    /// It was a second full `fetchAll` of the whole library plus a `fileExists`
    /// per candidate, on the main thread, before the first window existed — a
    /// large part of the 662 ms the launch marks attributed to building
    /// `LibraryService`. It is a rescue for a build that shipped a long time
    /// ago, so it can happen after the app is on screen; it reads the tracks
    /// the first refresh has already published rather than fetching them again.
    public func reclaimNeverUploadedAudioFromCache() {
        let tracks = self.tracks
        let atRisk = tracks.filter {
            !$0.file.uploaded
                && ($0.file.remoteKey?.isEmpty ?? true)
                && !$0.file.localPath.isEmpty
                && !$0.isOnline
        }
        let filenames = Set(atRisk.map { ($0.file.localPath as NSString).lastPathComponent })
        guard !filenames.isEmpty else { return }
        Task.detached(priority: .utility) {
            _ = AudioPaths.reclaimFromCache(filenames: filenames)
        }
    }

    // MARK: - Refresh

    /// What the library is busy doing, for whoever draws a spinner.
    ///
    /// Reading the library is not instant and never announced itself, so a first
    /// launch looked like a broken screen: an empty list, no indication anything
    /// was happening, and then everything at once. This is what the sidebar and
    /// the Library tab show while that runs.
    public enum Activity: Equatable {
        case idle
        /// `detail` is the count when there is one to give — "2,010 songs".
        case working(String, detail: String?)

        var label: String? {
            if case .working(let l, _) = self { return l }
            return nil
        }
        var detail: String? {
            if case .working(_, let d) = self { return d }
            return nil
        }
    }

    @Published public private(set) var activity: Activity = .idle

    /// Announces a piece of library work, and takes the announcement back when
    /// the body returns — including when it throws.
    func withActivity<T>(_ label: String, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        activity = .working(label, detail: detail)
        defer { activity = .idle }
        return try body()
    }

    /// The same announcement, for work that spans awaits rather than one call.
    ///
    /// Paired rather than scoped because the sync service's use of it straddles
    /// a network round trip, and `refresh()` deliberately keeps quiet while an
    /// announcement is already standing — so the label the user sees for the
    /// whole operation is the one that describes it, not "Updating library".
    public func beginActivity(_ label: String, detail: String? = nil) {
        activity = .working(label, detail: detail)
    }

    public func endActivity() {
        activity = .idle
    }

    /// A refresh that has been asked for but not run yet. See `scheduleRefresh`.
    private var pendingRefreshTask: Task<Void, Never>?

    /// The live track ids as of the last refresh that ran the repair passes.
    ///
    /// `nil` until the first refresh, so a launch always repairs once — which is
    /// what a migration wants, and it is also the only chance a library changed
    /// by another process gets to be noticed.
    private var lastRepairedTrackIDs: Set<UUID>?

    /// Cost of the three `fetchAll` calls in the last refresh, and whether that
    /// refresh also paid for the repair passes. Reported on the refresh log line
    /// so the two halves can be told apart.
    private var fetchMilliseconds = 0
    private var didRunRepairs = false

    /// Asks for a refresh soon, collapsing a burst of requests into one run.
    ///
    /// `refresh()` is not cheap and never was: it re-reads every track, album
    /// and artist out of SwiftData, sweeps and rewrites the album and artist
    /// rows, rebuilds three indexes and republishes four arrays — which
    /// invalidates the entire view tree. Paying that once is fine. Paying it
    /// once *per imported song*, on the main actor, is quadratic, and it is why
    /// importing a couple of thousand songs locked the app up and left it
    /// sluggish afterwards.
    ///
    /// So anything that runs in a loop asks for a refresh instead of performing
    /// one, and the loop ends up costing a single pass. Callers that need the
    /// published state to be current right now call `flushPendingRefresh()`.
    public func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Off the main actor, like the sync path. This is already an async
            // context 250 ms after the fact — nothing here is inside the user
            // action that wrote, so there is no read-your-write reason to pay
            // for the blocking form. A hang sample caught this exact closure
            // holding the main thread for the length of `TrackRepository`'s
            // bulk fetch during an import.
            await self?.refreshOffMain()
        }
    }

    /// Runs a scheduled refresh now, if one is still waiting. No-op otherwise,
    /// so a batch can end with this unconditionally without paying for a second
    /// pass over the library.
    public func flushPendingRefresh() {
        guard pendingRefreshTask != nil else { return }
        refresh()
    }

    /// Whether `refresh()` has completed at least once since launch.
    ///
    /// A screen that appears wants the library *loaded*, not re-read. Those were
    /// the same thing while the app was small; at 2,100 tracks, 3,700 albums and
    /// 1,500 artists a full pass is a second of main-thread time, and paying it
    /// every time a tab comes back is what made leaving a playlist feel like it
    /// hung.
    public private(set) var hasLoaded = false

    /// What a screen calls when it appears: playlists on screen now, the rest
    /// a moment later.
    ///
    /// `refreshIfNeeded()` does the same work in one main-actor turn, so nothing
    /// it produced could be drawn until all of it was — which is why opening the
    /// Library tab on a cold launch showed an empty list for as long as the read
    /// took. This publishes the cheap half, hands the main actor back so SwiftUI
    /// can actually paint it, and only then pays for the rest.
    ///
    /// The expensive read now runs off the main actor too (`refreshOffMain()`),
    /// so the frame this hands back stays interactive for the whole load rather
    /// than only until the fetch starts. The repair-and-publish half still runs
    /// here, because it writes through the main-actor repositories.
    public func loadForDisplay() async {
        guard !hasLoaded else { return }

        refreshPlaylists()
        activity = .working("Loading library", detail: nil)
        // A frame, not a yield: `Task.yield()` hands the main *actor* back but
        // does not guarantee a trip through the run loop, and without one the
        // list and the spinner would be published into the same frame that the
        // blocking read below already owns.
        try? await Task.sleep(for: .milliseconds(16))

        await refreshOffMain()
        activity = .idle
    }

    /// Loads the library if it has never been loaded, and does nothing if it
    /// has.
    ///
    /// Safe to call from every `.task`/`.onAppear` that needs data on screen:
    /// the published arrays are kept current by whoever writes to them, so a
    /// second full read can only ever produce the values already being shown.
    public func refreshIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    /// Re-reads all entities from SwiftData and updates published properties.
    /// Cross-references album/artist trackID arrays against live tracks so that
    /// any bucket whose songs have all been deleted is soft-deleted and hidden.
    public func refresh() {
        guard !holdRefreshes else { pendingFullRefresh = true; return }
        let pass = beginRefreshPass()
        do {
            let fetchStarted = CFAbsoluteTimeGetCurrent()
            let allTracks  = try mixMainActivity("library-refresh/fetch-tracks")  { try trackRepo.fetchAll()  }
            let allAlbums  = try mixMainActivity("library-refresh/fetch-albums")  { try albumRepo.fetchAll()  }
            let allArtists = try mixMainActivity("library-refresh/fetch-artists") { try artistRepo.fetchAll() }
            apply(LibrarySnapshot(
                tracks:  allTracks,
                albums:  allAlbums,
                artists: allArtists,
                tracksWithArtwork: nil,
                fetchMilliseconds: Int((CFAbsoluteTimeGetCurrent() - fetchStarted) * 1000)
            ))
        } catch {
            print("[LibraryService] refresh tracks/albums/artists failed: \(error)")
        }
        endRefreshPass(pass)
    }

    /// `refresh()`, with the three bulk fetches moved off the main actor.
    ///
    /// The fetch is the expensive half and it needs nothing from the main actor
    /// — it reads rows and hands back `Sendable` structs. `LibrarySnapshotReader`
    /// runs it against its own private context, so the ~1 s the main-actor path
    /// spends unable to draw a frame becomes an `await` the run loop is free
    /// during. Everything after the fetch — the repair passes, the writes they
    /// make, publishing the arrays — stays here, because all of it goes through
    /// the main-actor repositories and the `@Published` properties.
    ///
    /// The write paths keep calling the synchronous `refresh()` on purpose: they
    /// run inside a user action that has already saved through `mainContext`,
    /// and a read against a second context could still be looking at the store
    /// as it was before that save.
    public func refreshOffMain() async {
        // The reader looks at the store through its own context, so anything
        // still sitting unsaved in `mainContext` would be invisible to it. The
        // write paths save as they go, but a batch that ended a moment ago may
        // not have flushed yet, and a refresh that silently drops the change it
        // was called to publish is worse than a slow one.
        let context = trackRepo.modelContext
        if context.hasChanges { try? context.save() }

        let pass = beginRefreshPass()
        do {
            apply(try await snapshotReader.read(container: ModelStore.shared.container))
        } catch {
            print("[LibraryService] refresh tracks/albums/artists failed: \(error)")
        }
        endRefreshPass(pass)
    }

    /// What both refresh paths do before the fetch: announce themselves, publish
    /// the cheap collection, and drop the artwork caches.
    private func beginRefreshPass() -> RefreshPass {
        // Everything published between here and `endRefreshPass` is a
        // republish, not an edit — see `localChanges`.
        refreshDepth += 1

        // Whatever a pending refresh was going to do, this pass is doing now.
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil

        // Only if nothing else has already said what it is doing: `refresh()` is
        // the tail of imports, syncs and wipes, and each of those has a better
        // name for itself than "Updating library".
        let announced = activity == .idle
        if announced {
            activity = .working("Updating library",
                                detail: tracks.isEmpty ? nil : "\(tracks.count) songs")
        }

        // Playlists first, not only last. They are a cheap read that depends on
        // nothing below, and publishing them here means a screen that opens on
        // the playlist list has something to draw before the expensive pass —
        // rather than an empty list until every track, album and artist has been
        // read and swept.
        refreshPlaylists()

        // Every path that writes a cover — import, sync download, the backfill,
        // a picked image — ends in a refresh, so this is the one place that
        // has to forget the old picture. It used to forget *every* picture,
        // which is why adding a single playlist made the whole app redraw its
        // icons and stall: a 2,000-song library threw away 2,000 cached covers
        // to pick up one. The writers now name what they changed instead, and
        // only those rows are dropped. `noteAllArtworkChanged()` remains for
        // the cases where everything genuinely is stale — a wipe, an account
        // switch, memory pressure.
        flushDirtyArtwork()

        return RefreshPass(
            signpost: MixSignpost.database.beginInterval("library-refresh",
                                                        id: MixSignpost.database.makeSignpostID()),
            started:  CFAbsoluteTimeGetCurrent(),
            announced: announced
        )
    }

    private func endRefreshPass(_ pass: RefreshPass) {
        refreshPlaylists()
        refreshDepth = max(0, refreshDepth - 1)
        if pass.announced { activity = .idle }
        MixSignpost.database.endInterval("library-refresh", pass.signpost)
        let ms = Int((CFAbsoluteTimeGetCurrent() - pass.started) * 1000)
        MixLog.database.info("library-refresh \(ms, privacy: .public) ms (fetch \(self.fetchMilliseconds, privacy: .public) ms, repairs \(self.didRunRepairs ? "yes" : "no", privacy: .public)) — \(self.tracks.count, privacy: .public) tracks, \(self.albums.count, privacy: .public) albums, \(self.artists.count, privacy: .public) artists")
    }

    private struct RefreshPass {
        let signpost:  OSSignpostIntervalState
        let started:   CFAbsoluteTime
        let announced: Bool
    }

    /// The repair-and-publish half of a refresh, given rows somebody else read.
    ///
    /// Main-actor by inheritance and it has to be: every repair below writes
    /// through a `@MainActor` repository, and the three assignments at the end
    /// are `@Published`.
    private func apply(_ snapshot: LibrarySnapshot) {
        mixMainActivity("library-refresh/apply") { applyOnMain(snapshot) }
    }

    private func applyOnMain(_ snapshot: LibrarySnapshot) {
        // The repair sweeps below soft-delete or save every bucket they touch,
        // and each of those was its own `ModelContext` commit — the unnamed
        // second inside a 1414 ms `library-refresh/apply`. See
        // `RepositorySaveBatch`.
        RepositorySaveBatch.run(trackRepo.modelContext) { applyOnMainBody(snapshot) }
    }

    private func applyOnMainBody(_ snapshot: LibrarySnapshot) {
            let allTracks  = snapshot.tracks
            let allAlbums  = snapshot.albums
            let allArtists = snapshot.artists
            fetchMilliseconds = snapshot.fetchMilliseconds
            // Marked once the read has actually succeeded, not in the `defer`: a
            // refresh that threw has loaded nothing, and `refreshIfNeeded`
            // callers must still be able to bring the library in.
            hasLoaded = true

            let liveIDs = Set(allTracks.map(\.id))

            // The repair passes below are migrations, not maintenance: composite
            // artist rows, tracks no artist or album row claims, playlist entries
            // pointing at deleted songs. They only have anything to do when the
            // set of live tracks has changed since the last time they ran — and
            // running them anyway is most of what made a steady-state refresh
            // cost ~1.9 s of main-thread time on every sync tick.
            let repairsNeeded = liveIDs != lastRepairedTrackIDs
            if repairsNeeded { lastRepairedTrackIDs = liveIDs }
            didRunRepairs = repairsNeeded

            // Sweep albums: soft-delete any whose trackIDs contain no live tracks
            if repairsNeeded {
            mixMainActivity("library-refresh/sweep-buckets") {
            for var album in allAlbums {
                // Counted first, list built only when it turns out to differ:
                // the sweep touches nothing in the common case, so the array
                // the old form always allocated was almost always discarded.
                let liveCount = album.trackIDs.count(where: liveIDs.contains)
                if liveCount == album.trackIDs.count, liveCount > 0 { continue }
                let live = album.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else if live.count != album.trackIDs.count {
                    // Prune stale IDs while we're here
                    album.trackIDs = live
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }

            // Sweep artists: same
            for var artist in allArtists {
                let liveCount = artist.trackIDs.count(where: liveIDs.contains)
                if liveCount == artist.trackIDs.count, liveCount > 0 { continue }
                let live = artist.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else if live.count != artist.trackIDs.count {
                    artist.trackIDs = live
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }

            }
            // Libraries imported before credit splitting landed contain rows
            // named after the whole credit string ("c4rl, Yungpalo"). Break
            // those apart so each artist gets their own page.
            }

            var artistsNow = allArtists
            var albumsNow  = allAlbums
            if repairsNeeded { beginRepairCollection() }

            if repairsNeeded, mixMainActivity("library-refresh/repair-composite-artists", { splitCompositeArtists(artistsNow) }) {
                artistsNow = mergeRepairedArtists(into: artistsNow)
            }

            // Adopt any track that no artist row claims. Only the import path
            // creates artist rows, so tracks that arrive another way (synced
            // from another device, restored from the export folder) were
            // missing from the Artists section entirely even though they showed
            // up under Songs.
            if repairsNeeded, mixMainActivity("library-refresh/adopt-orphan-tracks", { adoptOrphanTracks(allTracks, knownArtists: artistsNow) }) {
                artistsNow = mergeRepairedArtists(into: artistsNow)
                // Rows born here (Spotify playlist import, songs synced from
                // another device) wear an album cover until a real photo is
                // fetched for them.
                scheduleArtistImageBackfill()
            }

            // Same story for albums: those tracks had no Album row either, so
            // they were missing from the Albums section and `album(title:
            // artistName:)` couldn't find them. Runs after the artist pass so
            // the rows the album link attaches to already exist.
            if repairsNeeded, mixMainActivity("library-refresh/adopt-orphan-albums", { adoptOrphanAlbums(allTracks, knownAlbums: albumsNow) }) {
                albumsNow  = mergeRepairedAlbums(into: albumsNow)
                artistsNow = mergeRepairedArtists(into: artistsNow)
            }

            mixMainActivity("library-refresh/publish-tracks") {
                // Assigning an *identical* array is the single most expensive
                // thing a refresh does, and it is invisible to every span here.
                //
                // `@Published` announces on assignment, not on change, so a sync
                // that pulled "0 new, 0 updated" still replaced 2,131 tracks,
                // 3,736 albums and 1,473 artists with equal values — and SwiftUI
                // then re-evaluated and re-diffed every view observing the
                // library. That is the ~2.4 s hang that follows every
                // `library-refresh` line in the log, sitting in no span because
                // it happens after the refresh returns, in SwiftUI's own update.
                //
                // Comparing first is cheap by comparison: these are `Hashable`
                // value types, the comparison short-circuits on the first
                // difference, and the artwork blobs are not in these rows (the
                // fetch leaves them behind), so it is an id-and-scalar walk.
                //
                // The one that changed still publishes, so a real edit is as
                // immediate as it ever was — this only removes the announcements
                // that carried no news.
                let tracksChanged = tracks != allTracks
                if tracksChanged {
                    // When the reader already answered "which tracks have a
                    // cover?" on its own actor, don't ask again here: the
                    // `didSet` version is a full-table fetch with a predicate
                    // against an external-storage attribute.
                    if let covers = snapshot.tracksWithArtwork {
                        suppressCoverIndexRebuild = true
                        tracks = allTracks
                        suppressCoverIndexRebuild = false
                        tracksWithArtwork = covers
                    } else {
                        tracks = allTracks
                    }
                } else if let covers = snapshot.tracksWithArtwork, tracksWithArtwork != covers {
                    // Same list of songs, different set of covers — a sync that
                    // downloaded artwork lands here.
                    tracksWithArtwork = covers
                }
            }
            // `contains(where:)`, not `!filter(...).isEmpty`: the old form
            // allocated an array per bucket to ask a yes/no question, over
            // ~3700 albums and ~1500 artists, on every refresh. That was most
            // of the second inside `library-refresh/apply` that none of its
            // named children accounted for.
            mixMainActivity("library-refresh/publish-buckets") {
                // Same reasoning as `publish-tracks`: announce only a change.
                let liveAlbums  = dedupeAlbums(albumsNow.filter { $0.trackIDs.contains(where: liveIDs.contains) },
                                               persist: repairsNeeded)
                let liveArtists = artistsNow.filter { $0.trackIDs.contains(where: liveIDs.contains) }
                if albums  != liveAlbums  { albums  = liveAlbums }
                if artists != liveArtists { artists = liveArtists }
            }

            // Playlists holding ids for songs that are gone. See the method.
            if repairsNeeded { mixMainActivity("library-refresh/prune-playlists") { prunePlaylistsOfDeletedTracks(allTracks) } }

            // Ensure All Songs is always a perfectly accurate reflection of the local library.
            // Since tracks can be synced from other devices, we dynamically rebuild the All Songs
            // playlist on every refresh to guarantee it matches exactly what we have locally.
            mixMainActivity("library-refresh/all-songs") {
                migrateMembershipIfNeeded(allTracks)
                if var allSongs = try? playlistRepo.fetch(id: Playlist.allSongsID) {
                    let albumOnly = SavedAlbumsService.shared.albumOnlyIDs
                    let held      = heldTrackIDs()
                    // Album-only songs are held (their album keeps them) but are
                    // not listed here, same as Spotify keeps a saved album out of
                    // Liked Songs.
                    let expectedIDs = allTracks.sorted { $0.dateImported < $1.dateImported }.map(\.id)
                        .filter { held.contains($0) && !albumOnly.contains($0) }
                    if allSongs.trackIDs != expectedIDs {
                        allSongs.trackIDs = expectedIDs
                        try? playlistRepo.save(allSongs)
                    }
                }
            }
    }

    // MARK: - Incremental publish

    /// Publishes rows this device just wrote, without re-reading the library.
    ///
    /// The write paths used to end in `refresh()`, which re-fetches every
    /// track, album and artist from the store, runs the repair sweeps and
    /// rebuilds All Songs — a second or more of main-thread time to publish
    /// twenty-four new rows. Saving a mix from Discover spent all of it inside
    /// the button press, which is what the beachball was.
    ///
    /// This is the same publish for the case where we already know exactly what
    /// changed. It appends the rows, extends All Songs, and stops. The repair
    /// sweeps are deliberately skipped: they exist to catch buckets that went
    /// stale behind our back — a deletion arriving over sync, a bucket whose
    /// songs are all gone — and neither can be true of rows written a moment
    /// ago in this process. The next full refresh still runs them.
    ///
    /// Callers that need album and artist buckets updated for the new rows
    /// should do that work themselves, off the press; `ImportService` does.
    public func insertLocally(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }

        // Anything already published is an update, not an insert — a save that
        // wrote over a soft-deleted row lands here.
        var byID = Dictionary(uniqueKeysWithValues: newTracks.map { ($0.id, $0) })
        var merged = tracks
        for i in merged.indices {
            if let replacement = byID.removeValue(forKey: merged[i].id) { merged[i] = replacement }
        }
        let appended = newTracks.filter { byID[$0.id] != nil }
        merged.append(contentsOf: appended)

        // Straight from the rows we are holding, rather than the full-table
        // fetch `rebuildTrackCoverIndex` does. That fetch runs a predicate
        // against an external-storage attribute and is one of the costs this
        // whole path exists to avoid paying per save.
        var covers = tracksWithArtwork
        for track in newTracks where track.artworkData != nil { covers.insert(track.id) }

        // The assignment's `didSet` would otherwise run the full-table fetch
        // and throw `covers` away, which is the cost this path exists to skip.
        suppressCoverIndexRebuild = true
        tracks = merged           // rebuilds the id and recording indexes
        suppressCoverIndexRebuild = false
        tracksWithArtwork = covers

        // Deliberately does not extend All Songs. That list is derived from
        // what holds a song now (see `heldTrackIDs`), and these rows are not
        // held yet — the like or the playlist that holds them lands a moment
        // later and brings the scheduled refresh that lists them.
        refreshPlaylists()
    }

    /// Re-publishes the album and artist arrays alone.
    ///
    /// The counterpart to `insertLocally` for the work it deliberately defers:
    /// a caller that has just filed new rows into their buckets calls this to
    /// put those buckets on screen, without the track fetch and the repair
    /// sweeps a full `refresh()` would also run.
    public func publishBuckets() {
        let liveIDs = Set(tracks.lazy.filter { !$0.isDeleted }.map(\.id))
        albums  = dedupeAlbums(((try? albumRepo.fetchAll())  ?? albums)
            .filter { $0.trackIDs.contains(where: liveIDs.contains) }, persist: false)
        artists = ((try? artistRepo.fetchAll()) ?? artists)
            .filter { $0.trackIDs.contains(where: liveIDs.contains) }
    }

    /// One row per record. Songs imported through different paths each grew
    /// their own Album row for the same album — one with the cover, one
    /// without — so the Library listed it twice. Keeps the row with artwork
    /// (then the most songs), folds the others' songs into it, and with
    /// `persist` soft-deletes the losers so they sync away too.
    private func dedupeAlbums(_ rows: [Album], persist: Bool) -> [Album] {
        var winners: [String: Album] = [:]
        var order: [String] = []
        var losers: [Album] = []
        var touched = Set<String>()
        for row in rows {
            let key = SavedAlbumsService.key(title: row.title, artistName: row.artistName)
            guard var kept = winners[key] else { winners[key] = row; order.append(key); continue }
            func score(_ a: Album) -> (Int, Int) { ((a.artworkKey != nil || a.artworkData != nil) ? 1 : 0, a.trackIDs.count) }
            var loser = row
            if score(row) > score(kept) { swap(&kept, &loser) }
            for id in loser.trackIDs where !kept.trackIDs.contains(id) { kept.trackIDs.append(id) }
            winners[key] = kept
            losers.append(loser)
            touched.insert(key)
        }
        guard !losers.isEmpty else { return rows }
        if persist {
            for loser in losers { try? albumRepo.softDelete(id: loser.id) }
            for key in touched { if var w = winners[key] { w.sync.markModified(); try? albumRepo.save(w) } }
        }
        return order.compactMap { winners[$0] }
    }

    /// Drops playlist entries whose track has been deleted for good.
    ///
    /// Deleting locally already does this — `deleteTracks(ids:)` purges every
    /// playlist in the same write. A deletion that arrives *over sync* does not:
    /// `pullTracks` applies the tombstone to the track row and stops there, so
    /// the playlist keeps an id pointing at nothing. The symptom is a header
    /// that counts songs the list can't show — clear the library on one device
    /// and the other still says Favourites has 1 song, with nothing in it.
    ///
    /// Two things are deliberately left alone:
    ///
    /// • ids whose track has no local row **at all**. That is not a deletion,
    ///   it's a song this device hasn't pulled yet, and pruning it would delete
    ///   somebody's playlist contents for the crime of syncing slowly.
    /// • ids whose track is a restore candidate (`isResurrected`). Those are
    ///   tombstones this device applied in error, and "Restore Missing Songs"
    ///   only means anything while the playlist still has a slot to put them
    ///   back into.
    ///
    /// Only playlists this device may edit. A subscribed playlist's track list
    /// belongs to whoever published it, and our local deletion is not news about
    /// their playlist.
    private func prunePlaylistsOfDeletedTracks(_ liveTracks: [Track]) {
        // Tombstones first, and bail on an empty set before touching the
        // playlist store: with nothing deleted there is nothing to prune, and
        // fetching every playlist only to discard it is the common case, not
        // the rare one. Both fetches are spanned because this whole function
        // measured 758 ms on the main actor and the loop below is in-memory.
        // Everything tombstoned, minus the ones we might still put back.
        let goneForGood = mixMainActivity("library-refresh/prune ▸ fetch-tombstones") {
            Set(
                ((try? trackRepo.fetchSoftDeleted()) ?? [])
                    .filter { !Self.isResurrected($0) }
                    .map(\.id)
            )
        }
        guard !goneForGood.isEmpty else { return }

        guard let all = mixMainActivity("library-refresh/prune ▸ fetch-playlists", {
            try? playlistRepo.fetchAll()
        }) else { return }

        let liveIDs = Set(liveTracks.map(\.id))

        for var playlist in all where playlist.isEditable || playlist.isSystem {
            guard !playlist.trackIDs.isEmpty else { continue }
            let kept = playlist.trackIDs.filter { !goneForGood.contains($0) || liveIDs.contains($0) }
            guard kept.count != playlist.trackIDs.count else { continue }
            let dropped = Set(playlist.trackIDs).subtracting(kept)
            playlist.trackIDs = kept
            // Touched rather than saved quietly: the id is gone from this
            // playlist now, and every other device should hear about it.
            playlist.touch()
            try? playlistRepo.save(playlist)
            // Same reason as the local delete path: the songs the cover was
            // composed from have changed. A deletion that arrives over sync is
            // still a deletion.
            rebakeDerivedCover(forPlaylist: playlist.id)
            // Favourites is mirrored by its own rows, and a heart that outlives
            // the song comes straight back the next time an id matches.
            if playlist.isFavourites {
                for id in dropped { try? favoriteRepo.remove(trackID: id) }
            }
        }
    }

    /// Migrates artist rows whose name is really several credits ("c4rl, Yungpalo")
    /// into one row per credited artist, then retires the composite row.
    /// Returns true if anything was written.
    // MARK: - Repair bookkeeping

    /// Rows the repair passes wrote, so `apply` doesn't have to re-read the store.
    ///
    /// Each of the three passes used to be followed by `artistRepo.fetchAll()`
    /// — up to four whole-table reads per refresh, none of them inside a span,
    /// and on the Mac an itemised one of those measured 166-333 ms. That is the
    /// second and a bit inside a 1560 ms `library-refresh/apply` that none of
    /// its named children ever accounted for, and it was paid on every sync
    /// that changed anything. The passes already hold the rows they just saved,
    /// so they hand them over instead.
    private var repairedArtists: [UUID: Artist] = [:]
    private var repairedAlbums:  [UUID: Album]  = [:]
    private var retiredArtists:  Set<UUID>      = []

    private func beginRepairCollection() {
        repairedArtists.removeAll(keepingCapacity: true)
        repairedAlbums.removeAll(keepingCapacity: true)
        retiredArtists.removeAll(keepingCapacity: true)
    }

    /// Blobs are dropped on the way in: these rows came from `findOrCreate`,
    /// which reads the whole row, while the bulk fetch these merge into
    /// deliberately carries no artwork. Keeping them would put a cover per
    /// repaired row into a published array.
    private func noteRepaired(_ artist: Artist) {
        var row = artist
        row.artworkData = nil
        repairedArtists[row.id] = row
    }

    private func noteRepaired(_ album: Album) {
        var row = album
        row.artworkData = nil
        repairedAlbums[row.id] = row
    }

    private func mergeRepairedArtists(into rows: [Artist]) -> [Artist] {
        guard !repairedArtists.isEmpty || !retiredArtists.isEmpty else { return rows }
        var pending = repairedArtists
        var merged = rows.compactMap { row -> Artist? in
            if retiredArtists.contains(row.id) { pending[row.id] = nil; return nil }
            return pending.removeValue(forKey: row.id) ?? row
        }
        // Rows `findOrCreate` invented are in neither the fetch nor the list.
        merged.append(contentsOf: pending.values.filter { !retiredArtists.contains($0.id) })
        return merged
    }

    private func mergeRepairedAlbums(into rows: [Album]) -> [Album] {
        guard !repairedAlbums.isEmpty else { return rows }
        var pending = repairedAlbums
        var merged = rows.map { pending.removeValue(forKey: $0.id) ?? $0 }
        merged.append(contentsOf: pending.values)
        return merged
    }

    private func splitCompositeArtists(_ knownArtists: [Artist]) -> Bool {
        var didWrite = false

        for composite in knownArtists where !composite.isDeleted {
            let credits = ImportService.creditedArtists(from: composite.name)
            guard credits.count > 1 else { continue }

            for name in credits {
                guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                      artist.id != composite.id else { continue }

                var modified = false
                for id in composite.trackIDs where !artist.trackIDs.contains(id) {
                    artist.trackIDs.append(id)
                    modified = true
                }
                for id in composite.albumIDs where !artist.albumIDs.contains(id) {
                    artist.albumIDs.append(id)
                    modified = true
                }
                // `composite` came from the bulk fetch and carries no blob —
                // the store is the only place to get one.
                if artist.artworkData == nil,
                   let art = ArtworkProvider.shared.data(for: .artist(composite.id)) {
                    artist.artworkData = art
                    noteArtworkChanged(.artist(artist.id))
                    modified = true
                }
                guard modified else { continue }
                artist.sync.markModified()
                try? artistRepo.save(artist)
                noteRepaired(artist)
                didWrite = true
            }

            // The composite row's tracks now live on the individual rows, so
            // retiring it can't orphan anything.
            try? artistRepo.softDelete(id: composite.id)
            retiredArtists.insert(composite.id)
            didWrite = true
        }
        return didWrite
    }

    /// Files every track that isn't in any artist row under each of its credited
    /// artists, creating rows as needed. Returns true if anything was written.
    private func adoptOrphanTracks(_ allTracks: [Track], knownArtists: [Artist]) -> Bool {
        var claimed = Set<UUID>()
        for artist in knownArtists where !artist.isDeleted {
            claimed.formUnion(artist.trackIDs)
        }

        // Group the leftovers by credited artist so each artist row is fetched,
        // mutated and saved once rather than once per track. A featured track
        // lands under every artist on the credit, same as the import path.
        var byArtist: [String: [UUID]] = [:]
        for track in allTracks where !claimed.contains(track.id) {
            for name in ImportService.creditedArtists(from: track.artistName) {
                byArtist[name, default: []].append(track.id)
            }
        }
        guard !byArtist.isEmpty else { return false }

        for (name, trackIDs) in byArtist {
            guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID) else { continue }
            let missing = trackIDs.filter { !artist.trackIDs.contains($0) }
            guard !missing.isEmpty else { continue }
            artist.trackIDs.append(contentsOf: missing)
            // Give a freshly created row a face, so it isn't a blank circle.
            if artist.artworkData == nil,
               let art = allTracks.lazy.filter({ missing.contains($0.id) })
                   .compactMap({ ArtworkProvider.shared.data(for: .track($0.id)) }).first {
                artist.artworkData = art
                noteArtworkChanged(.artist(artist.id))
            }
            artist.sync.markModified()
            try? artistRepo.save(artist)
            noteRepaired(artist)
        }
        return true
    }

    /// The bucket an album row is filed under — album title plus the *primary*
    /// artist, matching the key `ImportService.updateAlbum(for:)` uses.
    private struct AlbumKey: Hashable {
        let title: String
        let artistName: String
    }

    /// Files every track that isn't in any album row under its (album title,
    /// primary artist) bucket, creating rows as needed. Returns true if anything
    /// was written.
    private func adoptOrphanAlbums(_ allTracks: [Track], knownAlbums: [Album]) -> Bool {
        var claimed = Set<UUID>()
        for album in knownAlbums where !album.isDeleted {
            claimed.formUnion(album.trackIDs)
        }

        // Group the leftovers so each album row is fetched, mutated and saved
        // once rather than once per track. Grouping by the primary artist keeps a
        // featured track on the headliner's album instead of starting a second
        // one called "A, B" — same as the import path.
        var byAlbum: [AlbumKey: [UUID]] = [:]
        for track in allTracks where !claimed.contains(track.id) {
            // A single has nothing to sit in; an album called "" would be a
            // permanent blank row in the Albums grid.
            guard !track.albumTitle.isEmpty else { continue }
            let key = AlbumKey(
                title:      track.albumTitle,
                artistName: ImportService.primaryArtistName(from: track.artistName)
            )
            byAlbum[key, default: []].append(track.id)
        }
        guard !byAlbum.isEmpty else { return false }

        for (key, trackIDs) in byAlbum {
            guard var album = try? albumRepo.findOrCreate(
                title:      key.title,
                artistName: key.artistName,
                deviceID:   deviceID
            ) else { continue }

            let missing = trackIDs.filter { !album.trackIDs.contains($0) }
            guard !missing.isEmpty else { continue }
            album.trackIDs.append(contentsOf: missing)

            // Give a freshly created row a cover and a year, so it isn't a blank
            // tile in the grid.
            let adopted = allTracks.filter { missing.contains($0.id) }
            if album.artworkData == nil {
                album.artworkData = adopted.lazy
                    .compactMap { ArtworkProvider.shared.data(for: .track($0.id)) }.first
                if album.artworkData != nil { noteArtworkChanged(.album(album.id)) }
            }
            if album.year == nil {
                album.year = adopted.compactMap(\.year).first
            }

            album.sync.markModified()
            try? albumRepo.save(album)
            noteRepaired(album)
            linkAlbum(album, toArtistsCreditedOn: adopted)
        }
        return true
    }

    /// Makes the album ↔ artist link the import path makes in `attachTrack`: the
    /// artist pages list albums by `albumIDs`, not by track membership, so an
    /// adopted album is invisible there until it's registered on every credit.
    private func linkAlbum(_ album: Album, toArtistsCreditedOn tracks: [Track]) {
        var names = Set<String>()
        for track in tracks {
            names.formUnion(ImportService.creditedArtists(from: track.artistName))
        }
        for name in names {
            guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                  !artist.albumIDs.contains(album.id) else { continue }
            artist.albumIDs.append(album.id)
            artist.sync.markModified()
            try? artistRepo.save(artist)
            noteRepaired(artist)
        }
    }

    /// Stores a pin on the playlist row.
    ///
    /// `PlaylistMetadataService` is what the screens ask, but it has no
    /// repository — this is the hook it writes back through. See `pinWriter`.
    public func setPlaylistPinned(id: UUID, pinned: Bool) {
        guard let playlist = try? playlistRepo.fetch(id: id), playlist.isPinned != pinned else { return }
        mutatePlaylist(id: id) {
            $0.isPinned = pinned
            // Touched, not saved quietly: the whole point is that the other
            // device hears about it.
            $0.touch()
        }
        refreshPlaylists()
    }

    /// Stores the user's arrangement on the playlist rows.
    ///
    /// `ids` is the whole visible sequence, not a pair of indices: the order is
    /// rewritten from what the user can see, so the very first drag has
    /// something complete to say rather than describing a list that has never
    /// heard of most of the rows. Anything not named keeps whatever index it
    /// had, and un-arranged playlists stay un-arranged.
    ///
    /// Only rows whose index actually changes are touched, so dragging one
    /// playlist doesn't send the entire library to the other device.
    public func setPlaylistOrder(_ ids: [UUID]) {
        for (index, id) in ids.enumerated() {
            guard let playlist = try? playlistRepo.fetch(id: id),
                  playlist.sortIndex != index else { continue }
            mutatePlaylist(id: id) {
                $0.sortIndex = index
                // Touched, not saved quietly: the whole point is that the other
                // device hears about it.
                $0.touch()
            }
        }
        refreshPlaylists()
    }

    public func refreshPlaylists() {
        guard !holdRefreshes else { pendingPlaylistRefresh = true; return }
        mixMainActivity("library-refresh/playlists") { refreshPlaylistsBody() }
    }

    // MARK: - Coalesced refreshes

    private var refreshHoldDepth = 0
    private var pendingFullRefresh = false
    private var pendingPlaylistRefresh = false
    private var holdRefreshes: Bool { refreshHoldDepth > 0 }

    /// Runs `body` with the published-state rebuilds held until it returns, then
    /// does at most one of each.
    ///
    /// A full `refresh()` re-reads every track, album and artist — measured at
    /// 1.5-2 s on this library — and several write paths trigger one per item
    /// they touch. Deleting four playlists meant four full refreshes plus four
    /// playlist refreshes, all on the main actor, which is the multi-second
    /// beachball. The reads are idempotent, so collapsing them costs nothing:
    /// the last one would have produced the same answer as all of them.
    @discardableResult
    public func coalescingRefreshes<T>(_ body: () -> T) -> T {
        refreshHoldDepth += 1
        let result = body()
        refreshHoldDepth -= 1
        guard refreshHoldDepth == 0 else { return result }

        let full = pendingFullRefresh
        let playlists = pendingPlaylistRefresh
        pendingFullRefresh = false
        pendingPlaylistRefresh = false
        // Off the main actor. The coalesced tail is the last thing a batch of
        // writes does, and by the time it runs those writes have already been
        // saved through `mainContext` — which is the one condition the
        // synchronous `refresh()` exists to guarantee. So the caveat on
        // `refreshOffMain()` doesn't apply here, and the three bulk fetches
        // (measured at 309 + 333 + 166 ms) plus the apply (587 ms) stop being
        // a second and a half of frozen window after deleting playlists.
        if playlists { refreshPlaylists() }
        if full {
            Task { [weak self] in await self?.refreshOffMain() }
        }
        return result
    }

    private func refreshPlaylistsBody() {
        invalidateFavouriteIndex()
        do {
            var all = try playlistRepo.fetchAll()
            let meta = PlaylistMetadataService.shared

            // Pins used to live in UserDefaults, which is why a playlist pinned
            // on the phone was unpinned on the Mac. They are a playlist property
            // now; this hands the ones this device already had over to the rows,
            // once, so upgrading doesn't read as everything being unpinned.
            if let legacy = meta.consumeLegacyPins() {
                // A device that never pinned anything still expects the two
                // system playlists at the top, which is what the old default did.
                let carried = legacy.isEmpty
                    ? [Playlist.allSongsID, Playlist.favouritesID]
                    : Array(legacy)
                for i in all.indices where carried.contains(all[i].id) && !all[i].isPinned {
                    all[i].isPinned = true
                    all[i].touch()
                    try? playlistRepo.save(all[i])
                }
            }

            // The Mac's drag order lived in UserDefaults for the same reason
            // pins did, with the same result: iOS never saw it. Hand it to the
            // rows once, so upgrading doesn't read as an arrangement being
            // thrown away. See `Playlist.sortIndex`.
            if let legacy = meta.consumeLegacySidebarOrder(), !legacy.isEmpty {
                let position = Dictionary(uniqueKeysWithValues:
                    legacy.enumerated().map { ($0.element, $0.offset) })
                for i in all.indices {
                    guard let index = position[all[i].id],
                          all[i].sortIndex != index else { continue }
                    all[i].sortIndex = index
                    all[i].touch()
                    try? playlistRepo.save(all[i])
                }
            }

            // The rows own this; the service is a published mirror of them.
            meta.adoptPins(Set(all.filter(\.isPinned).map(\.id)))

            // Pinned Playlists
            var pinned = all.filter(\.isPinned)
            // The user's arrangement first; then alphabetically, with All Songs
            // first and Favourites second among whatever they never arranged.
            pinned.sort { a, b in
                Self.arranged(a, b) {
                    if $0.isAllSongs { return true }
                    if $1.isAllSongs { return false }
                    if $0.isFavourites { return true }
                    if $1.isFavourites { return false }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }

            // Unpinned Playlists
            var unpinned = all.filter { !$0.isPinned }
            // Arrangement first, then last played (newest first) for the rest.
            unpinned.sort { a, b in
                Self.arranged(a, b) {
                    let dateA = meta.playlistLastPlayedDates[$0.id] ?? Date.distantPast
                    let dateB = meta.playlistLastPlayedDates[$1.id] ?? Date.distantPast
                    if dateA != dateB { return dateA > dateB }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            
            // Twice per refresh (`beginRefreshPass` and `endRefreshPass`), and
            // again from every write path — almost always with the same answer.
            // See `publish-tracks` for why an identical assignment is not free.
            let ordered = pinned + unpinned
            if playlists != ordered { playlists = ordered }
        } catch {
            print("[LibraryService] refresh playlists failed: \(error)")
        }
    }

    /// Orders two playlists by the user's own arrangement, falling back to a
    /// rule for the ones they never arranged.
    ///
    /// An arranged playlist always outranks an un-arranged one. That is what
    /// makes a half-arranged library read sensibly: the rows someone dragged
    /// stay where they were put, and everything else queues up behind them in
    /// whatever order that list is normally shown in — rather than the two
    /// groups interleaving by a number half of them don't have.
    private static func arranged(_ a: Playlist,
                                 _ b: Playlist,
                                 fallback: (Playlist, Playlist) -> Bool) -> Bool {
        switch (a.sortIndex, b.sortIndex) {
        case let (x?, y?): return x == y ? fallback(a, b) : x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return fallback(a, b)
        }
    }

    // MARK: - Clear

    /// Empties the local library completely: music, artwork, favourites and every
    /// user-made playlist. Only All Songs and Favourites survive, emptied — they
    /// are structural, and the app recreates them anyway.
    ///
    /// Listening history is deliberately not here; it isn't the library's to
    /// delete. `ListeningStatsService.resetHistory()` owns that, and Clear
    /// Everything calls both.
    /// Stops anything this service has running of its own accord.
    ///
    /// Right now that's the artist-photo backfill, which a first import leaves
    /// with hundreds of lookups to make — plenty of time for a wipe to land
    /// underneath it.
    /// Extra work to stop when the library stops its own.
    ///
    /// Same wiring shape and the same reason as `onTrackWillDelete`: the
    /// artwork compaction pass owns a `ModelContext` the library has no
    /// business knowing about, but a wipe has to stop it — it would otherwise
    /// go on re-encoding covers on rows that are being deleted underneath it.
    /// `AppDependencies` installs it.
    public var onCancelBackgroundWork: (() -> Void)?

    public func cancelBackgroundWork() {
        artistImageBackfillTask?.cancel()
        artistImageBackfillTask = nil
        cancelArtworkBackfill()
        onCancelBackgroundWork?()
    }

    public func clearAll() {
        cancelBackgroundWork()
        // Nothing survives this, so there is nothing worth naming — every
        // cached cover is about to point at a row that no longer exists.
        noteAllArtworkChanged()
        do {
            try trackRepo.deleteAll()
            try albumRepo.deleteAll()
            try artistRepo.deleteAll()
        } catch {
            print("[LibraryService] clearAll failed: \(error)")
        }
        // Favourites are their own rows; without this the hearts come back the
        // moment a song with a matching id is imported again.
        try? favoriteRepo.deleteAll()

        // Both audio directories, not just the legacy one. The playback cache moved
        // to Library/Caches/Music/, and for a while this removed only the old
        // Documents/Music/ path — which no longer exists, so the wipe reported
        // success and left every audio file exactly where it was.
        SupabaseFileStorageService.purgeLocalAudio()

        // Soft-delete, so the tombstones propagate if any device is still holding
        // a copy the server delete didn't reach.
        if let all = try? playlistRepo.fetchAll() {
            for playlist in all where !playlist.isSystem {
                try? playlistRepo.softDelete(id: playlist.id)
            }
        }
        // Reset system playlists to empty (keep the playlists, wipe their track lists)
        for systemID in [Playlist.favouritesID, Playlist.allSongsID] {
            if var p = try? playlistRepo.fetch(id: systemID) {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }
        refresh()
    }

    /// Stands the local store down so a full pull can rebuild it from the server.
    /// See `PlaylistRepository.yieldFavouritesToServer`.
    public func prepareForFullResync() {
        // The local rows are about to be replaced wholesale from the server.
        noteAllArtworkChanged()
        try? playlistRepo.yieldFavouritesToServer()
    }

    /// Brings back songs that a full re-sync tombstoned by mistake, and tells the
    /// server to drop the tombstone that did it.
    ///
    /// A song deleted from Discover and later saved again comes back under the
    /// *same* id — `OnlineTrack.stableID` hashes title and artist, so identity is
    /// deterministic rather than random. The server, meanwhile, still holds the
    /// original row marked `is_deleted`. Incremental pulls never ask for it
    /// again, so the two coexist quietly; a full re-sync asks for everything,
    /// the old tombstone comes back down, and `pullTracks` applies it to a track
    /// that has been alive again for days. `pullTracks` no longer does that, but
    /// libraries that have already been through it are still holding the damage,
    /// and nothing else can see it: the rows are soft-deleted, so every query in
    /// the app skips them, while the playlists that contain them still count them.
    /// That is the "6 songs" header above four rows.
    ///
    /// The test is `dateImported` against the server's own timestamp. A song
    /// imported *after* the server said it was deleted cannot be something the
    /// deletion was about. A genuine delete from another device fails that test —
    /// its row was imported long before the tombstone — so this can't resurrect
    /// something the user actually threw away.
    ///
    /// Marking them modified is the other half: without it the tombstone stays on
    /// the server and the next full re-sync kills the same songs again.
    @discardableResult
    /// Whether a tombstoned track is one this device buried by mistake.
    ///
    /// True only for the stale-server-record case: the row was imported *after*
    /// the server said it was deleted, so the tombstone is describing a song the
    /// user has since acquired again. A delete this device asked for and hasn't
    /// pushed yet is excluded — undoing that would be resurrecting something on
    /// the user's behalf — and so is an ordinary deletion from another device,
    /// which is exactly what it looks like: a song the user got rid of.
    ///
    /// Read by `restoreResurrectedTracks`, which puts these back, and by
    /// `prunePlaylistsOfDeletedTracks`, which leaves their playlist slots alone
    /// so there is something to put them back *into*.
    private static func isResurrected(_ track: Track) -> Bool {
        guard track.sync.status != .deleted else { return false }
        guard let serverSaidDeleted = track.sync.serverModifiedAt else { return false }
        return track.dateImported > serverSaidDeleted
    }

    public func restoreResurrectedTracks() -> Int {
        restore(((try? trackRepo.fetchSoftDeleted()) ?? []).filter(Self.isResurrected))
    }

    /// Which of `ids` name a song a restore would actually bring back.
    ///
    /// Anything offering to restore songs has to count *these*. The playlist menu
    /// counted the ids a playlist couldn’t show instead, which is a wider set: it
    /// also covers rows deleted on purpose, and ids with no row behind them at
    /// all. So the menu offered "Restore 1 Missing Song" and the restore then
    /// answered that there was nothing to restore — both of them telling the
    /// truth about different questions.
    public func resurrectableTrackIDs(among ids: [UUID]) -> [UUID] {
        resurrectable(among: ids).map(\.id)
    }

    /// Restores exactly the songs `resurrectableTrackIDs` named, and nothing else
    /// in `ids`. One rule answers both, so what a caller counted is what it gets.
    @discardableResult
    public func restoreTracks(ids: [UUID]) -> Int {
        restore(resurrectable(among: ids))
    }

    private func resurrectable(among ids: [UUID]) -> [Track] {
        guard !ids.isEmpty, let rows = try? trackRepo.fetch(ids: ids) else { return [] }
        return rows.values.filter { $0.isDeleted && Self.isResurrected($0) }
    }

    private func restore(_ tracks: [Track]) -> Int {
        var restored = 0
        for var track in tracks {
            track.isDeleted = false
            track.sync.markModified()
            try? trackRepo.save(track)
            restored += 1
        }
        if restored > 0 {
            print("[LibraryService] ♻️ Restored \(restored) track(s) tombstoned by a stale server record")
            refresh()
        }
        return restored
    }

    // MARK: - Bulk Delete (Settings actions)

    /// Deletes every track, album, and artist from the local store.
    /// All playlist trackID arrays are emptied; the playlists themselves remain.
    /// Call `syncService.deleteAllServerTracks()` BEFORE this to push the deletion.
    public func deleteAllTracks() {
        do { try trackRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — trackRepo.deleteAll failed: \(error)")
        }
        do { try albumRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — albumRepo.deleteAll failed: \(error)")
        }
        do { try artistRepo.deleteAll() } catch {
            print("[LibraryService] deleteAllTracks — artistRepo.deleteAll failed: \(error)")
        }
        try? favoriteRepo.deleteAll()

        // Remove local audio files — both the cache and the legacy Documents path.
        // See the note in `clearAll()`: removing only the old path is a silent no-op.
        SupabaseFileStorageService.purgeLocalAudio()

        // Empty every playlist's track list (keeps the playlist structures intact).
        if let all = try? playlistRepo.fetchAll() {
            for var p in all where !p.trackIDs.isEmpty {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }

        refresh()
    }

    /// Soft-deletes all user-created playlists locally. System playlists
    /// (All Songs, Favourites) are kept. Tracks are untouched.
    /// Call `syncService.deleteAllServerUserPlaylists()` BEFORE this to push the deletion.
    public func deleteAllUserPlaylists() {
        guard let all = try? playlistRepo.fetchAll() else { return }
        for playlist in all where !playlist.isSystem {
            try? playlistRepo.softDelete(id: playlist.id)
        }
        refreshPlaylists()
    }

    // MARK: - Favourites

    /// Every favourited track id, cached.
    ///
    /// `nil` means "not loaded" rather than "no favourites"; see
    /// `invalidateFavouriteIndex`.
    private var favouriteIDCache: Set<UUID>?

    /// Drops the cached favourites so the next read reloads them.
    ///
    /// Called from `refreshPlaylists()`, which every favourite mutation already
    /// ends with — that is also the signal the hearts redraw on, so the two can
    /// never disagree.
    private func invalidateFavouriteIndex() {
        favouriteIDCache = nil
    }

    /// Public so callers that need the whole set at once (Home's shelves) can
    /// take it in one go instead of asking `isFavourited` per track.
    public func favouriteIDs() -> Set<UUID> {
        if let cached = favouriteIDCache { return cached }
        let ids = Set((try? favoriteRepo.allFavouritedIDs()) ?? [])
        favouriteIDCache = ids
        return ids
    }

    /// Whether a song is favourited.
    ///
    /// Answered from an in-memory set, not a fetch. Every track row in every
    /// list asks this during layout, so the per-call fetch this replaced meant
    /// one query per visible row per redraw — thousands of them to scroll a
    /// large playlist.
    public func isFavourited(trackID: UUID) -> Bool {
        favouriteIDs().contains(trackID)
    }

    @discardableResult
    public func toggleFavourite(trackID: UUID) -> Bool {
        // Guard: don't allow favouriting a track that has been deleted from the library.
        // This prevents a stale mini-player from creating a phantom Favourites entry.
        guard track(id: trackID) != nil else { return false }
        if isFavourited(trackID: trackID) {
            try? favoriteRepo.remove(trackID: trackID)
            favouriteIDCache?.remove(trackID)
            mutatePlaylist(id: Playlist.favouritesID) { $0.removeTrack(trackID) }
            // Unliking a song removes it from the library, because for a song
            // saved from Discover the like is the only thing that was holding it
            // there. One a playlist, a saved album or a file of the user's own
            // still holds stays exactly where it is.
            if orphanedTrackIDs(among: [trackID]).isEmpty {
                refreshPlaylists()   // publish change so heart icon & Favourites list update immediately
            } else {
                deleteTracks(ids: [trackID])
            }
            return false
        } else {
            addFavourite(trackID)
            refreshPlaylists()   // publish change so heart icon & Favourites list update immediately
            return true
        }
    }

    /// The like itself, without the publish. Shared with `saveToLibrary`, which
    /// runs before the row it just wrote has reached the in-memory index and so
    /// can't come through the guard above.
    private func addFavourite(_ trackID: UUID) {
        try? favoriteRepo.add(trackID: trackID, deviceID: deviceID)
        favouriteIDCache?.insert(trackID)
        mutatePlaylist(id: Playlist.favouritesID) { $0.addTrack(trackID) }
        // Liked on its own, so it is a library song now rather than its album's.
        SavedAlbumsService.shared.promote(trackID)
    }

    // MARK: - Lookups (used by clickable now-playing / inspector navigation)

    /// The library album matching `title`, disambiguated first by the song that
    /// asked (an album that actually contains the track is the right one, no
    /// matter how its artist is spelled) and then by an exact artist match.
    ///
    /// There is deliberately no "any album with this title" fallback: album
    /// titles collide across unrelated records — "Split Decision" opened Steve
    /// Morse Band's — and opening the wrong album is worse than opening none.
    public func album(title: String, artistName: String, containing trackID: UUID? = nil) -> Album? {
        guard !title.isEmpty else { return nil }
        let matches = albums.filter { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        if let trackID, let owned = matches.first(where: { $0.trackIDs.contains(trackID) }) { return owned }
        return matches.first { $0.artistName.localizedCaseInsensitiveCompare(artistName) == .orderedSame }
    }

    /// The library artist whose name matches `name`.
    public func artist(named name: String) -> Artist? {
        guard !name.isEmpty else { return nil }
        return artists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// A song the user just saved, from Discover or from the player.
    ///
    /// Add to Library and Like are one action, the way they are on Spotify: the
    /// row is metadata only, so the like is the only thing that holds it. There
    /// is nothing to write into All Songs — that list is derived from what holds
    /// a song (see `heldTrackIDs`).
    ///
    /// Imports deliberately don't come through here. A file is held by being a
    /// file and a saved mix's songs by the playlist they land in, and liking
    /// five thousand imported songs on the user's behalf is not a library, it's
    /// a mess someone has to undo by hand.
    ///
    /// `scheduleRefresh()` rather than a publish: the callers are per-song
    /// loops, and re-reading and re-sorting every playlist once per song is the
    /// quadratic shape the scheduler exists for.
    public func saveToLibrary(trackID: UUID) {
        guard !SavedAlbumsService.shared.albumOnlyIDs.contains(trackID),
              !isFavourited(trackID: trackID) else { return }
        addFavourite(trackID)
        scheduleRefresh()
    }

    /// One-shot: brings a library built under the old rule onto the new one.
    ///
    /// Two kinds of row are held by nothing once "it has a row" stops counting.
    /// Songs the user saved from Discover, which they meant to keep — those
    /// become likes. And songs a deleted playlist left behind, which they meant
    /// to be rid of — those go. The tombstones are what tells the two apart,
    /// which is the only reason they are kept.
    ///
    /// Runs on the first refresh that sees a library, so it works offline; a
    /// fresh install has nothing to migrate and waits for one that does. The
    /// work is deferred by a turn because deleting ends in `refresh()`, and this
    /// is called from inside one.
    ///
    /// ponytail: a first sign-in whose songs sync down before its playlists
    /// migrates against an incomplete `held`, and likes songs a playlist would
    /// have held. Nothing is lost — the deletions are scoped to tombstones,
    /// which need those same playlists to exist — the user just finds more in
    /// Liked Songs than they put there. Wait for a settled library if that
    /// turns out to bite.
    private func migrateMembershipIfNeeded(_ allTracks: [Track]) {
        let key = "mix.libraryMembership.v1"
        guard !UserDefaults.standard.bool(forKey: key), !allTracks.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stranded = Set((try? playlistRepo.fetchDeleted())?.flatMap(\.trackIDs) ?? [])
            let (doomed, rescue) = LibraryMembership.migration(
                rows: tracks.lazy.filter { !$0.isDeleted }.map { .init(id: $0.id, isOnline: $0.isOnline) },
                held: heldTrackIDs(),
                strandedByDeletedPlaylists: stranded)
            if !rescue.isEmpty {
                try? favoriteRepo.add(trackIDs: rescue, deviceID: deviceID)
                favouriteIDCache = nil
                mutatePlaylist(id: Playlist.favouritesID) { $0.addTracks(rescue) }
            }
            if !doomed.isEmpty { deleteTracks(ids: doomed) }
            guard !rescue.isEmpty || !doomed.isEmpty else { return }
            print("[Library] 🎧 Migrated \(rescue.count) saved song(s) to likes, removed \(doomed.count) leftover(s)")
            refresh()
        }
    }

    // MARK: - Playlist Management

    /// `id` is settable for one caller: restoring a playlist you published and no
    /// longer have. The published row on the server points at the id the playlist
    /// had when it was shared, so recreating it under a fresh uuid produces a
    /// second playlist that the row still doesn't name — and the profile goes on
    /// advertising something the library can't show. Everyone else takes the
    /// default and gets a new identity, which is what creating a playlist means.
    ///
    /// `origin`/`ownerName` mark a playlist that came from outside — a saved mix
    /// or someone else's published playlist. Both default to "the user made this
    /// one", so every existing caller keeps meaning what it did.
    /// `imported` says this playlist came from somewhere else rather than being
    /// typed out here, and fires `onPlaylistImported`. It is separate from
    /// `origin` on purpose: a Spotify transfer or a file import produces a
    /// playlist that is genuinely the user's own (`.owned`) but still arrived
    /// from outside, and it is arrival, not ownership, that the auto-download
    /// setting is about.
    public func createPlaylist(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        artworkData: Data? = nil,
        origin: PlaylistOrigin = .owned,
        ownerName: String? = nil,
        imported: Bool = false
    ) -> Playlist {
        let p = Playlist(
            id:          id,
            name:        name,
            description: description,
            artworkData: artworkData,
            origin:      origin,
            ownerName:   ownerName,
            sync:        SyncMetadata(deviceID: deviceID)
        )
        try? playlistRepo.save(p)
        refreshPlaylists()
        // After the refresh: whoever listens has to be able to find the
        // playlist it is being told about.
        if imported { onPlaylistImported?(p.id) }
        return p
    }

    public func deletePlaylist(id: UUID) {
        deletePlaylists(ids: [id])
    }

    /// Deletes one or more playlists, and the songs left holding nothing.
    ///
    /// Batched on purpose: `deleteTracks` scans the playlist, album and artist
    /// tables once per call, so deleting four playlists one at a time paid that
    /// four times over (~580 ms each, measured) on top of the refreshes
    /// `coalescingRefreshes` already collapses. The orphan test is computed
    /// against the whole batch, which is also more correct than doing it one at
    /// a time — a song held only by two playlists that are both being deleted
    /// is an orphan, and per-playlist deletion decided that twice, from two
    /// different views of the library.
    public func deletePlaylists(ids: [UUID]) {
        let targets = ids.filter { $0 != Playlist.favouritesID && $0 != Playlist.allSongsID }
        guard !targets.isEmpty else { return }

        // A stored sort for a playlist that no longer exists is dead weight in
        // the account's metadata, so it goes with the playlist.
        for id in targets { PlaylistTrackSortService.shared.forget(playlistID: id) }

        coalescingRefreshes {
            var held: [UUID] = []
            for id in targets {
                // Deleting a *subscription* is un-saving it, and the stored link
                // has to go with it — otherwise the row stays pointed at a
                // playlist that no longer exists, and saving the same playlist
                // again later would find that dead link first. Here rather than
                // in the screens because there are five ways to delete a
                // playlist (the detail page, the library swipe, the Mac grid,
                // ⌘⌫, the profile page) and only one of them knew about
                // subscriptions.
                //
                // Owner links are left alone on purpose: an owner's published row
                // is torn down by `deletePublished`, which has server work to do
                // first.
                if PlaylistSharingService.shared.linkedShare(forLocalPlaylist: id)?.isViewer == true {
                    PlaylistSharingService.shared.setLinkedShare(nil, forLocalPlaylist: id)
                }

                // The songs it held, before the playlist stops being able to
                // answer for them. Deleting the playlists first is what makes the
                // orphan test simple: `fetchAll` skips tombstones, so by the time
                // it runs, "still in a playlist" no longer counts these.
                held += (try? playlistRepo.fetch(id: id))?.trackIDs ?? []
                try? playlistRepo.softDelete(id: id)
            }

            let orphans = mixMainActivity("playlist-delete/find-orphans") {
                orphanedTrackIDs(among: held)
            }
            mixMainActivity("playlist-delete/delete-tracks") { deleteTracks(ids: orphans) }
            refreshPlaylists()
        }

        // Same scoped measurement as the mix save, for the same reason: deleting
        // a handful of playlists stalls the app and nothing in the path says
        // where the time goes.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            MainThreadActivity.shared.logReport("playlist-delete")
        }
    }

    /// How many songs would leave the library along with this playlist.
    ///
    /// For the delete confirmation, which is the only place the number is worth
    /// anything — "this also deletes 47 songs" is a different decision from "this
    /// also deletes nothing".
    public func songCountRemovedWithPlaylist(id: UUID) -> Int {
        guard id != Playlist.favouritesID, id != Playlist.allSongsID,
              let playlist = try? playlistRepo.fetch(id: id)
        else { return 0 }
        return orphanedTrackIDs(among: playlist.trackIDs, ignoring: id).count
    }

    /// The songs in `trackIDs` that nothing else in the library is holding on to.
    ///
    /// "Nothing else" means: no playlist the user made, saved or subscribed to,
    /// and not favourited. All Songs doesn't count — every song in the library is
    /// in it, so counting it would mean nothing was ever orphaned. Favourites
    /// does count, and so does `FavoriteEntity`: they're two records of the same
    /// fact and a song only has to be marked in one of them to be spared.
    private func orphanedTrackIDs(among trackIDs: [UUID], ignoring excluded: UUID? = nil) -> [UUID] {
        guard !trackIDs.isEmpty else { return [] }
        let held = heldTrackIDs(ignoring: excluded)
        return trackIDs.filter { !held.contains($0) }
    }

    /// The songs the library is holding on to — and the whole of the rule.
    ///
    /// Having a row used to be the answer, which is why deleting a playlist left
    /// its songs in the library forever. Four things hold a song now: a like, a
    /// playlist, a saved album, or the fact that it *is* one of the user's own
    /// files. All Songs is derived from this set rather than being a list anyone
    /// writes into, so a song that falls out of all four is simply not in the
    /// library any more and nothing has to be swept up after the fact.
    ///
    /// In one read rather than one per song: the delete confirmation asks for
    /// this while it's on screen, and a per-song fetch across a long playlist is
    /// a stutter every time SwiftUI re-evaluates the message.
    private func heldTrackIDs(ignoring excluded: UUID? = nil) -> Set<UUID> {
        // Favourites the playlist and `FavoriteEntity` are two records of the
        // same fact; a song marked in either one is held.
        var held = Set((try? favoriteRepo.allFavouritedIDs()) ?? [])
        for playlist in (try? playlistRepo.fetchAll()) ?? []
        where !playlist.isAllSongs && playlist.id != excluded {
            held.formUnion(playlist.trackIDs)
        }
        held.formUnion(SavedAlbumsService.shared.albumOnlyIDs)
        // Imported, watched and unresolvable-share rows. The file or the
        // snapshot is the point of those, and no like was ever asked for.
        held.formUnion(tracks.lazy.filter { !$0.isOnline }.map(\.id))
        return held
    }

    /// Songs a deleted playlist left behind: they were in a playlist that is now
    /// a tombstone, they are in no live playlist, and they aren't favourited.
    ///
    /// `deletePlaylists` already sweeps these at the moment of the delete, so
    /// this only ever finds songs stranded by a delete that happened before it
    /// did. Scoped to the tombstones on purpose: a song saved straight from
    /// Discover is in no playlist either, and it is in the library because
    /// someone put it there.
    public func orphansFromDeletedPlaylists() -> [UUID] {
        let stranded = Set((try? playlistRepo.fetchDeleted())?.flatMap(\.trackIDs) ?? [])
        guard !stranded.isEmpty else { return [] }
        // Only ids the library still has a live row for — a tombstone keeps the
        // ids of songs that were deleted years ago too.
        return orphanedTrackIDs(among: stranded.filter { trackIndex[$0] != nil })
    }

    /// Deletes them, and says how many went.
    @discardableResult
    public func cleanUpOrphanedSongs() -> Int {
        let orphans = orphansFromDeletedPlaylists()
        guard !orphans.isEmpty else { return 0 }
        deleteTracks(ids: orphans)
        return orphans.count
    }

    /// The `isEditable` guards on this and the mutations below are the backstop,
    /// not the mechanism: the screens hide these actions for a saved mix or a
    /// subscribed playlist. They're here because there is no single screen that
    /// edits a playlist — the same argument `pushIfShared` makes — and a stray
    /// context menu shouldn't be able to rewrite something that isn't the user's.
    public func renamePlaylist(id: UUID, newName: String) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id) { $0.name = newName; $0.touch() }
        refreshPlaylists()
    }

    public func updatePlaylist(id: UUID, name: String, description: String?, artworkData: Data?) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id) { 
            $0.name = name
            $0.description = description
            $0.artworkData = artworkData
            // Same reading as `setPlaylistArtwork`: an empty picker means the
            // user cleared the cover, not that they want one guessed.
            $0.coverKind   = artworkData == nil ? PlaylistCoverKind.none : .chosen
            $0.touch()
        }
        bakedCoverSources[id] = nil
        invalidateCover(playlistID: id)
        refreshPlaylists()
    }

    /// Replaces a playlist's whole track list, editable or not.
    ///
    /// The counterpart to `setPlaylistArtwork`, and for the same reason: filling
    /// in a saved mix, or pulling down someone else's latest order, is the source
    /// speaking rather than the user editing. Ordinary edits still go through
    /// `addTrack`/`removeTrack` and still answer to `isEditable`.
    public func setTracks(_ trackIDs: [UUID], inPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) {
            guard $0.trackIDs != trackIDs else { return }
            $0.trackIDs = trackIDs
            $0.touch()
        }
        invalidateCover(playlistID: playlistID)
        rebakeDerivedCover(forPlaylist: playlistID)
        refreshPlaylists()
    }

    /// Changes what kind of playlist this is — who owns it and whether the user
    /// may edit it.
    ///
    /// The only caller is a link being made or broken: following a Spotify
    /// playlist makes it a read-only mirror, unlinking hands it back. Not part of
    /// `updatePlaylist`, which is the user editing and must keep answering to
    /// `isEditable`.
    public func setOrigin(_ origin: PlaylistOrigin, forPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) {
            guard $0.origin != origin else { return }
            $0.origin = origin
            $0.touch()
        }
        refreshPlaylists()
    }

    /// Renames a playlist and rewrites its description without asking whether
    /// the user may edit it.
    ///
    /// Same exemption as `setPlaylistArtwork`, for the same reason: a followed
    /// playlist adopting the title and description its source now has is the
    /// source speaking, not the viewer editing.
    /// An independent copy of a playlist, tracks and cover included.
    ///
    /// The same rows, not copies of them: a playlist holds ids, and duplicating
    /// a song would give the library two of everything. Nothing is inherited but
    /// what is visible — the copy is `.owned`, unlinked and unpublished, whatever
    /// the original was.
    @discardableResult
    public func duplicatePlaylist(id: UUID) -> Playlist? {
        guard let source = playlist(id: id), !source.isDeleted else { return nil }

        let copy = createPlaylist(name: Self.copyName(for: source.name,
                                                      taken: playlists.map(\.name)),
                                  description: source.description,
                                  artworkData: source.artworkData)
        // Wholesale, like a saved mix: `addTrack` refuses playlists this one is
        // allowed to copy, and the order matters.
        setTracks(source.trackIDs, inPlaylist: copy.id)
        return playlist(id: copy.id) ?? copy
    }

    /// "Mix" → "Mix (Copy)" → "Mix (Copy 2)". Duplicating twice has to produce
    /// two distinguishable rows in the sidebar, not two called the same thing.
    static func copyName(for name: String, taken: [String]) -> String {
        let existing = Set(taken.map { $0.lowercased() })
        let first = "\(name) (Copy)"
        guard existing.contains(first.lowercased()) else { return first }
        var n = 2
        while existing.contains("\(name) (Copy \(n))".lowercased()) { n += 1 }
        return "\(name) (Copy \(n))"
    }

    public func setPlaylistDetails(id: UUID, name: String, description: String?) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        mutatePlaylist(id: id) {
            guard $0.name != name || $0.description != description else { return }
            $0.name = name
            $0.description = description
            $0.touch()
        }
        refreshPlaylists()
    }

    /// Sets a playlist's cover without asking whether the user may edit it.
    ///
    /// The one legitimate way a read-only playlist changes: adopting the cover
    /// published alongside it. That's the owner's picture arriving, not the
    /// viewer editing, so it goes around `updatePlaylist`'s guard rather than
    /// weakening it.
    public func setPlaylistArtwork(id: UUID, data: Data?) {
        // A picture arriving here was chosen by somebody — the user, or the
        // owner of a playlist being followed. Removing one is a decision too:
        // it means "no picture", not "pick one for me", so nothing is composed
        // to fill the gap. `generateDefaultCover(forPlaylist:)` is how the user
        // asks for that.
        mutatePlaylist(id: id) {
            $0.artworkData = data
            $0.coverKind   = data == nil ? PlaylistCoverKind.none : .chosen
            $0.touch()
        }
        bakedCoverSources[id] = nil
        invalidateCover(playlistID: id)
        refreshPlaylists()
    }

    // MARK: - Track ↔ Playlist

    public func addTrack(id trackID: UUID, toPlaylist playlistID: UUID) {
        addTracks(ids: [trackID], toPlaylist: playlistID)
    }

    /// Adds a whole selection in one write.
    ///
    /// Not a loop over `addTrack`: each single add saves the playlist, rebuilds
    /// the published lists and schedules an upload, and a hundred selected rows
    /// would do all three a hundred times — the upload race alone would leave a
    /// shared playlist holding whichever partial list landed last.
    public func addTracks(ids trackIDs: [UUID], toPlaylist playlistID: UUID) {
        guard !trackIDs.isEmpty, playlist(id: playlistID)?.isEditable != false else { return }
        mutatePlaylist(id: playlistID) { pl in
            pl.addTracks(trackIDs)
        }
        // Keep FavoriteEntity in sync when adding to Favourites from a context menu
        if playlistID == Playlist.favouritesID {
            try? favoriteRepo.add(trackIDs: trackIDs, deviceID: deviceID)
        }
        invalidateCover(playlistID: playlistID)
        rebakeDerivedCover(forPlaylist: playlistID)
        refreshPlaylists()
        pushIfShared(playlistID)
    }

    /// Removes a track from ONE specific playlist, and from the library if that
    /// playlist was the last thing holding it.
    public func removeTrack(id trackID: UUID, fromPlaylist playlistID: UUID) {
        removeTracks(ids: [trackID], fromPlaylist: playlistID)
    }

    /// Removes a whole selection from one playlist in a single write, and from
    /// the library itself for any song this playlist was the last holder of —
    /// membership is derived, so "in the library but in no list" is not a state.
    /// A song still held by another playlist, a saved album or a file of the
    /// user's own is untouched. `deleteTracks(ids:)` is the unconditional form.
    public func removeTracks(ids trackIDs: [UUID], fromPlaylist playlistID: UUID) {
        guard !trackIDs.isEmpty, playlist(id: playlistID)?.isEditable != false else { return }
        // One commit for the whole removal, for the same reason `deleteTracks`
        // takes one: every repository write below commits on its own otherwise.
        RepositorySaveBatch.run(trackRepo.modelContext) {
            mutatePlaylist(id: playlistID) { pl in pl.removeTracks(trackIDs) }
            if playlistID == Playlist.favouritesID {
                try? favoriteRepo.remove(trackIDs: trackIDs)
            }
            // The same rule unliking and deleting a playlist already follow: a
            // song nothing holds any more isn't "in the library but in no
            // list", it's gone. Without it the rows survived every list that
            // could show them and sat in All Songs until some later full
            // refresh rebuilt them away — which is how unhearting 2,117
            // imported songs left all 2,117 of them still counted.
            let orphans = orphanedTrackIDs(among: trackIDs)
            if !orphans.isEmpty { deleteTracks(ids: orphans) }
            invalidateCover(playlistID: playlistID)
            rebakeDerivedCover(forPlaylist: playlistID)
            refreshPlaylists()
        }
        pushIfShared(playlistID)
    }

    /// Sends a shared playlist's new track list up, if it is one.
    ///
    /// This lives at the bottom of the library rather than in the playlist screen
    /// because there is no single screen that edits a playlist: the detail view,
    /// the Add to Playlist sheet, drag-and-drop onto the sidebar and half a dozen
    /// context menus all land here, and a collaborator whose additions travelled
    /// only from one of those would be worse than one whose additions never
    /// travelled at all.
    ///
    /// Deliberately not called from `reconcileSharedPlaylist`, which is the *pull*
    /// direction — pushing what we just pulled is how you build a loop.
    /// `pushLocalChanges` returns immediately for anything unshared, so the cost
    /// on an ordinary playlist edit is a UserDefaults read.
    ///
    /// A subscribed playlist is linked but must never push: the link is how it
    /// follows someone else's edits, not a claim to make any. Without this guard
    /// the first local change would be uploaded over the owner's own list.
    private func pushIfShared(_ playlistID: UUID) {
        guard playlistID != Playlist.favouritesID,
              playlist(id: playlistID)?.isEditable != false,
              PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlistID) != nil
        else { return }

        Task { [weak self] in
            guard let self else { return }
            await PlaylistSharingService.shared.pushLocalChanges(localPlaylistID: playlistID,
                                                                 libraryService: self)
        }
    }

    // MARK: - Shared / Collaborative Playlists

    /// The online search key a shared snapshot came from, when it demonstrably did.
    ///
    /// Two ways to know, in order of trust.
    ///
    /// The owner's device says so. `SharedTrackMeta.sourceKey` is written on every
    /// share and is the only source that survives the owner renaming a song after
    /// saving it, or saving one whose audio matched a file already in their
    /// library. Both of those detach the row from its key locally, and neither is
    /// visible from here.
    ///
    /// Failing that, prove it. `OnlineTrack.id` is `"title|artist"` lowercased and
    /// every Discover save path mints the library row under `stableID(for:)` of
    /// that key — a SHA-256, so the mapping is one-way and can't be faked by
    /// coincidence. Recomputing it from the snapshot's own title and artist and
    /// finding the id it was stored under is proof the song came from Discover,
    /// established locally, offline. This is the only thing rows shared before
    /// `sourceKey` existed can offer, which is why it stays.
    ///
    /// That matters because it's the difference between a row that can be played
    /// and one that can't: a song with a key is one `OnlineTrack` away from audio,
    /// and the resolver rebuilds that from title and artist alone.
    private static func onlineKey(for meta: PlaylistSharingService.SharedTrackMeta) -> String? {
        if let declared = meta.sourceKey, !declared.isEmpty { return declared }
        return OnlineTrack.identityKey(title: meta.title,
                                       artistName: meta.artist,
                                       matching: meta.id)
    }

    /// Imports a metadata-only Track from a shared-playlist snapshot, so a song this
    /// device doesn't hold the audio for still appears in the playlist.
    ///
    /// Two shapes come out of this, and which one decides whether the row plays.
    ///
    /// A song the owner found in Discover is minted in *online* form — carrying its
    /// `"title|artist"` key in `fileHash`, exactly as `OnlineTrack.asTrack` does.
    /// Nothing else is needed: it has no local file and no `remoteKey`, so the
    /// engine routes it to the online coordinator, which reconstructs the search
    /// from the title and artist and streams it. This is what the collaborator
    /// actually wanted — the same playlist, playable, without importing anything.
    ///
    /// Everything else stays a true placeholder, with an empty `fileHash`: someone
    /// else's local file, which no amount of searching will produce.
    ///
    /// If a real track with this id already exists locally, it's kept as-is.
    /// Returns the track id (always equal to `meta.id`).
    @discardableResult
    public func importSharedTrack(meta: PlaylistSharingService.SharedTrackMeta) -> UUID {
        if var existing = ((try? trackRepo.fetch(id: meta.id)) ?? nil), !existing.isDeleted {
            // One exception to "kept as-is": a placeholder that this snapshot can
            // now prove is streamable. Rows imported before the owner started
            // sending `sourceKey` are sitting in libraries as dead grey entries,
            // and without this they stay that way forever — the id already exists,
            // so every later reconcile takes the early return above and the fixed
            // snapshot never reaches them.
            if existing.isUnresolvableShare, let key = Self.onlineKey(for: meta) {
                var upgraded = FileProvenance.onlinePlaceholder(sourceRef: key)
                upgraded.fileHash = key
                existing.file = upgraded
                existing.sync.markModified()
                try? trackRepo.save(existing)
            }
            return existing.id
        }
        let imported = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
        try? trackRepo.save(imported)
        return imported.id
    }

    /// The Track a snapshot entry becomes. Pure — it writes nothing — so the
    /// reconciler can build a whole playlist's worth and commit them together.
    ///
    /// A snapshot that carries a source key came from Discover and can be
    /// resolved here; one that doesn't is somebody else's local file and stays
    /// unresolvable.
    private static func sharedTrackRow(meta: PlaylistSharingService.SharedTrackMeta,
                                       deviceID: String) -> Track {
        let provenance: FileProvenance = {
            guard let key = onlineKey(for: meta) else {
                return FileProvenance(fileHash: "", fileSize: 0, localPath: "",
                                      remoteKey: nil, uploaded: false, downloadedAt: nil,
                                      origin: .unresolvableShare, sourceRef: nil)
            }
            var online = FileProvenance.onlinePlaceholder(sourceRef: key)
            online.fileHash = key
            return online
        }()
        return Track(
            id: meta.id,
            title: meta.title,
            artistName: meta.artist,
            albumTitle: meta.album,
            duration: meta.duration,
            sync: SyncMetadata(deviceID: deviceID),
            file: provenance
        )
    }

    /// Reconciles a local (shared) playlist's track list to match a remote snapshot.
    /// For every remote track id: if it exists locally it's linked directly; otherwise
    /// it's imported from the snapshot metadata so the song is visible — streamable
    /// when it came from Discover, an unavailable placeholder when it didn't.
    /// The local playlist's `trackIDs` are then set to exactly the remote order.
    ///
    /// `ownerID` is who published the row, and is only used to find their covers.
    /// Without it a joined playlist is a list of grey squares; it's optional
    /// because a couple of callers reconcile a row they didn't fetch.
    ///
    /// `dedupeAgainstLibrary` points a song the user already owns at *their* row
    /// instead of importing the owner's copy of it beside it — what stops saving
    /// a playlist of songs you have from doubling every one of them in Songs.
    ///
    /// Off by default, and deliberately not passed by the collaborative paths:
    /// there the local track ids are pushed back up to the shared row, so
    /// swapping in this library's ids would rewrite the playlist under the
    /// owner's feet. Saving, copying and following are pull-only, and are the
    /// ones that turn it on.
    public func reconcileSharedPlaylist(
        localPlaylistID: UUID,
        remoteTrackIDs: [UUID],
        remoteTrackMeta: [PlaylistSharingService.SharedTrackMeta],
        ownerID: UUID? = nil,
        dedupeAgainstLibrary: Bool = false
    ) {
        let metaByID = Dictionary(remoteTrackMeta.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Hashed once rather than scanned per song. `track(id:)` walks the whole
        // in-memory library, so a 60-song playlist against a few thousand tracks
        // was hundreds of thousands of comparisons before this wrote anything —
        // paid on the main actor, while the user waits for the playlist.
        let liveIDs = Set(tracks.map(\.id))

        // Ensure a local Track row exists for every remote id (real or imported).
        // One query and one transaction for the whole snapshot: a sixty-song
        // playlist used to cost sixty fetches and sixty separate SwiftData
        // commits, all on the main actor with the user waiting on them.
        let storedByID = (try? trackRepo.fetch(ids: remoteTrackIDs)) ?? [:]
        var imported: [UUID] = []
        var writes: [Track] = []
        // The songs the user already holds, under whatever ids their own library
        // gave them. Only built when the caller asked for it — see the note on
        // `dedupeAgainstLibrary`.
        var owned = dedupeAgainstLibrary ? LibraryTrackIndex(tracks: tracks) : nil
        // The remote order with every song the user owns swapped for their copy.
        // Identical to `remoteTrackIDs` when nothing matched.
        var resolvedTrackIDs: [UUID] = []
        for trackID in remoteTrackIDs {
            guard let meta = metaByID[trackID] else {
                // No metadata to match on, so there is nothing to do but carry
                // the id through exactly as the snapshot gave it.
                resolvedTrackIDs.append(trackID)
                continue
            }
            let stored = storedByID[trackID]
            // Placeholders are rebuilt as well as missing rows. They're the ones
            // a re-shared snapshot can now upgrade — see `sharedTrackRow` — and
            // skipping them because "a row exists" is what left them unplayable
            // across every subsequent sync.
            if !liveIDs.contains(trackID), stored == nil {
                // Nothing under the owner's id — but possibly the same song
                // under one of this library's own. Pointing at that row leaves
                // it untouched: same file, same artwork, same download.
                if let existing = owned?.match(title: meta.title,
                                               artistName: meta.artist,
                                               duration: meta.duration) {
                    resolvedTrackIDs.append(existing.id)
                    continue
                }
                let row = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
                writes.append(row)
                imported.append(trackID)
                // A snapshot listing the same song twice under two spellings is
                // still one row here.
                owned?.insert(row)
            } else if stored?.isUnresolvableShare == true {
                if var row = stored, !row.isDeleted, let key = Self.onlineKey(for: meta) {
                    var upgraded = FileProvenance.onlinePlaceholder(sourceRef: key)
                    upgraded.fileHash = key
                    row.file = upgraded
                    row.sync.markModified()
                    writes.append(row)
                } else if stored?.isDeleted == true {
                    writes.append(Self.sharedTrackRow(meta: meta, deviceID: deviceID))
                }
            }
            resolvedTrackIDs.append(trackID)
        }
        try? trackRepo.save(writes)

        // Set the playlist's order to exactly match the remote list. Stable
        // across refreshes even with substitutions in it: the same snapshot
        // against the same library resolves to the same ids every time.
        mutatePlaylist(id: localPlaylistID) { playlist in
            if playlist.trackIDs != resolvedTrackIDs {
                playlist.trackIDs = resolvedTrackIDs
                playlist.touch()
            }
        }

        refresh()

        // Covers, after the list is on screen rather than before it. A snapshot
        // carries no artwork, so a joined playlist arrives blank and fills in;
        // holding the playlist back until every cover has been fetched would make
        // joining look like it had hung.
        //
        // A local `ITunesSearchClient` rather than the app's: it's stateless, and
        // the Spotify half it can be given is only used for artist photos, which
        // this path never asks for.
        guard !imported.isEmpty else { return }
        scheduleArtworkBackfill(trackIDs: imported,
                                publishedBy: ownerID,
                                using: ITunesSearchClient())
    }

    // MARK: - Delete Single Track From Library

    /// Soft-deletes a track from the library, removes its audio file,
    /// strips it from every playlist, and removes it from its album/artist
    /// buckets — soft-deleting those too if they become empty.
    public func deleteTrack(id: UUID) {
        deleteTracks(ids: [id])
    }

    /// The same, for a whole set at once.
    ///
    /// Not a loop over `deleteTrack` because the expensive half is per *library*
    /// rather than per track: every playlist, album and artist is fetched, walked
    /// and saved, and the published collections are rebuilt. Deleting a playlist
    /// cascades into as many songs as it held, and paying that price ninety times
    /// over is the difference between a delete and a hang.
    public func deleteTracks(ids: [UUID]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }

        // One commit for the whole deletion. Every song, every playlist that
        // held one, and every album and artist bucket it leaves behind is its
        // own repository save otherwise — a hundred-odd `ModelContext` commits
        // for three playlists, none of them individually slow enough to show up
        // in the log. See `RepositorySaveBatch`.
        RepositorySaveBatch.run(trackRepo.modelContext) { deleteTracksBody(doomed) }
    }

    private func deleteTracksBody(_ doomed: Set<UUID>) {
        // While the rows are still here to be found — see `onTracksWillDelete`.
        onTracksWillDelete?(doomed)

        // The files first, while the rows they are named by are still readable.
        // Copies in the *export* folder are the user's, and stay: nothing reads
        // that folder back in any more, so there is no deletion to remember and
        // nothing to undo this one.
        for id in doomed {
            if let localPath = track(id: id)?.file.localPath {
                AudioPaths.removeAllCopies(ofLocalPath: localPath)
            }
        }

        let deleted: Set<UUID>
        do {
            deleted = try trackRepo.softDelete(ids: Array(doomed))
        } catch {
            print("[LibraryService] deleteTracks failed: \(error)")
            return
        }
        guard !deleted.isEmpty else { return }
        try? favoriteRepo.remove(trackIDs: Array(deleted))

        // Purge from every playlist (including Favourites)
        var coversToRebake: [UUID] = []
        if var all = try? playlistRepo.fetchAll() {
            for i in all.indices where all[i].trackIDs.contains(where: deleted.contains) {
                all[i].trackIDs.removeAll(where: deleted.contains)
                all[i].touch()
                try? playlistRepo.save(all[i])
                coversToRebake.append(all[i].id)
            }
        }

        // A derived cover is composed from the playlist's songs, so a song
        // leaving can change it — and the baked bytes are what every other
        // device is shown. Without this a deleted song stays on the cover, and
        // syncs there. Only the playlists that actually lost something, and
        // `rebakeDerivedCover` refuses the ones whose picture isn't ours.
        for id in coversToRebake { rebakeDerivedCover(forPlaylist: id) }

        // Remove from album buckets — soft-delete the album if it becomes empty.
        //
        // From the published array rather than `fetchAll()`: re-reading every
        // album and artist row cost ~450 ms of the delete, to look at buckets
        // this service is already holding. A bucket missing from the published
        // list is one that holds no live track, which by definition holds none
        // of the songs being deleted — and the refresh sweep tidies those.
        do {
            for var album in albums where album.trackIDs.contains(where: deleted.contains) {
                album.trackIDs.removeAll(where: deleted.contains)
                if album.trackIDs.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else {
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }
        }

        // Remove from artist buckets — see the note on albums above.
        do {
            for var artist in artists where artist.trackIDs.contains(where: deleted.contains) {
                artist.trackIDs.removeAll(where: deleted.contains)
                if artist.trackIDs.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else {
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }
        }

        refresh()
    }

    // MARK: - Convenience Accessors

    /// The library's row for an id.
    ///
    /// Backed by a dictionary rebuilt with `tracks` rather than a scan. This is
    /// called from 25 places, several of them per-song inside a loop —
    /// `DownloadManager.resolve(_:)` turns a playlist's ids into rows one at a
    /// time — so the linear version made "is this playlist downloaded?" cost
    /// songs × library, on the main actor, while a view redrew.
    public func track(id: UUID) -> Track? {
        guard let i = trackIndex[id], i < tracks.count else { return nil }
        return tracks[i]
    }

    /// "Do I already own this recording?", by name rather than by row id.
    ///
    /// `track(id:)` only ever recognises a song the library acquired the same
    /// way, spelled the same way — an online id is a hash of "title|artist", and
    /// catalogues disagree about both halves. Deezer files a song as "Ran To
    /// Atlanta" by "Drake" where Spotify's import wrote "Ran To Atlanta (feat.
    /// Future & Molly Santana)" by "Drake, Future, Molly Santana", so the two
    /// hash to different ids and a library that plainly had the song reported
    /// that it didn't. Rebuilt with `tracks` for the same reason `trackIndex`
    /// is: this is read from view bodies, once per visible row.
    /// Built on demand and dropped whenever `tracks` is replaced. See the
    /// `didSet` for why it is not rebuilt eagerly.
    private var cachedRecordingIndex: LibraryTrackIndex?

    /// The recording index for the library as it stands, building it if the
    /// last one was dropped.
    private var recordingIndex: LibraryTrackIndex {
        if let cachedRecordingIndex { return cachedRecordingIndex }
        let built = LibraryTrackIndex(tracks: tracks)
        cachedRecordingIndex = built
        return built
    }

    /// A copy of the recording index for a caller that will add to it as it
    /// writes — an import, a saved mix, a Spotify pull.
    ///
    /// Every one of those paths used to build its own with
    /// `LibraryTrackIndex(tracks:)`, which is the expensive constructor above
    /// run again from scratch. They share this one instead: the value semantics
    /// mean a caller's `insert`s stay its own, and copy-on-write means taking a
    /// copy costs nothing until it writes.
    public var ownedRecordingIndex: LibraryTrackIndex { recordingIndex }

    /// The library's copy of a song described by name, or nil.
    ///
    /// Pass the duration when it's known — it's what keeps a radio edit and an
    /// eight-minute club mix from being judged the same recording.
    public func track(matching title: String,
                      artistName: String,
                      duration: TimeInterval = 0) -> Track? {
        recordingIndex.match(title: title, artistName: artistName, duration: duration)
    }

    /// Track id → its position in `tracks`, rebuilt whenever that array is
    /// replaced. Positions rather than rows: the two are written in the same
    /// `didSet` and can't disagree, and this way the index costs a dictionary
    /// instead of a second copy of every track in the library.
    private var trackIndex: [UUID: Int] = [:]

    private func rebuildTrackIndex() {
        var index: [UUID: Int] = [:]
        index.reserveCapacity(tracks.count)
        for (i, track) in tracks.enumerated() { index[track.id] = i }
        trackIndex = index
    }

    public func album(id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    public func artist(id: UUID) -> Artist? {
        artists.first { $0.id == id }
    }

    public func tracks(in album: Album) -> [Track] {
        // All tracks, not `displayTracks`: the Downloaded filter used to empty
        // album pages and zero every artist's count. Rows gray out instead.
        let ids = Set(album.trackIDs)
        return tracks
            .filter { ids.contains($0.id) }
            .sorted {
                let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
                if d0 != d1 { return d0 < d1 }
                return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
            }
    }

    public func tracks(by artist: Artist) -> [Track] {
        let ids = Set(artist.trackIDs)
        return tracks.filter { ids.contains($0.id) }
    }

    // MARK: - Playlist Covers

    /// Which tracks have a cover at all — ids only, never bytes.
    ///
    /// This used to be a `[UUID: Data]` built by walking `tracks` and reading
    /// `artworkData` off each one. That stopped working the moment the bulk
    /// fetch stopped carrying artwork: every struct's `artworkData` is nil now,
    /// so the index came back empty and every playlist quietly lost its
    /// borrowed cover. Rebuilding it from the bytes isn't the fix either —
    /// that would fault in all 2 000 blobs, which is the thing the slim fetch
    /// exists to avoid. The store can answer "does this row have a cover"
    /// without reading one, so that is all this holds; the bytes are fetched
    /// per row, when something actually draws them.
    private var tracksWithArtwork: Set<UUID> = []

    /// Set by `insertLocally`, which computes the cover index from the rows it
    /// already holds instead of asking the store for it again.
    private var suppressCoverIndexRebuild = false

    private func rebuildTrackCoverIndex() {
        guard !suppressCoverIndexRebuild else { return }
        tracksWithArtwork = ArtworkProvider.shared.trackIDsWithArtwork()
        // Deliberately not clearing `mosaics`: the cache is keyed by what went
        // into each one, so a stale entry is caught on the next read. Dropping
        // it here would recompose every playlist's 2×2 on the main actor after
        // every library refresh — a download landing would cost a stutter.
    }

    /// Composed 2×2s, kept because composing one means decoding four JPEGs and
    /// a row asks for its cover on every redraw.
    private var mosaics: [UUID: (sources: [CoverFingerprint], data: Data)] = [:]

    /// Enough of a cover to tell it apart from another one without holding or
    /// hashing the whole image: a playlist that is one album shouldn't get a
    /// 2×2 of the same picture four times.
    private struct CoverFingerprint: Hashable {
        let count: Int
        let head:  Int
        let tail:  Int

        init(_ data: Data) {
            count = data.count
            head  = data.prefix(64).hashValue
            tail  = data.suffix(64).hashValue
        }
    }

    /// The picture a playlist wears.
    ///
    /// A cover the user chose always wins. Failing that the playlist borrows
    /// from its own songs: the first song's cover, or — once there are four
    /// different ones to show — the same 2×2 a mix wears, so a playlist you
    /// built yourself ends up looking like the ones the app builds for you.
    ///
    /// Nil for the two system playlists unless they were given a cover. All
    /// Songs and Favourites are identities, not collections — they wear their
    /// own glyph everywhere, and a borrowed cover would make Favourites look
    /// like whichever song happens to sit at the top of it.
    public func coverData(for playlist: Playlist) -> Data? {
        if let own = playlist.displayArtwork { return own }
        guard !playlist.isSystem else { return nil }
        // A cover the user deleted stays deleted. See `PlaylistCoverKind.none`.
        guard playlist.coverKind != PlaylistCoverKind.none else { return nil }

        let covers = borrowableCovers(in: playlist)
        guard let first = covers.first else { return nil }
        guard covers.count >= 4 else { return first }

        let fingerprints = covers.map(CoverFingerprint.init)
        if let cached = mosaics[playlist.id], cached.sources == fingerprints {
            return cached.data
        }
        // 512 rather than the 640 a saved mix is baked at: this one is composed
        // while a view draws, and the largest thing that shows it is a 200pt
        // hero. Nothing here is stored, so there's no reason to pay for pixels
        // no screen asks for.
        guard let composed = MixCoverArt.compose(tiles: covers, side: 512) else { return first }
        mosaics[playlist.id] = (fingerprints, composed)
        return composed
    }

    /// Up to four different covers from the front of the playlist.
    ///
    /// Songs without artwork are stepped over rather than counted — a playlist
    /// whose opener is an untagged local file would otherwise show the generic
    /// tile with nine covers sitting underneath it. The scan is bounded because
    /// this runs while a row draws: past the first stretch of songs, a playlist
    /// that hasn't produced four different pictures isn't going to.
    private func borrowableCovers(in playlist: Playlist, limit: Int = 4) -> [Data] {
        var found: [Data] = []
        var seen = Set<CoverFingerprint>()
        for ref in coverRefs(forPlaylistID: playlist.id) {
            guard let art = ArtworkProvider.shared.data(for: ref),
                  seen.insert(CoverFingerprint(art)).inserted
            else { continue }
            found.append(art)
            if found.count == limit { break }
        }
        return found
    }

    // MARK: - Derived covers

    /// Forgets a playlist's cover everywhere it is remembered.
    ///
    /// Three caches answer "what does this playlist look like": the composed
    /// mosaic here, the raw bytes in `ArtworkProvider`, and the decoded images
    /// in `ArtworkImageLoader` (at every size, and under both the row key and
    /// the mosaic key). A full `refresh()` clears all of them wholesale, which
    /// is why changing a cover appeared to work only after one — but
    /// `refreshPlaylists()`, which is what every playlist edit actually calls,
    /// cleared none. That is the whole reason a new cover didn't reach the
    /// sidebar until something else forced a full reload.
    ///
    /// Also needed when the *track list* changes, not just the cover: a
    /// playlist with no picture of its own borrows one from its songs.
    private func invalidateCover(playlistID: UUID) {
        mosaics[playlistID] = nil
        ArtworkProvider.shared.invalidate(.playlist(playlistID))
        ArtworkImageLoader.shared.invalidate(.playlist(playlistID))
    }

    // MARK: - Artwork invalidation

    /// Covers written since the last refresh, and so the only ones whose cached
    /// image is out of date.
    private var dirtyArtwork: Set<ArtworkRef> = []

    /// Set when the change is too broad to enumerate — a wipe, an account
    /// switch — and every cached cover has to go.
    private var allArtworkDirty = false

    /// Records that one row's cover has changed. The next refresh drops it.
    public func noteArtworkChanged(_ ref: ArtworkRef) {
        dirtyArtwork.insert(ref)
    }

    /// A playlist cover that arrived from somewhere outside this device — a
    /// sync download, most often.
    ///
    /// Not the same as `noteArtworkChanged(.playlist(id))`: a playlist is drawn
    /// from two caches, the image caches *and* the mosaic this service composes
    /// for coverless lists, and the sidebar reads the second one. Clearing only
    /// the first is why a cover picked on another device appeared in the
    /// playlist view and left the sidebar icon empty.
    public func noteCoverChanged(playlistID: UUID) {
        mosaics[playlistID] = nil
        bakedCoverSources[playlistID] = nil
        dirtyArtwork.insert(.playlist(playlistID))
    }

    /// Records that every cover is stale. Only for changes that really are
    /// library-wide; a per-row write should name its row.
    public func noteAllArtworkChanged() {
        allArtworkDirty = true
    }

    private func flushDirtyArtwork() {
        if allArtworkDirty {
            ArtworkProvider.shared.invalidateAll()
            ArtworkImageLoader.shared.invalidateAll()
            allArtworkDirty = false
            dirtyArtwork.removeAll()
            return
        }
        guard !dirtyArtwork.isEmpty else { return }
        // Both take the whole set: each one costs a redraw of every cover on
        // screen, so it has to happen once per refresh, not once per row.
        ArtworkProvider.shared.invalidate(dirtyArtwork)
        ArtworkImageLoader.shared.invalidate(dirtyArtwork)
        dirtyArtwork.removeAll()
    }

    /// The tiles the current baked cover was made from, per playlist.
    ///
    /// Only a skip-check. A track added to the end of a fifty-song playlist
    /// cannot change the first four pictures, and re-composing (and then
    /// re-uploading) an identical cover on every add is the cost this avoids.
    /// In-memory, so the first edit after a launch always re-composes once.
    private var bakedCoverSources: [UUID: [CoverFingerprint]] = [:]

    /// Composes a playlist's borrowed cover and stores it as the playlist's own.
    ///
    /// This is what makes a playlist look the same on every device. A borrowed
    /// cover is assembled from whichever of the playlist's songs have artwork
    /// *here* — so two devices holding different subsets of the artwork drew
    /// different covers, and neither was wrong. Baking resolves it once, on the
    /// device that made the change, and the bytes then travel like any other
    /// playlist cover.
    ///
    /// Refuses a cover the user chose: `coverKind` is the whole reason that
    /// distinction is stored. Also refuses the two system playlists, which wear
    /// a glyph rather than a picture.
    ///
    /// - Returns: whether it wrote anything.
    @discardableResult
    public func rebakeDerivedCover(forPlaylist playlistID: UUID) -> Bool {
        guard let playlist = try? playlistRepo.fetch(id: playlistID),
              !playlist.isSystem, !playlist.isDeleted else { return false }
        // `.chosen` is the user's picture and `.none` is the user's decision to
        // have none. Neither is ours to overwrite.
        guard playlist.coverKind == .derived else { return false }

        let tiles = borrowableCovers(in: playlist)
        guard let first = tiles.first else { return false }

        let fingerprints = tiles.map(CoverFingerprint.init)
        if bakedCoverSources[playlistID] == fingerprints, playlist.displayArtwork != nil {
            return false
        }

        // 640, the side a saved mix is baked at — unlike `coverData`, this one
        // is stored and synced, so it has to survive the largest thing that
        // draws it rather than the largest thing drawing it right now.
        // Under four different pictures there is no mosaic to make and the
        // opener's cover stands in, exactly as `coverData` would have shown it.
        let baked = tiles.count >= 4 ? MixCoverArt.compose(tiles: tiles, side: 640) : first
        guard let baked else { return false }

        bakedCoverSources[playlistID] = fingerprints
        guard baked != playlist.displayArtwork else { return false }

        mutatePlaylist(id: playlistID) {
            $0.artworkData = baked
            $0.coverKind   = .derived
            $0.touch()
        }
        invalidateCover(playlistID: playlistID)
        return true
    }

    /// "Generate Cover" — compose one from the playlist's songs, now.
    ///
    /// The one way back from `.none`, and a way to refresh a stale derived cover
    /// without editing the playlist. Throws away whatever picture is there,
    /// including one the user chose, because that is what the command says it
    /// does and it is only ever reached by asking for it.
    @discardableResult
    public func generateDefaultCover(forPlaylist playlistID: UUID) -> Bool {
        mutatePlaylist(id: playlistID) {
            $0.artworkData = nil
            $0.coverKind   = .derived
            $0.touch()
        }
        bakedCoverSources[playlistID] = nil
        let baked = rebakeDerivedCover(forPlaylist: playlistID)
        invalidateCover(playlistID: playlistID)
        refreshPlaylists()
        return baked
    }

    /// Whether "Generate Cover" would produce anything for this playlist.
    ///
    /// False for the two system playlists, which wear a glyph, and for one whose
    /// songs have no artwork between them — there is nothing to compose from.
    public func canGenerateCover(forPlaylist playlistID: UUID) -> Bool {
        guard let playlist = playlist(id: playlistID),
              !playlist.isSystem, !playlist.isDeleted else { return false }
        return playlist.trackIDs.contains { tracksWithArtwork.contains($0) }
    }

    /// The songs a playlist would borrow its cover from, as ids rather than
    /// pictures.
    ///
    /// This is what `AsyncArtworkImage` asks for: it hands the refs back to
    /// `ArtworkImageLoader`, which reads and composes them off the render path.
    /// The scan is bounded — past the first stretch of songs, a playlist that
    /// hasn't produced four different pictures isn't going to.
    ///
    /// Empty for the two system playlists. All Songs and Favourites are
    /// identities, not collections: they wear their own glyph everywhere, and a
    /// borrowed cover would make Favourites look like whichever song happens to
    /// sit at the top of it.
    /// - Parameter candidates: how many refs to hand back, not how many tiles
    ///   the caller wants. A playlist that is one album has twelve songs
    ///   wearing the same picture, and whoever draws it needs enough candidates
    ///   to find four *different* ones — a check that needs the bytes, so it
    ///   belongs downstream of here.
    public func coverRefs(forPlaylistID id: UUID, candidates: Int = 12) -> [ArtworkRef] {
        guard let playlist = playlist(id: id), !playlist.isSystem,
              playlist.coverKind != PlaylistCoverKind.none else { return [] }
        return coverRefs(forTrackIDs: playlist.trackIDs, candidates: candidates)
    }

    /// The same borrowing rule for a list that isn't a stored playlist — a
    /// smart playlist resolves its songs live and wears the same cover.
    public func coverRefs(forTrackIDs trackIDs: [UUID], candidates: Int = 12) -> [ArtworkRef] {
        var found: [ArtworkRef] = []
        for trackID in trackIDs.prefix(24) where tracksWithArtwork.contains(trackID) {
            found.append(.track(trackID))
            if found.count == candidates { break }
        }
        return found
    }

    // MARK: - Artist Profile Photos

    /// One client for the whole session so the Spotify token and the resolved
    /// image URLs stay cached across the backfills that follow each import.
    private static let artistImageClient = SpotifyClient()

    /// Names Spotify has no artist for. Without this, a library full of
    /// local-only artists re-queries the same dead names after every import.
    private var artistImageMisses: Set<String> = []

    private var artistImageBackfillTask: Task<Void, Never>?

    /// True when the row is showing a stand-in rather than a real profile photo.
    ///
    /// Import seeds a new artist with one of its tracks' album covers so the row
    /// isn't a blank circle — which is exactly why a freshly imported artist wore
    /// the album art until you refreshed it by hand. The stand-in is byte-identical
    /// to the cover it was copied from, so it's recognisable; anything else was
    /// fetched from Spotify and is left alone.
    private func hasPlaceholderImage(_ artist: Artist) -> Bool {
        guard let art = artist.artworkData else { return true }
        let ids = Set(artist.trackIDs)
        return tracks.contains { ids.contains($0.id) && $0.artworkData == art }
    }

    /// Coalesced backfill request. Import paths call this once per track; the
    /// work runs once, a moment after the last one lands.
    public func scheduleArtistImageBackfill() {
        artistImageBackfillTask?.cancel()
        artistImageBackfillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.backfillArtistImages()
        }
    }

    /// Replaces album-cover stand-ins with the artist's real Spotify photo.
    /// This is the only way profile photos are fetched now — there was a manual
    /// "refresh" users had to run on every newly imported artist, and once this
    /// ran on its own that control did nothing but redo work already done.
    public func backfillArtistImages() async {
        // Rows that share a search term ("Drake", "Drake feat. 21 Savage")
        // resolve from a single lookup.
        var byQuery: [String: [Artist]] = [:]
        for artist in artists where !artist.isDeleted && hasPlaceholderImage(artist) {
            let query = ImportService.primaryArtistName(from: artist.name)
            guard !query.isEmpty, !artistImageMisses.contains(query.lowercased()) else { continue }
            byQuery[query, default: []].append(artist)
        }
        guard !byQuery.isEmpty else { return }

        let queries  = Array(byQuery.keys)
        var didWrite = false
        var index    = 0

        // Chunked: a first import can leave hundreds of artists without a photo,
        // and firing every search at once earns a 429 instead of images.
        while index < queries.count {
            guard !Task.isCancelled else { break }
            let chunk = Array(queries[index ..< min(index + 8, queries.count)])
            index += 8

            let urls = await Self.artistImageClient.artistImages(for: chunk)
            // Nothing at all back for a whole chunk usually means offline or a
            // dead token rather than "none of these artists exist" — recording
            // that as a miss would make the session give up on them.
            let reachable = !urls.isEmpty

            for name in chunk {
                guard let url = urls[name] else {
                    if reachable { artistImageMisses.insert(name.lowercased()) }
                    continue
                }
                guard let (raw, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let data = ImageDownsampler.artworkJPEG(from: raw) else { continue }

                for artist in byQuery[name] ?? [] {
                    guard var stored = try? artistRepo.fetch(id: artist.id) else { continue }
                    stored.artworkData = data
                    stored.sync.markModified()
                    try? artistRepo.save(stored)
                    noteArtworkChanged(.artist(stored.id))
                    didWrite = true
                }
            }
        }

        if didWrite { refresh() }
    }

    // MARK: - Placeholder Track Artwork

    /// Fills in cover art for tracks that arrived as metadata only.
    ///
    /// A playlist adopted from someone else's profile (or joined by code) is built
    /// from `SharedTrackMeta` — title, artist, album, duration and nothing else.
    /// The owner's own covers can't come with it: they live in the private
    /// `artwork` bucket, readable by that one account. So the songs landed in the
    /// library as rows of grey squares.
    ///
    /// Two sources, in order of how right they are.
    ///
    /// First the owner's own cover, published beside the playlist — the actual
    /// image, and the only one that works for music that was never released to a
    /// store. Then the catalogue, which knows commercial records and knows
    /// nothing else; leaning on it alone left a library of imported songs looking
    /// exactly as blank as before.
    ///
    /// Results are written to the track, so this runs once and the covers are
    /// simply there afterwards — including offline.
    ///
    /// `replacingExisting` widens it from a backfill to a re-fetch: every track
    /// is looked up again, not just the blank ones. That's the manual repair —
    /// a cover can be present and still be wrong (the placeholder a bad import
    /// left behind, or a stand-in from before the song was matched properly),
    /// and "only touch the empty ones" has no way to fix those. Nothing is ever
    /// cleared: a track keeps the cover it has unless a better lookup replaces
    /// it, so a re-fetch that finds nothing costs time and no artwork.
    ///
    /// `directCovers` short-circuits both lookups for songs whose cover URL the
    /// caller already knows — a mix saved from Discover arrives with the
    /// catalogue's own artwork URL on every track, so searching for it again
    /// would be asking a question we're holding the answer to.
    ///
    /// Returns the number of tracks whose artwork was written.
    /// The one cover backfill this service is allowed to have in flight.
    ///
    /// It used to be an anonymous `Task { }` per caller, which meant nothing
    /// could stop it and several could overlap. A first import queues thousands
    /// of sequential catalogue lookups, so an unstoppable one goes on making
    /// network calls — and writing to the library — long after the import is
    /// over, for the whole time the user is trying to browse.
    private var artworkBackfillTask: Task<Void, Never>?

    /// How many catalogue lookups one *automatic* backfill may make.
    ///
    /// The lookups are deliberately sequential (iTunes 403s bursts), so an
    /// unbounded run over a freshly imported library is an hour of traffic.
    /// Whatever this leaves behind is not lost: Settings' "Find Missing Covers"
    /// is the unbounded version, run on purpose, with progress the user can see.
    public static let automaticCatalogueLookupLimit = 250

    /// Runs a backfill as the service's single owned background job, replacing
    /// whatever was running before. Bounded, and cancelled by
    /// `cancelBackgroundWork()`.
    public func scheduleArtworkBackfill(trackIDs: [UUID],
                                        publishedBy ownerID: UUID?,
                                        using catalogue: ITunesSearchClient,
                                        directCovers: [UUID: URL] = [:]) {
        artworkBackfillTask?.cancel()
        artworkBackfillTask = Task { [weak self] in
            await self?.backfillPlaceholderArtwork(
                trackIDs:             trackIDs,
                publishedBy:          ownerID,
                using:                catalogue,
                directCovers:         directCovers,
                catalogueLookupLimit: Self.automaticCatalogueLookupLimit
            )
        }
    }

    public func cancelArtworkBackfill() {
        artworkBackfillTask?.cancel()
        artworkBackfillTask = nil
    }

    /// `catalogueLookupLimit` bounds pass two. `nil` means "no limit" and is
    /// what the user-initiated repairs pass — they are the whole reason someone
    /// pressed the button, and they report progress while they run.
    @discardableResult
    public func backfillPlaceholderArtwork(trackIDs: [UUID],
                                           publishedBy ownerID: UUID?,
                                           using catalogue: ITunesSearchClient,
                                           directCovers: [UUID: URL] = [:],
                                           replacingExisting: Bool = false,
                                           catalogueLookupLimit: Int? = nil) async -> Int {
        let pending = trackIDs.compactMap { id -> Track? in
            guard let track = track(id: id), !track.isDeleted,
                  replacingExisting || track.artworkData == nil else {
                return nil
            }
            return track
        }
        guard !pending.isEmpty, !Task.isCancelled else { return 0 }

        var found: [UUID: Data] = [:]

        // Pass zero: the covers the caller already knows the address of. No
        // lookup at all — a mix saved from Discover carries the catalogue's own
        // artwork URL on every song, so searching for it would be asking a
        // question we're holding the answer to.
        if !directCovers.isEmpty {
            let jobs = pending.compactMap { track in
                directCovers[track.id].map { (track.id, $0) }
            }
            found.merge(await Self.fetchImages(jobs)) { a, _ in a }
        }

        // Pass one: the owner's covers, straight out of the public bucket.
        if let ownerID {
            let jobs = pending.compactMap { track -> (UUID, URL)? in
                guard found[track.id] == nil,
                      let url = PlaylistSharingService.trackCoverURL(ownerID: ownerID,
                                                                    trackID: track.id)
                else { return nil }
                return (track.id, url)
            }
            found.merge(await Self.fetchImages(jobs)) { a, _ in a }
        }

        // Pass two: the catalogue, for whatever the owner never published.
        //
        // One at a time, unlike above. iTunes throttles bursts — six concurrent
        // lookups reliably comes back with a couple of 403s — and a throttled
        // request is indistinguishable from a song it has genuinely never heard
        // of, so running these in parallel was quietly dropping covers that were
        // there for the asking.
        var lookups = 0
        for track in pending where found[track.id] == nil {
            // Checked every iteration, not once at the top: this loop is
            // thousands of round trips long, and the point of cancelling it is
            // to stop it *now* rather than at the end of a run nobody is
            // waiting for any more.
            guard !Task.isCancelled else { break }
            if let limit = catalogueLookupLimit, lookups >= limit { break }
            lookups += 1
            if let data = await Self.catalogueArtwork(for: track, catalogue: catalogue) {
                found[track.id] = data
            }
        }

        let storedByID = (try? trackRepo.fetch(ids: Array(found.keys))) ?? [:]
        var updates: [Track] = []
        for (id, data) in found {
            guard var stored = storedByID[id] else { continue }
            // Identical bytes back again isn't a change — writing it anyway would
            // mark the row modified and push a no-op up on the next sync.
            guard stored.artworkData != data else { continue }
            stored.artworkData = data
            stored.sync.markModified()
            noteArtworkChanged(.track(stored.id))
            updates.append(stored)
        }
        try? trackRepo.save(updates)
        let written = updates.count

        if written > 0 {
            propagateArtworkToContainers(from: Array(found.keys))
            // Not `refresh()`. This runs a second or two after a mix is saved,
            // once the covers come down — a full re-read of every track, album
            // and artist (~1.4 s on the main actor) to learn about rows this
            // function is holding in `updates`. That was the lag left after the
            // press itself got fast: the app went unresponsive and the covers
            // greyed out *while the user was scrolling*. `insertLocally` merges
            // by id, so an update publishes the same way an insert does.
            insertLocally(updates)
        }
        return written
    }

    /// Cover art for one track, from the same catalogue Discover searches.
    ///
    /// Deezer first, iTunes second, and deliberately in that order: Discover *is*
    /// Deezer, so a song that arrived from there is by definition a song Deezer
    /// has a cover for, while the iTunes storefronts queried here have often
    /// never heard of it. Asking iTunes alone — which is all this used to do —
    /// is why the repair kept coming back empty for exactly the songs that
    /// needed it most.
    private static func catalogueArtwork(for track: Track,
                                         catalogue: ITunesSearchClient) async -> Data? {
        guard let url = await catalogueArtworkURL(for: track, catalogue: catalogue) else { return nil }
        return await fetchImage(url)
    }

    /// A cover *URL* for a track the library has no bytes for.
    ///
    /// Split out of `catalogueArtwork` because continuity needs the address
    /// rather than the pixels: a web client on the other end signs and loads it
    /// itself, and a song playing from Discover has no stored blob to send.
    /// Memoized by the caller, not here — this is a couple of network round
    /// trips.
    static func catalogueArtworkURL(for track: Track,
                                    catalogue: ITunesSearchClient) async -> URL? {
        let primaryArtist = ImportService.primaryArtistName(from: track.artistName)
        let query = "\(track.title) \(primaryArtist)".trimmingCharacters(in: .whitespaces)

        // Twelve, not one: Deezer ranks by popularity, so the exact song is
        // usually near the top but can sit under a remix or a live version.
        let popular = await catalogue.searchPopular(query: query, limit: 12)
        if let hit = popular.first(where: { isSameSong(track, primaryArtist: primaryArtist, as: $0) }),
           let raw = hit.artworkUrl100,
           let url = catalogue.artworkURL(from: raw, size: 1000) {
            return url
        }

        guard let hit = try? await catalogue.search(title: track.title,
                                                    artist: track.artistName).first,
              let raw = hit.artworkUrl100
        else { return nil }
        return catalogue.artworkURL(from: raw, size: 1000)
    }

    /// Whether a search hit really is the song being repaired.
    ///
    /// Deezer answers *something* for almost any query, so taking the first
    /// result unchecked would staple a stranger's album cover onto the track —
    /// worse than the grey square it replaced, because it looks correct. The
    /// title has to match outright; the artist is allowed to match loosely,
    /// since a song credited "A, B & C" locally comes back as just "A".
    private static func isSameSong(_ track: Track,
                                   primaryArtist: String,
                                   as hit: ITunesTrackResult) -> Bool {
        guard DiscoverNameMatch.sameName(track.title, hit.trackName) else { return false }
        guard !primaryArtist.isEmpty else { return true }
        if DiscoverNameMatch.sameName(primaryArtist, hit.artistName) { return true }

        let mine  = DiscoverNameMatch.normalize(track.artistName)
        let their = DiscoverNameMatch.normalize(hit.artistName)
        guard !mine.isEmpty, !their.isEmpty else { return false }
        return mine.contains(their) || their.contains(mine)
    }

    /// Downloads a batch of covers six at a time.
    ///
    /// Bounded rather than one task group over the whole list: these are static
    /// objects on our own storage or a CDN, and a hundred-song playlist still
    /// shouldn't open a hundred sockets.
    private static func fetchImages(_ jobs: [(UUID, URL)]) async -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for start in stride(from: 0, to: jobs.count, by: 6) {
            let chunk = Array(jobs[start..<min(start + 6, jobs.count)])
            let batch = await withTaskGroup(of: (UUID, Data?).self) { group in
                for (id, url) in chunk {
                    group.addTask { (id, await fetchImage(url)) }
                }
                var landed: [UUID: Data] = [:]
                for await (id, data) in group {
                    if let data { landed[id] = data }
                }
                return landed
            }
            out.merge(batch) { a, _ in a }
        }
        return out
    }

    /// Downloads a cover and shrinks it to the size the library stores.
    ///
    /// The downsample is not cosmetic. Every blob written here ends up resident
    /// in `tracks`/`albums`/`artists` for as long as the app runs, so storing a
    /// catalogue image at whatever size it happened to arrive at is how a large
    /// library turns into gigabytes of untouchable memory.
    static func fetchImage(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return ImageDownsampler.artworkJPEG(from: data)
    }

    /// Pushes freshly-arrived track covers up to the album and artist rows that
    /// hold those tracks.
    ///
    /// Those rows only ever take a picture at the moment they *adopt* a track
    /// (`adoptOrphanAlbums`, `adoptOrphanTracks`). By the time artwork is filled
    /// in afterwards the track is already claimed, so the row is skipped on every
    /// subsequent pass and keeps the nil it was created with — which is why the
    /// Albums grid and the Artists list stayed walls of grey squares even once
    /// every song underneath them had a cover.
    private func propagateArtworkToContainers(from trackIDs: [UUID]) {
        for id in trackIDs {
            guard let track = track(id: id), let art = track.artworkData else { continue }

            if !track.albumTitle.isEmpty,
               var album = try? albumRepo.findOrCreate(
                   title:      track.albumTitle,
                   artistName: ImportService.primaryArtistName(from: track.artistName),
                   deviceID:   deviceID
               ), album.artworkData == nil {
                album.artworkData = art
                album.sync.markModified()
                try? albumRepo.save(album)
                noteArtworkChanged(.album(album.id))
            }

            for name in ImportService.creditedArtists(from: track.artistName) {
                guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                      artist.artworkData == nil else { continue }
                artist.artworkData = art
                artist.sync.markModified()
                try? artistRepo.save(artist)
                noteArtworkChanged(.artist(artist.id))
            }
        }
    }

    public func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Private Helpers

    private func mutatePlaylist(id: UUID, body: (inout Playlist) -> Void) {
        guard var p = try? playlistRepo.fetch(id: id) else { return }
        body(&p)
        try? playlistRepo.save(p)
    }
}

// touch() is defined on Playlist directly (see Core/Models/Playlist.swift)
