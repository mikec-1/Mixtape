import Foundation
import SwiftData

@MainActor
public final class ArtistRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Artist] {
        var descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.name)]
        )
        // Only the id, to keep artwork out of the fetch. See `TrackRepository.fetchAll`.
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map { $0.toDomain(includingArtwork: false) }
    }

    public func fetch(id: UUID) throws -> Artist? {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    // MARK: - Find or Create

    /// Existing artist with this name, or a new one. Case-sensitive to keep the original casing.
    public func findOrCreate(name: String, deviceID: String) throws -> Artist {
        var descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.name == name && !$0.isSoftDeleted }
        )
        // Only the first match is ever used.
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            // Load the cover: `ImportService.attachTrack` checks `artworkData == nil`, and
            // an unloaded nil would make it rewrite the image on every import.
            return existing.toDomain()
        }
        // `name` is unique, so inserting next to a soft-deleted row would upsert onto
        // it and take its artwork and id. Revive it instead.
        if let buried = try fetchEntity(name: name) {
            buried.isSoftDeleted = false
            buried.syncStatus    = SyncStatus.localOnly.rawValue
            buried.syncLocalModifiedAt = Date()
            try context.saveBatched()
            return buried.toDomain()
        }
        let artist = Artist(name: name, sync: SyncMetadata(deviceID: deviceID))
        context.insert(ArtistEntity(from: artist))
        try context.saveBatched()
        return artist
    }

    // MARK: - Save

    public func save(_ artist: Artist) throws {
        // By id, then by name: inserting over a unique name silently replaces the row,
        // losing whatever the struct doesn't carry (like artwork).
        if let existing = try fetchEntity(id: artist.id) ?? fetchEntity(name: artist.name) {
            existing.update(from: artist)
        } else {
            context.insert(ArtistEntity(from: artist))
        }
        try context.saveBatched()
    }

    // MARK: - Delete

    public func deleteAll() throws {
        try context.delete(model: ArtistEntity.self)
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

    /// Includes soft-deleted rows, since they still hold the unique name.
    private func fetchEntity(name: String) throws -> ArtistEntity? {
        var descriptor = FetchDescriptor<ArtistEntity>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchEntity(id: UUID) throws -> ArtistEntity? {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Entity <-> Domain Mapping

extension ArtistEntity {


    /// `includingArtwork: false` is the bulk path. See `TrackEntity.toDomain`.
    func toDomain(includingArtwork: Bool = true) -> Artist {
        Artist(
            id:          id,
            name:        name,
            bio:         bio,
            artworkData: includingArtwork ? artworkData : nil,
            artworkKey:  artworkKey,
            isFollowed:  isFollowed,
            albumIDs:    albumIDsData.toUUIDArray(),
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

    func update(from artist: Artist) {
        name        = artist.name
        bio         = artist.bio
        // Nil from a bulk-fetched struct means "not loaded", not "delete".
        if let art = artist.artworkData { artworkData = art }
        // Same for the key; clearing it would re-upload the artwork on the next sync.
        if let key = artist.artworkKey {
            artworkKey = key
        } else if artist.artworkData != nil {
            artworkKey = nil
        }
        isFollowed  = artist.isFollowed
        albumIDsData = artist.albumIDs.toData()
        trackIDsData = artist.trackIDs.toData()
        isSoftDeleted = artist.isDeleted

        syncStatus           = artist.sync.status.rawValue
        syncServerID         = artist.sync.serverID
        syncDeviceID         = artist.sync.deviceID
        syncLocalModifiedAt  = artist.sync.localModifiedAt
        syncServerModifiedAt = artist.sync.serverModifiedAt
        syncLastSyncedAt     = artist.sync.lastSyncedAt
    }
}

extension ArtistEntity {
    convenience init(from artist: Artist) {
        self.init(
            id:           artist.id,
            name:         artist.name,
            bio:          artist.bio,
            artworkData:  artist.artworkData,
            artworkKey:   artist.artworkKey,
            isFollowed:   artist.isFollowed,
            albumIDsData: artist.albumIDs.toData(),
            trackIDsData: artist.trackIDs.toData(),
            dateCreated:  artist.dateCreated,
            isSoftDeleted:    artist.isDeleted,
            syncStatus:           artist.sync.status.rawValue,
            syncServerID:         artist.sync.serverID,
            syncDeviceID:         artist.sync.deviceID,
            syncLocalModifiedAt:  artist.sync.localModifiedAt,
            syncServerModifiedAt: artist.sync.serverModifiedAt,
            syncLastSyncedAt:     artist.sync.lastSyncedAt
        )
    }
}
