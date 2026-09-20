// ArtistRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class ArtistRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Fetch

    public func fetchAll() throws -> [Artist] {
        var descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.name)]
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
        var descriptor = FetchDescriptor<ArtistEntity>(
            predicate: #Predicate { $0.name == name && !$0.isSoftDeleted }
        )
        // Only the first match is ever used.
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            // The cover is loaded on purpose: `ImportService.attachTrack` reads
            // `artist.artworkData == nil` to decide whether the artist still
            // needs a picture, and a nil that only means "wasn't fetched" makes
            // it rewrite the image on every imported song.
            return existing.toDomain()
        }
        // The name is unique in the store, so a row that exists but is
        // soft-deleted can't simply be inserted alongside: SwiftData would
        // upsert onto it and the new blank row would take its artwork, its id
        // and its sync history with it. Reviving is both correct and cheaper.
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
        // By id first, then by name — `name` is unique too, and inserting over
        // it is a silent replace rather than the error it looks like. What the
        // replaced row loses is whatever the incoming struct doesn't carry,
        // which for anything out of the bulk fetch means its artwork.
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

    /// Deliberately *includes* soft-deleted rows: they still hold the unique
    /// name, so they are still in the way of an insert.
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

// MARK: - Entity ↔ Domain Mapping

extension ArtistEntity {


    /// See TrackEntity.toDomain — `includingArtwork: false` is the bulk path.
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
        // A domain struct from the bulk fetch carries no cover — nil here
        // means "wasn't loaded", never "delete it". Clearing artwork is done
        // on the entity directly.
        if let art = artist.artworkData { artworkData = art }
        // Same rule for the key, and for the same reason: a struct carrying
        // neither is one that didn't load the cover, not one asking for the
        // cover to be forgotten. Clearing it on that would send the artwork
        // back up on the next sync as if it were new.
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
