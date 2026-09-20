// FavoriteRepository.swift
// Mixtape — Data/Repositories

import Foundation
import SwiftData

@MainActor
public final class FavoriteRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    // MARK: - Query

    public func isFavourited(trackID: UUID) throws -> Bool {
        let desc = FetchDescriptor<FavoriteEntity>(
            predicate: #Predicate { $0.trackID == trackID }
        )
        // A count, not the row: nothing here reads the entity.
        return try context.fetchCount(desc) > 0
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
        try context.saveBatched()
    }

    /// Favourites a whole selection in one fetch and one save.
    ///
    /// Called per song, `add(trackID:)` is a predicate fetch *and* a full
    /// `context.save()` each time — importing 2,200 Liked Songs meant 2,200 of
    /// each, on the main thread, after the progress bar had already reached the
    /// end. That was the second freeze: the one that happened when the import
    /// looked finished.
    public func add(trackIDs: [UUID], deviceID: String) throws {
        guard !trackIDs.isEmpty else { return }
        let existing = Set(try allFavouritedIDs())
        var inserted = Set<UUID>()
        for id in trackIDs where !existing.contains(id) && inserted.insert(id).inserted {
            context.insert(FavoriteEntity(trackID: id, syncDeviceID: deviceID))
        }
        guard !inserted.isEmpty else { return }
        try context.saveBatched()
    }

    public func remove(trackID: UUID) throws {
        try remove(trackIDs: [trackID])
    }

    /// Unhearts a whole selection in one fetch and one save — the mirror of
    /// `add(trackIDs:)`, and for the same reason. Removing 2,100 imported songs
    /// went through the single-id version, so it was 2,100 predicate fetches and
    /// 2,100 commits on the main thread: the app was unresponsive for the whole
    /// of it.
    public func remove(trackIDs: [UUID]) throws {
        let doomed = Set(trackIDs)
        guard !doomed.isEmpty else { return }
        var removed = false
        for entity in try context.fetch(FetchDescriptor<FavoriteEntity>())
        where doomed.contains(entity.trackID) {
            context.delete(entity)
            removed = true
        }
        guard removed else { return }
        try context.saveBatched()
    }

    /// Hard-deletes all FavoriteEntity records from the local store.
    public func deleteAll() throws {
        try context.delete(model: FavoriteEntity.self)
        try context.saveBatched()
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
        try context.saveBatched()
    }
}
