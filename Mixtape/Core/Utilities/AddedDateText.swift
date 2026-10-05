// Wording for the "Date added" column: relative ("2 days ago", "Last week"),
// with the exact date in the tooltip. Computed at draw time, never live-updated,
// so the bands are wide enough that staleness doesn't show.

import Foundation

/// How long ago a song was added, in words.
public enum AddedDateText {

    /// Cached; `Calendar.current` allocates on every read. Autoupdating still follows locale changes.
    private static let calendar = Calendar.autoupdatingCurrent

    /// The column text. Pass one `now` for a whole page so rows agree.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)

        // Future dates (clock skew) read as "Just now".
        guard seconds >= 60 else { return "Just now" }

        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) min ago"
        }

        // Hours for the whole first day, so crossing midnight doesn't switch wording.
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        // Calendar days, not 24h blocks.
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

        // Past a year, "Mar 2024" beats "14 months ago".
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// Full date for tooltips and VoiceOver.
    public static func exact(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    /// Relative phrase plus the exact date, for VoiceOver.
    public static func accessibleLabel(_ date: Date, now: Date = Date()) -> String {
        "Added \(relative(date, now: now)), \(exact(date))"
    }
}
