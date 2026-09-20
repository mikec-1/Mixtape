// ListeningStatsService.swift
// Mixtape — Core/Services
//
// Pure read-side aggregation over the persistent play history ("Year in
// Mixtape"). No new schema, no writes — it joins PlayHistory play events
// against the in-memory library to produce top tracks/artists, estimated
// minutes and a by-hour distribution.

import Foundation

// MARK: - Period

public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case last30Days
    case thisYear
    case allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .last30Days: return "30 Days"
        case .thisYear:   return "This Year"
        case .allTime:    return "All Time"
        }
    }

    /// Lower bound for the query, or nil for all-time.
    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .thisYear:
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .allTime:
            return nil
        }
    }
}

// MARK: - Result types

public struct ArtistStat: Identifiable, Sendable {
    public let id: String          // artist name (lowercased key)
    public let name: String
    public let playCount: Int
    public let artworkData: Data?
}

public struct TrackStat: Identifiable, Sendable {
    public var id: UUID { track.id }
    public let track: Track
    public let playCount: Int
}

public struct ListeningStats: Sendable {
    public let period: StatsPeriod
    public let totalPlays: Int
    public let uniqueTracks: Int
    public let estimatedMinutes: Int
    public let topTracks: [TrackStat]
    public let topArtists: [ArtistStat]
    public let busiestHour: Int?            // 0...23
    public let playsByHour: [Int]           // 24 buckets
    public let firstPlay: Date?

    public static let empty = ListeningStats(
        period: .allTime, totalPlays: 0, uniqueTracks: 0, estimatedMinutes: 0,
        topTracks: [], topArtists: [],
        busiestHour: nil, playsByHour: Array(repeating: 0, count: 24), firstPlay: nil
    )

    public var hasData: Bool { totalPlays > 0 }
}

// MARK: - Service

@MainActor
public final class ListeningStatsService {

    private let history: PlayHistoryRepository
    private let library: LibraryService
    private let snapshots: PlayedTrackSnapshotRepository?
    private let calendar: Calendar

    /// Wipes the account's play history on the server too. Set by
    /// `AppDependencies` once the sync service exists — without it, a reset is
    /// undone the next time another device pushes the plays it still holds.
    public var remoteWipe: (() -> Void)?

    public init(history: PlayHistoryRepository, library: LibraryService,
                snapshots: PlayedTrackSnapshotRepository? = nil, calendar: Calendar = .current) {
        self.history = history
        self.library = library
        self.snapshots = snapshots
        self.calendar = calendar
    }

    /// Erases everything the stats are computed from: the play log, and the
    /// snapshots of played tracks that never lived in the library.
    ///
    /// Deleting your music does NOT do this, and shouldn't — history is a record
    /// of what you listened to, not of what you own, and re-importing a song
    /// should not resurrect zeroed play counts. But it does mean a wiped library
    /// can still report top artists, which is only ever what someone wants when
    /// they asked for it explicitly.
    public func resetHistory() {
        do { try history.deleteAll() } catch {
            print("[ListeningStats] history wipe failed: \(error)")
        }
        remoteWipe?()
        do { try snapshots?.deleteAll() } catch {
            print("[ListeningStats] snapshot wipe failed: \(error)")
        }
    }

    public func compute(period: StatsPeriod, now: Date = Date()) -> ListeningStats {
        mixMainActivity("stats-compute") { computeBody(period: period, now: now) }
    }

    private func computeBody(period: StatsPeriod, now: Date) -> ListeningStats {
        // Two SwiftData fetches and then pure in-memory work, spanned apart
        // because the cost is lopsided in a way the total hides: one call in
        // seven measured 746 ms and the rest were single digits. That is the
        // shape of a cold fetch, not of the loops below — and `library.track(id:)`
        // is already an O(1) index lookup, so the loops were never the suspect
        // they look like.
        let plays = mixMainActivity("stats-compute ▸ fetch-plays") {
            (try? history.fetchAllPlays(since: period.startDate(now: now, calendar: calendar))) ?? []
        }
        guard !plays.isEmpty else { return ListeningStats.empty }

        // Resolve a play's track against the library first, then the online-track
        // snapshot store — so Discover plays count toward stats too.
        let snapshotMap = mixMainActivity("stats-compute ▸ fetch-snapshots") {
            (try? snapshots?.fetchAll()) ?? [:]
        }
        func resolve(_ id: UUID) -> Track? { library.track(id: id) ?? snapshotMap[id] }

        // Per-track play counts
        var countByTrack: [UUID: Int] = [:]
        var playsByHour = Array(repeating: 0, count: 24)
        var estimatedSeconds: TimeInterval = 0

        for play in plays {
            countByTrack[play.trackID, default: 0] += 1
            let hour = calendar.component(.hour, from: play.playedAt)
            if hour >= 0 && hour < 24 { playsByHour[hour] += 1 }
            // The real listen when the play recorded one; rows written before
            // the engine reported it, and plays the app never finalised, fall
            // back to the track's full length.
            if play.secondsPlayed > 0 {
                estimatedSeconds += play.secondsPlayed
            } else if let track = resolve(play.trackID) {
                estimatedSeconds += track.duration
            }
        }

        // Top tracks (resolve against library; drop tracks no longer present)
        let topTracks: [TrackStat] = countByTrack
            .compactMap { id, count -> TrackStat? in
                guard let track = resolve(id) else { return nil }
                return TrackStat(track: track, playCount: count)
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(10)
            .map { $0 }

        // Top artists (group resolved tracks by artist name)
        // The cover is carried as a track id rather than bytes: this loop runs
        // over every song ever played, and only ten of them end up on screen.
        var artistCount: [String: (name: String, count: Int, cover: UUID?)] = [:]
        // Each credited artist counted separately: "Dave, Stormzy" is two
        // artists, and bucketing it whole both hid them from the stats and fed
        // the recommendation seeds a name no catalogue can resolve.
        for (id, count) in countByTrack {
            guard let track = resolve(id) else { continue }
            for name in ImportService.creditedArtists(from: track.artistName) {
                let key = name.lowercased()
                var entry = artistCount[key] ?? (name, 0, nil)
                entry.count += count
                if entry.cover == nil { entry.cover = track.id }
                artistCount[key] = entry
            }
        }
        let topArtists: [ArtistStat] = artistCount
            .sorted { $0.value.count > $1.value.count }
            .prefix(10)
            .map { entry in
                ArtistStat(id: entry.key,
                           name: entry.value.name,
                           playCount: entry.value.count,
                           artworkData: entry.value.cover
                               .flatMap { ArtworkProvider.shared.data(for: .track($0)) })
            }

        let busiestHour = playsByHour.enumerated().max(by: { $0.element < $1.element })
            .flatMap { $0.element > 0 ? $0.offset : nil }

        return ListeningStats(
            period: period,
            totalPlays: plays.count,
            uniqueTracks: countByTrack.count,
            estimatedMinutes: Int(estimatedSeconds / 60),
            topTracks: topTracks,
            topArtists: topArtists,
            busiestHour: busiestHour,
            playsByHour: playsByHour,
            firstPlay: plays.last?.playedAt   // plays sorted newest-first
        )
    }
}
