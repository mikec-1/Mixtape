// listening-trends-check.swift
// Mixtape — scripts
//
// The one check on the stats page's streak, series and movement maths. No test
// target, so this compiles standalone against the real source file:
//
//   xcrun swiftc Mixtape/Core/Services/ListeningTrends.swift \
//       scripts/listening-trends-check.swift -o /tmp/trendcheck && /tmp/trendcheck

import Foundation

@main
struct ListeningTrendsCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!   // crosses a DST change below
        func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }

        // Streaks: a 3-day run ending yesterday is still current when today is empty,
        // and the best run spans the October clock change.
        let today = day(2026, 11, 10)
        let played: Set<Date> = [day(2026, 10, 24), day(2026, 10, 25, 23), day(2026, 10, 26, 1),
                                 day(2026, 10, 27), day(2026, 11, 7), day(2026, 11, 8), day(2026, 11, 9)]
        let s = ListeningTrends.streaks(days: played, today: today, calendar: cal)
        assert(s.current == 3, "run ending yesterday counts: \(s)")
        assert(s.best == 4, "best run across DST: \(s)")
        assert(ListeningTrends.streaks(days: played, today: day(2026, 11, 12), calendar: cal).current == 0,
               "a missed day breaks the streak")
        assert(ListeningTrends.streaks(days: [], today: today, calendar: cal) == (0, 0))

        // Series: zero-filled, one bar per day, totals preserved.
        let byDay = [cal.startOfDay(for: day(2026, 9, 1)): 4, cal.startOfDay(for: day(2026, 9, 3)): 2]
        let daily = ListeningTrends.series(playsByDay: byDay, from: day(2026, 9, 1), to: day(2026, 9, 5),
                                           unit: .day, calendar: cal)
        assert(daily.map(\.plays) == [4, 0, 2, 0, 0], "\(daily.map(\.plays))")
        let weekly = ListeningTrends.series(playsByDay: byDay, from: day(2026, 1, 1), to: day(2026, 12, 31),
                                            unit: .weekOfYear, calendar: cal)
        assert(weekly.map(\.plays).reduce(0, +) == 6 && (52...54).contains(weekly.count), "\(weekly.count)")
        assert(ListeningTrends.bucketUnit(from: day(2026, 8, 26), to: day(2026, 9, 25)) == .day)
        assert(ListeningTrends.bucketUnit(from: day(2026, 1, 1), to: day(2026, 12, 31)) == .weekOfYear)
        assert(ListeningTrends.bucketUnit(from: day(2023, 1, 1), to: day(2026, 9, 25)) == .month)

        // Movement: whole rankings, so a deep climb is a number, not NEW.
        let previous = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n"]
        let moves = ListeningTrends.moves(current: ["n", "a", "z", "b"], previous: previous)
        assert(moves["n"] == .moved(13), "climbed from #14 to #1")
        assert(moves["a"] == .moved(-1), "fell one place")
        assert(moves["z"] == .new)
        assert(moves["b"] == .moved(-2))

        print("listening-trends-check: all passed")
    }
}
