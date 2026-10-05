import Foundation
import SwiftData

@MainActor
public final class AlbumRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Album] {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        // Only the id: naming more properties makes Core Data prefetch the whole row,
        // artwork included. Scalars fault in on access. See `TrackRepository.fetchAll`.
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Album? {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    // MARK: - Find or Create

    /// The album with this exact title and artist, without the cover. Cheaper than scanning `fetchAll()`.
    public func find(title: String, artistName: String) throws -> Album? {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.title == title && $0.artistName == artistName && !$0.isSoftDeleted
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toDomain(includingArtwork: false)
    }

    /// Existing album by title and artist, or a new one. Call `save(_:)` after mutating it.
    public func findOrCreate(title: String, artistName: String, deviceID: String) throws -> Album {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.title == title && $0.artistName == artistName && !$0.isSoftDeleted
            }
        )
        // Only the first match is ever used.
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            // Load the cover: `ImportService.updateAlbum` checks `artworkData == nil`, and
            // an unloaded nil would make it rewrite the cover on every import.
            return existing.toDomain()
        }
        let album = Album(
            title: title,
            artistName: artistName,
            sync: SyncMetadata(deviceID: deviceID)
        )
        context.insert(AlbumEntity(from: album))
        try context.saveBatched()
        return album
    }

    // MARK: - Save

    public func save(_ album: Album) throws {
        if let existing = try fetchEntity(id: album.id) {
            existing.update(from: album)
        } else {
            context.insert(AlbumEntity(from: album))
        }
        try context.saveBatched()
    }

    // MARK: - Delete

    public func deleteAll() throws {
        try context.delete(model: AlbumEntity.self)
        try context.saveBatched()
    }

    // MARK: - Delete (soft)

    public func softDelete(id: UUID) throws {
        guard let entity = try fetchEntity(id: id) else { return }
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
        try context.saveBatched()
    }

    // MARK: - Private

    private func fetchEntity(id: UUID) throws -> AlbumEntity? {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Entity <-> Domain Mapping

extension AlbumEntity {


    /// `includingArtwork: false` is the bulk path. See `TrackEntity.toDomain`.
    func toDomain(includingArtwork: Bool = true) -> Album {
        Album(
            id:          id,
            title:       title,
            artistName:  artistName,
            year:        year,
            genre:       genre,
            artworkData: includingArtwork ? artworkData : nil,
            artworkKey:  artworkKey,
            trackIDs:    trackIDsData.toUUIDArray(),
            dateCreated: dateCreated,
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

    func update(from album: Album) {
        title       = album.title
        artistName  = album.artistName
        year        = album.year
        genre       = album.genre
        // Nil from a bulk-fetched struct means "not loaded", not "delete".
        if let art = album.artworkData { artworkData = art }
        artworkKey  = album.artworkKey
        trackIDsData = album.trackIDs.toData()
        isSoftDeleted = album.isDeleted

        syncStatus           = album.sync.status.rawValue
        syncServerID         = album.sync.serverID
        syncDeviceID         = album.sync.deviceID
        syncLocalModifiedAt  = album.sync.localModifiedAt
        syncServerModifiedAt = album.sync.serverModifiedAt
        syncLastSyncedAt     = album.sync.lastSyncedAt
    }
}

extension AlbumEntity {
    convenience init(from album: Album) {
        self.init(
            id:           album.id,
            title:        album.title,
            artistName:   album.artistName,
            year:         album.year,
            genre:        album.genre,
            artworkData:  album.artworkData,
            artworkKey:   album.artworkKey,
            trackIDsData: album.trackIDs.toData(),
            dateCreated:  album.dateCreated,
            isSoftDeleted: album.isDeleted,
            syncStatus:           album.sync.status.rawValue,
            syncServerID:         album.sync.serverID,
            syncDeviceID:         album.sync.deviceID,
            syncLocalModifiedAt:  album.sync.localModifiedAt,
            syncServerModifiedAt: album.sync.serverModifiedAt,
            syncLastSyncedAt:     album.sync.lastSyncedAt
        )
    }
}
