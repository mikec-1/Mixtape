import Foundation
import SwiftData

@MainActor
public final class FavoriteRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }

    public init() {}

    /// All liked ids, shared by every instance (sync makes its own). Every mutator below clears it,
    /// so it always matches what a fresh fetch would return. Tied to the context so a switched
    /// account's store never reads the old set.
    private static var cachedIDs: Set<UUID>?
    private static weak var cachedContext: ModelContext?

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

    /// The same ids as `allFavouritedIDs`, unordered, read once until the next change.
    public func favouritedIDSet() throws -> Set<UUID> {
        if let cached = Self.cachedIDs, Self.cachedContext === context { return cached }
        let ids = Set(try allFavouritedIDs())
        Self.cachedIDs = ids
        Self.cachedContext = context
        return ids
    }

    // MARK: - Mutate

    public func add(trackID: UUID, deviceID: String) throws {
        defer { Self.cachedIDs = nil }
        guard !(try isFavourited(trackID: trackID)) else { return }
        let entity = FavoriteEntity(trackID: trackID, syncDeviceID: deviceID)
        context.insert(entity)
        try context.saveBatched()
    }

    /// Favourites a whole selection with one fetch and one save.
    public func add(trackIDs: [UUID], deviceID: String) throws {
        defer { Self.cachedIDs = nil }
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

    /// Unhearts a whole selection with one fetch and one save.
    public func remove(trackIDs: [UUID]) throws {
        defer { Self.cachedIDs = nil }
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
        defer { Self.cachedIDs = nil }
        try context.delete(model: FavoriteEntity.self)
        try context.saveBatched()
    }

    // MARK: - Sync Rebuild

    /// Replaces all favourites with this ordered list, after a pull. Keeps `addedAt`
    /// for ids already hearted; new ones get now.
    public func rebuildFromIDs(_ ids: [UUID], deviceID: String) throws {
        defer { Self.cachedIDs = nil }
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
