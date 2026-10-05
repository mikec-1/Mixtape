// A rule-based playlist evaluated live against the library. Stores no track ids.

import Foundation

// MARK: - SmartPlaylistRule

public enum SmartPlaylistRule: Codable, Hashable, Sendable {

    /// The newest additions. A count, not a date window, since an import
    /// gives everything the same date.
    case recentlyAdded(limit: Int)
    /// The `limit` most-played tracks (by play-history count), most-played first.
    case mostPlayed(limit: Int)
    /// Tracks that have never appeared in play history.
    case neverPlayed
    /// Most played recently, as opposed to all-time `mostPlayed`.
    case onRepeat(limit: Int)
    /// Favourited tracks not played within the last `days` days.
    case forgottenFavourites(days: Int)
    /// Simple metadata filter: the chosen field contains `value` (case-insensitive).
    case fieldContains(field: Field, value: String)
    /// The most played songs of one calendar month. Frozen once the month ends,
    /// since its plays can't change.
    case monthTape(year: Int, month: Int)

    /// Metadata fields supported by `.fieldContains`.
    public enum Field: String, Codable, Hashable, Sendable, CaseIterable {
        case genre
        case artist
        case year

        public var displayName: String {
            switch self {
            case .genre:  return "Genre"
            case .artist: return "Artist"
            case .year:   return "Year"
            }
        }
    }
}

// MARK: - SmartPlaylist

public struct SmartPlaylist: Identifiable, Hashable, Sendable {

    public let id: UUID
    public var name: String
    /// SF Symbol name shown in the UI.
    public var iconName: String
    public var rule: SmartPlaylistRule
    public var dateCreated: Date
    /// Listed in Your Library (and the Mac sidebar). See the entity.
    public var inLibrary: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "wand.and.stars",
        rule: SmartPlaylistRule,
        dateCreated: Date = Date(),
        inLibrary: Bool = false
    ) {
        self.id          = id
        self.name        = name
        self.iconName    = iconName
        self.rule        = rule
        self.dateCreated = dateCreated
        self.inLibrary   = inLibrary
    }
}

// MARK: - Rule Codable payload

extension SmartPlaylist {
    /// Encodes the rule to JSON `Data` for persistence on the entity.
    public func encodedRule() -> Data {
        (try? JSONEncoder().encode(rule)) ?? Data()
    }

    /// Decodes a rule from persisted `Data`, defaulting to a harmless rule.
    public static func decodeRule(_ data: Data) -> SmartPlaylistRule {
        (try? JSONDecoder().decode(SmartPlaylistRule.self, from: data))
            ?? .recentlyAdded(limit: 50)
    }
}

// MARK: - Rule presentation helpers

extension SmartPlaylistRule {
    /// Short human-readable description of the rule for subtitles.
    public var summary: String {
        switch self {
        case .recentlyAdded(let limit):
            return "The \(limit) newest additions"
        case .mostPlayed(let limit):
            return "Top \(limit) most played"
        case .neverPlayed:
            return "Never played"
        case .onRepeat(let limit):
            return "Your \(limit) most-played lately"
        case .forgottenFavourites(let days):
            return "Loved but not played in \(days) days"
        case .fieldContains(let field, let value):
            return "\(field.displayName) contains “\(value)”"
        case .monthTape:
            return "Top \(Self.tapeLength) of \(tapeStart?.formatted(.dateTime.month(.wide).year()) ?? "the month")"
        }
    }

    /// What the playlist is for, where `summary` states the rule.
    public var blurb: String {
        switch self {
        case .recentlyAdded:
            return "Everything you've added to Mixtape lately, newest first."
        case .mostPlayed:
            return "The songs you've played more than any others."
        case .neverPlayed:
            return "Sitting in your library, never once played. A new selection every Monday."
        case .forgottenFavourites:
            return "Songs you loved and then stopped playing. A new selection every Monday."
        case .onRepeat:
            return "What you've had on repeat recently."
        case .fieldContains:
            return summary
        case .monthTape:
            let month = tapeStart ?? Date()
            return Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month)
                ? "Your most played this month, filling as you listen. Freezes on the 1st."
                : "Your most played in \(month.formatted(.dateTime.month(.wide).year()))."
        }
    }

    /// Only the open-ended rules reshuffle weekly. Ranked ones would contradict their name.
    public var rotatesWeekly: Bool {
        switch self {
        case .neverPlayed, .forgottenFavourites: return true
        default:                                 return false
        }
    }

    /// Seeds the weekly deal. Web builds the same string.
    var dealKey: String {
        if case .forgottenFavourites(let days) = self { return "forgottenFavourites:\(days)" }
        return "neverPlayed"
    }

    public var defaultIcon: String {
        switch self {
        case .recentlyAdded:       return "clock.badge.checkmark"
        case .mostPlayed:          return "flame.fill"
        case .neverPlayed:         return "moon.zzz.fill"
        case .onRepeat:            return "repeat"
        case .forgottenFavourites: return "heart.slash.fill"
        case .fieldContains:       return "line.3.horizontal.decrease.circle.fill"
        case .monthTape:           return "calendar"
        }
    }

    /// Songs on a monthly tape.
    public static let tapeLength = 25

    /// A tape's month as its first day. Nil for every other rule.
    public var tapeStart: Date? {
        guard case .monthTape(let year, let month) = self else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month))
    }
}
