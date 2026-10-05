import Foundation
import SwiftUI
import Combine
import OSLog

@MainActor
public final class SettingsViewModel: ObservableObject {

    @Published public private(set) var currentUser:           AppUser?
    @Published public private(set) var syncState:             SyncState = .idle

    /// True when the signed-in user has the "developer" role in their Supabase user_metadata.
    public var isDeveloper: Bool { currentUser?.isDeveloper == true }

    // Clear all tracks
    @Published public private(set) var isDeletingTracks:      Bool = false
    @Published public private(set) var deleteTracksError:     String? = nil
    // Clear user playlists
    @Published public private(set) var isDeletingPlaylists:   Bool = false
    @Published public private(set) var deletePlaylistsError:  String? = nil
    // Clear entire database
    @Published public private(set) var isClearing:            Bool = false
    @Published public private(set) var clearError:            String? = nil
    // Reset listening history
    @Published public private(set) var isResettingStats:      Bool = false
    @Published public private(set) var resetStatsError:       String? = nil
    // Rebuild groupings
    @Published public private(set) var isRebuilding:          Bool = false
    // Find missing covers
    @Published public private(set) var isFindingCovers:       Bool = false
    @Published public private(set) var findCoversResult:      String? = nil
    @Published public private(set) var isUpgradingCovers:     Bool = false
    @Published public private(set) var upgradeCoversResult:   String? = nil
    // Restore missing songs
    @Published public private(set) var isRestoringSongs:      Bool = false
    @Published public private(set) var restoreSongsResult:    String? = nil
    // Songs left behind by playlists deleted before deletes took their orphans with them.
    @Published public private(set) var isCleaningOrphans:     Bool = false
    @Published public private(set) var orphanCount:           Int  = 0

    @Published public var showSignOutConfirm:                  Bool = false
    @Published public var showDeleteTracksConfirm:             Bool = false
    @Published public var showDeletePlaylistsConfirm:          Bool = false
    @Published public var showClearLibraryConfirm:             Bool = false
    @Published public var showResetStatsConfirm:               Bool = false
    @Published public var showCleanOrphansConfirm:             Bool = false

    private let authService:    SupabaseAuthService
    private let syncService:    SupabaseSyncService
    private let libraryService: LibraryService
    private let importService:  ImportService
    private let statsService:   ListeningStatsService
    private let profileStats:   ProfileStatsService
    private let downloadManager: DownloadManager
    private var cancellables = Set<AnyCancellable>()

    public init(
        authService:    SupabaseAuthService,
        syncService:    SupabaseSyncService,
        libraryService: LibraryService,
        importService:  ImportService,
        statsService:   ListeningStatsService,
        profileStats:   ProfileStatsService,
        downloadManager: DownloadManager
    ) {
        self.authService    = authService
        self.syncService    = syncService
        self.libraryService = libraryService
        self.importService  = importService
        self.statsService   = statsService
        self.profileStats   = profileStats
        self.downloadManager = downloadManager

        authService.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if case .authenticated(let user) = state {
                    self?.currentUser = user
                } else {
                    self?.currentUser = nil
                }
            }
            .store(in: &cancellables)

