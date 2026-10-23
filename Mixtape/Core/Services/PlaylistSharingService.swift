// Two share paths:
// - M3U export, via M3UExporter.
// - Supabase collaborative sharing (20260613_collaborative_playlists.sql and
// 20260807000000_fix_shared_playlist_policy_recursion.sql).
// Collaboration is two-way but not live: edits go up on edit (`pushLocalChanges`) and come down on open
// (`refreshSharedPlaylist`), last-write-wins on the whole track array.

import Foundation
import Combine
import Supabase
import OSLog
import Observation

@Observable
@MainActor
public final class PlaylistSharingService {

    public static let shared = PlaylistSharingService()

    private var client: SupabaseClient { SupabaseConfig.client }

    private init() {}

    // MARK: - M3U sharing

    /// Writes `playlist` to a temporary `.m3u8` file for a platform share sheet.
    public func exportM3U(playlist: Playlist, tracks: [Track]) throws -> URL {
        try M3UExporter.writeTemporaryFile(playlist: playlist, resolving: tracks)
    }

    /// Returns the playlist as M3U text (for share-as-text call sites).
    public func m3uText(playlist: Playlist, tracks: [Track]) -> String {
        M3UExporter.shareableText(playlist: playlist, resolving: tracks)
    }

    // MARK: - Supabase collaborative sharing

    /// Metadata snapshot of a track, so a device without the song can still show it.
    public struct SharedTrackMeta: Codable, Identifiable, Sendable, Hashable {
        public let id: UUID
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval
        /// The `"title|artist"` key this song can be found online under, sent by the device that knows it.
        /// Recomputing it from title and artist (`LibraryService.onlineKey(for:)`) fails once enrichment or an
        /// edit has changed them. Nil on older rows, so the recomputation stays as a fallback.
        public var sourceKey: String?
        /// Set for an edit, so the recipient renders it from their own copy of the original.
        public var edit: SongEdit?

        enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration, edit
            case sourceKey = "source_key"
        }

        public init(id: UUID,
                    title: String,
                    artist: String,
                    album: String,
                    duration: TimeInterval,
                    sourceKey: String? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.sourceKey = sourceKey
        }

        public init(track: Track) {
            self.id = track.id
            self.title = track.title
            self.artist = track.artistName
            self.album = track.albumTitle
            self.duration = track.duration
            self.sourceKey = Self.onlineKey(for: track)
            self.edit = track.edit
        }

