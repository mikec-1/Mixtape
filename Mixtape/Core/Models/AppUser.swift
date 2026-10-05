// The signed-in user. Tokens live in AuthService, not here.

import Foundation

public struct AppUser: Identifiable, Codable, Hashable, Sendable {

    // MARK: Identity
    /// Matches Supabase auth.users.id.
    public let id: UUID
    /// The user's email address (used for auth and display).
    public var email: String
    /// Free-form, not unique.
    public var displayName: String
    /// Unique handle from user_metadata.username.
    public var username: String?
    /// Remote URL of a profile avatar image (optional; set via account settings).
    public var avatarURL: URL?
    /// From user_metadata.role. "developer" unlocks dev tools.
    public var role: String?
    /// Playlist sort order, synced via user_metadata. See PlaylistSortSyncService.
    public var playlistSortOrder: String?
    /// Per-playlist track sorts, synced via user_metadata.
    public var playlistTrackSorts: String?
    /// Per-playlist transitions, synced via user_metadata. See PlaylistTransitionService.
    public var playlistTransitions: String?
    /// Imported Spotify playlists, synced via user_metadata. See SpotifyImportLedger.
    public var spotifyImports: String?
    /// Saved albums JSON, `user_metadata.saved_albums`. See `SavedAlbumsService`.
    public var savedAlbums: String?
    /// Crates JSON, `user_metadata.crates`. See `CrateService`.
    public var crates: String?
    /// Playlists following a Spotify source, synced via user_metadata.
    public var spotifyLinks: String?
    /// Background colour, `user_metadata.backdrop`. See `MixBackdrop`.
    public var backdrop: String?
    /// `user_metadata.show_all_songs`. See `PlaylistMetadataService.showsAllSongs`.
    public var showsAllSongs: Bool?
    /// `user_metadata.imports_to`. See `PlaylistMetadataService.importDestination`.
    public var importsTo: String?
    /// `user_metadata.analytics_opt_in`, so one choice (often made on the web) covers every device.
    public var analyticsOptIn: Bool?

    // MARK: Computed
    /// True if this user has the "developer" role set in their Supabase user_metadata.
    public var isDeveloper: Bool { role == "developer" }

    // MARK: Timestamps
    public var createdAt: Date
    public var lastLoginAt: Date

    // MARK: Preferences (local-only, not synced, device specific)
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
        playlistTransitions: String? = nil,
        spotifyImports: String? = nil,
        savedAlbums: String? = nil,
        crates: String? = nil,
        spotifyLinks: String? = nil,
        backdrop: String? = nil,
        showsAllSongs: Bool? = nil,
        importsTo: String? = nil,
        analyticsOptIn: Bool? = nil,
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
        self.playlistTransitions = playlistTransitions
        self.spotifyImports = spotifyImports
        self.savedAlbums = savedAlbums
        self.crates = crates
        self.spotifyLinks = spotifyLinks
        self.backdrop = backdrop
        self.showsAllSongs = showsAllSongs
        self.importsTo = importsTo
        self.analyticsOptIn = analyticsOptIn
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
