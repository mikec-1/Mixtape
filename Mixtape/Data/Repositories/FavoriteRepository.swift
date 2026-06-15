// FavoriteRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class FavoriteRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Query

    public func isFavourited(trackID: UUID) throws -> Bool {
        let desc = FetchDescriptor<FavoriteEntity>(
            predicate: #Predicate { $0.trackID == trackID }
        )
        return !(try context.fetch(desc).isEmpty)
    }

    public func allFavouritedIDs() throws -> [UUID] {
        let desc = FetchDescriptor<FavoriteEntity>(
            sortBy: [SortDescriptor(\.addedAt)]
        )
        return try context.fetch(desc).map(\.trackID)
    }

    // MARK: - Mutate

    public func add(trackID: UUID, deviceID: String) throws {
        guard !(try isFavourited(trackID: trackID)) else { return }
        let entity = FavoriteEntity(trackID: trackID, syncDeviceID: deviceID)
        context.insert(entity)
        try context.save()
    }

    public func remove(trackID: UUID) throws {
        let desc = FetchDescriptor<FavoriteEntity>(
            predicate: #Predicate { $0.trackID == trackID }
        )
        for entity in try context.fetch(desc) {
            context.delete(entity)
        }
        try context.save()
    }

    /// Hard-deletes all FavoriteEntity records from the local store.
    public func deleteAll() throws {
        try context.delete(model: FavoriteEntity.self)
        try context.save()
    }

    // MARK: - Sync Rebuild

    /// Atomically replaces all FavoriteEntity records with the given ordered list.
    /// Called after pullPlaylists() merges a new Favourites track_ids array from the server.
    /// Preserves addedAt for IDs that were already locally hearted; uses Date() for new ones.
    public func rebuildFromIDs(_ ids: [UUID], deviceID: String) throws {
        // Build a lookup of existing addedAt values so we don't lose timestamps.
        var existingAddedAt: [UUID: Date] = [:]
        for entity in try context.fetch(FetchDescriptor<FavoriteEntity>()) {
            existingAddedAt[entity.trackID] = entity.addedAt
            context.delete(entity)
        }

        for trackID in ids {
            let entity = FavoriteEntity(
                trackID:             trackID,
                addedAt:             existingAddedAt[trackID] ?? Date(),
                syncStatus:          SyncStatus.synced.rawValue,
                syncDeviceID:        deviceID,
                syncLocalModifiedAt: Date()
            )
            context.insert(entity)
        }
        try context.save()
    }
}
