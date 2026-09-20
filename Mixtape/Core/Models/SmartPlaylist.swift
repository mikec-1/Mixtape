// SmartPlaylist.swift
// Mixtape — Core Domain Models
//
// A SmartPlaylist is a local-only, auto-updating playlist defined by a single
// rule that is evaluated live against the current library, play history and
// favourites. Unlike a regular Playlist it stores no track IDs — its contents
// are resolved on demand by SmartPlaylistService.
//
// Minimum deployment: iOS 17 / macOS 14

import Foundation

// MARK: - SmartPlaylistRule

/// The rule that drives a smart playlist. Codable so it can be persisted as
/// `Data` on the SwiftData entity.
public enum SmartPlaylistRule: Codable, Hashable, Sendable {

    /// The `limit` newest additions to the library, newest first.
    ///
    /// A count, not a date window: a library that arrived in one Spotify import
    /// shares a single import date, so "the last 30 days" was either everything
    /// or nothing. The newest N is right in both cases.
    case recentlyAdded(limit: Int)
    /// The `limit` most-played tracks (by play-history count), most-played first.
    case mostPlayed(limit: Int)
    /// Tracks that have never appeared in play history.
    case neverPlayed
    /// The songs played most often in the recent history window — what's in
    /// rotation now, as opposed to `mostPlayed`, which is all-time.
    case onRepeat(limit: Int)
    /// Favourited tracks not played within the last `days` days.
    case forgottenFavourites(days: Int)
    /// Simple metadata filter: the chosen field contains `value` (case-insensitive).
    case fieldContains(field: Field, value: String)

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
        }
    }

    /// A sentence for the playlist page and the Home card — the same job a
    /// hand-written playlist description does. `summary` states the rule;
    /// this says what the playlist is *for*.
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
        }
    }

    /// Whether this rule's list is re-dealt each week.
    ///
    /// Only the two open-ended ones. `recentlyAdded` is ordered by date and
    /// `mostPlayed`/`onRepeat` are ordered by rank — shuffling any of those
    /// would make the playlist disagree with its own name. "Never played" and
    /// "Forgotten favourites" match hundreds of songs and show a hundred, so
    /// without a redeal the other hundreds are never seen at all.
    public var rotatesWeekly: Bool {
        switch self {
        case .neverPlayed, .forgottenFavourites: return true
        default:                                 return false
        }
    }

    public var defaultIcon: String {
        switch self {
        case .recentlyAdded:       return "clock.badge.checkmark"
        case .mostPlayed:          return "flame.fill"
        case .neverPlayed:         return "moon.zzz.fill"
        case .onRepeat:            return "repeat"
        case .forgottenFavourites: return "heart.slash.fill"
        case .fieldContains:       return "line.3.horizontal.decrease.circle.fill"
        }
    }
}
