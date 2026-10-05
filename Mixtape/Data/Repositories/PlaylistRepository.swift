import Foundation
import SwiftData

@MainActor
public final class PlaylistRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Playlist] {
        let descriptor = FetchDescriptor<PlaylistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.dateCreated)]
        )
        // No covers: this runs on every library change, and reading `artworkData` faults
        // in each blob. `displayArtwork` loads on-screen covers via `ArtworkProvider`.
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Playlist? {
        try fetchEntity(id: id)?.toDomain()
    }

    /// Soft-deleted playlists, kept so the deletion reaches every device. Used to find
    /// songs a delete left behind; see `LibraryService.orphansFromDeletedPlaylists`.
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

    /// Drops every local playlist row without telling the server. For sign-out or
    /// account switch, not deleting.
    /// Not `softDelete`: the next push would run as the incoming user and delete
    /// their playlists. System playlists are emptied without `touch()`, or an empty
    /// pending Favourites would overwrite the server copy.
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

    /// Makes the server's Favourites win the next pull regardless of timestamps.
    /// Only for the explicit "re-sync from server" action.
    public func yieldFavouritesToServer() throws {
        guard let fav = try fetchEntity(id: Playlist.favouritesID) else { return }
        fav.syncLocalModifiedAt = .distantPast
        fav.syncStatus          = SyncStatus.synced.rawValue
        try context.saveBatched()
    }

    // MARK: - Ensure System Playlists

    /// Creates Favourites if missing. Starts `.synced` so a fresh install never pushes
    /// an empty list over the server's (the pull fills it).
    public func ensureFavourites(deviceID: String) throws {
        if let fav = try fetchEntity(id: Playlist.favouritesID) {
            var dirty = false
            if fav.isSoftDeleted {
                fav.isSoftDeleted = false
                fav.syncStatus = SyncStatus.synced.rawValue
                dirty = true
            }
            // Renamed 2026-09. Checked every launch since older builds can sync the old name back.
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
            // Pinned from creation, matching what the pin migration gives upgraded installs.
            isPinned:    true,
            sync: SyncMetadata(
                serverID:        nil,
                status:          .synced,  // Don't push an empty Favourites over an existing server version
                // Older than any server copy. Stamped now, it was newer than the server's and the pull skipped it.
                localModifiedAt: .distantPast,
                serverModifiedAt: nil,
                lastSyncedAt:    nil,
                deviceID:        deviceID
            )
        )
        context.insert(PlaylistEntity(from: fav))
        try context.saveBatched()
    }

    /// Creates All Songs if missing. Returns true if newly created, so the caller can seed it.
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

// MARK: - PlaylistEntity <-> Domain Mapping

extension PlaylistEntity {

    /// `includingArtwork: false` is the bulk path. See `TrackEntity.toDomain`.
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
            sides:       [PlaylistSide](data: sidesData),
            notes:       PlaylistNotes(data: notesData),
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
        // A changed cover needs uploading again; the upload pass checks `artworkKey`.
        if artworkData != playlist.artworkData {
            artworkKey = nil
            // Local edit wins; the remote stamp is stale now.
            artworkRemoteStamp = nil
        }
        // A removed cover must be deleted from the bucket too. See `artworkNeedsRemoteDelete`.
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
        sidesData            = playlist.sides.sidesData
        notesData            = playlist.notes.data

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
            sidesData:            playlist.sides.sidesData,
            notesData:            playlist.notes.data,
            syncStatus:           playlist.sync.status.rawValue,
            syncServerID:         playlist.sync.serverID,
            syncDeviceID:         playlist.sync.deviceID,
            syncLocalModifiedAt:  playlist.sync.localModifiedAt,
            syncServerModifiedAt: playlist.sync.serverModifiedAt,
            syncLastSyncedAt:     playlist.sync.lastSyncedAt
        )
    }
}
