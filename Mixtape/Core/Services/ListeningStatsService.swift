// ListeningStatsService.swift
// Mixtape — Core/Services
//
// Pure read-side aggregation over the persistent play history ("Year in
// Mixtape"). No new schema, no writes — it joins PlayHistory play events
// against the in-memory library to produce top tracks/artists, estimated
// minutes, listening streaks and a by-hour distribution.

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
    public let currentStreakDays: Int
    public let busiestHour: Int?            // 0...23
    public let playsByHour: [Int]           // 24 buckets
    public let firstPlay: Date?

    public static let empty = ListeningStats(
        period: .allTime, totalPlays: 0, uniqueTracks: 0, estimatedMinutes: 0,
        topTracks: [], topArtists: [], currentStreakDays: 0,
        busiestHour: nil, playsByHour: Array(repeating: 0, count: 24), firstPlay: nil
    )

    public var hasData: Bool { totalPlays > 0 }
}

// MARK: - Service

@MainActor
public final class ListeningStatsService {

    private let history: PlayHistoryRepository
    private let library: LibraryService
    private let calendar: Calendar

    public init(history: PlayHistoryRepository, library: LibraryService, calendar: Calendar = .current) {
        self.history = history
        self.library = library
        self.calendar = calendar
    }

    public func compute(period: StatsPeriod, now: Date = Date()) -> ListeningStats {
        let plays = (try? history.fetchAllPlays(since: period.startDate(now: now, calendar: calendar))) ?? []
        guard !plays.isEmpty else { return ListeningStats.empty }

        // Per-track play counts
        var countByTrack: [UUID: Int] = [:]
        var playsByHour = Array(repeating: 0, count: 24)
        var dayKeys: Set<Date> = []
        var estimatedSeconds: TimeInterval = 0

        for play in plays {
            countByTrack[play.trackID, default: 0] += 1
            let hour = calendar.component(.hour, from: play.playedAt)
            if hour >= 0 && hour < 24 { playsByHour[hour] += 1 }
            dayKeys.insert(calendar.startOfDay(for: play.playedAt))
            if let track = library.track(id: play.trackID) {
                estimatedSeconds += track.duration
            }
        }

        // Top tracks (resolve against library; drop tracks no longer present)
        let topTracks: [TrackStat] = countByTrack
            .compactMap { id, count -> TrackStat? in
                guard let track = library.track(id: id) else { return nil }
                return TrackStat(track: track, playCount: count)
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(10)
            .map { $0 }

        // Top artists (group resolved tracks by artist name)
        var artistCount: [String: (name: String, count: Int, art: Data?)] = [:]
        for (id, count) in countByTrack {
            guard let track = library.track(id: id) else { continue }
            let key = track.artistName.lowercased()
            var entry = artistCount[key] ?? (track.artistName, 0, track.artworkData)
            entry.count += count
            if entry.art == nil { entry.art = track.artworkData }
            artistCount[key] = entry
        }
        let topArtists: [ArtistStat] = artistCount
            .map { ArtistStat(id: $0.key, name: $0.value.name, playCount: $0.value.count, artworkData: $0.value.art) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(10)
            .map { $0 }

        let busiestHour = playsByHour.enumerated().max(by: { $0.element < $1.element })
            .flatMap { $0.element > 0 ? $0.offset : nil }

        return ListeningStats(
            period: period,
            totalPlays: plays.count,
            uniqueTracks: countByTrack.count,
            estimatedMinutes: Int(estimatedSeconds / 60),
            topTracks: topTracks,
            topArtists: topArtists,
            currentStreakDays: currentStreak(dayKeys: dayKeys, now: now),
            busiestHour: busiestHour,
            playsByHour: playsByHour,
            firstPlay: plays.last?.playedAt   // plays sorted newest-first
        )
    }

    /// Consecutive days (counting back from today) that have at least one play.
    /// Today with no plays yet doesn't break a streak that's current as of
    /// yesterday.
    private func currentStreak(dayKeys: Set<Date>, now: Date) -> Int {
        guard !dayKeys.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        var cursor = today
        // If nothing played today, allow the streak to anchor on yesterday.
        if !dayKeys.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  dayKeys.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while dayKeys.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }
}
