// AlbumRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class AlbumRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetch

    public func fetchAll() throws -> [Album] {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func fetch(id: UUID) throws -> Album? {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toDomain()
    }

    // MARK: - Find or Create

    /// Returns an existing album matching title + artistName, or creates a new one.
    /// Callers should call `save(_:)` after mutating the returned album.
    public func findOrCreate(title: String, artistName: String, deviceID: String) throws -> Album {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.title == title && $0.artistName == artistName && !$0.isSoftDeleted
            }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing.toDomain()
        }
        let album = Album(
            title: title,
            artistName: artistName,
            sync: SyncMetadata(deviceID: deviceID)
        )
        context.insert(AlbumEntity(from: album))
        try context.save()
        return album
    }

    // MARK: - Save

    public func save(_ album: Album) throws {
        if let existing = try fetchEntity(id: album.id) {
            existing.update(from: album)
        } else {
            context.insert(AlbumEntity(from: album))
        }
        try context.save()
    }

    // MARK: - Delete

    public func deleteAll() throws {
        try context.delete(model: AlbumEntity.self)
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

    private func fetchEntity(id: UUID) throws -> AlbumEntity? {
        let descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Entity ↔ Domain Mapping

extension AlbumEntity {
    func toDomain() -> Album {
        Album(
            id:          id,
            title:       title,
            artistName:  artistName,
            year:        year,
            genre:       genre,
            artworkData: artworkData,
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
        artworkData = album.artworkData
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
