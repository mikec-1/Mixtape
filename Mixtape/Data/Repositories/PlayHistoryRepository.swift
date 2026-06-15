// PlayHistoryRepository.swift
// Mixtape — Data/Repositories
//
// Handles reads and writes for PlayHistoryEntity (persistent listen history).
// Caps history at 50 entries by pruning the oldest records automatically.

import Foundation
import SwiftData

@MainActor
public final class PlayHistoryRepository {

    private let context: ModelContext
    // Kept generous so listening-stats aggregates ("Year in Mixtape") have real
    // data to work with. Still bounded to avoid unbounded table growth.
    private let historyLimit = 10_000

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Query

    /// Returns up to `limit` most recently played track IDs, newest first.
    public func fetchRecentTrackIDs(limit: Int = 50) throws -> [UUID] {
        var desc = FetchDescriptor<PlayHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return try context.fetch(desc).map(\.trackID)
    }

    /// One lightweight play record — just what the stats aggregator needs.
    public struct PlayRecord: Sendable {
        public let trackID: UUID
        public let playedAt: Date
    }

    /// Returns every retained play event (newest first), for listening-stats
    /// aggregation. Optionally restricts to plays at/after `since`.
    public func fetchAllPlays(since: Date? = nil) throws -> [PlayRecord] {
        var desc = FetchDescriptor<PlayHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        if let since {
            desc.predicate = #Predicate { $0.playedAt >= since }
        }
        return try context.fetch(desc).map { PlayRecord(trackID: $0.trackID, playedAt: $0.playedAt) }
    }

    // MARK: - Mutate

    /// Records a newly played track and prunes old entries beyond the history limit.
    public func record(trackID: UUID, deviceID: String) throws {
        // Insert the new entry
        let entry = PlayHistoryEntity(
            trackID:          trackID,
            playedAt:         Date(),
            secondsPlayed:    0,
            syncStatus:       SyncStatus.localOnly.rawValue,
            syncDeviceID:     deviceID,
            syncLocalModifiedAt: Date()
        )
        context.insert(entry)

        // Fetch all sorted newest-first to prune excess
        var pruneDesc = FetchDescriptor<PlayHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        pruneDesc.fetchLimit = historyLimit + 50 // fetch a bit extra
        let all = try context.fetch(pruneDesc)

        if all.count > historyLimit {
            let toDelete = all.dropFirst(historyLimit)
            for entity in toDelete {
                context.delete(entity)
            }
        }

        try context.save()
    }

    // MARK: - Clear

    public func deleteAll() throws {
        try context.delete(model: PlayHistoryEntity.self)
        try context.save()
    }
}
