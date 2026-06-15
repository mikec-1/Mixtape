// AppUser.swift
// Mixtape — Core Domain Models
//
// Represents the authenticated user of the app.
// The access/refresh token is managed by AuthService (never stored here).

import Foundation

public struct AppUser: Identifiable, Codable, Hashable, Sendable {

    // MARK: Identity
    /// Local UUID — mirrors the Supabase `auth.users.id` after first sign-in.
    public let id: UUID
    /// The user's email address (used for auth and display).
    public var email: String
    /// Display name shown in the UI.
    public var displayName: String
    /// Remote URL of a profile avatar image (optional; set via account settings).
    public var avatarURL: URL?
    /// Role read from Supabase `user_metadata.role`. "developer" grants access to dev tools.
    public var role: String?

    // MARK: Computed
    /// True if this user has the "developer" role set in their Supabase user_metadata.
    public var isDeveloper: Bool { role == "developer" }

    // MARK: Timestamps
    public var createdAt: Date
    public var lastLoginAt: Date

    // MARK: Preferences (local-only, not synced — device specific)
    /// Whether the user has opted into background sync on cellular.
    public var syncOnCellular: Bool
    /// Preferred audio quality for streaming/sync (reserved for future use).
    public var preferredQuality: AudioQuality

    // MARK: Init
    public init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        avatarURL: URL? = nil,
        role: String? = nil,
        createdAt: Date = Date(),
        lastLoginAt: Date = Date(),
        syncOnCellular: Bool = false,
        preferredQuality: AudioQuality = .high
    ) {
        self.id               = id
        self.email            = email
        self.displayName      = displayName
        self.avatarURL        = avatarURL
        self.role             = role
        self.createdAt        = createdAt
        self.lastLoginAt      = lastLoginAt
        self.syncOnCellular   = syncOnCellular
        self.preferredQuality = preferredQuality
    }
}

// MARK: - Supporting Types

public enum AudioQuality: String, Codable, Hashable, CaseIterable {
    case high   = "High (lossless preferred)"
    case medium = "Medium (compressed)"
    case low    = "Low (smallest file)"
}

// MARK: - Mock Convenience

#if DEBUG
extension AppUser {
    static let preview = AppUser(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        email: "demo@mixtape.app",
        displayName: "Demo User"
    )
}
#endif
