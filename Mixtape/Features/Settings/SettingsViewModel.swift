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
    // Rebuild groupings
    @Published public private(set) var isRebuilding:          Bool = false

    @Published public var showSignOutConfirm:                  Bool = false
    @Published public var showDeleteTracksConfirm:             Bool = false
    @Published public var showDeletePlaylistsConfirm:          Bool = false
    @Published public var showClearLibraryConfirm:             Bool = false

    private let authService:    SupabaseAuthService
    private let syncService:    SupabaseSyncService
    private let libraryService: LibraryService
    private let importService:  ImportService
    private var cancellables = Set<AnyCancellable>()

    public init(
        authService:    SupabaseAuthService,
        syncService:    SupabaseSyncService,
        libraryService: LibraryService,
        importService:  ImportService
    ) {
        self.authService    = authService
        self.syncService    = syncService
        self.libraryService = libraryService
        self.importService  = importService

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

        syncService.stopBackgroundSync()
        defer { syncService.startBackgroundSync(intervalSeconds: 60) }

        do {
            try await syncService.deleteAllServerTracks()
        } catch {
            deleteTracksError = "Couldn't delete from server: \(error.localizedDescription)"
            print("[Settings] ❌ deleteAllServerTracks failed: \(error)")
            return
        }

        libraryService.deleteAllTracks()
        // Reset per-table pull timestamps for tracks, albums, artists so
        // a subsequent sync doesn't re-download deleted items.
        syncService.resetSyncTimestamps()
        print("[Settings] ✅ All music deleted on server and locally")
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

    /// Deletes ALL data for this user from the Supabase database and Storage,
    /// then wipes the local SwiftData store and audio cache.
    /// Every device will be empty after their next sync.
    public func clearLibrary() async {
        isClearing = true
        clearError = nil
        defer { isClearing = false }

        // Stop background sync so it doesn't race with the delete.
        syncService.stopBackgroundSync()

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
        syncService.resetSyncTimestamps()

        // Restart background sync (will pull nothing since server is empty).
        syncService.startBackgroundSync(intervalSeconds: 60)
        print("[Settings] ✅ Library cleared on server and locally")
    }
}
