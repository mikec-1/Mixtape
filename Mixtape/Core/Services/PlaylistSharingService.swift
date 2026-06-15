// PlaylistSharingService.swift
// Mixtape — Core/Services
//
// Two share paths:
// • M3U export — delegates to M3UExporter.
// • Supabase collaborative sharing — matches the
//   20260613_collaborative_playlists.sql migration, which must be applied (with
//   an RLS review) before going live. Realtime collaborative editing is deferred.

import Foundation
import Combine
import Supabase

@MainActor
public final class PlaylistSharingService: ObservableObject {

    public static let shared = PlaylistSharingService()

    private var client: SupabaseClient { SupabaseConfig.client }

    private init() {}

    // MARK: - M3U sharing

    /// Writes `playlist` to a temporary `.m3u8` file and returns its URL, ready to
    /// hand to a platform share sheet (UIActivityViewController / NSSharingService).
    public func exportM3U(playlist: Playlist, tracks: [Track]) throws -> URL {
        try M3UExporter.writeTemporaryFile(playlist: playlist, resolving: tracks)
    }

    /// Returns the playlist as M3U text (for share-as-text call sites).
    public func m3uText(playlist: Playlist, tracks: [Track]) -> String {
        M3UExporter.shareableText(playlist: playlist, resolving: tracks)
    }

    // MARK: - Supabase collaborative sharing

    /// A metadata SNAPSHOT of a single track, carried in the shared row so a joining
    /// device that doesn't have the song locally can still display it.
    public struct SharedTrackMeta: Codable, Identifiable, Sendable, Hashable {
        public let id: UUID
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval

        public init(id: UUID, title: String, artist: String, album: String, duration: TimeInterval) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }

