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

    // MARK: - Services

    public let authService:    SupabaseAuthService
    public let syncService:    SupabaseSyncService
    public let fileStorage:    SupabaseFileStorageService
    public let queueService:   QueueService
    public let equalizer:      AudioEqualizer             // graphic EQ
    public let playbackEngine: PlaybackEngine
    public let downloadManager: DownloadManager

    // MARK: - Library & Import

    public let libraryService:    LibraryService
    public let importService:     ImportService
    public let statsService:      ListeningStatsService

    // MARK: - Metadata Enrichment

    public let enrichmentService: MetadataEnrichmentService

    // MARK: - Supabase Client

    /// Shared across all Supabase-backed services (auth, sync, storage).
    public let supabase: SupabaseClient

    // MARK: - Persistence

    public let modelContainer: ModelContainer

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

    // MARK: - Init

    public init() {
        self.supabase       = SupabaseConfig.client
        self.authService    = SupabaseAuthService(client: supabase)
        self.fileStorage    = SupabaseFileStorageService(client: supabase)
        self.queueService   = QueueService()
        self.modelContainer = ModelContainerSetup.makeContainer()

        let context      = modelContainer.mainContext
        let trackRepo    = TrackRepository(context: context)
        let albumRepo    = AlbumRepository(context: context)
        let artistRepo   = ArtistRepository(context: context)
        let playlistRepo = PlaylistRepository(context: context)
        let favoriteRepo = FavoriteRepository(context: context)
        let historyRepo  = PlayHistoryRepository(context: context)

        self.libraryService = LibraryService(
            trackRepo:    trackRepo,
            albumRepo:    albumRepo,
            artistRepo:   artistRepo,
            playlistRepo: playlistRepo,
            favoriteRepo: favoriteRepo,
            deviceID:     Self.deviceID
        )
        self.statsService = ListeningStatsService(history: historyRepo, library: libraryService)
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

        self.syncService = SupabaseSyncService(
            client:         supabase,
            context:        context,
            libraryService: libraryService,
            deviceID:       Self.deviceID
        )

        // Auto-sync 1 s after the last imported track lands.
        // Weak capture breaks the AppDependencies → importService → closure → AppDependencies cycle.
        let syncRef = self.syncService
        self.importService.onSyncNeeded = {
            try? await syncRef.sync()
        }

        self.equalizer = AudioEqualizer()

        self.playbackEngine = PlaybackEngine(
            queue:       queueService,
            fileStorage: fileStorage,
            equalizer:   equalizer
        )

        self.downloadManager = DownloadManager(
            fileStorage:    fileStorage,
            libraryService: libraryService,
            queueService:   queueService
        )

        // Wire history persistence: save every new play to SwiftData.
        let deviceID = Self.deviceID
        self.playbackEngine.onTrackAddedToHistory = { track in
            try? historyRepo.record(trackID: track.id, deviceID: deviceID)
        }

        // Restore persisted history so the "Recently Played" list is populated on launch.
        if let recentIDs = try? historyRepo.fetchRecentTrackIDs() {
            let tracks = recentIDs.compactMap { id in
                try? trackRepo.fetch(id: id)
            }
            self.playbackEngine.restoreHistory(tracks)
        }

        wireAuthObserver()
        libraryService.refresh()

        // Restore the last playback session (paused at its saved position) so the
        // user can resume where they left off. Does NOT auto-play.
        self.playbackEngine.restoreLastSession(allTracks: libraryService.tracks)

        libraryService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward DownloadManager publishes as well
        downloadManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward authService publishes so views can react to authentication changes (like user logins/logouts)
        authService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
    }

    private func onSignInSync(user: AppUser) {
        fileStorage.currentUserID = user.id
        PlaylistMetadataService.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUserID = user.id.uuidString
        ExportManager.shared.currentUsername = user.displayName
        downloadManager.currentUserID = user.id.uuidString

        // Detect account switching on the same device.
        // If a different user's data is in the local store, wipe it first
        // so they never see another person's library.
        let lastUserKey = "mix.lastSignedInUserID"
        let lastUserID = UserDefaults.standard.string(forKey: lastUserKey)
        if let lastUserID, lastUserID != user.id.uuidString {
            print("[AppDependencies] ⚠️ Different user signed in — wiping local data for isolation.")
            wipeLocalData()
        }
        UserDefaults.standard.set(user.id.uuidString, forKey: lastUserKey)
    }

    private func onSignIn(user: AppUser) async {
        let token = authService.accessToken ?? ""
        await syncService.onSignIn(user: user, accessToken: token)
        syncService.startBackgroundSync(intervalSeconds: 60)
    }

    private func onSignOutSync() {
        playbackEngine.stopPlayback()
        playbackEngine.queue.clearCurrentTrack()
        playbackEngine.restoreHistory([]) // Clear in-memory history immediately on sign out

        fileStorage.currentUserID = nil
        PlaylistMetadataService.shared.currentUserID = nil
        ExportManager.shared.currentUserID = nil
        ExportManager.shared.currentUsername = nil
        downloadManager.currentUserID = nil
    }

    private func onSignOut() async {
        await syncService.onSignOut()
        // Wipe all local data so a subsequent sign-in (even on this device)
        // starts from a clean slate and never leaks one user's library to another.
        wipeLocalData()
        // Clear the last-user marker so the next sign-in always does a full pull.
        UserDefaults.standard.removeObject(forKey: "mix.lastSignedInUserID")
    }

    /// Hard-deletes all local SwiftData entities and resets sync timestamps.
    /// Does NOT touch Supabase — this is purely a local cache wipe.
    private func wipeLocalData() {
        libraryService.clearAll()
        libraryService.deleteAllUserPlaylists()
        try? PlayHistoryRepository(context: modelContainer.mainContext).deleteAll()
        syncService.resetSyncTimestamps()
        playbackEngine.restoreHistory([]) // clear in-memory recently played
        print("[AppDependencies] 🗑 Local library cache wiped.")
    }
}
