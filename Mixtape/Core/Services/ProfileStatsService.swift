// Publishes listening stats to `profile_stats` and reads back any user's stats
// and shared playlists. When opted out we still push shared=false so RLS hides the row.

import Foundation
import Supabase
import OSLog

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

/// A song in a public playlist. Display-only snapshot of `shared_playlists.tracks`.
public struct PublicPlaylistTrack: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public var sourceKey: String? = nil
    public var edit: SongEdit? = nil
}

public struct PublicPlaylistSummary: Codable, Identifiable, Sendable, Hashable {
    /// The `shared_playlists` row id.
    public let id: UUID
    /// The owner's local playlist id, used to match the row back on their device.
    public let playlistID: UUID
    public let name: String
    public let description: String?
    public let trackCount: Int
    /// Published snapshot. Empty for rows from before the column existed.
    public var tracks: [PublicPlaylistTrack] = []
    /// Path in the public `playlist-covers` bucket. Nil when there's no cover.
    public var artworkPath: String? = nil
    /// Stamped by `fetchPublicPlaylists` (the RPC already takes the owner). Needed
    /// to build per-song cover paths.
    public var ownerID: UUID? = nil
    /// Set by `fetchPublicSummary`. Not a column, so not in CodingKeys.
    public var isDub = false

    /// The owner's real cover, the same image they see. Everything else the
    /// client can show is a guess.
    public var artworkURL: URL? {
        artworkPath.flatMap { PlaylistSharingService.coverURL(path: $0) }
    }

    /// The owner's published cover for one song. Nil when the owner is unknown.
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

/// Which local playlist a published row mirrors, and whether it's on the profile.
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

    // Deferred: building the client is slow and must stay off the launch path.
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

    /// Computes the all-time snapshot and upserts it. Best-effort, only logs failures.
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
            MixLog.library.error("[ProfileStatsService] publish failed: \(error.localizedDescription)")
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

    /// Playlists `userID` shows on their profile, via a SECURITY DEFINER RPC since
    /// shared_playlists is member-only readable.
    public func fetchPublicPlaylists(for userID: UUID) async throws -> [PublicPlaylistSummary] {
        let rows: [PublicPlaylistSummary] = try await client
            .rpc("get_user_public_playlists", params: ["target": userID])
            .execute()
            .value
        return rows.map { var row = $0; row.ownerID = userID; return row }
    }

    // MARK: Visibility (own playlists)

    /// The signed-in user's published rows, keyed by local playlist id.
    public func fetchMyPlaylistVisibility(userID: UUID) async throws -> [UUID: PlaylistVisibility] {
        let rows: [PlaylistVisibility] = try await client
            .from("shared_playlists")
            .select("id,playlist_id,is_public")
            .eq("owner_id", value: userID)
            .eq("is_deleted", value: false)
            .execute()
            .value

        // Duplicates: newest wins, matching the profile query's order.
        return Dictionary(rows.map { ($0.playlistID, $0) }, uniquingKeysWith: { _, b in b })
    }
}
