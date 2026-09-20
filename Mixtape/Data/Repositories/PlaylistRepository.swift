// PlaylistRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class PlaylistRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Playlist] {
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.dateCreated)]
        )
        // No covers. This is the bulk path — `LibraryService.refreshPlaylists()`
        // calls it on every library mutation — and each `artworkData` touched
        // here faults a whole external-storage blob in off disk. A library with
        // fifty playlists was reading fifty covers, one of them megabytes wide,
        // every time a song was added or a playlist deleted. `displayArtwork`
        // resolves the bytes through `ArtworkProvider` for the handful of
        // covers actually on screen.
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Playlist? {
        try fetchEntity(id: id)?.toDomain()
    }

    /// The tombstones: playlists that were deleted but whose rows stay behind so
    /// the deletion can reach every device. `fetchAll` filters them out, and
    /// that filter is exactly what makes them a record of which songs a delete
    /// left in the library. See `LibraryService.orphansFromDeletedPlaylists`.
    public func fetchDeleted() throws -> [Playlist] {
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { $0.isSoftDeleted }
        )
        // No covers, for the reason `fetchAll` gives: only `trackIDs` is read.
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    // MARK: - Save / Upsert

    public func save(_ playlist: Playlist) throws {
        if let existing = try fetchEntity(id: playlist.id) {
            existing.update(from: playlist)
        } else {
            context.insert(PlaylistEntity(from: playlist))
        }
        try context.saveBatched()
    }

    // MARK: - Soft Delete (protected: system playlists are untouchable)

    public func softDelete(id: UUID) throws {
        guard id != Playlist.favouritesID else { return }
        guard id != Playlist.allSongsID   else { return }
        guard let entity = try fetchEntity(id: id) else { return }
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
        try context.saveBatched()
    }

    // MARK: - Cache Discard (account switch)

    /// Drops every local playlist row without leaving a trace the server will
    /// ever see. For signing out or switching accounts — not for deleting.
    ///
    /// Deliberately not `softDelete`: that stamps `syncStatus = .deleted`, and
    /// the next push turns it into `is_deleted = true`. On an account switch the
    /// push runs as the *incoming* user, so signing in was writing deletions for
    /// playlists that account had never seen. System playlists are emptied
    /// without `touch()` for the same reason — a touched Favourites is pending,
    /// and an empty pending Favourites overwrites the real one on the server.
    public func discardLocalCopies() throws {
        for entity in try context.fetch(FetchDescriptor<PlaylistEntity>()) {
            if entity.id == Playlist.favouritesID || entity.id == Playlist.allSongsID {
                entity.trackIDsData = Data()
                entity.syncStatus   = SyncStatus.synced.rawValue
            } else {
                context.delete(entity)
            }
        }
        try context.saveBatched()
    }

    /// Lets the server's Favourites win the next pull regardless of timestamps.
    ///
    /// Favourites is last-write-wins on `syncLocalModifiedAt`, so a local copy
    /// emptied five minutes ago beats a server row that still holds every heart
    /// but hasn't changed in months: the pull fetches the right data and then
    /// throws it away. Only for the explicit "re-sync from server" action, where
    /// taking the server's word is the entire point of pressing the button.
    public func yieldFavouritesToServer() throws {
        guard let fav = try fetchEntity(id: Playlist.favouritesID) else { return }
        fav.syncLocalModifiedAt = .distantPast
        fav.syncStatus          = SyncStatus.synced.rawValue
        try context.saveBatched()
    }

    // MARK: - Ensure System Playlists

    /// Creates the Favourites system playlist if it doesn't already exist.
    /// Initialised as `.synced` so a fresh install never pushes an empty array
    /// over an existing server version (pull runs and populates it instead).
    public func ensureFavourites(deviceID: String) throws {
        if let fav = try fetchEntity(id: Playlist.favouritesID) {
            var dirty = false
            if fav.isSoftDeleted {
                fav.isSoftDeleted = false
                fav.syncStatus = SyncStatus.synced.rawValue
                dirty = true
            }
            // Renamed in 2026-09. Done here rather than as a one-shot because a
            // pull from a device still on the old build brings the old name
            // back, and this runs every launch.
            if fav.name == "Favourites" {
                fav.name = Playlist.favouritesName
                dirty = true
            }
            if dirty { try context.saveBatched() }
            return
        }
        let fav = Playlist(
            id:          Playlist.favouritesID,
            name:        Playlist.favouritesName,
            description: "Songs you've loved.",
            // Pinned from birth, so a first launch opens on the shape the
            // legacy pin migration below already gave every upgrading device:
            // the system playlists at the top of the sidebar. Without it a
            // fresh install was the one case that started with nothing pinned.
            isPinned:    true,
            sync: SyncMetadata(
                serverID:        nil,
                status:          .synced,  // Don't push an empty Favourites over an existing server version
                localModifiedAt: Date(),
                serverModifiedAt: nil,
                lastSyncedAt:    nil,
                deviceID:        deviceID
            )
        )
        context.insert(PlaylistEntity(from: fav))
        try context.saveBatched()
    }

    /// Creates the All Songs system playlist if it doesn't already exist.
    /// Returns `true` if the playlist was freshly created (caller can then seed it
    /// with existing tracks for users upgrading from an older version).
    @discardableResult
    public func ensureAllSongs(deviceID: String) throws -> Bool {
        if let all = try fetchEntity(id: Playlist.allSongsID) {
            if all.isSoftDeleted {
                all.isSoftDeleted = false
                all.syncStatus = SyncStatus.synced.rawValue
                try context.saveBatched()
            }
            return false
        }
        let allSongs = Playlist(
            id:          Playlist.allSongsID,
            name:        "All Songs",
            description: "Every song you've imported.",
            isPinned:    true,   // See `ensureFavourites`.
            sync: SyncMetadata(
                serverID:        nil,
                status:          .synced,
                localModifiedAt: Date(),
                serverModifiedAt: nil,
                lastSyncedAt:    nil,
                deviceID:        deviceID
            )
        )
        context.insert(PlaylistEntity(from: allSongs))
        try context.saveBatched()
        return true
    }

    // MARK: - Private

    func fetchEntity(id: UUID) throws -> PlaylistEntity? {
        try context.fetch(
            FetchDescriptor<PlaylistEntity>(predicate: #Predicate { $0.id == id })
        ).first
    }
}

