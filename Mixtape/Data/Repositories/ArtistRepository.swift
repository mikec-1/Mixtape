// ArtistRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class ArtistRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetch

    public func fetchAll() throws -> [Artist] {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func fetch(id: UUID) throws -> Artist? {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    // MARK: - Find or Create

    /// Returns the existing artist with this name, or creates a new one.
    /// Artist names are treated case-sensitively to preserve original casing.
    public func findOrCreate(name: String, deviceID: String) throws -> Artist {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.name == name && !$0.isSoftDeleted }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing.toDomain()
        }
        let artist = Artist(name: name, sync: SyncMetadata(deviceID: deviceID))
        context.insert(ArtistEntity(from: artist))
        try context.save()
        return artist
    }

    // MARK: - Save

    public func save(_ artist: Artist) throws {
        if let existing = try fetchEntity(id: artist.id) {
            existing.update(from: artist)
        } else {
            context.insert(ArtistEntity(from: artist))
        }
        try context.save()
    }

    // MARK: - Delete

    public func deleteAll() throws {
        try context.delete(model: ArtistEntity.self)
        try context.save()
    }

    // MARK: - Delete (soft)

    public func softDelete(id: UUID) throws {
        guard let entity = try fetchEntity(id: id) else { return }
        entity.isSoftDeleted = true
        entity.syncStatus = SyncStatus.deleted.rawValue
        entity.syncLocalModifiedAt = Date()
        try context.save()
    }

    // MARK: - Private

    private func fetchEntity(id: UUID) throws -> ArtistEntity? {
        let descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Entity ↔ Domain Mapping

extension ArtistEntity {
    func toDomain() -> Artist {
        Artist(
            id:          id,
            name:        name,
            bio:         bio,
            artworkData: artworkData,
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
        artworkData = artist.artworkData
        artworkKey  = artist.artworkKey
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
