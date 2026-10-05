// Dependency container, injected as an @EnvironmentObject from MixtapeApp.
// Every service is built and wired here.

import Foundation
import AppIntents
import SwiftData
import Supabase
import Combine
import OSLog

@MainActor
public final class AppDependencies: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var isRestoringSession: Bool = true

    // MARK: - In-App Toast

    /// The message card. Its own object, so a toast doesn't redraw everything watching deps.
    public let toasts = ToastCenter()

    public func showToast(_ toast: Toast) { toasts.show(toast) }
    public func showToast(_ message: String) { toasts.show(Toast(message)) }

    private var isResavingEdits = false

    /// Re-save Edits: renders every edit again from its original at the current Song Edit Quality,
    /// since changing the setting can't touch files already written. One at a time; each keeps its song.
    public func resaveEdits() async {
        guard !isResavingEdits else { return }
        isResavingEdits = true
        defer { isResavingEdits = false }
        let edits = libraryService.tracks.filter { $0.origin == .edit && $0.edit?.studioReady != false }
        guard !edits.isEmpty else { return }
        showToast("Re-saving \(edits.count) edit\(edits.count == 1 ? "" : "s") at \(downloadManager.editQuality.title) quality")
        var failed = 0
        for track in edits {
            do { _ = try await renderEdit(track) } catch { failed += 1 }
        }
        if failed == 0 {
            showToast(.done("Re-saved \(edits.count) edit\(edits.count == 1 ? "" : "s")"))
        } else {
            // Mostly an original that's gone or can't be fetched right now.
            showToast(.failed("Couldn't re-save \(failed) of \(edits.count) edits"))
        }
    }

    /// So a tap and a download of the same edit render it once.
    private var editRebuilds: [UUID: Task<URL, Error>] = [:]

    /// An edit's file, rendered from its original when this device has none (made on another device, or
    /// in a shared tape). Playback and downloads call this.
    public func rebuildEdit(_ track: Track) async throws -> URL {
        let track = libraryService.track(id: track.id) ?? track
        if let url = AudioPaths.durableURL(forLocalPath: track.file.localPath) { return url }
        if let running = editRebuilds[track.id] { return try await running.value }
        let task = Task { try await self.renderEdit(track) }
        editRebuilds[track.id] = task
        defer { editRebuilds[track.id] = nil }
        return try await task.value
    }

    private struct EditUnavailable: Error {}

    /// Renders `track` from its original at the current quality. A library song gets the file in place,
    /// keeping its id, likes and playlists; one that isn't in the library (a Jam pick) plays from a temp file.
    private func renderEdit(_ track: Track) async throws -> URL {
        guard let recipe = track.edit else { throw EditUnavailable() }
        let original = editOriginal(of: recipe, editDuration: track.duration)
        let dest = FileManager.default.temporaryDirectory.appending(path: "Edit-\(track.id.uuidString).m4a")
        let audio = try await downloadManager.localAudio(for: original)
        defer { if let scratch = audio.scratch { try? FileManager.default.removeItem(at: scratch) } }
        try? FileManager.default.removeItem(at: dest)
        let layers = try await EditRenderer.layers(for: recipe, source: audio.url)
        try await EditRenderer.render(layers, edit: recipe,
                                      quality: downloadManager.editQuality, to: dest) { _ in }
        guard libraryService.track(id: track.id) != nil else { return dest }
        defer { try? FileManager.default.removeItem(at: dest) }
        let saved = try await importService.replaceEditAudio(of: track, with: dest)
        guard let url = AudioPaths.durableURL(forLocalPath: saved.file.localPath) else { throw EditUnavailable() }
        return url
    }

    /// The song an edit was made from: this library's copy if there is one, else an online row the
    /// resolver can fetch from the recipe's "title|artist".
    func editOriginal(of recipe: SongEdit, editDuration: TimeInterval) -> Track {
        if let own = libraryService.track(id: recipe.of) { return own }
        let parts = recipe.sourceRef.split(separator: "|", maxSplits: 1).map(String.init)
        let title = parts.first ?? "", artist = parts.count > 1 ? parts[1] : ""
        let duration = editDuration * recipe.speed
        let id = OnlineTrack.stableID(for: recipe.sourceRef)
        if let own = libraryService.track(id: id)
            ?? libraryService.track(matching: title, artistName: artist, duration: duration) {
            return own
        }
        return Track(id: id, title: title, artistName: artist, albumTitle: "", duration: duration,
                     sync: SyncMetadata(deviceID: ""), file: .onlinePlaceholder(sourceRef: recipe.sourceRef))
    }

    /// Saves a community post as your own edit, liked, like the editor's Save. An edit you already
    /// have with the same recipe comes back instead, so a post can't land in the library twice.
    public func savePost(_ post: CommunityPost) async throws -> (track: Track, isNew: Bool) {
        let original = editOriginal(of: post.edit, editDuration: post.duration ?? 0)
        // `of` named the poster's copy; yours rebuilds from your own.
        var recipe = post.edit
        recipe.of = original.id
        if let have = libraryService.tracks.first(where: { !$0.isDeleted && $0.edit?.sameSound(as: recipe) == true }) {
            return (have, false)
        }
        guard post.audioPath != nil else {
            return (try importService.saveEdit(recipe: recipe, of: original, title: post.title), true)
        }
        // A studio post keeps its posted file. A copy, since saving tags the file it's given.
        let audio = try await downloadManager.localAudio(for: post.track(artwork: nil))
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "Post-\(post.id.uuidString).\(audio.url.pathExtension)")
        defer {
            try? FileManager.default.removeItem(at: copy)
            if let scratch = audio.scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: audio.url, to: copy)
        return (try await importService.saveEdit(rendered: copy, of: original, edit: recipe, title: post.title), true)
    }

    private var refreshedPostWaveforms = false

    /// Gives your posts the current shape: older ones have none, or a coarser one. Once per launch,
    /// one at a time, from your own copy of the edit when you have it.
    private func refreshPostWaveforms(user: UUID) async {
        guard !refreshedPostWaveforms else { return }
        refreshedPostWaveforms = true
        var posts: [CommunityPost] = []
        while let page = try? await community.profile(user, .posts, after: posts.map { FeedItem(post: $0) }),
              !page.isEmpty {
            posts += page.map(\.post)
            if page.count < CommunityService.pageSize { break }
        }
        for post in posts where Waveform.decode(post.waveform)?.count != Waveform.postSlices {
            let mine = libraryService.tracks.first { !$0.isDeleted && $0.edit?.sameSound(as: post.edit) == true }
            guard let shape = await postWaveform(of: mine ?? post.track(artwork: nil)) else { continue }
            try? await community.setWaveform(post.id, shape)
        }
    }

    /// "Wrong version". A downloaded copy is the rejected version too, so it's
    /// removed and fetched again once a new source is picked.
    public func reResolve(_ track: Track, at index: Int? = nil) async {
        let wasDownloaded = downloadManager.discardOfflineCopy(of: track)
        await onlineCoordinator.reResolve(track, at: index)
        if wasDownloaded { downloadManager.refetch(track) }
    }

    /// Thumbs down on the version card: another "Wrong version".
    public func tryAnotherVersion() async {
        await refetchingOfflineCopy { await self.onlineCoordinator.tryAnotherVersion() }
    }

    /// "Go back" on the version card.
    public func restorePreviousVersion() async {
        await refetchingOfflineCopy { await self.onlineCoordinator.restorePreviousVersion() }
    }

    /// The downloaded copy of the song on the card is the version being swapped out.
    private func refetchingOfflineCopy(_ swap: () async -> Void) async {
        let ref = onlineCoordinator.versionCheck?.sourceRef
        let track = playbackEngine.queue.currentTrack.flatMap { $0.sourceRef == ref ? $0 : nil }
        let wasDownloaded = track.map { downloadManager.discardOfflineCopy(of: $0) } ?? false
        await swap()
        if wasDownloaded, let track { downloadManager.refetch(track) }
    }

    // MARK: - Saved-song Pill

    /// The "Added to..." card. Separate from `toasts` since both can show
    /// at once. A plain `let` rather than @Published so a save doesn't redraw every
    /// view observing deps; only SavedToastHost watches it.
    public let savedToasts = SavedToastCenter()

    // MARK: - "Saved in" panel

    /// The "where is this song saved?" panel. Its own observable like savedToasts.
    public let savedInPanel = SavedInPanelCenter()

    /// Show where a song just went, with View to go there.
    public func showSavedToast(_ destination: SaveDestination, count: Int = 1) {
        let id = destination.playlistID
        savedToasts.show(destination, count: count, action: Toast.Action(title: "View") { Toast.openPlaylist(id) })
    }

    /// Removal version of the pill. Pass `undo` only when the songs can still be put back.
    public func showRemovedToast(_ destination: SaveDestination, count: Int = 1,
                                 undo: (@MainActor () -> Void)? = nil) {
        savedToasts.show(destination, count: count, direction: .removed,
                         action: undo.map { Toast.Action(title: "Undo", run: $0) })
    }

    // MARK: - Library writes that announce themselves
    // Wrappers so every add and remove shows the same card. Import and merge call libraryService directly.

    /// A smart playlist's current songs. One place so the cover, page and Home agree.
    /// Kept per library revision: the sidebar and list rows ask on every draw, and every
    /// play bumps `revision`, so history rules stay current.
    public func smartTracks(_ smart: SmartPlaylist) -> [Track] {
        let revision = libraryService.revision
        if smartMemoRevision != revision {
            smartMemo = [:]
            smartMemoRevision = revision
        }
        if let hit = smartMemo[smart] { return hit }
        let tracks = smartPlaylistService.resolve(
            smart,
            using: libraryService,
            history: PlayHistoryRepository()
        )
        smartMemo[smart] = tracks
        return tracks
    }

    private var smartMemo: [SmartPlaylist: [Track]] = [:]
    private var smartMemoRevision: UInt64?

    public func smartTrackIDs(_ smart: SmartPlaylist) -> [UUID] {
        smartTracks(smart).map(\.id)
    }

    /// Smart playlists in Your Library: only ones the user added. Built-in ones
    /// live on Home until added. User-written rules start added.
    public var visibleSmartPlaylists: [SmartPlaylist] {
        smartPlaylistService.playlists.filter(\.inLibrary)
    }

    /// Toggles the like and says so. Returns the new state.
    @discardableResult
    public func toggleFavourite(trackID: UUID) -> Bool {
        let before = libraryService.playlist(id: Playlist.favouritesID)?.trackIDs ?? []
        let favourited = libraryService.toggleFavourite(trackID: trackID)
        if favourited { showSavedToast(.favourites) }
        else { announceRemove([trackID], from: Playlist.favouritesID, order: before) }
        playbackEngine.syncRemoteCommandState()
        return favourited
    }

    /// Remove a selection from a playlist and say so.
    public func removeTracks(ids trackIDs: [UUID], fromPlaylist playlistID: UUID) {
        let before = libraryService.playlist(id: playlistID)?.trackIDs ?? []
        SupabaseSyncService.allowBulk("user-remove")
        libraryService.removeTracks(ids: trackIDs, fromPlaylist: playlistID)
        // Only what was there, so Undo doesn't fill in a playlist that held some of them.
        let held = Set(before)
        announceRemove(trackIDs.filter(held.contains), from: playlistID, order: before)
    }

    /// Offers Undo only while the songs still exist. One only this playlist held is deleted with its file.
    private func announceRemove(_ trackIDs: [UUID], from playlistID: UUID, order before: [UUID]) {
        guard !trackIDs.isEmpty, let playlist = libraryService.playlist(id: playlistID) else { return }
        let destination: SaveDestination = switch playlistID {
        case Playlist.favouritesID: .favourites
        case Playlist.allSongsID:   .library
        default:                    .playlist(id: playlistID, name: playlist.name)
        }
        guard trackIDs.allSatisfy({ libraryService.track(id: $0) != nil }) else {
            showRemovedToast(destination, count: trackIDs.count)
            return
        }
        showRemovedToast(destination, count: trackIDs.count) { [weak self] in
            self?.putBack(trackIDs, in: playlistID, order: before)
        }
    }

    /// Adds the songs back at the places they had.
    private func putBack(_ trackIDs: [UUID], in playlistID: UUID, order before: [UUID]) {
        libraryService.addTracks(ids: trackIDs, toPlaylist: playlistID)
        guard var now = libraryService.playlist(id: playlistID)?.trackIDs else { return }
        let restored = Set(trackIDs)
        now.removeAll(where: restored.contains)
        for (index, id) in before.enumerated() where restored.contains(id) {
            now.insert(id, at: min(index, now.count))
        }
        libraryService.setTracks(now, inPlaylist: playlistID)
        playbackEngine.syncRemoteCommandState()
    }

    /// Add one song to a playlist and say which one.
    public func addTrack(id trackID: UUID, toPlaylist playlistID: UUID) {
        libraryService.addTrack(id: trackID, toPlaylist: playlistID)
        announceAdd(to: playlistID, count: 1)
    }

    /// Add a selection to a playlist and say where it went.
    public func addTracks(ids trackIDs: [UUID], toPlaylist playlistID: UUID) {
        SupabaseSyncService.allowBulk("user-add")
        libraryService.addTracks(ids: trackIDs, toPlaylist: playlistID)
        announceAdd(to: playlistID, count: trackIDs.count)
    }

    /// Names Liked Songs and Your Library as themselves, not as playlists.
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
    /// Listening together with other accounts (Phase 6).
    public lazy var jam = JamService(
        client: SupabaseConfig.client, engine: playbackEngine, continuity: continuity,
        deviceID: Self.deviceID, currentUser: { [weak self] in self?.authService.currentUser },
        toast: { [weak self] in self?.showToast($0) })
    /// Two-person shared playlists, rebuilt daily.
    public lazy var blends = BlendService(
        client: SupabaseConfig.client, catalog: itunesClient,
        toast: { [weak self] in self?.showToast($0) })
    public let downloadManager: DownloadManager
    /// Posted edits, likes and comments (song edits phase 4).
    public lazy var community = CommunityService(client: SupabaseConfig.client)
    /// Last month's listening, once a month.
    public lazy var recap = RecapService(
        client: SupabaseConfig.client, history: PlayHistoryRepository(), library: libraryService,
        snapshots: PlayedTrackSnapshotRepository(),
        deviceNames: { [weak self] in await self?.syncService.deviceNames() ?? [:] })
    /// Named queues you switch between (7.6).
    public lazy var tapeDecks = TapeDeckService(
        engine: playbackEngine, coordinator: onlineCoordinator, library: libraryService,
        toast: { [weak self] in self?.showToast($0) },
        addToPlaylist: { [weak self] in self?.addTracks(ids: $0, toPlaylist: $1) })

    // MARK: - Library & Import

    public let libraryService:    LibraryService
    /// Shared so the Library's Smart section and the editor see the same list.
    public let smartPlaylistService: SmartPlaylistService
    public let importService:     ImportService
    /// Recreates a Spotify playlist locally. Audio resolves on play.
    public let spotifyImportService: SpotifyImportService
    /// Watched folders and their songs. Derived, not in the database.
    public let watchedFolders: WatchedFoldersStore
    public let localFiles:     LocalFilesService
    /// Spotify OAuth (PKCE), needed to read playlist tracks.
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
    /// Spotify Web API, for artist images in Discover.
    public let spotifyClient: SpotifyClient
    /// yt-dlp wrapper + orchestration for online streaming/caching.
    public let onlineCoordinator: OnlinePlaybackCoordinator
    /// "Paste a Spotify or YouTube link" -> one song in the library.
    public let linkImport: LinkImportService

    #if os(iOS)
    /// Tracks which hosted/Mac resolver is reachable (Settings status + failover).
    public let resolverStatus: ResolverStatusService
    #endif
    /// Keeps the play queue topped up with similar songs (local + Deezer radio).
    public let queueSuggestions: QueueSuggestionService

    // MARK: - Supabase Client

    /// Shared Supabase client, built on first use.
    public var supabase: SupabaseClient { SupabaseConfig.client }

    // MARK: - Persistence

    /// The open store. One file per account, owned by ModelStore.
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
    /// The Downloaded filter was turned on by losing the network, not by the user.
    private var filterWentOnOffline = false
    #if os(iOS)
    private(set) var nowPlayingSurfaces: NowPlayingSurfaces?
    #endif

    /// One-shot artwork shrink. Held so it can be cancelled and re-run.
    public let artworkCompaction: ArtworkCompaction

    // MARK: - Init

    public init() {
        LaunchTimeline.mark("deps/init-begin")
        self.authService    = SupabaseAuthService(client: SupabaseConfig.client)
        self.fileStorage    = SupabaseFileStorageService(client: SupabaseConfig.client)
        self.queueService   = QueueService()
        LaunchTimeline.mark("deps/auth+storage")
        // Opening the last account's store is the launch cost.
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
        // Pins live on the playlist row so they sync.
        PlaylistMetadataService.shared.pinWriter = { [weak libraryService] id, pinned in
            libraryService?.setPlaylistPinned(id: id, pinned: pinned)
        }
        // Sort order is per account, written back through here.
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
        CrateService.shared.pushWriter = { raw in
            Task { await auth.updateCrates(raw) }
        }
        PlaylistMetadataService.shared.showsAllSongsWriter = { on in
            Task { await auth.updateShowsAllSongs(on) }
        }
        PlaylistMetadataService.shared.importDestinationWriter = { raw in
            Task { await auth.updateImportDestination(raw) }
        }
        ThemeManager.shared.backdropWriter = { raw in
            Task { await auth.updateBackdrop(raw) }
        }
        SavedAlbumsService.shared.onUnsave = { [libraryService] ids in libraryService.deleteTracks(ids: ids) }
        queueService.playlistLookup = { [weak libraryService] id in
            libraryService?.playlist(id: id)
        }

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
            // A promoted file shows again once its library row is deleted.
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

        // Sync 1 s after the last imported track. Weak capture avoids a retain cycle.
        let syncRef = self.syncService
        // Reset history on the server too, or the next pull brings it back.
        self.statsService.remoteWipe = {
            Task { try? await syncRef.deleteAllServerPlayHistory() }
        }
        // Clearing from the history page has to do what Settings does: rebuild anything
        // derived from the log, and republish the profile's numbers from the empty one.
        // Without the republish the wipe is local only, and the old top artists stay
        // visible to everyone else.
        let profileStats = self.profileStatsService
        self.statsService.afterClear = {
            UserDataReset.announce(UserDataReset(clearedLibrary: false, clearedHistory: true))
            guard let userID = auth.currentUser?.id else { return }
            await profileStats.publishMyStats(userID: userID)
        }
        self.importService.onSyncNeeded = {
            try? await syncRef.sync()
        }

        // Shrinks old full-size artwork once per device, after launch.
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
        // macOS runs yt-dlp; iOS asks the resolver over HTTP. Both are TrackResolvers.
        #if os(macOS)
        let trackResolver: any TrackResolver = YTDLPService()
        #else
        // One status service for resolution and the Settings status dot.
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
        // Imported playlists are per account, not per device.
        self.spotifyImportLedger.pushWriter = { raw in
            Task { await auth.updateSpotifyImports(raw) }
        }
        if case .authenticated(let user) = auth.authState {
            // On a warm launch this is built after sign-in, so adopt now.
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
        // Follows are per account too.
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
        // Same resolver as Discover, so link saves and search saves are the same song.
        self.linkImport = LinkImportService(
            resolver:      trackResolver,
            importService: importService,
            spotify:       self.spotifyClient,
            catalogue:     self.itunesClient,
            library:       libraryService
        )
        // Online tracks with no local file go through the coordinator. Weak to avoid a cycle.
        self.playbackEngine.onlineRouter = { [weak coordinator = self.onlineCoordinator] track, tracks in
            await coordinator?.playStandaloneOnline(track, context: tracks)
        }

        // Deleted songs are removed from the offline store too. Playback isn't stopped;
        // unsaving the playing song shouldn't cut it off. Delete commands that should
        // stop it call stopIfPlaying themselves.
        libraryService.onTracksWillDelete = { [weak downloads = self.downloadManager,
                                               weak engine = self.playbackEngine] trackIDs in
            downloads?.removeDownloads(for: trackIDs)
            // Home reads the played list, so remove deleted songs there too.
            engine?.forgetFromRecentlyPlayed(ids: trackIDs)
            try? snapshotRepo.delete(ids: trackIDs)
        }

        // An imported playlist may be set to stay downloaded. The download manager decides.
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

        // The remote heart: like a saved song, save an unsaved one.
        self.playbackEngine.isLiked = { [weak self] in self?.libraryService.isFavourited(trackID: $0.id) ?? false }
        self.playbackEngine.onRemoteLike = { [weak self] track in
            guard let self else { return }
            if self.libraryService.track(id: track.id) != nil {
                _ = self.toggleFavourite(trackID: track.id)
            } else if let online = self.onlineCoordinator.currentOnlineTrack {
                await self.onlineCoordinator.addToLibrary(online)
            } else {
                await self.onlineCoordinator.addToLibrary(unsaved: track)
                self.showSavedToast(.library)
            }
        }

        // Wire history persistence: save every new play to SwiftData.
        let deviceID = Self.deviceID
        self.playbackEngine.onTrackAddedToHistory = { track, seconds, source in
            do { try historyRepo.record(trackID: track.id, deviceID: deviceID, secondsPlayed: seconds,
                                        source: source) }
            catch { MixLog.playback.error("[history] persist FAILED: \(error)") }
            // Discover tracks have no library row, so keep a snapshot for Home and stats.
            if track.isOnline {
                do { try snapshotRepo.upsert(track); MixLog.playback.debug("[history] snapshot upserted '\(track.title)'") }
                catch { MixLog.playback.error("[history] snapshot upsert FAILED: \(error)") }
            }
        }

        // Records how long the track was actually listened to.
        self.playbackEngine.onPlaySecondsFinalised = { trackID, seconds in
            do { try historyRepo.finaliseLatestPlay(trackID: trackID, secondsPlayed: seconds) }
            catch { MixLog.playback.error("[history] finalise FAILED: \(error)") }
        }

        // Restore Recently Played: library first, then online snapshots.
        mixMainActivity("launch/history-restore") {
        if let recentIDs = try? historyRepo.fetchRecentTrackIDs() {
            let snapshots = (try? snapshotRepo.fetchAll()) ?? [:]
            let tracks = recentIDs.compactMap { id -> Track? in
                // fetch(id:) sees tombstones. A deleted song stays hidden and skips its snapshot.
                if let row = try? trackRepo.fetch(id: id) { return row.isDeleted ? nil : row }
                return snapshots[id]
            }
            MixLog.playback.debug("[history] restore: \(recentIDs.count) ids, \(snapshots.count) snapshots, resolved \(tracks.count) tracks")
            self.playbackEngine.restoreHistory(tracks)
        }
        }

        // The library decides which songs a playlist's cover uses; the loader draws it.
        // Smart playlist ids fall through to their current songs.
        ArtworkImageLoader.shared.playlistCoverRefs = { [weak self] id in
            guard let self else { return [] }
            if let smart = self.smartPlaylistService.playlists.first(where: { $0.id == id }) {
                return self.libraryService.coverRefs(forTrackIDs: self.smartTrackIDs(smart))
            }
            return self.libraryService.coverRefs(forPlaylistID: id)
        }

        LaunchTimeline.mark("deps/history-restored")
        wireResetObserver()
        // Siri only knows the playlist names it's been told.
        libraryService.$playlists.map { $0.map(\.name) }.removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { _ in MixtapeShortcuts.updateAppShortcutParameters() }
            .store(in: &cancellables)
        // Skip the empty launch value, it would look like every song was deleted.
        libraryService.$tracks.combineLatest(libraryService.$artists).dropFirst()
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] tracks, artists in
                guard self?.libraryService.hasLoaded == true else { return }
                SpotlightIndex.update(tracks: tracks, artists: artists)
            }
            .store(in: &cancellables)
        #if os(iOS)
        nowPlayingSurfaces = NowPlayingSurfaces(engine: playbackEngine, library: libraryService)
        #endif
        wireAuthObserver()
        // Off the main actor; session restore waits for it.
        Task { [weak self, libraryService] in
            await libraryService.refreshOffMain()
            // After the first library load, off the launch path.
            libraryService.reclaimNeverUploadedAudioFromCache()
            mixMainActivity("launch/restore-session") {
                self?.playbackEngine.restoreLastSession(allTracks: libraryService.tracks)
            }
        }

        // Refresh followed Spotify playlists now and every 15 minutes.
        // Returns early when nothing is followed.
        LaunchTimeline.mark("deps/refresh-task-spawned")
        spotifyFollowService.startAutoSync()

        // Fetches real artist photos for old imports. Skips artists that have one.
        libraryService.scheduleArtistImageBackfill()

        LaunchTimeline.mark("deps/backfills-scheduled")
        libraryService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // DownloadManager isn't forwarded: it publishes on every status change and
        // would redraw every view holding deps. Views that show download state observe
        // it directly.

        // Nested ObservableObjects don't republish through their parent.
        localFiles.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        watchedFolders.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // First scan of watched folders. Cheap when there are none.
        mixMainActivity("launch/local-files-rescan") { localFiles.rescan() }

        authService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Build the Supabase client off the main actor.
        Task { await SupabaseConfig.warm(); LaunchTimeline.mark("deps/supabase-warmed") }
        // Eager, so a song started before sign-in still counts as "playing here".
        _ = continuity
        // Lets a handoff carry the upload the sending device already resolved.
        continuity.online = onlineCoordinator
        // The device picker shows each device's quality, so it goes with presence.
        downloadManager.$downloadQuality
            .sink { [weak self] q in self?.continuity.setQuality(q.title) }
            .store(in: &cancellables)
        // Eager too, so a guest's queue redirect is back before the first tap.
        jam.online = onlineCoordinator
        syncService.onBulkRefused = { [weak self] in
            self?.showToast(.failed("A change to more than 50 songs wasn't confirmed, so it was undone"))
        }
        syncService.onRealtimeReady = { [weak self] uid in
            guard let self else { return }
            // A Jam guest mirrors the host, not its own devices.
            if !jam.isGuest { continuity.start(userID: uid) }
            jam.resume()
            InboxService.shared.start(userID: uid)
            MessagesService.shared.start(userID: uid)
        }
        InboxService.shared.onToast = { [weak self] in self?.showToast(Toast($0, symbol: "bell.fill")) }
        MessagesService.shared.onToast = { [weak self] in self?.showToast(Toast($0, symbol: "bubble.left.fill")) }
        // Playback errors were a second banner at the top. Now they're the same card.
        playbackEngine.$errorMessage
            .merge(with: onlineCoordinator.$errorMessage)
            .compactMap { $0 }
            .sink { [weak self] in self?.showToast(.failed($0)) }
            .store(in: &cancellables)
        LaunchTimeline.mark("deps/init-end")
    }

    // MARK: - Session Restore

    public func restoreSessionIfNeeded() async {
        isRestoringSession = true
        // Restore the session and hold the splash at least 1.8 s, concurrently.
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

        // Going offline turns on the Downloaded filter. Non-downloaded songs show grey.
        libraryService.offlinePlayableIDs = { [weak self] in
            self?.downloadManager.downloadedTrackIDs ?? []
        }
        onlineCoordinator.isOnline = { [weak self] in
            self?.downloadManager.isConnected ?? true
        }
        onlineCoordinator.onStatus = { [weak self] in self?.showToast($0) }
        downloadManager.onlineCoordinator = onlineCoordinator
        // Edits synced from another device are rendered here from the original, not searched for.
        let rebuildEdit: (Track) async throws -> URL = { [weak self] track in
            guard let self else { throw CancellationError() }
            return try await self.rebuildEdit(track)
        }
        playbackEngine.editRebuilder = rebuildEdit
        downloadManager.editRebuilder = rebuildEdit
        downloadManager.$isConnected
            .combineLatest(authService.$isOffline)
            .map { !$0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] offline in
                guard let self else { return }
                libraryService.offlineOnly = offline
                // Coming back undoes it only if going offline turned it on.
                if offline, !libraryService.downloadedOnly {
                    libraryService.downloadedOnly = true
                    filterWentOnOffline = true
                } else if !offline, filterWentOnOffline {
                    libraryService.downloadedOnly = false
                    filterWentOnOffline = false
                }
            }
            .store(in: &cancellables)

        // Reconnecting retries a cached-session sign-in. No-op otherwise.
        downloadManager.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { [weak self] in await self?.authService.retryOnlineAuth() }
            }
            .store(in: &cancellables)

        // Coming back online runs the sync that onSignIn skipped.
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
        // Switch the store first so nothing below writes into the previous account's file.
        // Each account keeps its own store on disk.
        let lastUserKey = ModelStore.lastUserKey
        let lastUserID = UserDefaults.standard.string(forKey: lastUserKey)
        if ModelStore.shared.open(for: user.id) {
            MixLog.library.debug("[AppDependencies] 🔀 Different user signed in — opened their own local store.")
            adoptSwitchedStore()
        }

        fileStorage.currentUserID = user.id
        PlaylistMetadataService.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUsername = user.username ?? user.displayName
        downloadManager.currentUserID = user.id.uuidString
        smartPlaylistService.currentUserID = user.id.uuidString
        recap.currentUserID = user.id
        // Connections belong to the account. Told before the marker moves, since only
        // the previous id can say who made an unowned grant.
        spotifyAuth.accountDidChange(to: user.id, previous: lastUserID)
        LastFmScrobbler.shared.accountDidChange(to: user.id, previous: lastUserID)
        // Replaced, not cleared: a new user gets their own (possibly empty) copy.
        if let lastUserID, lastUserID != user.id.uuidString {
            spotifyImportLedger.accountDidChange(remote: user.spotifyImports)
            spotifyFollowService.accountDidChange(remote: user.spotifyLinks)
            CrateService.shared.accountDidChange(remote: user.crates)
        }
        UserDefaults.standard.set(user.id.uuidString, forKey: lastUserKey)
    }

    private func onSignIn(user: AppUser) async {
        // No token on a cached session. wireAuthObserver runs this when back online.
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
        await recap.refresh()
        Task { await refreshPostWaveforms(user: user.id) }

        // Refetch covers saved below 1024 px, once per install.
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
        jam.leave(quietly: true)
        continuity.stop()
        InboxService.shared.stop()
        MessagesService.shared.stop()
        clearPlaybackSession()
        // The next user starts with the filter off unless offline.
        libraryService.downloadedOnly = libraryService.offlineOnly
        smartPlaylistService.currentUserID = nil
        recap.signedOut()

        fileStorage.currentUserID = nil
        PlaylistMetadataService.shared.currentUserID = nil
        ExportManager.shared.currentUserID = nil
        ExportManager.shared.currentUsername = nil
        downloadManager.currentUserID = nil

        // Grants stay on disk with their owner until the account signs in again.
        spotifyAuth.signedOut()
        LastFmScrobbler.shared.signedOut()
    }

    private func onSignOut() async {
        await syncService.onSignOut()
        // Keeps the local library and the last-user marker. Isolation happens when a
        // different user signs in (onSignInSync).
    }

    /// Nothing playing, nothing queued, nothing to resume, no history.
    private func clearPlaybackSession() {
        onlineCoordinator.endSession()
        playbackEngine.forgetLastSession()
        playbackEngine.restoreHistory([])
        tapeDecks.reset()
    }

    /// Rebuilds what a wipe invalidated that nothing else refreshes: recently
    /// played and the library's published arrays. See UserDataReset.
    private func wireResetObserver() {
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reset = UserDataReset.from(note)
                if reset.clearedHistory { self.playbackEngine.clearRecentlyPlayed() }
                // A switch adopts the incoming account's copy on its first pull.
                if reset.clearedLibrary && !reset.isAccountSwitch { SuggestionFeedback.clear() }
                if reset.clearedLibrary {
                    // Only Discover plays survive a library wipe.
                    self.playbackEngine.clearRecentlyPlayed()
                    self.libraryService.refresh()
                }
            }
        }
    }

    /// Syncs in-memory state with the store ModelStore just opened. Nothing is
    /// deleted. Sync watermarks stay, so the next pull is incremental.
    private func adoptSwitchedStore() {
        // A session restored at launch belongs to the previous account.
        clearPlaybackSession()
        libraryService.storeDidOpen()
        playbackEngine.restoreHistory([]) // clear in-memory recently played
        // Announced as a switch, not a wipe, so per-account state isn't cleared.
        UserDataReset.announce(.accountSwitch)
    }
}
