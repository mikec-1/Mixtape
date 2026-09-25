// PlayHistoryRepository.swift
// Mixtape — Data/Repositories
//
// Handles reads and writes for PlayHistoryEntity (persistent listen history).
// Bounded by `historyLimit`, pruning the oldest records automatically.

import Foundation
import SwiftData

@MainActor
public final class PlayHistoryRepository {

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    // Listening stats are only as good as the history behind them, so this is
    // sized to outlive the user's interest in it: ~11 years at 50 plays a day.
    // Still bounded — an unbounded table eventually costs a launch.
    private let historyLimit = 200_000
    // Pruning is the expensive half of `record`, so let the table drift this far
    // past the cap before paying for it. Trades a little slack for one prune per
    // ~1000 plays instead of one per play.
    private let pruneSlack = 1_000

    public init() {}

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
        /// How long the listen actually lasted. Zero on rows written before the
        /// engine started reporting it, and on plays the app never got to
        /// finalise (quit mid-song) — callers should fall back to track duration.
        public let secondsPlayed: TimeInterval
        /// Where the play came from. See `QueueSource.historyRef`.
        public let sourceKind: String?
        public let sourceID: String?
        /// The install that played it. Pulled rows keep the writer's id.
        public let deviceID: String
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
        return try context.fetch(desc).map {
            PlayRecord(trackID: $0.trackID, playedAt: $0.playedAt, secondsPlayed: $0.secondsPlayed,
                       sourceKind: $0.sourceKind, sourceID: $0.sourceID, deviceID: $0.syncDeviceID)
        }
    }

    /// One page of plays, newest first. A browsable list doesn't need the whole log,
    /// which is what `fetchAllPlays` loads.
    public func fetchPlays(limit: Int, offset: Int = 0) throws -> [PlayRecord] {
        var desc = FetchDescriptor<PlayHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        desc.fetchOffset = offset
        return try context.fetch(desc).map {
            PlayRecord(trackID: $0.trackID, playedAt: $0.playedAt, secondsPlayed: $0.secondsPlayed,
                       sourceKind: $0.sourceKind, sourceID: $0.sourceID, deviceID: $0.syncDeviceID)
        }
    }

    /// How often one track was played, and when it was first and last played.
    public struct TrackPlays: Sendable {
        public let count: Int
        public let first: Date?
        public let last: Date?

        public static let none = TrackPlays(count: 0, first: nil, last: nil)
    }

    /// Counts and bounds for one track. A count plus two single-row fetches, so it
    /// stays cheap enough to run when a sheet opens.
    public func plays(of trackID: UUID) throws -> TrackPlays {
        let count = try context.fetchCount(
            FetchDescriptor<PlayHistoryEntity>(predicate: #Predicate { $0.trackID == trackID })
        )
        guard count > 0 else { return .none }

        func edge(_ order: SortOrder) throws -> Date? {
            var desc = FetchDescriptor<PlayHistoryEntity>(
                predicate: #Predicate { $0.trackID == trackID },
                sortBy: [SortDescriptor(\.playedAt, order: order)]
            )
            desc.fetchLimit = 1
            return try context.fetch(desc).first?.playedAt
        }
        return TrackPlays(count: count, first: try edge(.forward), last: try edge(.reverse))
    }

    /// Every song played before `date`, ids only. What makes a song in a period new to you.
    public func fetchTrackIDs(before date: Date) throws -> Set<UUID> {
        var desc = FetchDescriptor<PlayHistoryEntity>(predicate: #Predicate { $0.playedAt < date })
        desc.propertiesToFetch = [\.trackID]
        return Set(try context.fetch(desc).map(\.trackID))
    }

    // MARK: - Mutate

    /// Records a newly played track and prunes old entries beyond the history
    /// limit. `secondsPlayed` is the listen so far — the threshold the engine
    /// crossed to call this — and is corrected by `finaliseLatestPlay` once the
    /// user leaves the track.
    public func record(trackID: UUID, deviceID: String, secondsPlayed: TimeInterval,
                       source: QueueSource = .none) throws {
        let ref = source.historyRef
        let entry = PlayHistoryEntity(
            trackID:          trackID,
            playedAt:         Date(),
            secondsPlayed:    secondsPlayed,
            sourceKind:       ref?.kind,
            sourceID:         ref?.id,
            syncStatus:       SyncStatus.localOnly.rawValue,
            syncDeviceID:     deviceID,
            syncLocalModifiedAt: Date()
        )
        context.insert(entry)
        try context.save()
        try pruneIfNeeded()
    }

    /// Writes the real listen time onto the most recent play of `trackID`.
    ///
    /// No play id is plumbed through the engine: it logs one row per listen and
    /// finalises it before the next one starts, so "newest row for this track"
    /// is unambiguously that row. Only ever grows the figure, so a replay that
    /// races the flush can't shorten the listen it's correcting.
    public func finaliseLatestPlay(trackID: UUID, secondsPlayed: TimeInterval) throws {
        var desc = FetchDescriptor<PlayHistoryEntity>(
            predicate: #Predicate { $0.trackID == trackID },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let entry = try context.fetch(desc).first,
              secondsPlayed > entry.secondsPlayed else { return }
        entry.secondsPlayed = secondsPlayed
        // Back to pending so the next push re-upserts the corrected row. The
        // pull only ever inserts, so this converges on the device that played
        // it — the only one that knows how long the listen was.
        if entry.syncStatus == SyncStatus.synced.rawValue {
            entry.syncStatus = SyncStatus.modified.rawValue
        }
        entry.syncLocalModifiedAt = Date()
        try context.save()
    }

    /// Drops the oldest rows once the table has drifted `pruneSlack` past the
    /// cap. The count is cheap; the fetch-and-delete is not, which is why this
    /// used to be the most expensive thing about playing a song.
    private func pruneIfNeeded() throws {
        let count = try context.fetchCount(FetchDescriptor<PlayHistoryEntity>())
        guard count > historyLimit + pruneSlack else { return }

        // Offset past the rows being kept, so only the doomed ones are loaded.
        var pruneDesc = FetchDescriptor<PlayHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        pruneDesc.fetchOffset = historyLimit
        for entity in try context.fetch(pruneDesc) { context.delete(entity) }
        try context.save()
    }

    // MARK: - Clear

    public func deleteAll() throws {
        try context.delete(model: PlayHistoryEntity.self)
        try context.save()
    }
}
