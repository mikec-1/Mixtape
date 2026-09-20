// SettingsViewModel.swift
// Mixtape — Features/Settings

import Foundation
import SwiftUI
import Combine

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
    // Songs left behind by playlists that were deleted before the delete
    // started taking its orphans with it.
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

        // Same reasoning as `clearLibrary`: an import or a sync already under
        // way would go on writing songs back in behind the delete. Downloads
        // already on disk are left alone here — that is this command's promise —
        // but ones still arriving are for songs about to stop existing.
        SpotifyImportService.cancelAllRuns()
        syncService.cancelAllWork()
        downloadManager.stopAllDownloads()
        libraryService.cancelBackgroundWork()
        defer { syncService.startBackgroundSync(intervalSeconds: 60) }

        do {
            try await syncService.deleteAllServerTracks()
        } catch {
            deleteTracksError = "Couldn't delete from server: \(error.localizedDescription)"
            print("[Settings] ❌ deleteAllServerTracks failed: \(error)")
            return
        }

        libraryService.deleteAllTracks()
        // The history survives this on purpose, but everything that assumed the
        // songs were still there doesn't. See `UserDataReset`.
        UserDataReset.announce(.library)
        // Reset per-table pull timestamps for tracks, albums, artists so
        // a subsequent sync doesn't re-download deleted items.
        syncService.resetSyncTimestamps()
        print("[Settings] ✅ All music deleted on server and locally")
    }

    /// Forces the next sync to pull every server record rather than only what
    /// changed since the last one.
    ///
    /// The recovery hatch for a local store that has drifted from the server.
    /// Pulls are incremental against a stored per-table timestamp, so anything
    /// that vanishes locally without the server row changing — an interrupted
    /// account switch, a restore, a store rebuilt underneath us — leaves the
    /// client permanently not asking for records the server still has. Purely
    /// additive: nothing is deleted, here or on the server.
    public func resyncFromServer() async {
        syncService.resetSyncTimestamps()
        libraryService.prepareForFullResync()
        await triggerSync()
    }

    /// Fills in artwork for songs that don't have any, from the user's own
    /// published covers first and the iTunes catalogue second.
    ///
    /// Sync can't do this. `artwork_key` is only ever written *after* a device
    /// uploads a cover it already had, so artwork only ever travels between
    /// devices that already have it — a song that arrived without one (imported
    /// from a file with no embedded art, or pulled onto a fresh device) has
    /// nothing to download and stays blank through any number of re-syncs.
    /// Whatever this finds is uploaded on the next sync, so the repair only has
    /// to happen on one device.
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
        print("[Settings] 🖼️ Cover repair: found \(found), \(remaining) still missing")
    }

    /// Fetches full-size covers again for songs stored at the old ceilings.
    ///
    /// Sync compressed every cover it uploaded to 300 px, and local writes
    /// capped at 512 — which is why a song that arrived from another device
    /// looked pixelated. New covers are 1024; the ones already on disk can only
    /// be fixed by asking the catalogue again, so this is a button and not a
    /// silent pass.
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
        print("[Settings] 🖼️ Cover upgrade: replaced \(replaced) of \(low.count)")
    }

    /// Brings back songs a re-sync removed by replaying an out-of-date deletion
    /// from the server, and pushes the correction so it can't happen twice.
    ///
    /// The symptom is a playlist header that counts more songs than the list
    /// shows: the playlist still holds the id, but the track behind it is
    /// soft-deleted and therefore invisible to everything. See
    /// `LibraryService.restoreResurrectedTracks` for which rows qualify and why a
    /// song the user genuinely deleted can't be caught up in this.
    public func restoreMissingSongs() async {
        isRestoringSongs   = true
        restoreSongsResult = nil
        defer { isRestoringSongs = false }

        let restored = libraryService.restoreResurrectedTracks()
        guard restored > 0 else {
            restoreSongsResult = "Nothing to restore — no songs are missing."
            return
        }

        // Not optional. The restore is local; the server is still holding the
        // deletion that caused it, and the next full re-sync would hand it back.
        await triggerSync()

        restoreSongsResult = "Restored \(restored) song\(restored == 1 ? "" : "s")."
        print("[Settings] ♻️ Restored \(restored) song(s)")
    }

    /// How many songs a deleted playlist left in the library. Cheap enough to
    /// call whenever the page appears; it reads ids, not rows.
    public func refreshOrphanCount() {
        orphanCount = libraryService.orphansFromDeletedPlaylists().count
    }

    /// Removes them. The delete is local and soft, so the push is what makes it
    /// reach the other devices — same as every other deletion here.
    public func cleanUpOrphanedSongs() async {
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        let removed = libraryService.cleanUpOrphanedSongs()
        orphanCount = 0
        guard removed > 0 else { return }
        await triggerSync()
        print("[Settings] 🧹 Removed \(removed) orphaned song(s)")
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
            print("[Settings] ❌ deleteAllServerUserPlaylists failed: \(error)")
            return
        }

        libraryService.deleteAllUserPlaylists()
        print("[Settings] ✅ All user playlists deleted on server and locally")
    }

    public func signOut() async {
        try? await authService.signOut()
    }

    /// Ends every session on the account — other devices, browsers, and this one.
    public func signOutEverywhere() async {
        try? await authService.signOut(everywhere: true)
    }

    public func triggerSync() async {
        try? await syncService.sync()
    }

    /// Re-files every track under its correct primary artist + album.
    /// Run this once to clean up library groupings broken by earlier import bugs.
    public func rebuildGroupings() async {
        isRebuilding = true
        defer { isRebuilding = false }
        await importService.rebuildGroupings()
        print("[Settings] ✅ Library groupings rebuilt")
    }

    /// Wipes listening history: the local play log, the snapshots of played
    /// Discover tracks, and the published stats row other people see.
    ///
    /// This is separate from deleting music because the two are separate facts.
    /// Deleting a song says "I no longer have this"; deleting history says "I was
    /// never here". The first shouldn't imply the second — but with no way to do
    /// the second, an emptied library keeps reporting top artists it can't show.
    public func resetListeningStats() async {
        isResettingStats = true
        resetStatsError = nil
        defer { isResettingStats = false }

        statsService.resetHistory()

        // The mixes, the seeds and every "because you listened to…" claim were
        // built from the log that just went away. See `UserDataReset`.
        UserDataReset.announce(UserDataReset(clearedLibrary: false, clearedHistory: true))

        // Republishing now computes from an empty log, so the server row — and
        // therefore the profile page — goes to zero. Without this the wipe is
        // local only and the old top artists stay visible to everyone else.
        if let userID = currentUser?.id {
            await profileStats.publishMyStats(userID: userID)
        }
        print("[Settings] ✅ Listening history reset")
    }

    /// Deletes ALL data for this user from the Supabase database and Storage,
    /// then wipes the local SwiftData store, audio cache and listening history.
    /// Every device will be empty after their next sync.
    public func clearLibrary() async {
        isClearing = true
        clearError = nil
        defer { isClearing = false }

        // Everything in flight stops *before* anything is deleted.
        //
        // Stopping background sync alone only prevented the next run: an import
        // and a sync that were already going carried on afterwards, uploading
        // covers and placing songs into a library that had just been wiped —
        // which is how a "cleared" library ends up half-full of the thing you
        // were trying to get rid of.
        SpotifyImportService.cancelAllRuns()
        syncService.cancelAllWork()
        downloadManager.stopAllDownloads()
        libraryService.cancelBackgroundWork()

        do {
            try await syncService.deleteAllServerData()
        } catch {
            clearError = "Couldn't delete from server: \(error.localizedDescription)"
            print("[Settings] ❌ Server delete failed: \(error)")
            // Restart background sync even if we fail.
            syncService.startBackgroundSync(intervalSeconds: 60)
            return
        }

        // Server is clean — now wipe local data and timestamps.
        libraryService.clearAll()

        // Downloads live outside the library too, in Application Support/Offline/.
        // "Delete All Music" leaves them alone — its warning says nothing about
        // files, and Settings has a dedicated Remove All Downloads for them. This
        // one promises "all music … and files … from every device", so leaving a
        // folder of playable .m4a behind would make that a lie.
        downloadManager.removeAllDownloads()

        // History lives outside the library, so clearAll can't reach it. Skipping
        // this is what leaves top artists standing after "Clear Everything".
        statsService.resetHistory()
        if let userID = currentUser?.id {
            await profileStats.publishMyStats(userID: userID)
        }

        syncService.resetSyncTimestamps()

        // Everything derived from the library or the play history — the Discover
        // landing's mixes and recommendations, the Home shelf, recently played —
        // rebuilds itself from this. Without it the page keeps showing mixes
        // built from a history that no longer exists. See `UserDataReset`.
        UserDataReset.announce(.everything)

        // Restart background sync (will pull nothing since server is empty).
        syncService.startBackgroundSync(intervalSeconds: 60)
        print("[Settings] ✅ Library, history and published stats cleared")
    }
}
