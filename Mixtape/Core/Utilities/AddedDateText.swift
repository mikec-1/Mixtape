// AddedDateText.swift
// Mixtape — Core/Utilities
//
// The "Date added" column's wording.
//
// A date on its own is precise and almost never what the question was. Nobody
// scanning a playlist wants to know that a song arrived on 14 August; they want
// to know whether it is new. So the column answers that instead — "2 days ago",
// "Last week" — and keeps the exact stamp on the tooltip for the rare visit
// where the date itself is the point.
//
// Deliberately not live. Nothing here schedules a timer, observes a clock, or
// asks to be recomputed: a string is worked out when a row happens to draw and
// then left alone. A list of two thousand songs ticking once a second would be
// two thousand redraws a second to move one word, which is a lot of battery for
// a column nobody is watching. The cost of that choice is a row that has been on
// screen for an hour still saying "1 hour ago", and the wording below is picked
// so that staleness never shows: the bands are wide, and the one band that would
// visibly rot within a minute — a seconds count — is a fixed word instead.

import Foundation

/// How long ago a song was added, in words.
public enum AddedDateText {

    /// Stored rather than reached for per row. `Calendar.current` builds a fresh
    /// value every time it is read, and this runs once per visible row per draw.
    /// The autoupdating one still follows a locale or time-zone change.
    private static let calendar = Calendar.autoupdatingCurrent

    /// The column's text.
    ///
    /// `now` is a parameter so a caller formatting a whole page can pass one
    /// timestamp and have every row agree with every other, rather than each row
    /// reading its own slightly later clock.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)

        // Anything at or after `now` is a clock that disagrees — a row written
        // on another device a moment ago, or a daylight-saving shift — not a
        // song from the future. It reads as brand new, which it is.
        guard seconds >= 60 else { return "Just now" }

        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) min ago"
        }

        // Hours rather than "Yesterday" for the whole first day, so a song added
        // at 11pm doesn't jump to a different vocabulary an hour later just
        // because midnight passed.
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        // Whole days between the two *calendar days*, not the raw interval, so
        // "3 days ago" means three sleeps rather than 72 hours.
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to:   calendar.startOfDay(for: now)).day ?? 0
        if days < 7  { return "\(days) days ago" }
        if days < 14 { return "Last week" }
        if days < 35 { return "\(days / 7) weeks ago" }

        // Months from the calendar, because they are not all the same length.
        let months = calendar.dateComponents([.month], from: date, to: now).month ?? 0
        if months <= 1  { return "Last month" }
        if months < 12  { return "\(months) months ago" }

        // Past a year "14 months ago" is arithmetic the reader has to do. The
        // month and year is shorter to read and says more.
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// The full stamp, for the tooltip and for VoiceOver — everything the
    /// wording above rounds off.
    public static func exact(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    /// Both, for a screen reader: the phrase the sighted reader sees, then the
    /// date it stands for.
    public static func accessibleLabel(_ date: Date, now: Date = Date()) -> String {
        "Added \(relative(date, now: now)), \(exact(date))"
    }
}
