// AppDependencies.swift
// Mixtape — App
//
// Central dependency container. Injected as @EnvironmentObject from MixtapeApp.
// All services are constructed here and wired together.
// To swap an implementation, change it here only.

import Foundation
import SwiftData
import Supabase
import Combine

@MainActor
public final class AppDependencies: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var isRestoringSession: Bool = true

    // MARK: - In-App Toast

    /// Short message shown as a bottom toast (e.g. "Song added to Playlist").
    /// Set via `showToast(_:)` — auto-clears after 2.5 s.
    @Published public private(set) var toastMessage: String? = nil
    private var toastTask: Task<Void, Never>? = nil

    public func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastMessage = nil }
        }
    }

    // MARK: - Saved-song Pill

    /// The small "Added to \u{2026}" pill that slides up at the bottom. Separate
    /// from `toastMessage` on purpose: that one is a wide bar for sentences,
    /// this is a glance, and the two can legitimately want to be on screen at
    /// the same time (save a song, then hit a sync error) — the roots stack
    /// them rather than letting them argue over the same corner.
    ///
    /// A plain `let` holding its own observable, *not* another `@Published`
    /// here. Every view in the app observes `deps`, so publishing the pill from
    /// this object redrew the whole tree twice per save and the animation spent
    /// its first frames competing with that. Reading `deps.savedToasts` now
    /// subscribes to nothing; only `SavedToastHost` watches the contents.
    public let savedToasts = SavedToastCenter()

    // MARK: - "Saved in" panel

    /// The corner panel that answers "where is this song saved?". Lives here
    /// so any view can raise it without owning a sheet — on macOS it is drawn
    /// once by the root window, above the player bar. Same reasoning as
    /// `savedToasts` for why it is its own observable.
    public let savedInPanel = SavedInPanelCenter()

    /// Show where a song just went.
    public func showSavedToast(_ destination: SaveDestination, count: Int = 1) {
        savedToasts.show(destination, count: count)
    }

    /// Show where a song just left. Same pill, same corner — see the rule below
    /// for why this is deliberately *not* wired into every remove in the app.
    public func showRemovedToast(_ destination: SaveDestination, count: Int = 1) {
        savedToasts.show(destination, count: count, direction: .removed)
    }

    // MARK: - Library writes that announce themselves
    //
    // Thin wrappers over the same `LibraryService` calls, and the only reason
    // they exist is that the card has to mean the same thing everywhere. There
    // are around twenty places in the app that favourite a song or drop it in a
    // playlist — a context menu on every list, both player bars, the sidebar's
    // drag target, Discover — and asking each one to remember the rule was how
    // the old toasts ended up on some of them and not others.
    //
    // The rule, in one place: an add says where the song went, and a remove says
    // where it left *only when the removal is the whole point of the gesture* —
    // which in practice means the "Saved in" sheet, where you went looking for
    // the filing to change it. Un-favouriting from a context menu still says
    // nothing: the heart empties in front of you, and a card for every such
    // fidget turns a reversible one into an event. Anything genuinely
    // destructive still gets the full-width toast, which is a sentence.
    //
    // Import and merge deliberately keep calling `libraryService` directly:
    // they move hundreds of songs and are not a gesture anyone is watching for.

    /// A smart playlist's songs right now. One call site for the rule's inputs,
    /// so the cover, the page and Home can't resolve it three different ways.
    public func smartTracks(_ smart: SmartPlaylist) -> [Track] {
        smartPlaylistService.resolve(
            smart,
            using: libraryService,
            history: PlayHistoryRepository()
        )
    }

    public func smartTrackIDs(_ smart: SmartPlaylist) -> [UUID] {
        smartTracks(smart).map(\.id)
    }

    /// The smart playlists Your Library shows: the ones the user added, and
    /// nothing else. The shipped five live on Home until someone opens one and
    /// presses +; a rule the user wrote arrives added, because writing it was
    /// the gesture.
    public var visibleSmartPlaylists: [SmartPlaylist] {
        smartPlaylistService.playlists.filter(\.inLibrary)
    }

    /// Favourite or un-favourite, showing the card only on the way in.
    /// Returns the new state, like the service call it wraps.
    @discardableResult
    public func toggleFavourite(trackID: UUID) -> Bool {
        let favourited = libraryService.toggleFavourite(trackID: trackID)
        if favourited { showSavedToast(.favourites) }
        return favourited
    }

    /// Add one song to a playlist and say which one.
    public func addTrack(id trackID: UUID, toPlaylist playlistID: UUID) {
        libraryService.addTrack(id: trackID, toPlaylist: playlistID)
        announceAdd(to: playlistID, count: 1)
    }

    /// Add a selection to a playlist and say where it went.
    public func addTracks(ids trackIDs: [UUID], toPlaylist playlistID: UUID) {
        libraryService.addTracks(ids: trackIDs, toPlaylist: playlistID)
        announceAdd(to: playlistID, count: trackIDs.count)
    }

    /// Name the destination from the playlist itself, so Favourites and Your
    /// Library read as themselves rather than as playlists that happen to be
    /// called that — they are both really playlists underneath, and a card
    /// saying "Added to All Songs" would leak that.
    private func announceAdd(to playlistID: UUID, count: Int) {
        guard count > 0 else { return }
        switch playlistID {
        case Playlist.favouritesID:
            showSavedToast(.favourites, count: count)
        case Playlist.allSongsID:
            showSavedToast(.library, count: count)
        default:
            guard let name = libraryService.playlist(id: playlistID)?.name else { return }
            showSavedToast(.playlist(id: playlistID, name: name), count: count)
        }
    }

    // MARK: - Services

    public let authService:    SupabaseAuthService
    public let syncService:    SupabaseSyncService
    public let fileStorage:    SupabaseFileStorageService
    public let queueService:   QueueService
    public let equalizer:      AudioEqualizer             // graphic EQ
    public let playbackEngine: PlaybackEngine
    /// Which of the account's open devices is playing, and control of it.
    public lazy var continuity = ContinuityService(
        client: SupabaseConfig.client, engine: playbackEngine, library: libraryService,
        deviceID: Self.deviceID, name: SupabaseSyncService.deviceName,
        platform: SupabaseSyncService.platformName,
        toast: { [weak self] in self?.showToast($0) })
    public let downloadManager: DownloadManager

    // MARK: - Library & Import

    public let libraryService:    LibraryService
    /// Owned here rather than by a view: the Library's Smart section and the
    /// "New Smart Playlist" editor behind the + menu are two different screens
    /// that have to see the same list the moment one of them changes it.
    public let smartPlaylistService: SmartPlaylistService
    public let importService:     ImportService
    /// Recreates a Spotify playlist locally (same cover + songs); songs resolve
    /// their audio lazily on play via the online coordinator.
    public let spotifyImportService: SpotifyImportService
    /// The user's watched folders, and the songs found in them. Derived — see
    /// `LocalFilesService`; nothing here is in the database.
    public let watchedFolders: WatchedFoldersStore
    public let localFiles:     LocalFilesService
    /// Spotify user OAuth (PKCE) — required to read playlist tracks for import.
    public let spotifyAuth: SpotifyAuth
    /// Keeps imported Spotify playlists in step with the account they came from.
    public let spotifyFollowService: SpotifyFollowService
    public let spotifyImportLedger: SpotifyImportLedger
    public let spotifyExportService: SpotifyExportService
    public let statsService:      ListeningStatsService
    public let profileStatsService: ProfileStatsService

    // MARK: - Metadata Enrichment

    public let enrichmentService: MetadataEnrichmentService

    // MARK: - Online Discover (search & instant stream)

    /// iTunes Search client powering the Discover result cards.
    public let itunesClient: ITunesSearchClient
    /// Spotify Web API client — current artist images for Discover.
    public let spotifyClient: SpotifyClient
    /// yt-dlp wrapper + orchestration for online streaming/caching.
    public let onlineCoordinator: OnlinePlaybackCoordinator
    /// "Paste a Spotify or YouTube link" → one song in the library.
    public let linkImport: LinkImportService

    #if os(iOS)
    /// Tracks which hosted/Mac resolver is reachable (Settings status + failover).
    public let resolverStatus: ResolverStatusService
    #endif
    /// Keeps the play queue topped up with similar songs (local + Deezer radio).
    public let queueSuggestions: QueueSuggestionService

    // MARK: - Supabase Client

    /// Shared across all Supabase-backed services (auth, sync, storage).
    /// Computed, not stored: see the provider comment in SupabaseAuthService.
    /// `SupabaseConfig.client` is a `static let`, so this stays a single
    /// shared instance — it is just built on first use instead of at launch.
    public var supabase: SupabaseClient { SupabaseConfig.client }

    // MARK: - Persistence

    /// The store that is open right now. `ModelStore` owns it — one file per
    /// account, so signing back in opens a library rather than rebuilding one.
    public var modelContainer: ModelContainer { ModelStore.shared.container }

    // MARK: - Device Identity

    public static let deviceID: String = {
        let key = "mix.deviceID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    /// One-shot artwork shrink. Held so it can be cancelled and re-run.
    public let artworkCompaction: ArtworkCompaction

    // MARK: - Init

    public init() {
        LaunchTimeline.mark("deps/init-begin")
        self.authService    = SupabaseAuthService(client: SupabaseConfig.client)
        self.fileStorage    = SupabaseFileStorageService(client: SupabaseConfig.client)
        self.queueService   = QueueService()
        LaunchTimeline.mark("deps/auth+storage")
        // Opening the last account's file is what the launch cost is; the
        // repositories below just read whichever one is open.
        _ = mixMainActivity("launch/model-container") { ModelStore.shared.container }

        LaunchTimeline.mark("deps/container-ready")
        let trackRepo    = TrackRepository()
        let albumRepo    = AlbumRepository()
        let artistRepo   = ArtistRepository()
        let playlistRepo = PlaylistRepository()
        let favoriteRepo = FavoriteRepository()
        let historyRepo  = PlayHistoryRepository()
        let snapshotRepo = PlayedTrackSnapshotRepository()

        self.libraryService = LibraryService(
            trackRepo:    trackRepo,
            albumRepo:    albumRepo,
            artistRepo:   artistRepo,
            playlistRepo: playlistRepo,
            favoriteRepo: favoriteRepo,
            deviceID:     Self.deviceID
        )
        // Pins are stored on the playlist row so they sync; the screens still ask
        // `PlaylistMetadataService`, which writes back through here.
        PlaylistMetadataService.shared.pinWriter = { [weak libraryService] id, pinned in
            libraryService?.setPlaylistPinned(id: id, pinned: pinned)
        }
        // The chosen sort order rides on the account rather than the device —
        // same shape as the pin writer above: the screens keep asking the
        // shared service, which writes back through here.
        let auth = self.authService
        PlaylistSortSyncService.shared.pushWriter = { raw in
            Task { await auth.updatePlaylistSortOrder(raw) }
        }
        // Same again for how each individual playlist is sorted.
        PlaylistTrackSortService.shared.pushWriter = { raw in
            Task { await auth.updatePlaylistTrackSorts(raw) }
        }
        SavedAlbumsService.shared.pushWriter = { raw in
            Task { await auth.updateSavedAlbums(raw) }
        }
        SavedAlbumsService.shared.onUnsave = { [libraryService] ids in libraryService.deleteTracks(ids: ids) }

        LaunchTimeline.mark("deps/library-service")
        self.smartPlaylistService = SmartPlaylistService(deviceID: Self.deviceID)
        self.statsService = ListeningStatsService(history: historyRepo, library: libraryService,
                                                  snapshots: snapshotRepo)
        self.profileStatsService = ProfileStatsService(client: SupabaseConfig.client, stats: statsService)
        self.enrichmentService = MetadataEnrichmentService()

        // Enrichment enabled on both platforms.
        let activeEnrichment: MetadataEnrichmentService? = self.enrichmentService

        self.importService = ImportService(
            fileManager:       MusicFileManager(),
            metadataParser:    MetadataParser(),
            enrichmentService: activeEnrichment,
            trackRepo:         trackRepo,
            albumRepo:         albumRepo,
            artistRepo:        artistRepo,
            libraryService:    libraryService,
            deviceID:          Self.deviceID
        )

        self.spotifyImportService = SpotifyImportService(
            trackRepo:      trackRepo,
            libraryService: libraryService,
            deviceID:       Self.deviceID
        )

        let watchedFolders = WatchedFoldersStore()
        self.watchedFolders = watchedFolders
        self.localFiles = LocalFilesService(
            folders:  watchedFolders,
            deviceID: Self.deviceID,
            // A promoted file stops showing under Local Files only for as long
            // as its library row lives. Delete the song and the file — still in
            // the folder — comes back.
            isInLibrary: { [weak libraryService] id in
                libraryService?.track(id: id) != nil
            }
        )

        LaunchTimeline.mark("deps/import-services")
        self.spotifyAuth = SpotifyAuth()

        self.syncService = SupabaseSyncService(
            client:         SupabaseConfig.client,
            libraryService: libraryService,
            deviceID:       Self.deviceID
        )

        // Auto-sync 1 s after the last imported track lands.
        // Weak capture breaks the AppDependencies → importService → closure → AppDependencies cycle.
        let syncRef = self.syncService
        // Resetting the history has to reach the server, or the next pull — or
        // another device's backlog — puts it straight back.
        self.statsService.remoteWipe = {
            Task { try? await syncRef.deleteAllServerPlayHistory() }
        }
        self.importService.onSyncNeeded = {
            try? await syncRef.sync()
        }

        // Shrinks artwork stored before covers were downsampled on the way in.
        // Runs once per device, after launch rather than during it — nothing
        // waits on it and it stops the moment anything destructive starts.
        let compaction = ArtworkCompaction()
        self.artworkCompaction = compaction
        self.libraryService.onCancelBackgroundWork = { [weak compaction] in
            compaction?.cancel()
        }

        LaunchTimeline.mark("deps/sync-service")
        self.equalizer = AudioEqualizer()

        LaunchTimeline.mark("deps/equalizer")
        self.playbackEngine = PlaybackEngine(
            queue:       queueService,
            fileStorage: fileStorage,
            equalizer:   equalizer
        )

LaunchTimeline.mark("deps/engine")
                // Discover audio resolution is platform-specific: macOS shells out to
        // yt-dlp; iOS asks the Mac/server resolver over HTTP. Both satisfy
        // TrackResolver, so the coordinator is identical either way.
        #if os(macOS)
        let trackResolver: any TrackResolver = YTDLPService()
        #else
        // iOS: share one status service between resolution (failover reports the
        // source that served) and Settings (status dot).
        let resolverStatus = ResolverStatusService()
        self.resolverStatus = resolverStatus
        let trackResolver: any TrackResolver = RemoteResolverService(status: resolverStatus)
        #endif

        LaunchTimeline.mark("deps/track-resolver")
        self.downloadManager = DownloadManager(
            fileStorage:    fileStorage,
            libraryService: libraryService,
            queueService:   queueService,
            trackResolver:  trackResolver
        )

        // Online Discover: iTunes cards + yt-dlp streaming/caching.
        LaunchTimeline.mark("deps/playback-engine")
        self.spotifyClient = SpotifyClient()

        self.spotifyImportLedger = SpotifyImportLedger(libraryService: libraryService)
        // Which Spotify playlists you've already imported is a fact about the
        // account, not the device — see the ledger's header.
        self.spotifyImportLedger.pushWriter = { raw in
            Task { await auth.updateSpotifyImports(raw) }
        }
        if case .authenticated(let user) = auth.authState {
            // Built after sign-in on a warm launch, so it misses the adoption
            // the auth service does when the state changes.
            self.spotifyImportLedger.adoptRemote(user.spotifyImports)
        }
        self.spotifyExportService = SpotifyExportService(client: self.spotifyClient,
                                                         auth: self.spotifyAuth)

        self.spotifyFollowService = SpotifyFollowService(
            client:         self.spotifyClient,
            auth:           self.spotifyAuth,
            importService:  self.spotifyImportService,
            exportService:  self.spotifyExportService,
            libraryService: libraryService
        )
        // Which playlists follow Spotify is a fact about the account too — see
        // the follow service's header for what losing it cost.
        self.spotifyFollowService.pushWriter = { raw in
            Task { await auth.updateSpotifyLinks(raw) }
        }
        if case .authenticated(let user) = auth.authState {
            self.spotifyFollowService.adoptRemote(user.spotifyLinks)
        }
        // Inject Spotify so Discover artist images resolve via Spotify (never Deezer).
        self.itunesClient = ITunesSearchClient(spotifyClient: self.spotifyClient)
        
        self.onlineCoordinator = OnlinePlaybackCoordinator(
            ytdlp:         trackResolver,
            engine:        playbackEngine,
            importService: importService,
            deviceID:      Self.deviceID
        )
        // Same resolver as Discover, so a song saved from a link and the same
        // song saved from a search share their cached audio and their identity.
        self.linkImport = LinkImportService(
            resolver:      trackResolver,
            importService: importService,
            spotify:       self.spotifyClient,
            catalogue:     self.itunesClient,
            library:       libraryService
        )
        // Route online tracks with no local file (Spotify imports, history
        // replays) through the coordinator so they resolve & stream, instead of
        // hitting the local-file path. Weak capture breaks the retain cycle.
        self.playbackEngine.onlineRouter = { [weak coordinator = self.onlineCoordinator] track, tracks in
            await coordinator?.playStandaloneOnline(track, context: tracks)
        }

        // A song leaving the library has to leave the two places the library
        // can't see: the offline store (with its queue, its retries and its
        // cached audio) and the player. Deleting a playlist now takes its songs
        // with it, so this is no longer one row at a time — a download left
        // behind is disk the user asked to have back. Weak captures both ways:
        // each of these holds the library, and the library now holds this.
        //
        // Playback is deliberately *not* one of them any more. Leaving the
        // library is a filing decision, not an instruction to stop the music,
        // and stopping it was the loudest thing that happened when you unsaved
        // the song you were listening to: it vanished from the mini player
        // mid-bar as though it had been deleted from existence. The audio file
        // still open on the player keeps feeding it to the end of the track
        // even after the copy on disk goes; what happens *next* time is the
        // normal cold path, which resolves and streams it again.
        //
        // The delete paths that genuinely mean "and stop playing this" — the
        // Delete from Library commands in Songs, Albums, Artists and the
        // playlist pages — call `stopIfPlaying` themselves, immediately before
        // the delete, and are unaffected.
        libraryService.onTracksWillDelete = { [weak downloads = self.downloadManager,
                                               weak engine = self.playbackEngine] trackIDs in
            downloads?.removeDownloads(for: trackIDs)
            // Home's shelves read the played list, not the library, so a delete
            // that stops here leaves the song on the landing page — playable,
            // with a plus that has nothing to add to. The snapshot goes with it
            // or the next launch puts the row straight back.
            engine?.forgetFromRecentlyPlayed(ids: trackIDs)
            try? snapshotRepo.delete(ids: trackIDs)
        }

        // The other half of the same seam: a playlist arriving from outside may
        // be one the user has standing orders to keep on the device. The
        // download manager decides whether it is — this only tells it a playlist
        // landed.
        libraryService.onPlaylistImported = { [weak downloads = self.downloadManager] playlistID in
            downloads?.autoKeepImportedPlaylist(playlistID)
        }

        LaunchTimeline.mark("deps/online-services")
        self.queueSuggestions = QueueSuggestionService(
            queue:       queueService,
            engine:      playbackEngine,
            library:     libraryService,
            itunes:      itunesClient,
            coordinator: onlineCoordinator
        )

        // Wire history persistence: save every new play to SwiftData.
        let deviceID = Self.deviceID
        self.playbackEngine.onTrackAddedToHistory = { track, seconds in
            do { try historyRepo.record(trackID: track.id, deviceID: deviceID, secondsPlayed: seconds) }
            catch { print("[history] persist FAILED: \(error)") }
            // Online (Discover) tracks have no library row — persist a lightweight
            // snapshot so they survive relaunch on Home and resolve in stats.
            if track.isOnline {
                do { try snapshotRepo.upsert(track); print("[history] snapshot upserted '\(track.title)'") }
                catch { print("[history] snapshot upsert FAILED: \(error)") }
            }
        }

        // Correct the logged play's listen time once the user leaves the track —
        // the difference between "started this" and "actually listened to this".
        self.playbackEngine.onPlaySecondsFinalised = { trackID, seconds in
            do { try historyRepo.finaliseLatestPlay(trackID: trackID, secondsPlayed: seconds) }
            catch { print("[history] finalise FAILED: \(error)") }
        }

        // Restore persisted history so the "Recently Played" list is populated on
        // launch. Resolve each id against the library first, then fall back to the
        // online-track snapshot store.
        mixMainActivity("launch/history-restore") {
        if let recentIDs = try? historyRepo.fetchRecentTrackIDs() {
            let snapshots = (try? snapshotRepo.fetchAll()) ?? [:]
            let tracks = recentIDs.compactMap { id -> Track? in
                // `fetch(id:)` sees tombstones, unlike `fetchAll`. A deleted song
                // is deleted on Home too, and must not fall through to its
                // snapshot either — that copy outlives the library row.
                if let row = try? trackRepo.fetch(id: id) { return row.isDeleted ? nil : row }
                return snapshots[id]
            }
            print("[history] restore: \(recentIDs.count) ids, \(snapshots.count) snapshots, resolved \(tracks.count) tracks")
            self.playbackEngine.restoreHistory(tracks)
        }
        }

        // Which songs a playlist borrows its cover from is a `LibraryService`
        // rule; drawing it is the design system's job. This is the seam — the
        // loader asks, the library answers, and neither has to know the other's
        // type.
        // Smart playlists aren't library rows, so their id falls through to
        // the songs they resolve to right now — same rule, same cover.
        ArtworkImageLoader.shared.playlistCoverRefs = { [weak self] id in
            guard let self else { return [] }
            if let smart = self.smartPlaylistService.playlists.first(where: { $0.id == id }) {
                return self.libraryService.coverRefs(forTrackIDs: self.smartTrackIDs(smart))
            }
            return self.libraryService.coverRefs(forPlaylistID: id)
        }

        LaunchTimeline.mark("deps/history-restored")
        wireResetObserver()
        wireAuthObserver()
        // Off the main actor, and the session restore that needs the library
        // rides along behind it. The synchronous form held the main thread for
        // 3.1 s on the phone — the three bulk fetches alone were 1.4 s of it —
        // which is time the first window spends not existing.
        Task { [weak self] in
            await libraryService.refreshOffMain()
            // Needs the library to have been read once, and has no business
            // holding up the first window. See its own comment.
            libraryService.reclaimNeverUploadedAudioFromCache()
            mixMainActivity("launch/restore-session") {
                self?.playbackEngine.restoreLastSession(allTracks: libraryService.tracks)
            }
        }

        // Followed Spotify playlists: check once now, then quietly every quarter
        // of an hour. Returns immediately when nothing is followed or the account
        // isn't connected, so the cost for everyone else is one `if`.
        LaunchTimeline.mark("deps/refresh-task-spawned")
        spotifyFollowService.startAutoSync()

        // Libraries imported before the backfill existed are full of artists
        // wearing an album cover. This finds them on launch and fetches real
        // profile photos; once an artist has one it's skipped, so it's a
        // one-time cost rather than a burst of lookups every launch.
        libraryService.scheduleArtistImageBackfill()

        // Restore the last playback session (paused at its saved position) so the
        // user can resume where they left off. Does NOT auto-play.

        LaunchTimeline.mark("deps/backfills-scheduled")
        libraryService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // DownloadManager is deliberately NOT forwarded.
        //
        // It publishes on every status transition — a song starting, finishing,
        // failing — and forwarding that invalidated all 81 views that hold
        // `deps` as an @EnvironmentObject, most of which draw nothing to do with
        // downloads. A large download run put the whole tree through that
        // thousands of times, and the Mac songs table re-hashes the entire
        // library each time it re-renders.
        //
        // The views that actually draw download state subscribe to the manager
        // themselves (a `downloadTick` bumped from `.onReceive`), and the leaf
        // components — DownloadStatusBar, DownloadStatusRing, DownloadsPane,
        // StoragePane — take it as an @ObservedObject. Anything new that reads
        // `deps.downloadManager` inside a `body` has to do one of those two
        // things or it will draw a stale badge.

        // And the local-files scan. A nested ObservableObject doesn't republish
        // through its parent on its own, so without this the sidebar row and the
        // Settings count would both sit on whatever the first scan happened to
        // find and never move again.
        localFiles.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        watchedFolders.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The first look at the watched folders. Cheap when the list is empty,
        // which it is for everyone who has never opened this feature.
        mixMainActivity("launch/local-files-rescan") { localFiles.rescan() }

        // Forward authService publishes so views can react to authentication changes (like user logins/logouts)
        authService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Off-actor, so the first real Supabase call finds the client already
        // built rather than paying for it on the main thread. See SupabaseConfig.warm().
        Task { await SupabaseConfig.warm(); LaunchTimeline.mark("deps/supabase-warmed") }
        // Eager, so a song started before sign-in still counts as "playing here".
        _ = continuity
        // Lets a handoff carry the upload the sending device already resolved.
        continuity.online = onlineCoordinator
        // The device picker lists each device's audio quality, so the setting
        // has to travel with presence rather than sit in local Settings.
        downloadManager.$downloadQuality
            .sink { [weak self] q in self?.continuity.setQuality(q.title) }
            .store(in: &cancellables)
        syncService.onRealtimeReady = { [weak self] in self?.continuity.start(userID: $0) }
        LaunchTimeline.mark("deps/init-end")
    }

    // MARK: - Session Restore

    public func restoreSessionIfNeeded() async {
        isRestoringSession = true
        // Run the session restore and a minimum splash duration concurrently.
        // The splash stays visible for at least 1.8 s — long enough to feel
        // intentional — but never longer than the actual network call if that
        // takes more time.
        async let session: Void = authService.restoreSession()
        async let minDelay: Void = Task.sleep(nanoseconds: 1_800_000_000)
        await session
        _ = try? await minDelay
        isRestoringSession = false
    }

    // MARK: - Private Wiring

    private func wireAuthObserver() {
        authService.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .authenticated(let user):
                    self.onSignInSync(user: user)
                    self.isAuthenticated = true
                    Task { await self.onSignIn(user: user) }
                case .unauthenticated:
                    self.onSignOutSync()
                    self.isAuthenticated = false
                    Task { await self.onSignOut() }
                case .loading:
                    break
                }
            }
            .store(in: &cancellables)

        // Losing the network turns the Downloaded filter on for the user; it
        // stays a filter they can switch off, and what isn't downloaded is then
        // drawn grey rather than hidden. See `LibraryService.downloadedOnly`.
        libraryService.offlinePlayableIDs = { [weak self] in
            self?.downloadManager.downloadedTrackIDs ?? []
        }
        onlineCoordinator.isOnline = { [weak self] in
            self?.downloadManager.isConnected ?? true
        }
        downloadManager.$isConnected
            .combineLatest(authService.$isOffline)
            .map { !$0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] offline in
                self?.libraryService.offlineOnly = offline
                // Only on the way out — coming back doesn't yank a filter away
                // from somebody who may have chosen it.
                if offline { self?.libraryService.downloadedOnly = true }
            }
            .store(in: &cancellables)

        // The network coming back is the only signal an offline session gets
        // that it can try again — nothing else asks. The retry is a no-op
        // unless we are actually running on a cached session.
        downloadManager.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { [weak self] in await self?.authService.retryOnlineAuth() }
            }
            .store(in: &cancellables)

        // A refresh that lands turns isOffline off — which is the moment the
        // sync `onSignIn` skipped can finally run.
        authService.$isOffline
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self, let user = self.authService.currentUser else { return }
                Task { await self.onSignIn(user: user) }
            }
            .store(in: &cancellables)
    }

    private func onSignInSync(user: AppUser) {
        // The store goes first. Everything below writes through a repository or
        // seeds rows of its own, and until this has run those land in whichever
        // account's file was open a moment ago.
        //
        // Each account has its own store, so this opens theirs rather than
        // wiping anyone's: the outgoing library stays on disk for when they
        // come back, which is the whole point of it.
        let lastUserKey = ModelStore.lastUserKey
        let lastUserID = UserDefaults.standard.string(forKey: lastUserKey)
        if ModelStore.shared.open(for: user.id) {
            print("[AppDependencies] 🔀 Different user signed in — opened their own local store.")
            adoptSwitchedStore()
        }

        fileStorage.currentUserID = user.id
        PlaylistMetadataService.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUsername = user.username ?? user.displayName
        downloadManager.currentUserID = user.id.uuidString
        smartPlaylistService.currentUserID = user.id.uuidString
        // The outside connections are the account's, not the device's. Both are
        // told who is signing in *before* the marker moves, since "was this
        // grant made by this user?" is a question only the outgoing name can
        // answer for connections made before either service recorded an owner.
        spotifyAuth.accountDidChange(to: user.id, previous: lastUserID)
        LastFmScrobbler.shared.accountDidChange(to: user.id, previous: lastUserID)
        // What follows the account is replaced outright rather than cleared: an
        // incoming user with no copy of their own gets an empty one, which is
        // the truth, and the outgoing user's records are never pushed to them.
        if let lastUserID, lastUserID != user.id.uuidString {
            spotifyImportLedger.accountDidChange(remote: user.spotifyImports)
            spotifyFollowService.accountDidChange(remote: user.spotifyLinks)
        }
        UserDefaults.standard.set(user.id.uuidString, forKey: lastUserKey)
    }

    private func onSignIn(user: AppUser) async {
        // Signed in on a cached session: there is no token to sync with, and
        // handing the sync service an empty one only buys a round of failures.
        // `wireAuthObserver` runs this again when the network comes back.
        guard !authService.isOffline else { return }
        let token = authService.accessToken ?? ""
        // Force-logout hook: when this device is revoked from the web, sign out.
        syncService.onDeviceRevoked = { [weak self] in
            try? await self?.authService.signOut()
        }
        await syncService.onSignIn(user: user, accessToken: token)
        syncService.startBackgroundSync(intervalSeconds: 60)

        // Publish a fresh listening-stats snapshot for the discovery profile.
        await profileStatsService.publishMyStats(userID: user.id)

        // Covers saved before the 1024 px ceiling (300/512 px) stay soft forever
        // unless re-fetched. Do it once per install, in the background.
        let upgradeKey = "mix.coverUpgrade.v1"
        if !UserDefaults.standard.bool(forKey: upgradeKey) {
            let low = ArtworkProvider.shared.trackIDsWithLowResArtwork(maxDimension: 600)
            if !low.isEmpty {
                _ = await libraryService.backfillPlaceholderArtwork(
                    trackIDs: low, publishedBy: user.id,
                    using: itunesClient, replacingExisting: true)
            }
            UserDefaults.standard.set(true, forKey: upgradeKey)
        }
    }

    private func onSignOutSync() {
        continuity.stop()
        clearPlaybackSession()
        // The filter is a choice the signed-out person made; the next one starts
        // with it off unless there is genuinely no network.
        libraryService.downloadedOnly = libraryService.offlineOnly
        smartPlaylistService.currentUserID = nil

        fileStorage.currentUserID = nil
        PlaylistMetadataService.shared.currentUserID = nil
        ExportManager.shared.currentUserID = nil
        ExportManager.shared.currentUsername = nil
        downloadManager.currentUserID = nil

        // Connections follow the account out. The stored grants stay on disk,
        // stamped with their owner, exactly as the local library does — they are
        // simply unreachable until an account claims them again.
        spotifyAuth.signedOut()
        LastFmScrobbler.shared.signedOut()
    }

    private func onSignOut() async {
        await syncService.onSignOut()
        // Deliberately keeps the local library, and keeps the last-user marker
        // that guards it. Signing out is not a request to delete anything: this
        // is still the same person's data a minute later, and wiping it here
        // cost a full re-pull on every sign-in — and lost, permanently, anything
        // the server hadn't seen yet. Isolation is enforced at the point it
        // actually matters, when a *different* user signs in (onSignInSync).
        //
        // Nothing of the signed-out account stays on screen: onSignOutSync has
        // already stopped playback and cleared the in-memory history, and the
        // app shows the sign-in wall until someone authenticates.
    }

    /// Nothing playing, nothing queued, nothing to resume, no history.
    private func clearPlaybackSession() {
        onlineCoordinator.endSession()
        playbackEngine.forgetLastSession()
        playbackEngine.restoreHistory([])
    }

    /// Rebuild what a wipe invalidated.
    ///
    /// The stores that own their own derived state (the Discover landing, the
    /// playlist last-played dates) subscribe to the reset themselves. What's left
    /// is the state that lives on services this container wired together, and
    /// which nothing else is in a position to refresh: the in-memory
    /// recently-played list, and the library's own published arrays. See
    /// `UserDataReset`.
    private func wireResetObserver() {
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reset = UserDataReset.from(note)
                if reset.clearedHistory { self.playbackEngine.clearRecentlyPlayed() }
                if reset.clearedLibrary {
                    // The recently-played entries that survive a library-only
                    // wipe are the Discover plays — the library ones no longer
                    // resolve to anything playable.
                    self.playbackEngine.clearRecentlyPlayed()
                    self.libraryService.refresh()
                }
            }
        }
    }

    /// Brings the app in line with the store `ModelStore` just opened.
    ///
    /// Nothing is deleted here, which is the whole point: the outgoing
    /// account's rows, history and snapshots are in their own file, and the
    /// incoming account's are in the one now open. What has to change is
    /// everything held *outside* the store — in-memory lists, caches, and
    /// anything derived from a library that is no longer the one on screen.
    ///
    /// Their sync watermarks are deliberately left alone. They were written the
    /// last time this device pulled *their* rows, and those rows are still
    /// here, so the next pull is a few seconds of changes rather than the
    /// five-minute full re-download that made signing back in feel like a
    /// fresh install.
    private func adoptSwitchedStore() {
        // A session restored on launch, before anyone signed in, is the last
        // account's — and it may have been restored from an older build that
        // never cleared it on sign-out.
        clearPlaybackSession()
        libraryService.storeDidOpen()
        playbackEngine.restoreHistory([]) // clear in-memory recently played
        // A different person is signing in, so nothing derived from the last
        // one's library or history may survive into their home page. Announced
        // as a switch rather than a wipe: what follows the account has already
        // been handed the incoming user's own copy and must not be cleared.
        UserDataReset.announce(.accountSwitch)
    }
}
