// ProfileStatsService.swift
// Mixtape
//
// Publishes the user's listening stats to the public `profile_stats` table and
// reads back any user's stats + shared playlists. An opt-out flag mirrors to the
// `shared` column; when off we still push shared=false so RLS hides the row.

import Foundation
import Supabase

// MARK: - Public Models

public struct PublicProfileStats: Codable, Sendable {
    public let id: UUID
    public var shared: Bool
    public var totalPlays: Int
    public var uniqueTracks: Int
    public var minutes: Int
    public var topArtists: [ArtistEntry]
    public var topTracks: [TrackEntry]

    public struct ArtistEntry: Codable, Sendable, Identifiable, Hashable {
        public var id: String { name }
        public let name: String
        public let plays: Int
    }

    public struct TrackEntry: Codable, Sendable, Identifiable, Hashable {
        public var id: String { "\(title)—\(artist)" }
        public let title: String
        public let artist: String
        public let plays: Int
    }

    enum CodingKeys: String, CodingKey {
        case id
        case shared
        case totalPlays    = "total_plays"
        case uniqueTracks  = "unique_tracks"
        case minutes
        case topArtists    = "top_artists"
        case topTracks     = "top_tracks"
    }

    public var hasData: Bool { totalPlays > 0 }
}

/// One track inside a public playlist. A visitor owns none of these songs, so the
/// profile can only ever show the snapshot the owner published — this is a
/// display-only mirror of `shared_playlists.tracks`, not a playable track.
public struct PublicPlaylistTrack: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
}

public struct PublicPlaylistSummary: Codable, Identifiable, Sendable, Hashable {
    /// The `shared_playlists` row id.
    public let id: UUID
    /// The owner's local playlist id — how the owner's own device matches a
    /// published row back to the playlist in their library.
    public let playlistID: UUID
    public let name: String
    public let description: String?
    public let trackCount: Int
    /// Published snapshot, so tapping a public playlist shows songs rather than
    /// a dead end. Empty for rows published before the snapshot column existed.
    public var tracks: [PublicPlaylistTrack] = []
    /// Object path in the public `playlist-covers` bucket. Nil for a playlist
    /// with no cover, and for rows published before covers were published at all.
    public var artworkPath: String? = nil
    /// Whose playlist this is. Stamped by `fetchPublicPlaylists` rather than
    /// selected, because the RPC is already called with the owner as its argument
    /// — returning it as a column would mean changing a function signature (and
    /// so a migration) to carry a value the caller had in hand the whole time.
    ///
    /// Needed because a published song's cover lives at a path derived from the
    /// owner and the track; without this the snapshot says what the songs are but
    /// not where to find their pictures.
    public var ownerID: UUID? = nil

    /// The owner's real cover, the same image they see. Everything else the
    /// client can show is a guess.
    public var artworkURL: URL? {
        artworkPath.flatMap { PlaylistSharingService.coverURL(path: $0) }
    }

    /// The owner's cover for one song in this playlist, published alongside the
    /// playlist itself. Nil when we don't know whose playlist this is.
    public func trackArtworkURL(_ trackID: UUID) -> URL? {
        ownerID.flatMap { PlaylistSharingService.trackCoverURL(ownerID: $0, trackID: trackID) }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case playlistID = "playlist_id"
        case name
        case description
        case trackCount = "track_count"
        case tracks
        case artworkPath = "artwork_path"
    }
}

/// The owner's view of one of their published rows: which local playlist it
/// mirrors, and whether it's currently on their profile.
public struct PlaylistVisibility: Codable, Sendable, Hashable {
    public let id: UUID
    public let playlistID: UUID
    public let isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case playlistID = "playlist_id"
        case isPublic   = "is_public"
    }
}

// MARK: - Service

@MainActor
public final class ProfileStatsService {

    // Deferred for the same reason as the other Supabase services: building
    // the client costs ~1.3 s, and it must not land on the launch path.
    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    private let stats: ListeningStatsService

    /// Opt-out flag. Defaults to true (shared) for Spotify-style discovery.
    public static let sharingDefaultsKey = "mix.stats.shared"

    public init(client: @autoclosure @escaping () -> SupabaseClient, stats: ListeningStatsService) {
        self.clientProvider = client
        self.stats = stats
    }

    public var isSharingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.sharingDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.sharingDefaultsKey) }
    }

    // MARK: Publish (own stats)

    /// Computes the all-time snapshot and upserts it to `profile_stats`.
    /// Best-effort — failures are logged, never thrown into the UI.
    public func publishMyStats(userID: UUID) async {
        let shared = isSharingEnabled
        let s = stats.compute(period: .allTime)

        let row = PublicProfileStats(
            id: userID,
            shared: shared,
            totalPlays: s.totalPlays,
            uniqueTracks: s.uniqueTracks,
            minutes: s.estimatedMinutes,
            topArtists: s.topArtists.prefix(8).map {
                .init(name: $0.name, plays: $0.playCount)
            },
            topTracks: s.topTracks.prefix(8).map {
                .init(title: $0.track.title, artist: $0.track.artistName, plays: $0.playCount)
            }
        )

        do {
            try await client.from("profile_stats").upsert(row).execute()
        } catch {
            print("[ProfileStatsService] publish failed: \(error.localizedDescription)")
        }
    }

    /// Flips the sharing flag and re-publishes so the change takes effect remotely.
    public func setSharing(_ enabled: Bool, userID: UUID) async {
        isSharingEnabled = enabled
        await publishMyStats(userID: userID)
    }

    // MARK: Fetch (any user)

    public func fetchStats(for userID: UUID) async throws -> PublicProfileStats? {
        let rows: [PublicProfileStats] = try await client.from("profile_stats")
            .select()
            .eq("id", value: userID)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The playlists `userID` has chosen to show on their profile. Goes through a
    /// SECURITY DEFINER RPC because shared_playlists is member-only readable —
    /// a visitor is not a member, and shouldn't become one just by looking.
    public func fetchPublicPlaylists(for userID: UUID) async throws -> [PublicPlaylistSummary] {
        let rows: [PublicPlaylistSummary] = try await client
            .rpc("get_user_public_playlists", params: ["target": userID])
            .execute()
            .value
        // Every row belongs to the user we just asked about, so the owner is known
        // here and nowhere downstream. See `PublicPlaylistSummary.ownerID`.
        return rows.map { var row = $0; row.ownerID = userID; return row }
    }

    // MARK: Visibility (own playlists)

    /// Every published row the signed-in user owns, keyed by the LOCAL playlist id
    /// so a library view can ask "is this one public?" without a second lookup.
    /// Reads the table directly — the owner policy already allows it.
    public func fetchMyPlaylistVisibility(userID: UUID) async throws -> [UUID: PlaylistVisibility] {
        let rows: [PlaylistVisibility] = try await client
            .from("shared_playlists")
            .select("id,playlist_id,is_public")
            .eq("owner_id", value: userID)
            .eq("is_deleted", value: false)
            .execute()
            .value

        // A playlist shared more than once would collide; the newest row wins,
        // which matches what the profile query orders by.
        return Dictionary(rows.map { ($0.playlistID, $0) }, uniquingKeysWith: { _, b in b })
    }
}