        public init(track: Track) {
            self.id = track.id
            self.title = track.title
            self.artist = track.artistName
            self.album = track.albumTitle
            self.duration = track.duration
        }
    }

    /// Row shape mirroring public.shared_playlists.
    public struct SharedPlaylistRecord: Codable, Identifiable, Sendable {
        public let id: UUID
        public let playlistId: UUID
        public let ownerId: UUID
        public var name: String
        public var description: String?
        public var trackIds: [UUID]
        public var tracks: [SharedTrackMeta]
        public var shareCode: String
        public var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case playlistId  = "playlist_id"
            case ownerId     = "owner_id"
            case name
            case description
            case trackIds    = "track_ids"
            case tracks
            case shareCode   = "share_code"
            case updatedAt   = "updated_at"
        }

        public init(
            id: UUID,
            playlistId: UUID,
            ownerId: UUID,
            name: String,
            description: String?,
            trackIds: [UUID],
            tracks: [SharedTrackMeta],
            shareCode: String,
            updatedAt: Date
        ) {
            self.id = id
            self.playlistId = playlistId
            self.ownerId = ownerId
            self.name = name
            self.description = description
            self.trackIds = trackIds
            self.tracks = tracks
            self.shareCode = shareCode
            self.updatedAt = updatedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id          = try c.decode(UUID.self, forKey: .id)
            playlistId  = try c.decode(UUID.self, forKey: .playlistId)
            ownerId     = try c.decode(UUID.self, forKey: .ownerId)
            name        = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            trackIds    = try c.decodeIfPresent([UUID].self, forKey: .trackIds) ?? []
            // `tracks` is a newer column; tolerate rows that predate it.
            tracks      = try c.decodeIfPresent([SharedTrackMeta].self, forKey: .tracks) ?? []
            shareCode   = try c.decode(String.self, forKey: .shareCode)
            updatedAt   = try c.decode(Date.self, forKey: .updatedAt)
        }
    }

    /// The persisted association between a LOCAL playlist and its shared_playlists row.
    public struct LinkedShare: Codable, Sendable {
        public let sharedPlaylistID: UUID
        public let shareCode: String
        public let role: String   // "owner" | "editor"
    }

    /// Publishes `playlist` to public.shared_playlists and returns the generated
    /// share code that another user supplies to `joinSharedPlaylist`. The resolved
    /// `tracks` are stored as a metadata snapshot so joiners who don't have the songs
    /// locally can still display the playlist contents.
    /// Requires the collaborative-playlists migration applied + RLS review.
    @discardableResult
    public func shareToSupabase(playlist: Playlist, tracks: [Track], deviceID: String) async throws -> String {
        let session = try await client.auth.session
        let ownerId = session.user.id
        let shareCode = Self.generateShareCode()

        let record = SharedPlaylistRecord(
            id: UUID(),
            playlistId: playlist.id,
            ownerId: ownerId,
            name: playlist.name,
            description: playlist.description,
            trackIds: playlist.trackIDs,
            tracks: Self.snapshot(playlist: playlist, resolving: tracks),
            shareCode: shareCode,
            updatedAt: Date()
        )

        try await client
            .from("shared_playlists")
            .insert(record)
            .execute()

        // Remember the association so future edits can be pushed back (Issue 3).
        setLinkedShare(
            LinkedShare(sharedPlaylistID: record.id, shareCode: shareCode, role: "owner"),
            forLocalPlaylist: playlist.id
        )

        // The owner is implicitly a member via owner_id; an explicit collaborator
        // row for the owner is optional and left to the realtime follow-up.
        return shareCode
    }

    /// Builds the ordered track metadata snapshot for a playlist from resolved tracks.
    /// Preserves the playlist's track order; tracks not present in `resolving` are skipped.
    private static func snapshot(playlist: Playlist, resolving tracks: [Track]) -> [SharedTrackMeta] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackIDs.compactMap { id in
            byID[id].map { SharedTrackMeta(track: $0) }
        }
    }

    /// Redeems `shareCode` via the `join_shared_playlist` SECURITY DEFINER RPC,
    /// which validates the code and registers the current user as an editor in one
    /// atomic call (no broad read access to shared_playlists is needed — this avoids
    /// share-code enumeration). Returns the joined record for the caller to
    /// materialise into the local library.
    @discardableResult
    public func joinSharedPlaylist(shareCode: String) async throws -> SharedPlaylistRecord {
        struct Params: Encodable { let p_share_code: String }

        do {
            let record: SharedPlaylistRecord = try await client
                .rpc("join_shared_playlist", params: Params(p_share_code: shareCode))
                .single()
                .execute()
                .value
            return record
        } catch {
            // The RPC raises P0002 when no playlist matches the code.
            throw SharingError.notFound
        }
    }

    // MARK: - Re-pull / push (Issue 3 — cross-device updates)

    /// Re-pulls the latest shared row by share code. Goes through the same
    /// SECURITY DEFINER RPC as join so a member can refresh without needing broad
    /// SELECT access (and joining is idempotent on the collaborator row).
    public func fetchSharedPlaylist(shareCode: String) async throws -> SharedPlaylistRecord {
        try await joinSharedPlaylist(shareCode: shareCode)
    }

    /// Pushes a full update (name?/tracks/track_ids + bumped updatedAt) for a shared
    /// playlist. The DB column-guard trigger restricts non-owners to the editable
    /// content columns, so editors can push track changes while owner-only fields are
    /// protected server-side. LWW: `updated_at` is client-controlled and bumped here.
    public func pushUpdate(record: SharedPlaylistRecord) async throws {
        struct UpdatePayload: Encodable {
            let name: String
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let updated_at: Date
        }

        let payload = UpdatePayload(
            name: record.name,
            track_ids: record.trackIds,
            tracks: record.tracks,
            updated_at: Date()
        )

        try await client
            .from("shared_playlists")
            .update(payload)
            .eq("id", value: record.id.uuidString)
            .execute()
    }

    // MARK: - Local ↔ shared link persistence

    private func linkDefaultsKey(_ localPlaylistID: UUID) -> String {
        "sharedPlaylistLink.\(localPlaylistID.uuidString)"
    }

    /// The persisted association for a local playlist, if it was shared or joined.
    public func linkedShare(forLocalPlaylist localPlaylistID: UUID) -> LinkedShare? {
        guard let data = UserDefaults.standard.data(forKey: linkDefaultsKey(localPlaylistID)) else {
            return nil
        }
        return try? JSONDecoder().decode(LinkedShare.self, from: data)
    }

    /// Stores (or clears, when `nil`) the association between a local playlist and
    /// its shared row.
    public func setLinkedShare(_ link: LinkedShare?, forLocalPlaylist localPlaylistID: UUID) {
        let key = linkDefaultsKey(localPlaylistID)
        if let link, let data = try? JSONEncoder().encode(link) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// If `localPlaylistID` is linked to a shared row, re-pulls the latest snapshot
    /// and reconciles the local track list to match it (LWW on updatedAt — same model
    /// as the existing playlist sync). Tracks present locally are linked; tracks that
    /// aren't are imported as unavailable placeholders so the playlist isn't empty.
    /// No-op if the playlist isn't linked or the user isn't signed in.
    public func refreshSharedPlaylist(localPlaylistID: UUID, libraryService: LibraryService) async {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID) else { return }
        guard let remote = try? await fetchSharedPlaylist(shareCode: link.shareCode) else { return }

        guard let local = libraryService.playlist(id: localPlaylistID) else { return }

        // LWW: only adopt the remote list if it's at least as new as our local copy.
        guard remote.updatedAt >= local.dateModified else { return }

        libraryService.reconcileSharedPlaylist(
            localPlaylistID: localPlaylistID,
            remoteTrackIDs: remote.trackIds,
            remoteTrackMeta: remote.tracks
        )
    }

    // MARK: - Errors

    public enum SharingError: LocalizedError {
        case notFound

        public var errorDescription: String? {
            switch self {
            case .notFound: return "No shared playlist found for that code."
            }
        }
    }

    // MARK: - Helpers

    /// A short, human-shareable code (uppercase, no ambiguous chars).
    private static func generateShareCode() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // no 0/O/1/I
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
