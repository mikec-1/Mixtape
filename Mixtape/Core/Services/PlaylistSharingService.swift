// PlaylistSharingService.swift
// Mixtape — Core/Services
//
// Two share paths:
// • M3U export — delegates to M3UExporter.
// • Supabase collaborative sharing — backed by 20260613_collaborative_playlists.sql
//   and the policy rewrite in 20260807000000_fix_shared_playlist_policy_recursion.sql.
//
// Collaboration is two-way but not live: an editor's changes go up on edit
// (`pushLocalChanges`) and come down on open (`refreshSharedPlaylist`), with
// last-write-wins on the whole track array. Two people editing before either has
// pulled loses one set of changes. Per-track merge and realtime are both deferred.

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
        /// The `"title|artist"` key this song can be re-found online under, said
        /// out loud by the device that knows.
        ///
        /// The receiver could always *guess* this — recompute the key from the
        /// title and artist below and see whether it hashes to `id`, which is what
        /// `LibraryService.onlineKey(for:)` does. That guess is right for most
        /// songs and quietly wrong for the rest: saving a Discover song to the
        /// library keeps the id but lets the title and artist drift afterwards
        /// (`applyEnrichment` rewrites both, and so does any manual edit), and a
        /// save whose downloaded file matched an existing hash returns that other
        /// track entirely, id and all. Either way the recomputed key stops
        /// matching, the proof fails, and a perfectly streamable song lands on the
        /// collaborator's phone as an unavailable placeholder.
        ///
        /// Written on every share from now on; nil on rows snapshotted before this
        /// existed, which is why the recomputation stays as a fallback.
        public var sourceKey: String?

        enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration
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
        }

        /// The online key for a track, when this device can actually tell there is
        /// one. Nil for somebody's ripped local file, which no search will produce.
        private static func onlineKey(for track: Track) -> String? {
            // An unsaved Discover track carries the key verbatim in `fileHash` —
            // `OnlineTrack.asTrack` puts it there. Preferred over recomputing
            // because it survives the owner renaming the song afterwards.
            if track.isOnline, track.file.fileHash.contains("|") {
                return track.file.fileHash
            }
            // A saved one doesn't: the import overwrote `fileHash` with the real
            // content hash. What it kept is the id, which is the SHA-256 of the
            // key, so a match here is still proof of where the song came from.
            // Both spellings of the title are tried, because the stored one may
            // now carry a feature credit the key never had — see
            // `Track.identityTitle`. Still proof, not a guess: only a candidate
            // that hashes to this row's id is returned.
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
        /// Storage path of the playlist's cover in the public `playlist-covers`
        /// bucket, or nil when the owner's playlist has no artwork.
        ///
        /// Decoded, never encoded. The column is owner-guarded server-side, so a
        /// collaborator writing it would have it silently reverted; keeping it out
        /// of the payload means the pull direction can read a cover without the
        /// push direction pretending it can set one.
        public var artworkPath: String?

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
            artworkPath: String? = nil
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
            // Absent exactly once: `get_public_playlist` withholds the code on
            // purpose, because saving a public playlist must not hand out
            // editor access. A record with no code is read-only by construction
            // — `pushLocalChanges` only ever runs for owner/editor links.
            shareCode   = try c.decodeIfPresent(String.self, forKey: .shareCode) ?? ""
            updatedAt   = try c.decode(Date.self, forKey: .updatedAt)
            artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath)
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
        }

        /// Public URL of the playlist cover, if one was published.
        public var artworkURL: URL? {
            artworkPath.flatMap { PlaylistSharingService.coverURL(path: $0) }
        }
    }

    /// The persisted association between a LOCAL playlist and its shared_playlists row.
    ///
    /// `role` is the whole permission model in one string. "owner" and "editor"
    /// both push their edits up; "viewer" is a saved public playlist — it pulls
    /// the owner's changes down and never writes, which is why `shareCode` is
    /// empty for those (a viewer is never given one).
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

    /// Publishes `playlist` to public.shared_playlists and returns the share code
    /// that another user supplies to `joinSharedPlaylist`. The resolved `tracks` are
    /// stored as a metadata snapshot so joiners who don't have the songs locally can
    /// still display the playlist contents.
    ///
    /// Get-or-create, and that part is load-bearing: this used to insert
    /// unconditionally, so sharing a playlist twice left two rows for one playlist
    /// and re-pointed the local link at the newer one. The *older* row is the one
    /// carrying `is_public` and the published cover, so the second share quietly
    /// detached the playlist from its own profile entry. One playlist, one row,
    /// one code.
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

        // Before the insert, so the row is complete the first time anyone reads
        // it. Uploading afterwards leaves a window in which someone who followed
        // the link immediately gets a grey square, and nothing would tell them to
        // look again.
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
            artworkPath: artworkPath
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

        // Not awaited: one upload per song, and the sheet that called this is
        // holding a spinner. A joiner who arrives before these land falls back to
        // the online catalogue for artwork and picks the owner's up on a later
        // refresh, so the only cost of being late is a slightly different picture.
        let snapshot = tracks
        Task { await self.publishTrackCovers(snapshot) }

        // The owner is implicitly a member via owner_id; an explicit collaborator
        // row for the owner is optional and left to the realtime follow-up.
        return shareCode
    }

    /// Brings the published covers for an already-shared playlist up to date.
    ///
    /// Covers used to travel only with `setPublic` — putting a playlist on your
    /// profile — so a playlist that had been *shared* and never *published* had
    /// none of them, and the person who joined it saw a grey square and a list of
    /// grey squares. Sharing is now enough.
    ///
    /// Song covers are uploaded under the id of whoever uploads them, and read
    /// back under the shared row's `owner_id`. So this carries the owner's songs
    /// to collaborators and not the other way round. A song a collaborator added
    /// reaches the owner through the online catalogue instead — which works for
    /// anything from Discover, i.e. anything the owner could play anyway.
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

    /// The owner's existing published row for a local playlist, if there is one.
    /// Reads the table directly — the owner select policy already allows it, and
    /// `is_deleted` is excluded so an unpublished playlist gets a fresh row rather
    /// than resurrecting a tombstone.
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

    /// What redeeming a code actually did, so the caller can word the toast.
    public struct RedeemedInvite: Sendable {
        public let record: SharedPlaylistRecord
        public let localPlaylistID: UUID
        /// True when the playlist was already on this device and nothing new was
        /// created — the second tap on the same link, or the owner following it.
        public let alreadyHere: Bool
    }

    /// Redeems a share code and puts the playlist in the local library.
    ///
    /// The single path behind both the code sheet and a `mixtape://join` link, so
    /// the two can't drift into behaving differently.
    @discardableResult
    public func redeemInvite(code: String, libraryService: LibraryService) async throws -> RedeemedInvite {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw SharingError.notFound }

        let record = try await joinSharedPlaylist(shareCode: trimmed)
        return await materialise(record: record, libraryService: libraryService)
    }

    /// Puts a shared row into the local library, or finds the copy that's already
    /// there. Assumes membership has been established — `joinSharedPlaylist` or an
    /// accepted invite — and does no network work of its own beyond the artwork.
    ///
    /// Split out of `redeemInvite` so accepting an invite from the inbox lands in
    /// exactly the same place as following a link. The interesting cases here are
    /// all ones you only hit by accident:
    ///
    /// • **Second tap on the same link.** The RPC happily returns the row again,
    ///   so the duplicate guard has to be local. Without it, forwarding a link to
    ///   yourself is a way to fill your sidebar with copies.
    /// • **The owner following their own link.** They get their own playlist back
    ///   under the id the shared row already names, marked "owner" — not a second
    ///   copy of it, and not a link that would let `setPublic` mint a rival row.
    @discardableResult
    public func materialise(record: SharedPlaylistRecord,
                            libraryService: LibraryService) async -> RedeemedInvite {
        let viewerID = try? await client.auth.session.user.id
        let isOwner  = viewerID == record.ownerId
        let role     = isOwner ? "owner" : "editor"

        // Already linked on this device — refresh it rather than clone it.
        if let existingID = localPlaylistID(forSharedPlaylist: record.id),
           libraryService.playlist(id: existingID) != nil {
            libraryService.reconcileSharedPlaylist(localPlaylistID: existingID,
                                                   remoteTrackIDs: record.trackIds,
                                                   remoteTrackMeta: record.tracks,
                                                   ownerID: record.ownerId)
            setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                       shareCode: record.shareCode,
                                       role: role),
                           forLocalPlaylist: existingID)
            await adoptCover(record: record, localPlaylistID: existingID, libraryService: libraryService)
            return RedeemedInvite(record: record, localPlaylistID: existingID, alreadyHere: true)
        }

        // The owner's own playlist, here under the id the row points at but with
        // no link recorded — a device that has the playlist and has never opened
        // an invite for it. Adopt it in place.
        if isOwner, libraryService.playlist(id: record.playlistId) != nil {
            setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                       shareCode: record.shareCode,
                                       role: "owner"),
                           forLocalPlaylist: record.playlistId)
            return RedeemedInvite(record: record,
                                  localPlaylistID: record.playlistId,
                                  alreadyHere: true)
        }

        // An owner restoring reuses the published id so the shared row goes on
        // naming this playlist; anyone else gets a fresh one, because the id
        // belongs to the owner's library and would collide on a later restore.
        let local = libraryService.createPlaylist(id: isOwner ? record.playlistId : UUID(),
                                                  name: record.name,
                                                  description: record.description,
                                                  imported: true)
        libraryService.reconcileSharedPlaylist(localPlaylistID: local.id,
                                               remoteTrackIDs: record.trackIds,
                                               remoteTrackMeta: record.tracks,
                                               ownerID: record.ownerId)
        setLinkedShare(LinkedShare(sharedPlaylistID: record.id,
                                   shareCode: record.shareCode,
                                   role: role),
                       forLocalPlaylist: local.id)
        await adoptCover(record: record, localPlaylistID: local.id, libraryService: libraryService)

        return RedeemedInvite(record: record, localPlaylistID: local.id, alreadyHere: false)
    }

    /// Copies the owner's published cover onto the local copy of a joined playlist.
    ///
    /// A joined playlist used to arrive as a grey square, which reads as a broken
    /// import rather than as a playlist — the whole promise of collaborating is
    /// that both people are looking at the same thing. The bucket is public, so
    /// this is one unauthenticated GET.
    ///
    /// Only fills an empty cover. A collaborator who has since chosen their own
    /// picture for their copy keeps it, and a later refresh doesn't undo them.
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

    /// Whether a saved playlist's source is still there.
    ///
    /// Three cases, not two, and the third is the one that matters: a device
    /// with no connection must not be allowed to tell the user their friend
    /// unpublished a playlist. Only the server actually saying "no such public
    /// row" counts as `unavailable`.
    public enum SourceAvailability: Sendable, Hashable {
        case available
        case unavailable
        case unknown
    }

    /// Reads one public playlist by its shared-row id.
    ///
    /// The read behind both saving and every later refresh. Returns the same
    /// record shape as a joined playlist, minus the share code — see
    /// `get_public_playlist` in 20260815000000, and `SharedPlaylistRecord`'s
    /// decoder for why the missing code is tolerated rather than modelled.
    public func fetchPublicPlaylist(sharedPlaylistID: UUID) async throws -> SharedPlaylistRecord {
        struct Params: Encodable { let p_shared_playlist_id: UUID }

        let rows: [SharedPlaylistRecord] = try await client
            .rpc("get_public_playlist", params: Params(p_shared_playlist_id: sharedPlaylistID))
            .execute()
            .value

        // Zero rows is the answer, not an error: the playlist is private, taken
        // down, or was never public. `.single()` would fold that into the same
        // transport failure as a dropped connection, and the two have opposite
        // consequences for a saved copy.
        guard let record = rows.first else { throw SharingError.unavailable }
        return record
    }

    /// Puts someone else's public playlist in this library as a saved playlist.
    ///
    /// Deliberately *not* `materialise`: that path is for collaboration and
    /// registers the caller as an editor. This one writes nothing to the server.
    /// What it leaves behind locally is a real playlist — it sits in the library,
    /// plays, downloads, appears in search — that is marked `.subscribed`, so
    /// every edit path refuses it and `refreshSubscription` keeps it in step with
    /// the owner instead.
    ///
    /// Idempotent: saving a playlist that's already here refreshes it and hands
    /// back the copy that exists, so a second press can't produce a second row.
    ///
    /// Synchronous, and with no network in it at all — which is the whole point.
    /// This used to fetch the published row first, adopt its cover second, and
    /// only then return, so the button that says "Add to Library" sat spinning
    /// through two round trips before the playlist existed. Everything it needs
    /// is in the snapshot the caller is already *showing*: the name, the songs,
    /// the cover on screen. So the playlist lands in the library in the same
    /// frame as the press, and `refreshSubscription` — which the caller should
    /// start straight afterwards — reconciles it against the server behind the
    /// user's back.
    ///
    /// What that refresh is actually for: a snapshot assembled from a profile
    /// listing carries no `sourceKey`, so some songs arrive as placeholders that
    /// can't be streamed yet. `reconcileSharedPlaylist` re-imports exactly those
    /// when a fuller snapshot arrives, so they upgrade in place a moment later.
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

        // Already saved on this device — reconcile rather than clone.
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

        // A fresh local id, never the owner's: their playlist id belongs to their
        // library, and reusing it would collide with their own copy the day they
        // sign in here — the same reason `materialise` only reuses it for owners.
        let local = libraryService.createPlaylist(id: UUID(),
                                                  name: name,
                                                  description: description,
                                                  // The cover the page has already
                                                  // downloaded to show it. Passing it
                                                  // here is what stops the playlist
                                                  // appearing as a grey square for as
                                                  // long as a second GET takes.
                                                  artworkData: artworkData,
                                                  origin: .subscribed,
                                                  ownerName: ownerName,
                                                  imported: true)
        setLinkedShare(link, forLocalPlaylist: local.id)
        // A saved playlist is a list of songs, not a second set of them: anything
        // already in this library is linked, not copied.
        libraryService.reconcileSharedPlaylist(localPlaylistID: local.id,
                                               remoteTrackIDs: trackIDs,
                                               remoteTrackMeta: trackMeta,
                                               ownerID: ownerID,
                                               dedupeAgainstLibrary: true)
        return local.id
    }

    /// Re-reads a saved playlist's source and adopts whatever the owner has done
    /// to it since. The pull-only twin of `refreshSharedPlaylist`.
    ///
    /// No LWW check, unlike the collaborative path: there is nothing to race
    /// with. The local copy can't be edited, so the owner's list is simply the
    /// truth, and comparing timestamps would only let a stale local `touch()`
    /// (a download, say) pin an old track list in place.
    @discardableResult
    public func refreshSubscription(localPlaylistID: UUID,
                                    libraryService: LibraryService) async -> SourceAvailability {
        // Both conditions, not either. Copies adopted before saving existed are
        // linked as viewers too, but they were made to be detached — pulling the
        // owner's list onto one would silently undo months of a user's own edits.
        // The origin is what says "this one follows someone else".
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
                                                   dedupeAgainstLibrary: true)
            return .available
        } catch SharingError.unavailable {
            return .unavailable
        } catch {
            // Offline, or the server had a bad minute. The saved copy stays
            // exactly as it is — it's still playable, and possibly downloaded.
            return .unknown
        }
    }

    /// Removes a saved playlist from this library.
    ///
    /// Still no membership to revoke — the only server-side trace a save leaves
    /// is its line in the counter (see `recordSave`), and taking that back is
    /// what keeps the number honest about who is holding the playlist *now*.
    /// The owner is told nothing either way, and never was.
    public func unsavePublicPlaylist(localPlaylistID: UUID, libraryService: LibraryService) {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID), link.isViewer else { return }
        let sharedID = link.sharedPlaylistID
        setLinkedShare(nil, forLocalPlaylist: localPlaylistID)
        libraryService.deletePlaylist(id: localPlaylistID)
        Task { await withdrawSave(sharedPlaylistID: sharedID) }
    }

    // MARK: - Save count

    /// Records that this user is holding `sharedPlaylistID`.
    ///
    /// The one mark a save makes on the server, and it is only ever counted:
    /// `playlist_saves` hides every row but your own, so nobody — the owner
    /// included — can read the list of savers back. See migration
    /// 20260815010000.
    ///
    /// Best-effort on purpose. The playlist is already in the library by the
    /// time this runs, and a save that didn't get counted is a wrong number,
    /// not a lost playlist, so it must never surface as a failure.
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

    /// How many people are currently holding this playlist, or nil if the
    /// server can't say.
    ///
    /// Nil is a real answer and the caller must treat it as one: until the
    /// migration is applied the function doesn't exist, and a header that
    /// rendered that as "0 saves" would be stating something false about every
    /// playlist in the app.
    func saveCount(sharedPlaylistID: UUID) async -> Int? {
        struct Params: Encodable { let p_shared_playlist_id: UUID }
        guard let body = try? await client
            .rpc("get_playlist_save_count",
                 params: Params(p_shared_playlist_id: sharedPlaylistID))
            .execute()
            .data
        else { return nil }

        // A scalar function answers with a bare number. The one-element array is
        // tolerated too, so a header doesn't fall silent over which shape came
        // back.
        if let n = try? JSONDecoder().decode(Int.self, from: body) { return n }
        return (try? JSONDecoder().decode([Int].self, from: body))?.first
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

    // MARK: - Invites & collaborators

    /// The link handed out to invite someone to a playlist.
    ///
    /// A custom scheme, which costs something real: `mixtape://` isn't clickable in
    /// most messaging apps and shows nothing at all to someone who doesn't have
    /// Mixtape. The replacement is a page on mixtaped.tech that bounces into the
    /// app — when it exists this function is the only thing that changes, and every
    /// invite already sent keeps working, because the scheme handler stays.
    public static func inviteURL(code: String) -> URL {
        URL(string: "mixtape://join/\(code)")!
    }

    /// The invite code for a shared row, repairing the local link on the way past.
    ///
    /// Two reasons the code isn't already in hand. `get_user_public_playlists`
    /// deliberately doesn't return it, so an owner looking at their own public
    /// playlist page has the row id and nothing else. And a playlist restored from a
    /// published snapshot gets a link with an empty code — enough to recognise the
    /// row, not enough to invite anyone to it or to refresh it.
    ///
    /// The role on an existing link is preserved rather than assumed: an editor can
    /// reach this too, and stamping them "owner" would let them try to publish
    /// someone else's playlist to their profile.
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

    /// Rotates the share code, killing every invite already handed out. People who
    /// already joined keep their access — membership is a row in
    /// playlist_collaborators, not knowledge of the code.
    ///
    /// Owner-only, and enforced server-side by the column-guard trigger rather than
    /// by a policy: a non-owner's update lands, gets `share_code` reverted to its old
    /// value, and reports success. Offer this to owners only, or it lies.
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

    /// Where a membership stands: offered, taken up, or turned down.
    ///
    /// Separate from `role`, which says what you may do once you're in. Folding
    /// the two together would mean every policy that grants an editor something
    /// has to remember to exclude the not-yet-accepted case, and the first one
    /// that forgot would hand write access to someone who was only asked.
    public enum InviteStatus: String, Sendable, Hashable {
        case invited
        case joined
        case declined
    }

    /// One member of a shared playlist.
    ///
    /// The profile behind `userID` is fetched separately rather than embedded:
    /// `playlist_collaborators.user_id` references `auth.users`, not
    /// `public.profiles`, so PostgREST has no foreign key to resolve the join
    /// through and asking for one returns an error, not a null.
    public struct Collaborator: Codable, Sendable, Identifiable, Hashable {
        public let sharedPlaylistID: UUID
        public let userID: UUID
        public var role: String
        public var joinedAt: Date
        /// Raw column value. Read `status` instead — an unrecognised string from a
        /// newer client should leave the row visible, not fail the whole decode.
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
            // Every row that predates 20260811 is somebody who redeemed a code,
            // which is a join. Defaulting the other way would eject them.
            rawStatus        = try c.decodeIfPresent(String.self, forKey: .rawStatus) ?? InviteStatus.joined.rawValue
            invitedBy        = try c.decodeIfPresent(UUID.self, forKey: .invitedBy)
            invitedAt        = try c.decodeIfPresent(Date.self, forKey: .invitedAt)
            respondedAt      = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        }
    }

    /// The column list every collaborator read asks for. One constant because the
    /// decoder needs all of them and a select that quietly omits one fails at
    /// decode time, a long way from the query that caused it.
    private static let collaboratorColumns =
        "shared_playlist_id,user_id,role,joined_at,status,invited_by,invited_at,responded_at"

    /// Everyone on `sharedPlaylistID` — including people who have only been
    /// invited and people who said no — oldest first.
    ///
    /// The owner is usually *not* in here: ownership lives on
    /// `shared_playlists.owner_id`, and `shareToSupabase` never writes a
    /// collaborator row for them. A member list should add them separately.
    public func collaborators(sharedPlaylistID: UUID) async throws -> [Collaborator] {
        try await client
            .from("playlist_collaborators")
            .select(Self.collaboratorColumns)
            .eq("shared_playlist_id", value: sharedPlaylistID)
            .order("joined_at", ascending: true)
            .execute()
            .value
    }

    /// Invites someone directly, with no code changing hands. Allowed by the
    /// "Owner adds collaborators" policy, so it fails for everyone else.
    ///
    /// The row lands as `invited`, not `joined`: being added to a stranger's
    /// playlist without being asked is how a library fills with things nobody
    /// chose. Nothing appears in their library until they accept — see
    /// `pendingInvites` for the other end of this.
    ///
    /// Re-inviting someone who declined is allowed and resets the invite. Anyone
    /// already invited or joined is left alone, so tapping Invite twice can't
    /// re-ask a person who is already in.
    ///
    /// The return value exists because the no-op cases are indistinguishable from
    /// success at the call site, and the sheet was announcing "Invited @x" for all
    /// of them. Someone who had joined by link earlier got an invite that was
    /// never written, a toast saying it had been, and nothing on their phone —
    /// three symptoms of one silent branch.
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

    /// What `addCollaborator` actually did. Three of the four cases write nothing,
    /// and the caller has to be able to tell the user which one they got.
    public enum InviteOutcome: Sendable, Hashable {
        /// A fresh invite row is now waiting for an answer.
        case invited
        /// They had declined before; the invite has been re-opened.
        case reinvited
        /// Already accepted — they are in the playlist and can add songs.
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
        /// Resolved separately from the collaborator row — `invited_by` points at
        /// `auth.users`, so PostgREST can't embed the profile.
        public let inviterName: String?
        public let invitedAt: Date

        public var id: UUID { record.id }
        public var sharedPlaylistID: UUID { record.id }

        public static func == (a: PendingInvite, b: PendingInvite) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Invites waiting on this account, newest first.
    ///
    /// Published rather than fetched per screen because an invite has to be able
    /// to interrupt: the whole defect this fixes was that being invited was an
    /// event nobody's device ever noticed. One store, refreshed on sign-in and on
    /// foreground, and every surface that wants to show a badge observes it.
    @Published public private(set) var pendingInvites: [PendingInvite] = []

    /// Re-reads the inbox. Silent on failure — an invite you don't learn about
    /// for another minute is a far smaller problem than an error banner over a
    /// library, and this runs unprompted.
    ///
    /// No new RLS was needed: "Members read collaborators" already matches
    /// `user_id = auth.uid()`, and holding a collaborator row is what "Members
    /// read shared playlists" checks. Two queries rather than an embed, for the
    /// usual reason — the join crosses into `auth.users`.
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
            print("[Sharing] ❌ Invite inbox read failed: \(error)")
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
            print("[Sharing] ❌ Invite playlist read failed: \(error)")
            return
        }

        // One lookup per distinct inviter, not per invite — three invites from the
        // same person is one profile.
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

    /// Accepts or declines an invite, and on acceptance puts the playlist in the
    /// library. Returns the local playlist id when one was created or adopted.
    ///
    /// The status write comes first and is allowed to throw: if it fails, nothing
    /// has been added locally, and the invite is still sitting in the inbox to try
    /// again. Doing it the other way round would leave a playlist in the library
    /// that the server still thinks was never accepted — which the "Members update
    /// shared playlists" policy would then refuse every edit to, silently.
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

    /// Last known visibility for a local playlist. A cache, not the truth — the
    /// server is authoritative and another device can change it — but a toggle
    /// has to draw itself before any network call comes back.
    public func isPublicCached(localPlaylistID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: publicDefaultsKey(localPlaylistID))
    }

    public func cachePublic(_ isPublic: Bool, localPlaylistID: UUID) {
        UserDefaults.standard.set(isPublic, forKey: publicDefaultsKey(localPlaylistID))
    }

    /// Shows or hides `playlist` on the owner's public profile.
    ///
    /// Publishing needs a `shared_playlists` row, because that's the only place a
    /// track snapshot lives and a profile visitor owns none of the songs. If the
    /// playlist has never been shared, one is created here — silently, with a
    /// share code that is never surfaced. Going public is not the same as handing
    /// out a collaborator link, and the profile query deliberately doesn't return
    /// the code.
    ///
    /// Turning it on also refreshes the snapshot, so what people see is the
    /// playlist as it is now rather than as it was when it was first shared.
    public func setPublic(_ isPublic: Bool,
                          playlist: Playlist,
                          tracks: [Track],
                          deviceID: String) async throws {
        var link = linkedShare(forLocalPlaylist: playlist.id)

        // Only the owner may publish. A playlist joined from someone else's code
        // isn't ours to put on our profile.
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

        // The cover moves with the switch: published when the playlist goes on the
        // profile, deleted when it comes off. Leaving the image behind would keep
        // a picture of an unpublished playlist readable by anyone who kept the URL.
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
            let artwork_path: String?
            let updated_at: Date
        }

        let payload = VisibilityPayload(
            is_public: isPublic,
            name: playlist.name,
            description: playlist.description,
            track_ids: playlist.trackIDs,
            tracks: Self.snapshot(playlist: playlist, resolving: tracks),
            artwork_path: artworkPath,
            updated_at: Date()
        )

        try await client
            .from("shared_playlists")
            .update(payload)
            .eq("id", value: link.sharedPlaylistID.uuidString)
            .execute()

        cachePublic(isPublic, localPlaylistID: playlist.id)

        // Not awaited, and safe not to be: track cover paths are derived from the
        // owner and the track id, so the row above doesn't reference them and is
        // correct the moment it lands. Holding the toggle open for one upload per
        // song would make publishing a long playlist feel broken. If the app quits
        // mid-upload, `backfillPublishedCovers` finishes the job next time the
        // owner looks at their own profile.
        if isPublic {
            let snapshot = tracks
            Task { await self.publishTrackCovers(snapshot) }
        }
    }

    // MARK: - Sharing by link

    /// The shared row id behind mixtaped.tech/playlist/<id>, opening the row to
    /// link visitors on the way (`link_shared`, see 20260915000000).
    ///
    /// Separate from `setPublic`: a link must never put a playlist on a profile.
    /// A saved playlist hands out the owner's link; an editor can't open someone
    /// else's playlist to the internet.
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
            let artwork_path: String?
            let updated_at: Date
        }
        // A row that was taken off a profile lost its cover (see setPublic); a
        // new one was just given it by shareToSupabase.
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
                artwork_path: artworkPath,
                updated_at: Date()
            ))
            .eq("id", value: link.sharedPlaylistID.uuidString)
            .execute()
        return link.sharedPlaylistID
    }

    // MARK: - Taking a published playlist down

    // Both of these address the `shared_playlists` row directly, and that is the
    // entire reason they exist. `setPublic` is the ordinary way to hide a
    // playlist and it needs the local `Playlist`, because it republishes the
    // snapshot on its way past — fine right up until the local playlist isn't
    // there. Clear the library, reinstall, switch accounts, and the published
    // rows carry on sitting on the profile with nothing on the device able to
    // reach them: the only thing the page could offer was to restore the
    // playlist you were trying to get rid of.

    /// Takes a playlist off its owner's profile, keeping the row.
    ///
    /// The right call when the playlist still exists and might go back up:
    /// collaborators keep their access and the share code stays valid. The cover
    /// goes either way — leaving the image behind keeps a picture of an
    /// unpublished playlist readable by anyone who kept the URL.
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

        // Keep the local toggle honest when this device does still hold a copy —
        // otherwise its playlist page draws "On My Profile" over a playlist that
        // is no longer on it.
        if let localID = localPlaylistID(forSharedPlaylist: sharedPlaylistID) {
            cachePublic(false, localPlaylistID: localID)
        }
    }

    /// Deletes the published row outright.
    ///
    /// For when the playlist itself is going away, rather than just going
    /// private. Collaborator rows — and the invites carried on them — cascade
    /// from their foreign key, so this is the whole cleanup server-side. The
    /// stored link goes too: left behind it would point at a row that no longer
    /// exists, and `setPublic` refuses to publish through a stale link.
    ///
    /// Owner-only, enforced by the table's delete policy rather than here.
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

    /// The public bucket holding covers of published playlists. Deliberately not
    /// `artwork`, which is private and owner-scoped — see
    /// 20260808000000_public_playlist_covers.sql for why publishing one cover
    /// must not open a whole library.
    static let coverBucket = "playlist-covers"

    static func coverPath(ownerID: UUID, sharedPlaylistID: UUID) -> String {
        "\(ownerID.uuidString.lowercased())/\(sharedPlaylistID.uuidString.lowercased()).jpg"
    }

    /// Public URL for a stored cover path. The bucket is public, so this needs no
    /// token and no round trip — which is the point: a profile showing six covers
    /// would otherwise be six signed-URL requests before anything appears.
    public static func coverURL(path: String) -> URL? {
        SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(coverBucket)
            .appendingPathComponent(path)
    }

    /// Where a published song's cover lives, in the same public bucket.
    ///
    /// Derived rather than stored, unlike the playlist's own cover. A visitor
    /// already knows both halves — whose profile they are on, and the track id
    /// from the published snapshot — so the address needs no column, no migration
    /// and no round trip to discover. It also means a song in two published
    /// playlists is one object rather than two copies.
    ///
    /// The trade is that "no cover" and "not uploaded yet" both read as a 404,
    /// which is fine: the caller falls back to the catalogue either way.
    nonisolated static func trackCoverPath(ownerID: UUID, trackID: UUID) -> String {
        "\(ownerID.uuidString.lowercased())/tracks/\(trackID.uuidString.lowercased()).jpg"
    }

    nonisolated public static func trackCoverURL(ownerID: UUID, trackID: UUID) -> URL? {
        SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(coverBucket)
            .appendingPathComponent(trackCoverPath(ownerID: ownerID, trackID: trackID))
    }

    /// Uploads covers for rows that were published before covers existed.
    ///
    /// Without this, every playlist already on a profile stays a grey square until
    /// its owner happens to toggle it off and on again — a repair nobody would
    /// think to perform, on a screen that gives no hint it's needed. Runs when the
    /// owner opens their own profile, which is both the only place the local
    /// artwork is reachable and the moment they'd notice it missing.
    ///
    /// Returns the ids it filled in, so the caller can refresh what's on screen.
    @discardableResult
    public func backfillPublishedCovers(_ summaries: [PublicPlaylistSummary],
                                        library: LibraryService) async -> Set<UUID> {
        var repaired: Set<UUID> = []

        for summary in summaries where summary.artworkPath == nil {
            // Only the owner holds the local playlist, and only the owner may
            // write the row — the same fact expressed twice, which is why no
            // separate ownership check is needed here.
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
                print("[Sharing] ❌ Cover backfill failed for \(summary.name): \(error)")
            }
        }

        // Song covers for every published playlist, not just the ones missing a
        // playlist cover — a playlist can have had its own picture from day one
        // and still have published none of its songs'.
        let songs = summaries
            .flatMap(\.tracks)
            .compactMap { library.track(id: $0.id) }
        if !songs.isEmpty {
            var seen = Set<UUID>()
            await publishTrackCovers(songs.filter { seen.insert($0.id).inserted })
        }

        return repaired
    }

    /// Uploads the playlist's cover and returns its stored path, or nil when the
    /// playlist has no artwork or the upload fails. A failure is deliberately not
    /// thrown: a missing picture is worth far less than the publish itself, and
    /// failing the whole toggle over it would be the wrong trade.
    private func uploadCover(playlist: Playlist, sharedPlaylistID: UUID) async -> String? {
        guard let raw = playlist.displayArtwork else { return nil }
        guard let session = try? await client.auth.session else { return nil }
        // 512px matches the avatar path; the largest a cover is ever drawn is the
        // 180pt detail hero, so anything bigger is bytes nobody sees.
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
            print("[Sharing] ❌ Cover upload failed for \(playlist.name): \(error)")
            return nil
        }
    }

    private func deleteCover(sharedPlaylistID: UUID) async {
        guard let session = try? await client.auth.session else { return }
        let path = Self.coverPath(ownerID: session.user.id, sharedPlaylistID: sharedPlaylistID)
        _ = try? await client.storage.from(Self.coverBucket).remove(paths: [path])
    }

    // MARK: - Published track thumbnails

    /// Publishes the covers of the songs inside a playlist that's on a profile.
    ///
    /// The playlist's own cover isn't enough. What a visitor adopts is the
    /// *songs*, and those arrive as `SharedTrackMeta` — title, artist, album,
    /// duration and nothing else — so they land in the new library as rows of
    /// grey squares. Asking the catalogue was the first answer and it only works
    /// for records that were commercially released; for everything imported from
    /// a link, which is most of what's actually in these libraries, it returns
    /// nothing and the squares stay grey. The owner is holding the right image
    /// already. This is what carries it over.
    ///
    /// Ids that went up are remembered locally, so re-publishing or opening your
    /// own profile costs nothing after the first time. The record being
    /// per-device is deliberate: if it's wrong the worst case is a redundant
    /// upsert, never a missing picture.
    func publishTrackCovers(_ tracks: [Track]) async {
        guard let session = try? await client.auth.session else { return }

        var published = Self.publishedTrackCoverIDs
        let pending = tracks.filter { $0.artworkData != nil && !published.contains($0.id.uuidString) }
        guard !pending.isEmpty else { return }

        // Sequential, matching the sync service's own artwork upload. A playlist
        // is tens of songs, each image is ~20KB at 300px, and the caller doesn't
        // wait on this — see the call in `setPublic`.
        var uploadedAny = false
        for track in pending {
            guard let raw = track.artworkData,
                  // Smaller than the playlist cover on purpose: a song's cover is
                  // never drawn larger than a 40pt row or a 180pt album tile.
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
                print("[Sharing] ❌ Track cover upload failed for \(track.title): \(error)")
            }
        }

        if uploadedAny {
            Self.publishedTrackCoverIDs = published
            print("[Sharing] ✅ Published \(pending.count) track cover(s)")
        }
    }

    private static let publishedTrackCoversKey = "mix.sharing.publishedTrackCovers"

    private static var publishedTrackCoverIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: publishedTrackCoversKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: publishedTrackCoversKey) }
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
        let previous = linkedShare(forLocalPlaylist: localPlaylistID)

        if let link, let data = try? JSONEncoder().encode(link) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Keep the reverse index in step. It exists because the interesting
        // question at a public playlist is the one the forward key can't answer:
        // "do I already have THIS shared row?" — and the local copy's id is a
        // fresh uuid that shares nothing with the original.
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

    /// The local playlist made from a given shared row, if this device has one.
    ///
    /// Only as good as the device it's on — the mapping lives in UserDefaults, so
    /// adding the same playlist on your phone and your Mac still produces two
    /// copies. Fixing that properly means a synced column on public.playlists;
    /// this stops the duplicate that actually bites, which is adding it twice from
    /// the same profile page.
    public func localPlaylistID(forSharedPlaylist sharedPlaylistID: UUID) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: reverseLinkKey(sharedPlaylistID)) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    /// If `localPlaylistID` is linked to a shared row, re-pulls the latest snapshot
    /// and reconciles the local track list to match it (LWW on updatedAt — same model
    /// as the existing playlist sync). Tracks present locally are linked; tracks that
    /// aren't are imported as unavailable placeholders so the playlist isn't empty.
    /// No-op if the playlist isn't linked or the user isn't signed in.
    public func refreshSharedPlaylist(localPlaylistID: UUID, libraryService: LibraryService) async {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID) else { return }

        // A saved public playlist is linked too, but it holds no share code and
        // must never go through join — that would enrol the saver as an editor.
        guard !link.isViewer else {
            await refreshSubscription(localPlaylistID: localPlaylistID, libraryService: libraryService)
            return
        }

        guard let remote = try? await fetchSharedPlaylist(shareCode: link.shareCode) else { return }

        guard let local = libraryService.playlist(id: localPlaylistID) else { return }

        // The cover is outside the LWW check on purpose. It isn't part of the
        // track list being raced over, only the owner can set it, and a playlist
        // that joined before its cover was uploaded would otherwise stay a grey
        // square for as long as nobody edited it.
        await adoptCover(record: remote,
                         localPlaylistID: localPlaylistID,
                         libraryService: libraryService)

        // LWW: only adopt the remote list if it's at least as new as our local copy.
        guard remote.updatedAt >= local.dateModified else { return }

        libraryService.reconcileSharedPlaylist(
            localPlaylistID: localPlaylistID,
            remoteTrackIDs: remote.trackIds,
            remoteTrackMeta: remote.tracks,
            ownerID: remote.ownerId
        )
    }

    /// Pushes this device's track list for a linked playlist up to the shared row.
    ///
    /// The other half of `refreshSharedPlaylist`, and the thing that makes an invite
    /// mean anything: without it an editor's additions never left their device, and
    /// "collaborative" described a one-way subscription. Safe for either role — the
    /// column-guard trigger keeps a non-owner to the track columns, so an editor
    /// can't rename or unpublish the playlist by pushing.
    ///
    /// Silent on failure by design. This runs off the back of an edit the user has
    /// already seen succeed locally; an alert about the *other* copy of the playlist
    /// would be noise they can't act on, and the next open reconciles anyway.
    public func pushLocalChanges(localPlaylistID: UUID, libraryService: LibraryService) async {
        guard let link = linkedShare(forLocalPlaylist: localPlaylistID),
              link.role == "owner" || link.role == "editor",
              let local = libraryService.playlist(id: localPlaylistID)
        else { return }

        struct TracksPayload: Encodable {
            let track_ids: [UUID]
            let tracks: [SharedTrackMeta]
            let updated_at: Date
        }

        // Placeholders are in `libraryService.tracks`, and that's what stops an
        // editor wiping every song they personally don't have: `snapshot` drops ids
        // it can't resolve, and an unavailable song still resolves to a row.
        let payload = TracksPayload(
            track_ids: local.trackIDs,
            tracks: Self.snapshot(playlist: local, resolving: libraryService.tracks),
            updated_at: Date()
        )

        do {
            try await client
                .from("shared_playlists")
                .update(payload)
                .eq("id", value: link.sharedPlaylistID.uuidString)
                .execute()
        } catch {
            print("[Sharing] ❌ Push failed for \(local.name): \(error)")
        }

        // A song the owner adds after sharing needs its cover published too, or
        // it's the one grey row in an otherwise complete playlist. Owner-only:
        // covers are read back under the shared row's `owner_id`, so an editor
        // uploading here would be posting to an address nobody reads.
        // `publishTrackCovers` remembers what it has sent, so this costs nothing
        // for the songs that were already up.
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
        /// The playlist exists but is no longer published — the owner made it
        /// private, or took it down. Distinct from `notFound` because the answer
        /// for the user is different: wait, or remove it. Nothing was revoked.
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
