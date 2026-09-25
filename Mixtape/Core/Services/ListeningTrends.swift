// ListeningTrends.swift
// Mixtape — Core/Services
//
// The date and ranking maths behind the stats page's charts: streaks, the
// listening-over-time series and rank movement. Foundation only, so
// `scripts/listening-trends-check.swift` can compile against the real file:
//
//   xcrun swiftc Mixtape/Core/Services/ListeningTrends.swift \
//       scripts/listening-trends-check.swift -o /tmp/trendcheck && /tmp/trendcheck

import Foundation

/// Where an entry sits against the period before.
public enum RankMove: Sendable, Equatable {
    case new
    /// Places climbed. Negative is a fall, zero is holding.
    case moved(Int)
}

/// Plays in one bar of the listening-over-time chart.
public struct PlayPoint: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let plays: Int
}

public enum ListeningTrends {

    /// Runs of consecutive days with a play. `current` counts back from today, or from
    /// yesterday when nothing has played yet today, so a streak doesn't read 0 over
    /// breakfast.
    public static func streaks(days: Set<Date>, today: Date,
                               calendar: Calendar) -> (current: Int, best: Int) {
        let days = Set(days.map { calendar.startOfDay(for: $0) })
        func step(_ day: Date, _ n: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: n, to: day) ?? day)
        }
        var best = 0
        // Walking only from the first day of each run keeps this linear.
        for day in days where !days.contains(step(day, -1)) {
            var length = 1
            while days.contains(step(day, length)) { length += 1 }
            best = max(best, length)
        }
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) { cursor = step(cursor, -1) }
        var current = 0
        while days.contains(cursor) { current += 1; cursor = step(cursor, -1) }
        return (current, best)
    }

    /// Days for a month, weeks for a year, months past that: a readable number of bars.
    public static func bucketUnit(from start: Date, to end: Date) -> Calendar.Component {
        let days = end.timeIntervalSince(start) / 86_400
        return days <= 45 ? .day : days <= 400 ? .weekOfYear : .month
    }

    /// Plays per `unit` from `start` through `end`, zero-filled so a quiet week shows
    /// as a gap rather than disappearing.
    public static func series(playsByDay: [Date: Int], from start: Date, to end: Date,
                              unit: Calendar.Component, calendar: Calendar) -> [PlayPoint] {
        func bucket(_ date: Date) -> Date { calendar.dateInterval(of: unit, for: date)?.start ?? date }
        var totals: [Date: Int] = [:]
        for (day, plays) in playsByDay { totals[bucket(day), default: 0] += plays }

        var points: [PlayPoint] = []
        var cursor = bucket(start)
        while cursor <= end {
            points.append(PlayPoint(start: cursor, plays: totals[cursor] ?? 0))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor).map(bucket),
                  next > cursor else { break }
            cursor = next
        }
        return points
    }

    /// Each entry of `current` against where it sat in `previous`. Takes whole rankings,
    /// not top tens, so a climb from #14 to #3 reads ↑11 rather than NEW.
    public static func moves<Key: Hashable>(current: [Key], previous: [Key]) -> [Key: RankMove] {
        var before: [Key: Int] = [:]
        for (place, key) in previous.enumerated() where before[key] == nil { before[key] = place }
        var out: [Key: RankMove] = [:]
        for (place, key) in current.enumerated() {
            out[key] = before[key].map { .moved($0 - place) } ?? .new
        }
        return out
    }

    /// A monthly tape's order: most plays first, ties to whichever was played last.
    /// `idsNewestFirst` is the month's plays as history returns them.
    public static func tapeOrder<Key: Hashable>(_ idsNewestFirst: [Key]) -> [Key] {
        var counts: [Key: Int] = [:]
        var lastPlayed: [Key] = []
        for id in idsNewestFirst {
            if counts[id] == nil { lastPlayed.append(id) }
            counts[id, default: 0] += 1
        }
        return lastPlayed.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map(\.element)
    }

    /// Every calendar month from `first`'s through `now`'s, oldest first.
    public static func months(from first: Date, to now: Date,
                              calendar: Calendar) -> [(year: Int, month: Int)] {
        guard var cursor = calendar.dateInterval(of: .month, for: first)?.start else { return [] }
        var out: [(year: Int, month: Int)] = []
        while cursor <= now {
            let c = calendar.dateComponents([.year, .month], from: cursor)
            out.append((c.year!, c.month!))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}