        /// The online key for a track when there is one; nil for a ripped local file.
        private static func onlineKey(for track: Track) -> String? {
            // An unsaved Discover track carries the key in `fileHash` (`OnlineTrack.asTrack`), which survives
            // a rename.
            if track.isOnline, track.file.fileHash.contains("|") {
                return track.file.fileHash
            }
            // A saved one has a real content hash there, but its id is the SHA-256 of the key. Both title
            // spellings are tried (see `Track.identityTitle`); only a candidate hashing to this id is returned.
            return OnlineTrack.identityKey(title: track.title,
                                           artistName: track.artistName,
                                           matching: track.id)
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
        /// The cover's path in the public `playlist-covers` bucket, or nil. Decoded only: the column is
        /// owner-guarded server-side, so a collaborator write would be reverted.
        public var artworkPath: String?
        /// Set on dubs, from `get_public_playlist`. Decoded only: a dub row is frozen.
        public var dubFor: String?
        public var dubNote: String?

        /// Nil from a row that predates the column, which leaves local notes alone.
        public var notes: PlaylistNotes?

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
            case artworkPath = "artwork_path"
            case notes
            case dubFor      = "dub_for"
            case dubNote     = "dub_note"
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
            updatedAt: Date,
            artworkPath: String? = nil,
            notes: PlaylistNotes? = nil
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
            self.artworkPath = artworkPath
            self.notes = notes
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
            // Absent from `get_public_playlist`: saving a public playlist mustn't grant editor access. No code
            // means read-only.
            shareCode   = try c.decodeIfPresent(String.self, forKey: .shareCode) ?? ""
            updatedAt   = try c.decode(Date.self, forKey: .updatedAt)
            artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath)
            notes       = try c.decodeIfPresent(PlaylistNotes.self, forKey: .notes)
            dubFor      = try c.decodeIfPresent(String.self, forKey: .dubFor)
            dubNote     = try c.decodeIfPresent(String.self, forKey: .dubNote)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(playlistId, forKey: .playlistId)
            try c.encode(ownerId, forKey: .ownerId)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encode(trackIds, forKey: .trackIds)
            try c.encode(tracks, forKey: .tracks)
            try c.encode(shareCode, forKey: .shareCode)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encodeIfPresent(artworkPath, forKey: .artworkPath)
            try c.encodeIfPresent(notes, forKey: .notes)
        }

        /// Public URL of the playlist cover, if one was published.
        public var artworkURL: URL? {
            artworkPath.flatMap { PlaylistSharingService.coverURL(path: $0) }
        }
    }

    /// A local playlist's link to its shared_playlists row. `role`: "owner" and "editor" push edits;
    /// "viewer" is a saved public playlist that only pulls and has no share code.
    public struct LinkedShare: Codable, Sendable {
        public let sharedPlaylistID: UUID
        public let shareCode: String
        public let role: String   // "owner" | "editor" | "viewer"

        public var isViewer: Bool { role == Roles.viewer }
    }

    public enum Roles {
        public static let owner  = "owner"
        public static let editor = "editor"
        public static let viewer = "viewer"
    }

    /// Publishes `playlist` to shared_playlists and returns the share code for `joinSharedPlaylist`.
    /// `tracks` go in as a metadata snapshot. Get-or-create: one playlist, one row, one code.
    @discardableResult
    public func shareToSupabase(playlist: Playlist, tracks: [Track], deviceID: String) async throws -> String {
        let session = try await client.auth.session
        let ownerId = session.user.id

        if let existing = try await existingShare(playlistID: playlist.id, ownerID: ownerId) {
            setLinkedShare(
                LinkedShare(sharedPlaylistID: existing.id, shareCode: existing.shareCode, role: "owner"),
                forLocalPlaylist: playlist.id
            )
            await syncCovers(playlist: playlist, tracks: tracks, sharedPlaylistID: existing.id)
            return existing.shareCode
        }

        let shareCode = Self.generateShareCode()
        let sharedID  = UUID()

        // Before the insert, so nobody following the link early gets a grey square.
        let artworkPath = await uploadCover(playlist: playlist, sharedPlaylistID: sharedID)

        let record = SharedPlaylistRecord(
            id: sharedID,
            playlistId: playlist.id,
            ownerId: ownerId,
            name: playlist.name,
            description: playlist.description,
            trackIds: playlist.trackIDs,
            tracks: Self.snapshot(playlist: playlist, resolving: tracks),
            shareCode: shareCode,
            updatedAt: Date(),
            artworkPath: artworkPath,
            notes: playlist.notes
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

        // Not awaited (one upload per song). Early joiners fall back to catalogue artwork until a refresh.
        let snapshot = tracks
        Task { await self.publishTrackCovers(snapshot) }

        // The owner is a member via owner_id; no collaborator row needed.
        return shareCode
    }

    /// Brings the published covers for a shared playlist up to date, so sharing alone is enough.
    /// Song covers are stored under the uploader's id and read under `owner_id`, so this carries the owner's
    /// songs to collaborators; a collaborator's additions reach the owner via the online catalogue.
    private func syncCovers(playlist: Playlist, tracks: [Track], sharedPlaylistID: UUID) async {
        if let path = await uploadCover(playlist: playlist, sharedPlaylistID: sharedPlaylistID) {
            struct CoverPayload: Encodable { let artwork_path: String }
            _ = try? await client
                .from("shared_playlists")
                .update(CoverPayload(artwork_path: path))
                .eq("id", value: sharedPlaylistID.uuidString)
                .execute()
        }
        let snapshot = tracks
        Task { await self.publishTrackCovers(snapshot) }
    }

    /// Just enough of a shared row to identify it and invite people to it.
    struct ShareIdentity: Decodable, Sendable {
        let id: UUID
        let shareCode: String

        enum CodingKeys: String, CodingKey {
            case id
            case shareCode = "share_code"
        }
    }

    /// The owner's existing row for a local playlist, if any. Deleted rows are excluded, so an unpublished
    /// playlist gets a fresh row.
    private func existingShare(playlistID: UUID, ownerID: UUID) async throws -> ShareIdentity? {
        let rows: [ShareIdentity] = try await client
            .from("shared_playlists")
            .select("id,share_code")
            .eq("playlist_id", value: playlistID)
            .eq("owner_id", value: ownerID)
            .eq("is_deleted", value: false)
            .order("created_at", ascending: true)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The track snapshot in playlist order; tracks missing from `resolving` are skipped.
    private static func snapshot(playlist: Playlist, resolving tracks: [Track]) -> [SharedTrackMeta] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackIDs.compactMap { id in
            byID[id].map { SharedTrackMeta(track: $0) }
        }
    }

    /// Redeems `shareCode` via the `join_shared_playlist` SECURITY DEFINER RPC, which checks the code and
    /// adds the caller as an editor in one call (no broad read access, so no code enumeration).
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

    /// What redeeming a code actually did, so the caller can word the toast.
    public struct RedeemedInvite: Sendable {
        public let record: SharedPlaylistRecord
        public let localPlaylistID: UUID
        /// True when the playlist was already here: a second tap on the link, or the owner following it.
        public let alreadyHere: Bool
    }

    /// Redeems a share code and adds the playlist to the library. Behind both the code sheet and
    /// `mixtape://join` links.
    @discardableResult
    public func redeemInvite(code: String, libraryService: LibraryService) async throws -> RedeemedInvite {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw SharingError.notFound }

        let record = try await joinSharedPlaylist(shareCode: trimmed)
        return await materialise(record: record, libraryService: libraryService)
    }

    /// Adds a shared row to the local library, or finds the existing copy. Assumes membership is
    /// established (`joinSharedPlaylist` or an accepted invite); no network work beyond artwork.
    /// - A second tap on the same link refreshes rather than duplicates.
    /// - The owner following their own link gets their playlist back under the row's id, as "owner".
    @discardableResult
    public func materialise(record: SharedPlaylistRecord,
                            libraryService: LibraryService) async -> RedeemedInvite {
        let viewerID = try? await client.auth.session.user.id
        let isOwner  = viewerID == record.ownerId
        let role     = isOwner ? "owner" : "editor"

        // Already linked here: refresh, don't clone.
        if let existingID = localPlaylistID(forSharedPlaylist: record.id),
           libraryService.playlist(id: existingID) != nil {
            libraryService.reconcileSharedPlaylist(localPlaylistID: existingID,
                                                   remoteTrackIDs: record.trackIds,
                                                   remoteTrackMeta: record.tracks,
                                                   ownerID: record.ownerId,
                                                   notes: record.notes)
            setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                       shareCode: record.shareCode,
                                       role: role),
                           forLocalPlaylist: existingID)
            await adoptCover(record: record, localPlaylistID: existingID, libraryService: libraryService)
            return RedeemedInvite(record: record, localPlaylistID: existingID, alreadyHere: true)
        }

        // The owner's playlist is here under the row's id but unlinked; adopt it in place.
        if isOwner, libraryService.playlist(id: record.playlistId) != nil {
            setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                       shareCode: record.shareCode,
                                       role: "owner"),
                           forLocalPlaylist: record.playlistId)
            return RedeemedInvite(record: record,
                                  localPlaylistID: record.playlistId,
                                  alreadyHere: true)
        }

        // The owner reuses the published id; anyone else gets a fresh one so it can't collide later.
        let local = libraryService.createPlaylist(id: isOwner ? record.playlistId : UUID(),
                                                  name: record.name,
                                                  description: record.description,
                                                  imported: true)
        libraryService.reconcileSharedPlaylist(localPlaylistID: local.id,
                                               remoteTrackIDs: record.trackIds,
                                               remoteTrackMeta: record.tracks,
                                               ownerID: record.ownerId,
                                               notes: record.notes)
        setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                   shareCode: record.shareCode,
                                   role: role),
                       forLocalPlaylist: local.id)
        await adoptCover(record: record, localPlaylistID: local.id, libraryService: libraryService)

        return RedeemedInvite(record: record, localPlaylistID: local.id, alreadyHere: false)
    }

    /// Copies the owner's published cover onto a joined playlist (public bucket, one GET). Only fills an
    /// empty cover; a collaborator's own picture is kept.
    private func adoptCover(record: SharedPlaylistRecord,
                            localPlaylistID: UUID,
                            libraryService: LibraryService) async {
        guard let url = record.artworkURL,
              let local = libraryService.playlist(id: localPlaylistID),
              local.displayArtwork == nil
        else { return }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return }

        libraryService.setPlaylistArtwork(id: localPlaylistID, data: data)
    }

    // MARK: - Saving someone else's public playlist

    /// Whether a saved playlist's source still exists. Only the server saying so counts as `unavailable`;
    /// an offline device reports `unknown`.
    public enum SourceAvailability: Sendable, Hashable {
        case available
        case unavailable
        case unknown
    }

    /// Reads one public playlist by its shared-row id, for saving and refreshing. No share code; see
    /// `get_public_playlist` in 20260815000000.
    public func fetchPublicPlaylist(sharedPlaylistID: UUID) async throws -> SharedPlaylistRecord {
        struct Params: Encodable { let p_shared_playlist_id: UUID }

        let rows: [SharedPlaylistRecord] = try await client
            .rpc("get_public_playlist", params: Params(p_shared_playlist_id: sharedPlaylistID))
            .execute()
            .value

        // Zero rows means private, removed, or never public; `.single()` would make that look like a network error.
        guard let record = rows.first else { throw SharingError.unavailable }
        return record
    }

    /// The row as the public playlist page shows it. A dub's dedication becomes the description,
    /// the only text a saved copy carries, as on web.
    public func fetchPublicSummary(sharedPlaylistID: UUID) async throws -> PublicPlaylistSummary {
        summary(try await fetchPublicPlaylist(sharedPlaylistID: sharedPlaylistID))
    }

    private func summary(_ r: SharedPlaylistRecord) -> PublicPlaylistSummary {
        let dedication = r.dubFor.map { ["For \($0).", r.dubNote ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }
        return PublicPlaylistSummary(
            id: r.id,
            playlistID: r.playlistId,
            name: r.name,
            description: dedication ?? r.description,
            trackCount: r.trackIds.count,
            tracks: r.tracks.map {
                PublicPlaylistTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration,
                                    sourceKey: $0.sourceKey, edit: $0.edit)
            },
            artworkPath: r.artworkPath,
            ownerID: r.ownerId,
            isDub: r.dubFor != nil
        )
    }

    /// Where a shared playlist opens in the app.
    public enum InAppTarget {
        case library(Playlist)
        case page(PublicPlaylistSummary)
    }

    /// This device's copy, else the member's copy (linked or added here), else the public page.
    /// Nil only when this account can't see the playlist at all.
    public func inAppTarget(sharedPlaylistID: UUID, libraryService: LibraryService) async -> InAppTarget? {
        if let playlist = localPlaylistID(forSharedPlaylist: sharedPlaylistID).flatMap(libraryService.playlist(id:)) {
            return .library(playlist)
        }
        // Owners and members can read the row even when it's private.
        let record: SharedPlaylistRecord? = try? await client
            .from("shared_playlists")
            .select()
            .eq("id", value: sharedPlaylistID)
            .eq("is_deleted", value: false)
            .single()
            .execute()
            .value
        guard let record else {
            return (try? await fetchPublicSummary(sharedPlaylistID: sharedPlaylistID)).map { .page($0) }
        }
        let me = try? await client.auth.session.user.id
        if me == record.ownerId {
            guard libraryService.playlist(id: record.playlistId) != nil else { return .page(summary(record)) }
        } else if pendingInvites.contains(where: { $0.id == record.id }) {
            return .page(summary(record))
        } else if let twin = libraryService.playlists.first(where: {
            // A copy joined on another device syncs here without this device's link.
            !$0.isSystem && $0.name == record.name && Set($0.trackIDs) == Set(record.trackIds)
                && linkedShare(forLocalPlaylist: $0.id) == nil
        }) {
            setLinkedShare(LinkedShare(sharedPlaylistID: record.id, shareCode: record.shareCode, role: "editor"),
                           forLocalPlaylist: twin.id)
        }
        let local = await materialise(record: record, libraryService: libraryService).localPlaylistID
        return libraryService.playlist(id: local).map { .library($0) }
    }

    /// Adds someone else's public playlist to this library as a saved playlist. Not `materialise`, which
    /// makes the caller an editor; this writes nothing to the server. The result is a real `.subscribed`
    /// playlist that edit paths refuse and `refreshSubscription` keeps in step.
    /// Idempotent, and synchronous: it uses the snapshot already on screen so the playlist appears
    /// immediately. Callers should start `refreshSubscription` straight after, which also upgrades
    /// placeholder songs once a snapshot with `sourceKey`s arrives.
    @discardableResult
    public func savePublicPlaylist(sharedPlaylistID: UUID,
                                   ownerID: UUID?,
                                   ownerName: String?,
                                   name: String,
                                   description: String?,
                                   artworkData: Data?,
                                   trackMeta: [SharedTrackMeta],
                                   libraryService: LibraryService) -> UUID {
        let link = LinkedShare(sharedPlaylistID: sharedPlaylistID,
                               shareCode: "",
                               role: Roles.viewer)
        let trackIDs = trackMeta.map(\.id)

        // Already saved here: reconcile, don't clone.
        if let existingID = localPlaylistID(forSharedPlaylist: sharedPlaylistID),
           libraryService.playlist(id: existingID) != nil {
            setLinkedShare(link, forLocalPlaylist: existingID)
            libraryService.reconcileSharedPlaylist(localPlaylistID: existingID,
                                                   remoteTrackIDs: trackIDs,
                                                   remoteTrackMeta: trackMeta,
                                                   ownerID: ownerID,
                                                   dedupeAgainstLibrary: true)
            return existingID
        }

        // A fresh id, never the owner's, which would collide with their copy if they sign in here.
        let local = libraryService.createPlaylist(id: UUID(),
                                                  name: name,
                                                  description: description,
                                                  // The cover already on screen, so no grey square.
                                                  artworkData: artworkData,
                                                  origin: .subscribed,
                                                  ownerName: ownerName,
                                                  imported: true)
        setLinkedShare(link, forLocalPlaylist: local.id)
        // Songs already in this library are linked, not copied.
        libraryService.reconcileSharedPlaylist(localPlaylistID: local.id,
                                               remoteTrackIDs: trackIDs,
                                               remoteTrackMeta: trackMeta,
                                               ownerID: ownerID,
                                               dedupeAgainstLibrary: true)
        return local.id
    }

    /// Re-reads a saved playlist's source and adopts the owner's changes. No LWW check: the local copy can't
    /// be edited, and a stale local `touch()` could pin an old track list.
    @discardableResult
    public func refreshSubscription(localPlaylistID: UUID,
                                    libraryService: LibraryService) async -> SourceAvailability {
        // Both conditions: old adopted copies are also viewers but were meant to be detached; the origin says
        // "follows someone else".
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID), link.isViewer,
              libraryService.playlist(id: localPlaylistID)?.followsRemoteSource == true
        else { return .unknown }

        do {
            let remote = try await fetchPublicPlaylist(sharedPlaylistID: link.sharedPlaylistID)
            await adoptCover(record: remote,
                             localPlaylistID: localPlaylistID,
                             libraryService: libraryService)
            libraryService.reconcileSharedPlaylist(localPlaylistID: localPlaylistID,
                                                   remoteTrackIDs: remote.trackIds,
                                                   remoteTrackMeta: remote.tracks,
                                                   ownerID: remote.ownerId,
                                                   dedupeAgainstLibrary: true,
                                                   notes: remote.notes)
            return .available
        } catch SharingError.unavailable {
            return .unavailable
        } catch {
            // Offline or a server error: the saved copy stays as is.
            return .unknown
        }
    }

    /// Removes a saved playlist from this library and takes back its save count. The owner isn't told.
    public func unsavePublicPlaylist(localPlaylistID: UUID, libraryService: LibraryService) {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID), link.isViewer else { return }
        let sharedID = link.sharedPlaylistID
        setLinkedShare(nil, forLocalPlaylist: localPlaylistID)
        SupabaseSyncService.allowBulk("unsave-playlist")
        libraryService.deletePlaylist(id: localPlaylistID)
        Task { await withdrawSave(sharedPlaylistID: sharedID) }
    }

    // MARK: - Save count

    /// Records that this user holds `sharedPlaylistID`. Only ever counted: `playlist_saves` hides every row
    /// but your own (migration 20260815010000). Best-effort; a missed count must never surface as a failure.
    func recordSave(sharedPlaylistID: UUID) async {
        struct Row: Encodable {
            let shared_playlist_id: UUID
            let saver_id: UUID
        }
        guard let userID = try? await client.auth.session.user.id else { return }
        _ = try? await client
            .from("playlist_saves")
            .upsert(Row(shared_playlist_id: sharedPlaylistID, saver_id: userID))
            .execute()
    }

    func withdrawSave(sharedPlaylistID: UUID) async {
        guard let userID = try? await client.auth.session.user.id else { return }
        _ = try? await client
            .from("playlist_saves")
            .delete()
            .eq("shared_playlist_id", value: sharedPlaylistID)
            .eq("saver_id", value: userID)
            .execute()
    }

    /// How many people hold this playlist, or nil if the server can't say (e.g. migration not applied).
    /// Callers must not show nil as "0 saves".
    func saveCount(sharedPlaylistID: UUID) async -> Int? {
        struct Params: Encodable { let p_shared_playlist_id: UUID }
        guard let body = try? await client
            .rpc("get_playlist_save_count",
                 params: Params(p_shared_playlist_id: sharedPlaylistID))
            .execute()
            .data
        else { return nil }

        // A bare number, or a one-element array.
        if let n = try? JSONDecoder().decode(Int.self, from: body) { return n }
        return (try? JSONDecoder().decode([Int].self, from: body))?.first
    }

    // MARK: - Re-pull / push (cross-device updates)

    /// Re-pulls the shared row by share code via the same RPC as join, so members need no broad SELECT
    /// (joining is idempotent).
    public func fetchSharedPlaylist(shareCode: String) async throws -> SharedPlaylistRecord {
        try await joinSharedPlaylist(shareCode: shareCode)
    }

    /// Pushes a full update (name, tracks, track_ids, bumped updatedAt). The column-guard trigger limits
    /// non-owners to content columns. LWW on the client-set `updated_at`.
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

    // MARK: - Invites & collaborators

    /// The invite link. `mixtape://` isn't clickable in most messaging apps; when a bounce page on
    /// mixtaped.tech exists only this changes, and old links keep working.
    public static func inviteURL(code: String) -> URL {
        URL(string: "mixtape://join/\(code)")!
    }

    /// The invite code for a shared row, repairing the local link on the way. Needed because
    /// `get_user_public_playlists` doesn't return codes and restored links have an empty one.
    /// An existing link's role is kept, so an editor isn't stamped "owner".
    public func inviteCode(forSharedPlaylist sharedPlaylistID: UUID,
                           localPlaylistID: UUID? = nil) async throws -> String {
        let rows: [ShareIdentity] = try await client
            .from("shared_playlists")
            .select("id,share_code")
            .eq("id", value: sharedPlaylistID)
            .limit(1)
            .execute()
            .value

        guard let code = rows.first?.shareCode, !code.isEmpty else {
            throw SharingError.notFound
        }

        if let localPlaylistID {
            let existing = linkedShare(forLocalPlaylist: localPlaylistID)
            if existing?.shareCode != code {
                setLinkedShare(
                    LinkedShare(sharedPlaylistID: sharedPlaylistID,
                                shareCode: code,
                                role: existing?.role ?? "owner"),
                    forLocalPlaylist: localPlaylistID
                )
            }
        }
        return code
    }

    /// Rotates the share code, killing outstanding invites; existing members keep access. Owner-only via
    /// the column-guard trigger, which silently reverts a non-owner's change and reports success.
    @discardableResult
    public func regenerateShareCode(forSharedPlaylist sharedPlaylistID: UUID,
                                    localPlaylistID: UUID? = nil) async throws -> String {
        struct CodePayload: Encodable { let share_code: String }

        let code = Self.generateShareCode()
        try await client
            .from("shared_playlists")
            .update(CodePayload(share_code: code))
            .eq("id", value: sharedPlaylistID.uuidString)
            .execute()

        if let localPlaylistID, let existing = linkedShare(forLocalPlaylist: localPlaylistID) {
            setLinkedShare(
                LinkedShare(sharedPlaylistID: existing.sharedPlaylistID,
                            shareCode: code,
                            role: existing.role),
                forLocalPlaylist: localPlaylistID
            )
        }
        return code
    }

    /// Where a membership stands. Separate from `role` so policies granting editors something can't
    /// accidentally include people who were only invited.
    public enum InviteStatus: String, Sendable, Hashable {
        case invited
        case joined
        case declined
    }

    /// One member of a shared playlist. The profile is fetched separately: `user_id` references
    /// `auth.users`, so PostgREST can't embed `profiles`.
    public struct Collaborator: Codable, Sendable, Identifiable, Hashable {
        public let sharedPlaylistID: UUID
        public let userID: UUID
        public var role: String
        public var joinedAt: Date
        /// Raw column value; read `status`. An unknown string shouldn't fail the decode.
        public var rawStatus: String
        public var invitedBy: UUID?
        public var invitedAt: Date?
        public var respondedAt: Date?

        public var id: UUID { userID }

        public var status: InviteStatus {
            InviteStatus(rawValue: rawStatus) ?? .joined
        }

        enum CodingKeys: String, CodingKey {
            case sharedPlaylistID = "shared_playlist_id"
            case userID           = "user_id"
            case role
            case joinedAt         = "joined_at"
            case rawStatus        = "status"
            case invitedBy        = "invited_by"
            case invitedAt        = "invited_at"
            case respondedAt      = "responded_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sharedPlaylistID = try c.decode(UUID.self, forKey: .sharedPlaylistID)
            userID           = try c.decode(UUID.self, forKey: .userID)
            role             = try c.decode(String.self, forKey: .role)
            joinedAt         = try c.decode(Date.self, forKey: .joinedAt)
            // Rows before 20260811 are all code redemptions, so they're joins.
            rawStatus        = try c.decodeIfPresent(String.self, forKey: .rawStatus) ?? InviteStatus.joined.rawValue
            invitedBy        = try c.decodeIfPresent(UUID.self, forKey: .invitedBy)
            invitedAt        = try c.decodeIfPresent(Date.self, forKey: .invitedAt)
            respondedAt      = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        }
    }

    /// Every column the decoder needs; a missing one fails at decode, far from the query.
    private static let collaboratorColumns =
        "shared_playlist_id,user_id,role,joined_at,status,invited_by,invited_at,responded_at"

    /// Everyone on `sharedPlaylistID`, including invited and declined, oldest first. The owner usually isn't
    /// here (ownership is `owner_id`); add them separately.
    public func collaborators(sharedPlaylistID: UUID) async throws -> [Collaborator] {
        try await client
            .from("playlist_collaborators")
            .select(Self.collaboratorColumns)
            .eq("shared_playlist_id", value: sharedPlaylistID)
            .order("joined_at", ascending: true)
            .execute()
            .value
    }

    /// Invites someone directly, no code. Owner-only by policy. The row lands as `invited`, so nothing
    /// appears in their library until they accept (see `pendingInvites`). Re-inviting a decline resets it;
    /// invited or joined members are left alone. Returns what happened so the UI can say so.
    @discardableResult
    public func addCollaborator(userID: UUID,
                                toSharedPlaylist sharedPlaylistID: UUID,
                                role: String = "editor") async throws -> InviteOutcome {
        let me = try? await client.auth.session.user.id
        let existing = try await collaborators(sharedPlaylistID: sharedPlaylistID)

        if let row = existing.first(where: { $0.userID == userID }) {
            switch row.status {
            case .joined:  return .alreadyMember
            case .invited: return .alreadyInvited
            case .declined:
                struct ReinvitePayload: Encodable {
                    let status: String
                    let invited_by: UUID?
                }
                try await client
                    .from("playlist_collaborators")
                    .update(ReinvitePayload(status: InviteStatus.invited.rawValue, invited_by: me))
                    .eq("shared_playlist_id", value: sharedPlaylistID)
                    .eq("user_id", value: userID)
                    .execute()
                return .reinvited
            }
        }

        struct MemberPayload: Encodable {
            let shared_playlist_id: UUID
            let user_id: UUID
            let role: String
            let status: String
            let invited_by: UUID?
        }

        try await client
            .from("playlist_collaborators")
            .insert(MemberPayload(shared_playlist_id: sharedPlaylistID,
                                  user_id: userID,
                                  role: role,
                                  status: InviteStatus.invited.rawValue,
                                  invited_by: me))
            .execute()
        return .invited
    }

    /// What `addCollaborator` did; three of the four cases write nothing.
    public enum InviteOutcome: Sendable, Hashable {
        /// A fresh invite row is now waiting for an answer.
        case invited
        /// They had declined before; the invite has been re-opened.
        case reinvited
        /// Already joined.
        case alreadyMember
        /// Already asked and still deciding. Asking again would change nothing.
        case alreadyInvited
    }

    /// Removes a member. The owner may remove anyone; anyone may remove themselves.
    public func removeCollaborator(userID: UUID,
                                   fromSharedPlaylist sharedPlaylistID: UUID) async throws {
        try await client
            .from("playlist_collaborators")
            .delete()
            .eq("shared_playlist_id", value: sharedPlaylistID)
            .eq("user_id", value: userID)
            .execute()
    }

    // MARK: - Invite inbox

    /// A playlist somebody has offered you and you haven't answered.
    public struct PendingInvite: Identifiable, Sendable, Hashable {
        public let record: SharedPlaylistRecord
        public let invitedBy: UUID?
        /// Resolved separately: `invited_by` references `auth.users`, so PostgREST can't embed it.
        public let inviterName: String?
        public let invitedAt: Date

        public var id: UUID { record.id }
        public var sharedPlaylistID: UUID { record.id }

        public static func == (a: PendingInvite, b: PendingInvite) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Invites waiting on this account, newest first. Published so every surface can badge it; refreshed
    /// on sign-in and foreground.
    public private(set) var pendingInvites: [PendingInvite] = []

    /// Re-reads the inbox. Silent on failure since it runs unprompted. Existing RLS covers it; two
    /// queries because the join crosses into `auth.users`.
    public func refreshPendingInvites() async {
        guard let me = try? await client.auth.session.user.id else {
            pendingInvites = []
            return
        }

        let rows: [Collaborator]
        do {
            rows = try await client
                .from("playlist_collaborators")
                .select(Self.collaboratorColumns)
                .eq("user_id", value: me)
                .eq("status", value: InviteStatus.invited.rawValue)
                .execute()
                .value
        } catch {
            MixLog.sync.error("[Sharing] Invite inbox read failed: \(error)")
            return
        }

        guard !rows.isEmpty else {
            pendingInvites = []
            return
        }

        let records: [SharedPlaylistRecord]
        do {
            records = try await client
                .from("shared_playlists")
                .select()
                .in("id", values: rows.map(\.sharedPlaylistID))
                .eq("is_deleted", value: false)
                .execute()
                .value
        } catch {
            MixLog.sync.error("[Sharing] Invite playlist read failed: \(error)")
            return
        }

        // One lookup per distinct inviter.
        var names: [UUID: String] = [:]
        for inviterID in Set(rows.compactMap(\.invitedBy)) {
            let profiles: [UserProfile]? = try? await client
                .from("profiles")
                .select("id, username, display_name, avatar_url, created_at")
                .eq("id", value: inviterID)
                .limit(1)
                .execute()
                .value
            if let name = profiles?.first?.name { names[inviterID] = name }
        }

        let rowByID = Dictionary(rows.map { ($0.sharedPlaylistID, $0) }, uniquingKeysWith: { a, _ in a })
        pendingInvites = records.compactMap { record -> PendingInvite? in
            guard let row = rowByID[record.id] else { return nil }
            return PendingInvite(record: record,
                                 invitedBy: row.invitedBy,
                                 inviterName: row.invitedBy.flatMap { names[$0] },
                                 invitedAt: row.invitedAt ?? row.joinedAt)
        }
        .sorted { $0.invitedAt > $1.invitedAt }
    }

    /// Accepts or declines an invite; on accept, adds the playlist to the library and returns its local id.
    /// The status write goes first and may throw, so a failure leaves nothing local and the invite still
    /// in the inbox. The reverse order would leave a playlist the server refuses every edit to.
    @discardableResult
    public func respondToInvite(_ invite: PendingInvite,
                                accept: Bool,
                                libraryService: LibraryService) async throws -> UUID? {
        guard let me = try? await client.auth.session.user.id else {
            throw SharingError.notFound
        }

        struct StatusPayload: Encodable { let status: String }
        try await client
            .from("playlist_collaborators")
            .update(StatusPayload(status: (accept ? InviteStatus.joined : .declined).rawValue))
            .eq("shared_playlist_id", value: invite.sharedPlaylistID)
            .eq("user_id", value: me)
            .execute()

        pendingInvites.removeAll { $0.id == invite.id }

        guard accept else { return nil }
        return await materialise(record: invite.record, libraryService: libraryService).localPlaylistID
    }

    // MARK: - Profile visibility

    private func publicDefaultsKey(_ localPlaylistID: UUID) -> String {
        "playlistIsPublic.\(localPlaylistID.uuidString)"
    }

    /// Last known visibility, cached so a toggle can draw before the network answers. The server is authoritative.
    public func isPublicCached(localPlaylistID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: publicDefaultsKey(localPlaylistID))
    }

    public func cachePublic(_ isPublic: Bool, localPlaylistID: UUID) {
        UserDefaults.standard.set(isPublic, forKey: publicDefaultsKey(localPlaylistID))
    }

    /// Shows or hides `playlist` on the owner's public profile. Needs a `shared_playlists` row for the
    /// snapshot, created silently if missing (its code is never shown; going public isn't handing out an
    /// invite). Turning it on also refreshes the snapshot.
    public func setPublic(_ isPublic: Bool,
                          playlist: Playlist,
                          tracks: [Track],
                          deviceID: String) async throws {
        var link = linkedShare(forLocalPlaylist: playlist.id)

        // Only the owner may publish.
        if let existing = link, existing.role != "owner" {
            throw SharingError.notOwner
        }

        if link == nil {
            guard isPublic else {
                // Nothing published, nothing to hide.
                cachePublic(false, localPlaylistID: playlist.id)
                return
            }
            _ = try await shareToSupabase(playlist: playlist, tracks: tracks, deviceID: deviceID)
            link = linkedShare(forLocalPlaylist: playlist.id)
        }

        guard let link else { throw SharingError.notFound }

        // The cover goes up with the playlist and is deleted when it comes off, so an old URL stops working.
        let artworkPath = isPublic
            ? await uploadCover(playlist: playlist, sharedPlaylistID: link.sharedPlaylistID)
            : nil
        if !isPublic { await deleteCover(sharedPlaylistID: link.sharedPlaylistID) }

        struct VisibilityPayload: Encodable {
            let is_public: Bool
            let name: String
            let description: String?
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let notes: PlaylistNotes
            let artwork_path: String?
            let updated_at: Date
        }

        let payload = VisibilityPayload(
            is_public: isPublic,
            name: playlist.name,
            description: playlist.description,
            track_ids: playlist.trackIDs,
            tracks: Self.snapshot(playlist: playlist, resolving: tracks),
            notes: playlist.notes,
            artwork_path: artworkPath,
            updated_at: Date()
        )

        try await client
            .from("shared_playlists")
            .update(payload)
            .eq("id", value: link.sharedPlaylistID.uuidString)
            .execute()

        cachePublic(isPublic, localPlaylistID: playlist.id)

        // Not awaited: track cover paths are derived from owner and track id, so the row is complete without
        // them. `backfillPublishedCovers` finishes an interrupted run.
        if isPublic {
            let snapshot = tracks
            Task { await self.publishTrackCovers(snapshot) }
        }
    }

    // MARK: - Sharing by link

    /// The shared row id behind mixtaped.tech/playlist/<id>, opening the row to link visitors
    /// (`link_shared`, see 20260915000000). Never puts a playlist on a profile. A saved playlist hands out
    /// the owner's link; an editor can't open someone else's playlist.
    public func linkShareID(playlist: Playlist, tracks: [Track], deviceID: String) async throws -> UUID {
        let existing = linkedShare(forLocalPlaylist: playlist.id)
        if let existing, existing.role != Roles.owner {
            guard existing.isViewer else { throw SharingError.notOwner }
            return existing.sharedPlaylistID
        }
        if existing == nil {
            _ = try await shareToSupabase(playlist: playlist, tracks: tracks, deviceID: deviceID)
        }
        guard let link = linkedShare(forLocalPlaylist: playlist.id) else { throw SharingError.notFound }

        struct LinkPayload: Encodable {
            let link_shared: Bool
            let name: String
            let description: String?
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let notes: PlaylistNotes
            let artwork_path: String?
            let updated_at: Date
        }
        // A row taken off a profile lost its cover (see setPublic); a new one just got it from shareToSupabase.
        let artworkPath = existing == nil
            ? nil
            : await uploadCover(playlist: playlist, sharedPlaylistID: link.sharedPlaylistID)

        try await client
            .from("shared_playlists")
            .update(LinkPayload(
                link_shared: true,
                name: playlist.name,
                description: playlist.description,
                track_ids: playlist.trackIDs,
                tracks: Self.snapshot(playlist: playlist, resolving: tracks),
                notes: playlist.notes,
                artwork_path: artworkPath,
                updated_at: Date()
            ))
            .eq("id", value: link.sharedPlaylistID.uuidString)
            .execute()
        return link.sharedPlaylistID
    }

    // MARK: - Dubbing

    /// A copy made for one person: a new link-shared row the server freezes on insert (20260926040000).
    /// It gets its own playlist_id, so nothing that follows the local playlist ever finds or updates it.
    /// `to` names a Mixtape user, whose inbox gets it by trigger (20260927000000).
    public func dub(playlist: Playlist,
                    tracks: [Track],
                    artworkData: Data?,
                    for recipient: String,
                    to recipientID: UUID? = nil,
                    note: String?) async throws -> UUID {
        struct DubRow: Encodable {
            let id: UUID
            let playlist_id: UUID
            let owner_id: UUID
            let name: String
            let description: String?
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let notes: PlaylistNotes
            let share_code: String
            let artwork_path: String?
            let link_shared = true
            let dub_for: String
            let dub_to: UUID?
            let dub_note: String?
        }

        let ownerID = try await client.auth.session.user.id
        let id = UUID()
        let artworkPath = await uploadCover(artworkData, sharedPlaylistID: id)
        try await client
            .from("shared_playlists")
            .insert(DubRow(id: id,
                           playlist_id: UUID(),
                           owner_id: ownerID,
                           name: playlist.name,
                           description: playlist.description,
                           track_ids: playlist.trackIDs,
                           tracks: Self.snapshot(playlist: playlist, resolving: tracks),
                           notes: playlist.notes,
                           share_code: Self.generateShareCode(),
                           artwork_path: artworkPath,
                           dub_for: recipient,
                           dub_to: recipientID,
                           dub_note: note))
            .execute()

        let snapshot = tracks
        Task { await self.publishTrackCovers(snapshot) }
        return id
    }

    // MARK: - Taking a published playlist down

    // These address the `shared_playlists` row directly, so a published playlist can be managed even
    // when the local copy is gone (cleared library, reinstall, other account).

    /// Takes a playlist off its owner's profile, keeping the row: collaborators keep access and the code
    /// stays valid. The cover is deleted.
    public func unpublish(sharedPlaylistID: UUID) async throws {
        struct HidePayload: Encodable {
            let is_public: Bool
            let artwork_path: String?
            let updated_at: Date
        }

        await deleteCover(sharedPlaylistID: sharedPlaylistID)

        try await client
            .from("shared_playlists")
            .update(HidePayload(is_public: false, artwork_path: nil, updated_at: Date()))
            .eq("id", value: sharedPlaylistID.uuidString)
            .execute()

        // Keep the local toggle in step if this device has a copy.
        if let localID = localPlaylistID(forSharedPlaylist: sharedPlaylistID) {
            cachePublic(false, localPlaylistID: localID)
        }
    }

    /// Deletes the published row. Collaborator rows and invites cascade; the stored link goes too, since
    /// `setPublic` refuses a stale one. Owner-only via the delete policy.
    public func deletePublished(sharedPlaylistID: UUID) async throws {
        await deleteCover(sharedPlaylistID: sharedPlaylistID)

        try await client
            .from("shared_playlists")
            .delete()
            .eq("id", value: sharedPlaylistID.uuidString)
            .execute()

        if let localID = localPlaylistID(forSharedPlaylist: sharedPlaylistID) {
            setLinkedShare(nil, forLocalPlaylist: localID)
            cachePublic(false, localPlaylistID: localID)
        }
    }

    // MARK: - Published covers

    /// Public bucket for published covers; not `artwork`, which is private (see
    /// 20260808000000_public_playlist_covers.sql).
    nonisolated static let coverBucket = "playlist-covers"

    static func coverPath(ownerID: UUID, sharedPlaylistID: UUID) -> String {
        "\(ownerID.uuidString.lowercased())/\(sharedPlaylistID.uuidString.lowercased()).jpg"
    }

    /// Public URL for a cover path; no token or round trip needed.
    public static func coverURL(path: String) -> URL? {
        SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(coverBucket)
            .appendingPathComponent(path)
    }

    /// Where a published song's cover lives, derived from owner and track id so it needs no column.
    /// A song in two published playlists is one object. A 404 means no cover or not uploaded yet; callers
    /// fall back to the catalogue.
    nonisolated static func trackCoverPath(ownerID: UUID, trackID: UUID) -> String {
        "\(ownerID.uuidString.lowercased())/tracks/\(trackID.uuidString.lowercased()).jpg"
    }

    nonisolated public static func trackCoverURL(ownerID: UUID, trackID: UUID) -> URL? {
        SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(coverBucket)
            .appendingPathComponent(trackCoverPath(ownerID: ownerID, trackID: trackID))
    }

    /// Uploads covers for rows published before covers existed. Runs when the owner opens their own
    /// profile, the only place the local artwork is reachable. Returns the ids it filled in.
    @discardableResult
    public func backfillPublishedCovers(_ summaries: [PublicPlaylistSummary],
                                        library: LibraryService) async -> Set<UUID> {
        var repaired: Set<UUID> = []

        for summary in summaries where summary.artworkPath == nil {
            // Only the owner has the local playlist and may write the row, so this is the ownership check.
            guard let local = library.playlist(id: summary.playlistID),
                  local.displayArtwork != nil,
                  let path = await uploadCover(playlist: local, sharedPlaylistID: summary.id)
            else { continue }

            struct CoverPayload: Encodable { let artwork_path: String }
            do {
                try await client
                    .from("shared_playlists")
                    .update(CoverPayload(artwork_path: path))
                    .eq("id", value: summary.id.uuidString)
                    .execute()
                repaired.insert(summary.id)
            } catch {
                MixLog.sync.error("[Sharing] Cover backfill failed for \(summary.name): \(error)")
            }
        }

        // Song covers for every published playlist, not just those missing a playlist cover.
        let songs = summaries
            .flatMap(\.tracks)
            .compactMap { library.track(id: $0.id) }
        if !songs.isEmpty {
            var seen = Set<UUID>()
            await publishTrackCovers(songs.filter { seen.insert($0.id).inserted })
        }

        return repaired
    }

    /// Uploads the playlist's cover and returns its path, or nil when there's none or the upload fails.
    /// Not thrown: a missing picture shouldn't fail the publish.
    private func uploadCover(playlist: Playlist, sharedPlaylistID: UUID) async -> String? {
        await uploadCover(playlist.displayArtwork, sharedPlaylistID: sharedPlaylistID)
    }

    private func uploadCover(_ raw: Data?, sharedPlaylistID: UUID) async -> String? {
        guard let raw else { return nil }
        guard let session = try? await client.auth.session else { return nil }
        // 512px; the largest a cover is drawn is the 180pt detail hero.
        guard let jpeg = ImageDownsampler.downsampledJPEG(from: raw, maxDimension: 512) else {
            return nil
        }

        let path = Self.coverPath(ownerID: session.user.id, sharedPlaylistID: sharedPlaylistID)
        do {
            try await client.storage
                .from(Self.coverBucket)
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
            return path
        } catch {
            MixLog.sync.error("[Sharing] Cover upload failed for \(sharedPlaylistID): \(error)")
            return nil
        }
    }

    private func deleteCover(sharedPlaylistID: UUID) async {
        guard let session = try? await client.auth.session else { return }
        let path = Self.coverPath(ownerID: session.user.id, sharedPlaylistID: sharedPlaylistID)
        _ = try? await client.storage.from(Self.coverBucket).remove(paths: [path])
    }

    // MARK: - Published track thumbnails

    /// Publishes the covers of the songs in a published playlist. Visitors adopt the songs as
    /// `SharedTrackMeta` with no artwork, and the catalogue has nothing for most imported songs.
    /// Uploaded ids are remembered per device; a wrong record only costs a redundant upsert.
    func publishTrackCovers(_ tracks: [Track]) async {
        guard let session = try? await client.auth.session else { return }

        var published = Self.publishedTrackCoverIDs
        let pending = tracks.filter { $0.artworkData != nil && !published.contains($0.id.uuidString) }
        guard !pending.isEmpty else { return }

        // Sequential, like the sync service's upload; tens of ~20KB images and nobody waits on it.
        var uploadedAny = false
        for track in pending {
            guard let raw = track.artworkData,
                  // 300px: a song cover is never drawn larger than a 180pt tile.
                  let jpeg = ImageDownsampler.downsampledJPEG(from: raw, maxDimension: 300)
            else { continue }

            let path = Self.trackCoverPath(ownerID: session.user.id, trackID: track.id)
            do {
                try await client.storage
                    .from(Self.coverBucket)
                    .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
                published.insert(track.id.uuidString)
                uploadedAny = true
            } catch {
                MixLog.sync.error("[Sharing] Track cover upload failed for \(track.title): \(error)")
            }
        }

        if uploadedAny {
            Self.publishedTrackCoverIDs = published
            MixLog.sync.debug("[Sharing] Published \(pending.count) track cover(s)")
        }
    }

    private static let publishedTrackCoversKey = "mix.sharing.publishedTrackCovers"

    private static var publishedTrackCoverIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: publishedTrackCoversKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: publishedTrackCoversKey) }
    }

    // MARK: - Local <-> shared link persistence

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

    /// Stores (or clears, when `nil`) the link between a local playlist and its shared row.
    public func setLinkedShare(_ link: LinkedShare?, forLocalPlaylist localPlaylistID: UUID) {
        let key = linkDefaultsKey(localPlaylistID)
        let previous = linkedShare(forLocalPlaylist: localPlaylistID)

        if let link, let data = try? JSONEncoder().encode(link) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Keep the reverse index in step, for "do I already have this shared row?".
        if let old = previous?.sharedPlaylistID, old != link?.sharedPlaylistID {
            UserDefaults.standard.removeObject(forKey: reverseLinkKey(old))
        }
        if let link {
            UserDefaults.standard.set(localPlaylistID.uuidString,
                                      forKey: reverseLinkKey(link.sharedPlaylistID))
        }
    }

    private func reverseLinkKey(_ sharedPlaylistID: UUID) -> String {
        "sharedPlaylistCopy.\(sharedPlaylistID.uuidString)"
    }

    /// The local playlist made from a shared row, if this device has one. Stored in UserDefaults, so it's
    /// per device: phone and Mac can still each add a copy.
    public func localPlaylistID(forSharedPlaylist sharedPlaylistID: UUID) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: reverseLinkKey(sharedPlaylistID)) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    /// If `localPlaylistID` is linked, re-pulls the snapshot and reconciles the track list (LWW on
    /// updatedAt). Missing songs come in as unavailable placeholders. No-op if unlinked or signed out.
    public func refreshSharedPlaylist(localPlaylistID: UUID, libraryService: LibraryService) async {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID) else { return }

        // A saved public playlist has no share code and must never join (that would make the saver an editor).
        guard !link.isViewer else {
            await refreshSubscription(localPlaylistID: localPlaylistID, libraryService: libraryService)
            return
        }

        guard let remote = try? await fetchSharedPlaylist(shareCode: link.shareCode) else { return }

        guard let local = libraryService.playlist(id: localPlaylistID) else { return }

        // Outside the LWW check: the cover isn't part of the track race, and only the owner sets it.
        await adoptCover(record: remote,
                         localPlaylistID: localPlaylistID,
                         libraryService: libraryService)

        // LWW: only adopt the remote list if it's at least as new as our local copy.
        guard remote.updatedAt >= local.dateModified else { return }

        libraryService.reconcileSharedPlaylist(
            localPlaylistID: localPlaylistID,
            remoteTrackIDs: remote.trackIds,
            remoteTrackMeta: remote.tracks,
            ownerID: remote.ownerId,
            notes: remote.notes
        )
    }

    /// Pushes this device's track list for a linked playlist to the shared row; the other half of
    /// `refreshSharedPlaylist`. Safe for either role: the column-guard trigger limits editors to the track
    /// columns. Silent on failure; the next open reconciles.
    public func pushLocalChanges(localPlaylistID: UUID, libraryService: LibraryService) async {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID),
              link.role == "owner" || link.role == "editor",
              let local = libraryService.playlist(id: localPlaylistID)
        else { return }

        struct TracksPayload: Encodable {
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let notes: PlaylistNotes
            let updated_at: Date
        }

        // Placeholders resolve to rows, so an editor's push keeps songs they don't have locally.
        let payload = TracksPayload(
            track_ids: local.trackIDs,
            tracks: Self.snapshot(playlist: local, resolving: libraryService.tracks),
            notes: local.notes,
            updated_at: Date()
        )

        do {
            try await client
                .from("shared_playlists")
                .update(payload)
                .eq("id", value: link.sharedPlaylistID.uuidString)
                .execute()
        } catch {
            MixLog.sync.error("[Sharing] Push failed for \(local.name): \(error)")
        }

        // Owner-only: publish covers for songs added after sharing. Editors' uploads would go to an address
        // nobody reads. Already-sent covers are skipped.
        if link.role == "owner" {
            let ids = Set(local.trackIDs)
            let songs = libraryService.tracks.filter { ids.contains($0.id) }
            Task { await self.publishTrackCovers(songs) }
        }
    }

    // MARK: - Errors

    public enum SharingError: LocalizedError {
        case notFound
        case notOwner
        /// The playlist exists but is no longer published. Distinct from `notFound`: nothing was revoked.
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .notFound:    return "No shared playlist found for that code."
            case .notOwner:    return "Only the playlist's owner can do that."
            case .unavailable: return "This playlist isn't public any more."
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
