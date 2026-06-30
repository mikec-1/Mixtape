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
    public var currentStreak: Int
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
        case currentStreak = "current_streak"
        case topArtists    = "top_artists"
        case topTracks     = "top_tracks"
    }

    public var hasData: Bool { totalPlays > 0 }
}

public struct PublicPlaylistSummary: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let trackCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case trackCount = "track_count"
    }
}

// MARK: - Service

@MainActor
public final class ProfileStatsService {

    private let client: SupabaseClient
    private let stats: ListeningStatsService

    /// Opt-out flag. Defaults to true (shared) for Spotify-style discovery.
    public static let sharingDefaultsKey = "mix.stats.shared"

    public init(client: SupabaseClient, stats: ListeningStatsService) {
        self.client = client
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
            currentStreak: s.currentStreakDays,
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

    public func fetchPublicPlaylists(for userID: UUID) async throws -> [PublicPlaylistSummary] {
        let rows: [PublicPlaylistSummary] = try await client
            .rpc("get_user_public_playlists", params: ["target": userID])
            .execute()
            .value
        return rows
    }
}
