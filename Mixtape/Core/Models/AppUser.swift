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
    /// Display name shown in the UI — free-form, not unique.
    public var displayName: String
    /// The unique @handle, from `user_metadata.username`. Optional so a user
    /// cached before it existed still decodes.
    public var username: String?
    /// Remote URL of a profile avatar image (optional; set via account settings).
    public var avatarURL: URL?
    /// Role read from Supabase `user_metadata.role`. "developer" grants access to dev tools.
    public var role: String?
    /// Chosen playlist sort order, read from `user_metadata.playlist_sort_order`
    /// — the raw value of a `LibrarySortOrder`. Unlike the preferences below,
    /// this one follows the account between devices. See
    /// `PlaylistSortSyncService`.
    public var playlistSortOrder: String?
    /// Per-playlist track sort, read from `user_metadata.playlist_track_sorts`
    /// — a JSON map of playlist id → "field:direction". Follows the account
    /// like `playlistSortOrder` does. See `PlaylistTrackSortService`.
    public var playlistTrackSorts: String?
    /// Which Spotify playlists have been imported, read from
    /// `user_metadata.spotify_imports` — a JSON map of Spotify id → entry.
    /// Follows the account so a phone knows what the Mac already brought over.
    /// See `SpotifyImportLedger`.
    public var spotifyImports: String?
    /// Saved albums JSON, `user_metadata.saved_albums`. See `SavedAlbumsService`.
    public var savedAlbums: String?
    /// Which playlists follow a Spotify source, read from
    /// `user_metadata.spotify_links` — a JSON map of playlist id → link.
    /// Follows the account so signing out doesn't take the connection with it.
    /// See `SpotifyFollowService`.
    public var spotifyLinks: String?

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
        username: String? = nil,
        avatarURL: URL? = nil,
        role: String? = nil,
        playlistSortOrder: String? = nil,
        playlistTrackSorts: String? = nil,
        spotifyImports: String? = nil,
        savedAlbums: String? = nil,
        spotifyLinks: String? = nil,
        createdAt: Date = Date(),
        lastLoginAt: Date = Date(),
        syncOnCellular: Bool = false,
        preferredQuality: AudioQuality = .high
    ) {
        self.id               = id
        self.email            = email
        self.displayName      = displayName
        self.username         = username
        self.avatarURL        = avatarURL
        self.role             = role
        self.playlistSortOrder = playlistSortOrder
        self.playlistTrackSorts = playlistTrackSorts
        self.spotifyImports = spotifyImports
        self.savedAlbums = savedAlbums
        self.spotifyLinks = spotifyLinks
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
