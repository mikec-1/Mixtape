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

    /// Tracks imported within the last `days` days, newest first.
    case recentlyAdded(days: Int)
    /// The `limit` most-played tracks (by play-history count), most-played first.
    case mostPlayed(limit: Int)
    /// Tracks that have never appeared in play history.
    case neverPlayed
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

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "wand.and.stars",
        rule: SmartPlaylistRule,
        dateCreated: Date = Date()
    ) {
        self.id          = id
        self.name        = name
        self.iconName    = iconName
        self.rule        = rule
        self.dateCreated = dateCreated
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
            ?? .recentlyAdded(days: 30)
    }
}

// MARK: - Rule presentation helpers

extension SmartPlaylistRule {
    /// Short human-readable description of the rule for subtitles.
    public var summary: String {
        switch self {
        case .recentlyAdded(let days):
            return "Added in the last \(days) day\(days == 1 ? "" : "s")"
        case .mostPlayed(let limit):
            return "Top \(limit) most played"
        case .neverPlayed:
            return "Never played"
        case .forgottenFavourites(let days):
            return "Loved but not played in \(days) days"
        case .fieldContains(let field, let value):
            return "\(field.displayName) contains “\(value)”"
        }
    }

    public var defaultIcon: String {
        switch self {
        case .recentlyAdded:       return "clock.badge.checkmark"
        case .mostPlayed:          return "flame.fill"
        case .neverPlayed:         return "moon.zzz.fill"
        case .forgottenFavourites: return "heart.slash.fill"
        case .fieldContains:       return "line.3.horizontal.decrease.circle.fill"
        }
    }
}