// MARK: - PlaylistEntity ↔ Domain Mapping

extension PlaylistEntity {

    /// See TrackEntity.toDomain — `includingArtwork: false` is the bulk path.
    func toDomain(includingArtwork: Bool = true) -> Playlist {
        Playlist(
            id:          id,
            name:        name,
            description: playlistDescription,
            trackIDs:    trackIDsData.toUUIDArray(),
            artworkData: includingArtwork ? artworkData : nil,
            dateCreated: dateCreated,
            dateModified: dateModified,
            origin:      PlaylistOrigin(rawValue: originRaw) ?? .owned,
            ownerName:   ownerName,
            coverKind:   PlaylistCoverKind(rawValue: coverKindRaw) ?? .derived,
            isPinned:    isPinned,
            sortIndex:   sortIndex,
            sync: SyncMetadata(
                serverID:         syncServerID,
                status:           SyncStatus(rawValue: syncStatus) ?? .localOnly,
                localModifiedAt:  syncLocalModifiedAt,
                serverModifiedAt: syncServerModifiedAt,
                lastSyncedAt:     syncLastSyncedAt,
                deviceID:         syncDeviceID
            ),
            isDeleted: isSoftDeleted
        )
    }

    func update(from playlist: Playlist) {
        name                 = playlist.name
        playlistDescription  = playlist.description
        trackIDsData         = playlist.trackIDs.toData()
        // A cover that changed has to be sent again, and the upload pass decides
        // that by looking at `artworkKey`. Without this the first cover a
        // playlist ever had would be the only one the other device ever saw.
        if artworkData != playlist.artworkData {
            artworkKey = nil
            // A local edit is this device's answer now; the stamp describes a
            // file that no longer matches what is on screen here.
            artworkRemoteStamp = nil
        }
        // Throwing a cover away has to reach the bucket, or the download pass
        // finds the old file still sitting there and hands it back. See
        // `artworkNeedsRemoteDelete`.
        if playlist.coverKind == PlaylistCoverKind.none,
           artworkData != nil || artworkKey != nil {
            artworkNeedsRemoteDelete = true
        }
        artworkData          = playlist.artworkData
        dateModified         = playlist.dateModified
        isSoftDeleted        = playlist.isDeleted
        originRaw            = playlist.origin.rawValue
        ownerName            = playlist.ownerName
        coverKindRaw         = playlist.coverKind.rawValue
        isPinned             = playlist.isPinned
        sortIndex            = playlist.sortIndex

        syncStatus           = playlist.sync.status.rawValue
        syncServerID         = playlist.sync.serverID
        syncDeviceID         = playlist.sync.deviceID
        syncLocalModifiedAt  = playlist.sync.localModifiedAt
        syncServerModifiedAt = playlist.sync.serverModifiedAt
        syncLastSyncedAt     = playlist.sync.lastSyncedAt
    }

    convenience init(from playlist: Playlist) {
        self.init(
            id:                   playlist.id,
            name:                 playlist.name,
            playlistDescription:  playlist.description,
            trackIDsData:         playlist.trackIDs.toData(),
            artworkData:          playlist.artworkData,
            dateCreated:          playlist.dateCreated,
            dateModified:         playlist.dateModified,
            isSoftDeleted:            playlist.isDeleted,
            originRaw:            playlist.origin.rawValue,
            ownerName:            playlist.ownerName,
            coverKindRaw:         playlist.coverKind.rawValue,
            isPinned:             playlist.isPinned,
            sortIndex:            playlist.sortIndex,
            syncStatus:           playlist.sync.status.rawValue,
            syncServerID:         playlist.sync.serverID,
            syncDeviceID:         playlist.sync.deviceID,
            syncLocalModifiedAt:  playlist.sync.localModifiedAt,
            syncServerModifiedAt: playlist.sync.serverModifiedAt,
            syncLastSyncedAt:     playlist.sync.lastSyncedAt
        )
    }
}
