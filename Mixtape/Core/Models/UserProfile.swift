// UserProfile.swift
// Mixtape
//
// The world-readable `profiles` row — handle, avatar, etc. Unlike AppUser (the
// signed-in user, with private fields like email), this is what other people see.

import Foundation

public struct UserProfile: Identifiable, Codable, Hashable, Sendable {

    /// Mirrors `auth.users.id` / `profiles.id`.
    public let id: UUID
    /// Unique, lowercased handle.
    public var username: String
    /// Free-form name, not unique. Nil when never set — use `name` to show it.
    public var displayName: String?
    /// Public URL of the user's avatar (nil if they haven't set one).
    public var avatarURL: URL?
    /// Account creation date ("member since"), nil if unknown.
    public var createdAt: Date?

    /// What to call this person: their display name, or the handle until they set one.
    public var name: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? username : trimmed
    }

    public init(id: UUID, username: String, displayName: String? = nil, avatarURL: URL? = nil, createdAt: Date? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }

    // Decodes directly from a `profiles` row.
    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.username = try c.decode(String.self, forKey: .username)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        // avatar_url may be null or a non-URL string; decode defensively.
        if let raw = try c.decodeIfPresent(String.self, forKey: .avatarURL),
           !raw.isEmpty {
            self.avatarURL = URL(string: raw)
        } else {
            self.avatarURL = nil
        }
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarURL?.absoluteString, forKey: .avatarURL)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

#if DEBUG
extension UserProfile {
    static let previews: [UserProfile] = [
        UserProfile(id: UUID(), username: "rico"),
        UserProfile(id: UUID(), username: "mareep"),
        UserProfile(id: UUID(), username: "synthwave_sam")
    ]
}
#endif
