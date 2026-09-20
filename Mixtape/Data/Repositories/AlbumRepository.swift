// AlbumRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class AlbumRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Album] {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.title)]
        )
        // See TrackRepository.fetchAll — the cover is left out on purpose.
        // `propertiesToFetch` is not "the properties I want" so much as "what to
        // prefetch eagerly". Naming the full scalar list makes Core Data pull the
        // whole row *including the artwork blob*; naming only the id leaves the
        // blob alone and batch-faults the scalars on access. Measured on a
        // 2088-track library: full list 490 MB at end of refresh, id only
        // 218 MB — and the id-only fetch was also the faster of the two.
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

    /// Returns an existing album matching title + artistName, or creates a new one.
    /// Callers should call `save(_:)` after mutating the returned album.
    /// The album under this exact title and act, if there is one.
    ///
    /// The alternative callers reached for was `fetchAll().first(where:)`, which
    /// maps every album in the library into a domain value to find one of them.
    /// Done once per credited artist per imported song, that was a third of a
    /// second per song on the main actor.
    public func find(title: String, artistName: String) throws -> Album? {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.title == title && $0.artistName == artistName && !$0.isSoftDeleted
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toDomain(includingArtwork: false)
    }

    public func findOrCreate(title: String, artistName: String, deviceID: String) throws -> Album {
        var descriptor = FetchDescriptor<AlbumEntity>(
            predicate: #Predicate {
                $0.title == title && $0.artistName == artistName && !$0.isSoftDeleted
            }
        )
        // Only the first match is ever used.
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            // The cover is loaded on purpose: `ImportService.updateAlbum` reads
            // `album.artworkData == nil` to decide whether the album still needs
            // one, and a nil that only means "wasn't fetched" makes it rewrite
            // the cover on every imported song.
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

// MARK: - Entity ↔ Domain Mapping

extension AlbumEntity {


    /// See TrackEntity.toDomain — `includingArtwork: false` is the bulk path.
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
        // A domain struct from the bulk fetch carries no cover — nil here
        // means "wasn't loaded", never "delete it". Clearing artwork is done
        // on the entity directly.
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
