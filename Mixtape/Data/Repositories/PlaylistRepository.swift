// PlaylistRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class PlaylistRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetch

    public func fetchAll() throws -> [Playlist] {
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.dateCreated)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func fetch(id: UUID) throws -> Playlist? {
        try fetchEntity(id: id)?.toDomain()
    }

    // MARK: - Save / Upsert

    public func save(_ playlist: Playlist) throws {
        if let existing = try fetchEntity(id: playlist.id) {
            existing.update(from: playlist)
        } else {
            context.insert(PlaylistEntity(from: playlist))
        }
        try context.save()
    }

    // MARK: - Soft Delete (protected: system playlists are untouchable)

    public func softDelete(id: UUID) throws {
        guard id != Playlist.favouritesID else { return }
        guard id != Playlist.allSongsID   else { return }
        guard let entity = try fetchEntity(id: id) else { return }
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
        try context.save()
    }

    // MARK: - Ensure System Playlists

    /// Creates the Favourites system playlist if it doesn't already exist.
    /// Initialised as `.synced` so a fresh install never pushes an empty array
    /// over an existing server version (pull runs and populates it instead).
    public func ensureFavourites(deviceID: String) throws {
        if let fav = try fetchEntity(id: Playlist.favouritesID) {
            if fav.isSoftDeleted {
                fav.isSoftDeleted = false
                fav.syncStatus = SyncStatus.synced.rawValue
                try context.save()
            }
            return
        }
        let fav = Playlist(
            id:          Playlist.favouritesID,
            name:        "Favourites",
            description: "Songs you've loved.",
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
        try context.save()
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
                try context.save()
            }
            return false
        }
        let allSongs = Playlist(
            id:          Playlist.allSongsID,
            name:        "All Songs",
            description: "Every song you've imported.",
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
        try context.save()
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

    func toDomain() -> Playlist {
        Playlist(
            id:          id,
            name:        name,
            description: playlistDescription,
            trackIDs:    trackIDsData.toUUIDArray(),
            artworkData: artworkData,
            dateCreated: dateCreated,
            dateModified: dateModified,
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
        artworkData          = playlist.artworkData
        dateModified         = playlist.dateModified
        isSoftDeleted        = playlist.isDeleted

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
            syncStatus:           playlist.sync.status.rawValue,
            syncServerID:         playlist.sync.serverID,
            syncDeviceID:         playlist.sync.deviceID,
            syncLocalModifiedAt:  playlist.sync.localModifiedAt,
            syncServerModifiedAt: playlist.sync.serverModifiedAt,
            syncLastSyncedAt:     playlist.sync.lastSyncedAt
        )
    }
}