        syncService.$syncState
            .receive(on: RunLoop.main)
            .assign(to: &$syncState)
    }

    // MARK: - Actions

    /// Deletes all tracks, albums, and artists from the server and every device.
    /// All playlists are kept but their track lists are emptied.
    public func deleteAllTracks() async {
        isDeletingTracks = true
        deleteTracksError = nil
        defer { isDeletingTracks = false }

        // Stop imports, syncs and incoming downloads so they don't write songs back in.
        // Downloads already on disk are kept.
        SpotifyImportService.cancelAllRuns()
        syncService.cancelAllWork()
        downloadManager.stopAllDownloads()
        libraryService.cancelBackgroundWork()
        defer { syncService.startBackgroundSync(intervalSeconds: 60) }

        do {
            try await syncService.deleteAllServerTracks()
        } catch {
            deleteTracksError = "Couldn't delete from server: \(error.localizedDescription)"
            MixLog.library.error("[Settings] deleteAllServerTracks failed: \(error)")
            return
        }

        libraryService.deleteAllTracks()
        // History survives this, but anything assuming the songs exist is reset. See `UserDataReset`.
        UserDataReset.announce(.library)
        // So the next sync doesn't re-download deleted items.
        syncService.resetSyncTimestamps()
        MixLog.library.debug("[Settings] All music deleted on server and locally")
    }

    /// Forces the next sync to pull every server record. Recovers a local store that drifted
    /// from the server. Additive only; nothing is deleted.
    public func resyncFromServer() async {
        syncService.resetSyncTimestamps()
        libraryService.prepareForFullResync()
        await triggerSync()
    }

    /// Fills in missing artwork from the user's published covers, then iTunes. Sync can't:
    /// a song that arrived with no cover has nothing to download. Found covers upload on
    /// the next sync.
    public func findMissingCovers(using catalogue: ITunesSearchClient) async {
        isFindingCovers  = true
        findCoversResult = nil
        defer { isFindingCovers = false }

        let missing = ArtworkProvider.shared.trackIDsWithoutArtwork()
        guard !missing.isEmpty else {
            findCoversResult = "Every song already has a cover."
            return
        }

        await libraryService.backfillPlaceholderArtwork(
            trackIDs:    missing,
            publishedBy: currentUser?.id,
            using:       catalogue
        )

        let remaining = ArtworkProvider.shared.trackIDsWithoutArtwork().count
        let found     = missing.count - remaining
        findCoversResult = remaining == 0
            ? "Found artwork for all \(found)."
            : "Found \(found) of \(missing.count). The other \(remaining) aren't in the catalogue."
        MixLog.library.debug("[Settings] Cover repair: found \(found), \(remaining) still missing")
    }

    /// Refetches full-size covers for songs stored at the old 300/512 px limits.
    public func upgradeCoverQuality(using catalogue: ITunesSearchClient) async {
        isUpgradingCovers  = true
        upgradeCoversResult = nil
        defer { isUpgradingCovers = false }

        let low = ArtworkProvider.shared.trackIDsWithLowResArtwork(
            maxDimension: 600  // 640 px Spotify / 1000 px Deezer are already their best
        )
        guard !low.isEmpty else {
            upgradeCoversResult = "Every cover is already full size."
            return
        }

        let replaced = await libraryService.backfillPlaceholderArtwork(
            trackIDs:          low,
            publishedBy:       currentUser?.id,
            using:             catalogue,
            replacingExisting: true
        )
        upgradeCoversResult = "Replaced \(replaced) of \(low.count) with full-size artwork."
        MixLog.library.debug("[Settings] Cover upgrade: replaced \(replaced) of \(low.count)")
    }

    /// Restores songs a re-sync removed by replaying a stale server deletion, then pushes
    /// the fix. See `LibraryService.restoreResurrectedTracks`.
    public func restoreMissingSongs() async {
        isRestoringSongs   = true
        restoreSongsResult = nil
        defer { isRestoringSongs = false }

        let restored = libraryService.restoreResurrectedTracks()
        guard restored > 0 else {
            restoreSongsResult = "Nothing to restore — no songs are missing."
            return
        }

        // Otherwise the server's stale deletion comes back on the next full re-sync.
        await triggerSync()

        restoreSongsResult = "Restored \(restored) song\(restored == 1 ? "" : "s")."
        MixLog.library.debug("[Settings] Restored \(restored) song(s)")
    }

    /// How many songs deleted playlists left behind. Cheap; reads ids only.
    public func refreshOrphanCount() {
        orphanCount = libraryService.orphansFromDeletedPlaylists().count
    }

    /// Removes them. The push carries the delete to other devices.
    public func cleanUpOrphanedSongs() async {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        let removed = libraryService.cleanUpOrphanedSongs()
        orphanCount = 0
        guard removed > 0 else { return }
        await triggerSync()
        MixLog.library.debug("[Settings] Removed \(removed) orphaned song(s)")
    }

    /// Deletes all user-created playlists from the server and every device.
    /// System playlists (All Songs, Favourites) and all tracks are kept.
    public func deleteAllUserPlaylists() async {
        isDeletingPlaylists = true
        deletePlaylistsError = nil
        defer { isDeletingPlaylists = false }

        syncService.stopBackgroundSync()
        defer { syncService.startBackgroundSync(intervalSeconds: 60) }

        do {
            try await syncService.deleteAllServerUserPlaylists()
        } catch {
            deletePlaylistsError = "Couldn't delete from server: \(error.localizedDescription)"
            MixLog.library.error("[Settings] deleteAllServerUserPlaylists failed: \(error)")
            return
        }

        libraryService.deleteAllUserPlaylists()
        MixLog.library.debug("[Settings] All user playlists deleted on server and locally")
    }

    public func signOut() async {
        try? await authService.signOut()
    }

    /// Ends every session on the account, including this one.
    public func signOutEverywhere() async {
        try? await authService.signOut(everywhere: true)
    }

    public func triggerSync() async {
        try? await syncService.sync()
    }

    /// Re-files every track under its correct primary artist and album.
    public func rebuildGroupings() async {
        isRebuilding = true
        defer { isRebuilding = false }
        await importService.rebuildGroupings()
        MixLog.library.debug("[Settings] Library groupings rebuilt")
    }

    /// Wipes listening history: the play log, played Discover snapshots and the public stats row.
    public func resetListeningStats() async {
        isResettingStats = true
        resetStatsError = nil
        defer { isResettingStats = false }

        // Announcing the reset and republishing the profile are `clearHistory`'s job now,
        // so the history page's own Clear button has the same consequences as this one.
        await statsService.clearHistory()
        MixLog.library.debug("[Settings] Listening history reset")
    }

    /// Deletes ALL data for this user from the Supabase database and Storage,
    /// then wipes the local SwiftData store, audio cache and listening history.
    /// Every device will be empty after their next sync.
    public func clearLibrary() async {

        SupabaseSyncService.allowBulk("clear")
        isClearing = true
        clearError = nil
        defer { isClearing = false }

        // Stop everything in flight before deleting, or imports and syncs refill the library.
        SpotifyImportService.cancelAllRuns()
        syncService.cancelAllWork()
        downloadManager.stopAllDownloads()
        libraryService.cancelBackgroundWork()

        do {
            try await syncService.deleteAllServerData()
        } catch {
            clearError = "Couldn't delete from server: \(error.localizedDescription)"
            MixLog.library.error("[Settings] Server delete failed: \(error)")
            // Restart background sync even if we fail.
            syncService.startBackgroundSync(intervalSeconds: 60)
            return
        }

        // Server is clean, now wipe local data and timestamps.
        libraryService.clearAll()

        // This promises to delete files too, so remove downloads.
        downloadManager.removeAllDownloads()

        // History lives outside the library.
        statsService.resetHistory()
        if let userID = currentUser?.id {
            await profileStats.publishMyStats(userID: userID)
        }

        syncService.resetSyncTimestamps()

        // Rebuilds mixes, recommendations and recently played. See `UserDataReset`.
        UserDataReset.announce(.everything)

        // Restart background sync (will pull nothing since server is empty).
        syncService.startBackgroundSync(intervalSeconds: 60)
        MixLog.library.debug("[Settings] Library, history and published stats cleared")
    }
}
