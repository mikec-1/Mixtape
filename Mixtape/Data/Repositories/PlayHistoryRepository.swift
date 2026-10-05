// Reads and writes play history, capped at `historyLimit`.

import Foundation
import SwiftData

@MainActor
public final class PlayHistoryRepository {

    /// Not stored: belongs to the open account's store. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    // About 11 years at 50 plays a day. Bounded so it can't slow launch forever.
    private let historyLimit = 200_000
    // Only prune once the table is this far over the cap, so it runs once per ~1000 plays.
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

    /// One play, with just what the stats need.
    public struct PlayRecord: Sendable {
        public let trackID: UUID
        public let playedAt: Date
        /// Actual listen time. Zero on old rows and unfinalised plays (app quit
        /// mid-song); fall back to the track duration.
        public let secondsPlayed: TimeInterval
        /// Where the play came from. See `QueueSource.historyRef`.
        public let sourceKind: String?
        public let sourceID: String?
        /// The install that played it. Pulled rows keep the writer's id.
        public let deviceID: String
    }

    /// Every retained play, newest first, optionally from `since` on.
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

    /// Track ids played in `interval`, newest first. What a monthly tape is ranked from.
    public func fetchTrackIDs(in interval: DateInterval) throws -> [UUID] {
        let start = interval.start, end = interval.end
        var desc = FetchDescriptor<PlayHistoryEntity>(
            predicate: #Predicate { $0.playedAt >= start && $0.playedAt < end },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        desc.propertiesToFetch = [\.trackID]
        return try context.fetch(desc).map(\.trackID)
    }

    /// The oldest retained play, or nil with no history.
    public func firstPlayDate() throws -> Date? {
        var desc = FetchDescriptor<PlayHistoryEntity>(sortBy: [SortDescriptor(\.playedAt)])
        desc.fetchLimit = 1
        return try context.fetch(desc).first?.playedAt
    }

    // MARK: - Mutate

    /// Records a play and prunes if needed. `secondsPlayed` is the threshold crossed;
    /// `finaliseLatestPlay` corrects it when the track ends.
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

    /// Writes the real listen time onto the newest play of `trackID`. The engine
    /// finalises each play before the next starts, so that's the right row. Only
    /// increases, so a racing replay can't shorten it.
    public func finaliseLatestPlay(trackID: UUID, secondsPlayed: TimeInterval) throws {
        var desc = FetchDescriptor<PlayHistoryEntity>(
            predicate: #Predicate { $0.trackID == trackID },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let entry = try context.fetch(desc).first,
              secondsPlayed > entry.secondsPlayed else { return }
        entry.secondsPlayed = secondsPlayed
        // Back to pending so the next push sends the corrected row. Pulls only insert,
        // so only the playing device updates it.
        if entry.syncStatus == SyncStatus.synced.rawValue {
            entry.syncStatus = SyncStatus.modified.rawValue
        }
        entry.syncLocalModifiedAt = Date()
        try context.save()
    }

    /// Drops the oldest rows once the table is `pruneSlack` over the cap.
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
