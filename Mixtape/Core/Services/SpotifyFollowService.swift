// SpotifyFollowService.swift
// Mixtape — Core/Services
//
// Keeps imported Spotify playlists in step with the Spotify account they came
// from, so adding a song there adds it here.
//
// Why polling
//   Spotify has no push and no webhooks: nothing can tell Mixtape the moment a
//   song is added. What it does have is `snapshot_id`, a version marker that
//   changes on any edit — so "has this playlist changed?" costs one request of a
//   few dozen bytes whatever the playlist's size, and the expensive full read
//   only happens when the answer is yes. That's what makes checking forty
//   playlists every quarter of an hour reasonable rather than rude.
//
// Why the link lives here and not on the playlist
//   `Playlist.origin` already records that a playlist is a mirror, and that is
//   stored. The Spotify id behind it is kept in this file's own JSON store, the
//   same way `PlaylistMetadataService` keeps pins: the playlists table is synced
//   to Supabase and a new column there is a migration plus a matching change in
//   the web client.
//
// Why it follows the account
//   Because a link is a fact about the account, and keeping it purely on the
//   device meant losing it. Signing out and back in announced a library reset,
//   which dropped every link on the floor — and a lost link takes the whole
//   Spotify section of the playlist's menu with it, with no way back short of
//   removing every song and importing them again. It never reached a second
//   device either. So the identifying half rides in `user_metadata` beside the
//   import ledger; see `SpotifyImportLedger` for why that store and not a table.
//
//   The bulk fields stay on the device: `contributedIDs`, `syncedIDs` and
//   `uriByTrack` are tens of kilobytes for a large Liked Songs and there is no
//   room for them there. A device without them is in the same position as one
//   whose direction just changed — no agreed base, so the next sync reads both
//   sides as additions and nothing is deleted anywhere. See `setDirection`.

import Foundation
import Combine

@MainActor
public final class SpotifyFollowService: ObservableObject {

    // MARK: - Link

    public struct Link: Codable, Sendable, Hashable {

        public enum Kind: String, Codable, Sendable {
            case playlist
            case likedSongs
        }

        /// Which way changes travel.
        ///
        /// Presented as two independent toggles — "Spotify to Mixtape" and
        /// "Mixtape to Spotify" — because that is what people actually want to
        /// decide, and because ticking both is a real, well-defined thing here
        /// rather than a compromise: see `merge`.
        public enum Direction: String, Codable, Sendable {
            case pull   // Spotify is the source. The playlist is read-only here.
            case push   // Mixtape is the source. Spotify's copy is overwritten.
            case both   // Three-way merge, both ends end up the same.

            public var pulls: Bool { self != .push }
            public var pushes: Bool { self != .pull }
        }

        /// Spotify's id for the source, or `SpotifyLibraryItem.likedSongsID`.
        public var sourceID: String
        public var kind: Kind
        /// What it was called on Spotify when it was linked, for the byline and
        /// for saying which playlist a failure was about.
        public var name: String
        /// Spotify's version marker at the last successful check. Playlists only.
        public var snapshotID: String?
        /// The liked-songs total at the last successful check. Liked Songs only —
        /// it has no snapshot id, so this is the cheap signal in its place.
        public var likedCount: Int?
        /// The library ids this link put into Favourites last time.
        ///
        /// Only Liked Songs uses it, and it is the whole reason unliking on
        /// Spotify can un-heart here without ever touching a song the user
        /// hearted themselves: a song leaving Spotify's list is only removed if
        /// this list says Spotify is where it came from.
        public var contributedIDs: [UUID]?
        public var lastSyncedAt: Date?

        /// Stored rather than computed so that links written before directions
        /// existed decode without a migration: a missing value is `pull`, which
        /// is exactly what every link written until now was.
        ///
        /// Synthesised `Codable` ignores property defaults when *decoding*, so
        /// this has to be an Optional with the fallback in the accessor. The
        /// `= nil` is still worth having: it gives the memberwise init a
        /// default, so the existing call sites don't have to say anything.
        public var directionRaw: String? = nil

        public var direction: Direction {
            get { directionRaw.flatMap(Direction.init(rawValue:)) ?? .pull }
            set { directionRaw = newValue.rawValue }
        }

        /// The track list both ends agreed on at the last successful sync — the
        /// base of the three-way merge. Without it, "this song is here and not
        /// there" is unanswerable: it could be an add on one side or a delete on
        /// the other, and guessing wrong either resurrects deleted songs forever
        /// or quietly deletes new ones.
        public var syncedIDs: [UUID]? = nil

        /// Library track id → the Spotify URI it was matched to, so a push
        /// doesn't re-search songs it has already found. Keyed by string
        /// because `UUID` isn't a `Codable` dictionary key in JSON.
        public var uriByTrack: [String: String]? = nil

        /// The name, description and cover both ends agreed on last time — the
        /// same idea as `syncedIDs`, for everything about a playlist that isn't
        /// its songs. Without a base, "these differ" can't say *which* side
        /// moved, so a two-way playlist would push its old title back over a
        /// rename made on Spotify (or the other way round) forever.
        ///
        /// The cover is compared by Spotify's image URL on their side and by a
        /// hash of the bytes on ours: Spotify re-encodes what it's given, so the
        /// image that comes back is never byte-identical to the one that went
        /// up and comparing pictures directly would upload on every tick.
        public var syncedName: String? = nil
        public var syncedDescription: String? = nil
        public var syncedCoverURL: String? = nil
        public var syncedCoverHash: Int? = nil
    }

    // MARK: - Published

    /// Playlists being checked right now, for the spinner in their header.
    @Published public private(set) var syncing: Set<UUID> = []
    /// Last successful check per playlist, for "Updated 4 minutes ago".
    @Published public private(set) var lastSynced: [UUID: Date] = [:]
    /// Why the last check failed, per playlist. Cleared by the next success.
    @Published public private(set) var failures: [UUID: String] = [:]

    // MARK: - Dependencies

    private let client: SpotifyClient
    private let auth: SpotifyAuth
    private let importService: SpotifyImportService
    private let exportService: SpotifyExportService
    private let libraryService: LibraryService

    /// The one `AppDependencies` builds, so the auth service can hand it the
    /// account's copy on sign-in. Weak and static for the same reason as
    /// `SpotifyImportLedger.shared`: it is not a singleton.
    public private(set) static weak var shared: SpotifyFollowService?

    private var links: [UUID: Link] = [:]
    /// The playlists the last publish showed. See `propagateLocalDeletions` —
    /// this is what tells a deletion apart from a library that hasn't loaded.
    private var seenPlaylistIDs: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var localEdits: AnyCancellable?

    /// How often the background check runs while the app is open.
    ///
    /// Three minutes rather than the quarter hour this started at. The unchanged
    /// case is one `snapshot_id` request per playlist — a few dozen bytes — so
    /// the cost of asking more often is small, and a quarter of an hour was long
    /// enough that people reasonably concluded nothing was syncing at all.
    private static let interval: TimeInterval = 3 * 60

    public init(client: SpotifyClient,
                auth: SpotifyAuth,
                importService: SpotifyImportService,
                exportService: SpotifyExportService,
                libraryService: LibraryService) {
        self.client         = client
        self.auth           = auth
        self.importService  = importService
        self.exportService  = exportService
        self.libraryService = libraryService
        Self.shared         = self
        self.links          = Self.load()
        self.lastSynced     = links.compactMapValues(\.lastSyncedAt)

        observeLocalEdits()

        // A wiped library has no playlists left to follow, and a link pointing
        // at a playlist that no longer exists would recreate songs the user just
        // deleted on the next tick.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let reset = UserDataReset.from(note)
                // An account switch is not a wipe: the links this device now
                // holds are the incoming user's own, adopted moments ago.
                guard reset.clearedLibrary, !reset.isAccountSwitch else { return }
                self?.forgetAllLinks()
            }
        }
    }

    // MARK: - Linking

    public func link(_ link: Link, toPlaylist playlistID: UUID) {
        links[playlistID] = link
        unlinked[playlistID] = nil
        applyOrigin(for: link, playlistID: playlistID)
        save()
    }

    /// Changes which way an existing link travels.
    ///
    /// The direction is also what decides whether the playlist is editable
    /// here, so this has to move the origin with it — a playlist that pushes to
    /// Spotify is one the user edits, and leaving it a read-only mirror would
    /// mean a sync direction nobody could ever feed.
    public func setDirection(_ direction: Link.Direction, forPlaylist playlistID: UUID) {
        guard var link = links[playlistID], link.direction != direction else { return }
        link.direction = direction
        // The agreed-on base belongs to the old arrangement. Dropping it makes
        // the next sync treat both sides as additions, which for a switch of
        // direction is the safe reading: nothing is deleted anywhere.
        link.syncedIDs = nil
        links[playlistID] = link
        applyOrigin(for: link, playlistID: playlistID)
        save()
    }

    /// Read-only is for one arrangement only: Spotify is the source and the user
    /// doesn't edit this copy. Anything the user's own edits feed — push, or a
    /// two-way merge — has to stay an ordinary owned playlist.
    ///
    /// Liked Songs is never a mirror at all: it syncs *into* Favourites, which
    /// stays the user's own editable list. See `syncLikedSongs`.
    private func applyOrigin(for link: Link, playlistID: UUID) {
        guard link.kind == .playlist else { return }
        libraryService.setOrigin(link.direction == .pull ? .spotifyMirror : .owned,
                                 forPlaylist: playlistID)
    }

    /// Stops following, and hands the playlist back as an ordinary one.
    ///
    /// Nothing is removed: the songs it collected are songs the user has, and a
    /// playlist that emptied itself when unlinked would make following it a
    /// decision people were afraid to reverse.
    public func unlink(playlistID: UUID) {
        guard let link = links.removeValue(forKey: playlistID) else { return }
        unlinked[playlistID] = contributions(of: link, playlistID: playlistID)
        if link.kind == .playlist {
            libraryService.setOrigin(.owned, forPlaylist: playlistID)
        }
        lastSynced[playlistID] = nil
        failures[playlistID]   = nil
        save()
    }

    /// What this link put into a playlist the user also owns — i.e. Favourites.
    ///
    /// Only meaningful for a Liked Songs link: a followed playlist's whole
    /// contents are the link's contribution, and its own row count says so.
    public func contributionCount(playlistID: UUID) -> Int {
        importedSongs(playlistID: playlistID).count
    }

    /// What an import put into this playlist and is still there — whether the
    /// link is standing or was removed earlier. The tombstone keeps the list,
    /// so "take the imported songs out" stays available after unlinking.
    public func importedSongs(playlistID: UUID) -> [UUID] {
        let contributed = links[playlistID].map { contributions(of: $0, playlistID: playlistID) }
            ?? unlinked[playlistID] ?? []
        guard !contributed.isEmpty else { return [] }
        let current = Set(libraryService.playlist(id: playlistID)?.trackIDs ?? [])
        var seen: Set<UUID> = []
        return contributed.filter { current.contains($0) && seen.insert($0).inserted }
    }

    private func contributions(of link: Link, playlistID: UUID) -> [UUID] {
        link.kind == .likedSongs
            ? contributedSongs(link: link, playlistID: playlistID)
            : (libraryService.playlist(id: playlistID)?.trackIDs ?? [])
    }

    /// The songs still in the playlist that this link put there, each once.
    ///
    /// `contributedIDs` is an append-only record of what has been mirrored, so
    /// the same song can appear in it more than once — Spotify listing it again
    /// after a push, most often. Counting the raw array claimed 2,206 songs in
    /// a playlist holding 2,086.
    private func contributedSongs(link: Link, playlistID: UUID) -> [UUID] {
        let current = Set(libraryService.playlist(id: playlistID)?.trackIDs ?? [])
        var seen: Set<UUID> = []
        return (link.contributedIDs ?? []).filter { current.contains($0) && seen.insert($0).inserted }
    }

    /// Stops following *and* takes the songs this link brought over back out.
    ///
    /// The two halves have to happen together: removing the songs while the
    /// link stands would just mean the next pull put them all back.
    ///
    /// Only the songs this link contributed, never one the user hearted
    /// themselves — that is what `contributedIDs` is for. Anything still held
    /// by a playlist the user made, a saved album or a file of their own stays
    /// in the library; everything else goes with it, because
    /// `LibraryService.removeTracks` sweeps what nothing holds any more.
    ///
    /// There used to be a second, gentler option here — take them out of Liked
    /// Songs but leave them in the library. Under derived membership that is
    /// not a state the library can hold: a song no list holds is not in the
    /// library, so the "gentler" choice left thousands of rows that every
    /// screen but All Songs had already forgotten.
    @discardableResult
    public func unlinkRemovingImports(playlistID: UUID) -> Int {
        let mine = importedSongs(playlistID: playlistID)
        unlink(playlistID: playlistID)
        // Emptied rather than dropped: the key is what stops `adoptRemote`
        // putting the link back, and these songs are no longer owed a cleanup.
        if unlinked[playlistID] != nil { unlinked[playlistID] = [] }
        guard !mine.isEmpty else { return 0 }
        libraryService.removeTracks(ids: mine, fromPlaylist: playlistID)
        return mine.count
    }

    public func link(forPlaylist playlistID: UUID) -> Link? { links[playlistID] }

    public func isFollowing(playlistID: UUID) -> Bool { links[playlistID] != nil }

    public var followedCount: Int { links.count }

    /// Whether following is available at all: it needs a connected account.
    public var isAvailable: Bool { auth.isAuthorized && !auth.needsReauthorization }

    // MARK: - Scheduling

    /// Checks everything now, then every 15 minutes for as long as the app runs.
    public func startAutoSync() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    public func stopAutoSync() {
        timer?.cancel()
        timer = nil
    }

    /// Pushes an edit made here without waiting for the quarter-hour tick.
    ///
    /// Polling is the right shape for "did something change on Spotify?",
    /// because only Spotify knows. It is the wrong shape entirely for "did
    /// something change here" — the app is holding the answer. Adding a song to
    /// a two-way playlist and watching Spotify not have it for fifteen minutes
    /// is the difference between a feature and a promise.
    ///
    /// Debounced, because dragging twenty songs in publishes twenty times and
    /// each of those would otherwise be a write to somebody's Spotify account.
    private func observeLocalEdits() {
        localEdits = libraryService.$playlists
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] playlists in
                guard let self else { return }
                Task { await self.pushLocalChanges(playlists) }
            }
    }

    private func pushLocalChanges(_ playlists: [Playlist]) async {
        guard isAvailable else { return }
        await propagateLocalDeletions(playlists)
        let due = links.compactMap { id, link -> UUID? in
            guard link.kind == .playlist, link.direction.pushes else { return nil }
            // No base means the two ends have never agreed on anything yet, so
            // there is no "changed since" to measure. The timer's ordinary pass
            // establishes one; this only chases edits after that.
            guard let base = link.syncedIDs,
                  let playlist = playlists.first(where: { $0.id == id }),
                  playlist.trackIDs != base
            else { return nil }
            return id
        }
        for id in due { await sync(playlistID: id, force: true) }
    }

    /// Deleting a linked playlist here deletes it on Spotify.
    ///
    /// Only for a link that pushes: a playlist you were merely following is one
    /// you removed your *copy* of, and reaching into the account to remove the
    /// original would be doing something nobody asked for. Spotify has no
    /// delete, so this unfollows — which is what deleting a playlist does in
    /// their own client.
    ///
    /// It watches for a playlist *going away*, never for one being absent: at
    /// launch, and for a moment after an account switch, the library is empty
    /// because nothing has loaded yet, and "absent" there would mean deleting
    /// every linked playlist on the account. `seenPlaylistIDs` is what makes the
    /// difference between the two, and an empty list is never treated as news.
    private func propagateLocalDeletions(_ playlists: [Playlist]) async {
        guard !playlists.isEmpty else { return }
        let present = Set(playlists.map(\.id))
        defer { seenPlaylistIDs = present }
        guard !seenPlaylistIDs.isEmpty else { return }

        let vanished = links.keys.filter {
            seenPlaylistIDs.contains($0) && !present.contains($0)
        }
        guard !vanished.isEmpty else { return }

        for id in vanished {
            guard let link = links.removeValue(forKey: id) else { continue }
            lastSynced[id] = nil
            failures[id]   = nil
            guard link.kind == .playlist, link.direction.pushes else { continue }
            do {
                let token = try await auth.validAccessToken()
                try await client.unfollowPlaylist(playlistID: link.sourceID, accessToken: token)
            } catch {
                // The playlist is gone here either way; a failed write to
                // Spotify leaves their copy standing rather than blocking the
                // deletion the user actually made.
                print("[SpotifyFollow] Couldn't remove \(link.name) from Spotify: \(error)")
            }
        }
        save()
    }

    // MARK: - Syncing

    /// One pass over every followed playlist. Serialised against itself: the
    /// timer and an opened playlist can both ask, and two passes writing the same
    /// library rows is how you get duplicates.
    public func syncAll(force: Bool = false) async {
        guard isAvailable, !links.isEmpty else { return }
        await withRunning {
            for (playlistID, _) in self.links {
                await self.syncOne(playlistID: playlistID, force: force)
            }
        }
    }

    /// Checks one followed playlist. `force` skips the snapshot shortcut, which
    /// is what a manual "Sync now" means.
    public func sync(playlistID: UUID, force: Bool = false) async {
        guard isAvailable, links[playlistID] != nil else { return }
        await withRunning {
            await self.syncOne(playlistID: playlistID, force: force)
        }
    }

    private func withRunning(_ body: @escaping () async -> Void) async {
        if let running { _ = await running.result }
        let task = Task { await body() }
        running = task
        _ = await task.result
        if running == task { running = nil }
    }

    private func syncOne(playlistID: UUID, force: Bool) async {
        guard var link = links[playlistID] else { return }

        // The playlist itself may have been deleted since it was linked. Drop the
        // link rather than resurrecting it — and if this link pushes, take
        // Spotify's copy with it, the same as `propagateLocalDeletions`. Both
        // paths exist because either can get here first: the timer can land
        // between the deletion and the debounced publish that notices it.
        if link.kind == .playlist, libraryService.playlist(id: playlistID) == nil {
            let deleted = seenPlaylistIDs.contains(playlistID)
            links[playlistID] = nil
            save()
            if deleted, link.direction.pushes {
                if let token = try? await auth.validAccessToken() {
                    try? await client.unfollowPlaylist(playlistID: link.sourceID, accessToken: token)
                }
            }
            return
        }

        syncing.insert(playlistID)
        defer { syncing.remove(playlistID) }

        do {
            let token = try await auth.validAccessToken()
            switch link.kind {
            case .playlist:   try await syncPlaylist(playlistID, link: &link, token: token, force: force)
            case .likedSongs: try await syncLikedSongs(link: &link, token: token, force: force)
            }
            link.lastSyncedAt      = Date()
            links[playlistID]      = link
            lastSynced[playlistID] = link.lastSyncedAt
            failures[playlistID]   = nil
            save()
        } catch is CancellationError {
            return
        } catch SpotifyPlaylistError.notFoundOrPrivate where link.kind == .playlist {
            // The playlist is gone from Spotify — deleted, or made private to
            // us. A link that pulls treats that as the deletion it almost always
            // is and removes the copy here; a link that only pushes keeps its
            // playlist and simply stops having anywhere to send it.
            links[playlistID] = nil
            lastSynced[playlistID] = nil
            failures[playlistID]   = nil
            save()
            if link.direction.pulls {
                seenPlaylistIDs.remove(playlistID)
                libraryService.deletePlaylist(id: playlistID)
            } else {
                libraryService.setOrigin(.owned, forPlaylist: playlistID)
            }
        } catch {
            // A failed check is not a reason to unfollow: the network comes back,
            // and a playlist that quietly stopped following after one flight
            // would be worse than one that says it couldn't reach Spotify.
            failures[playlistID] = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
        }
    }

    /// One followed playlist, in whichever direction it was set up for.
    ///
    /// `pull` is the original behaviour: Spotify's list wins outright, and the
    /// copy here is read-only. `push` is its mirror image. `both` is a proper
    /// three-way merge against `syncedIDs`, the list the two ends last agreed
    /// on — which is the only way to tell an add on one side from a delete on
    /// the other. Without a base, a song present here and missing there is
    /// ambiguous, and either guess is wrong half the time: assume "added here"
    /// and deletions never stick, assume "deleted there" and new songs vanish.
    private func syncPlaylist(_ playlistID: UUID,
                              link: inout Link,
                              token: String,
                              force: Bool) async throws {
        let localIDs = libraryService.playlist(id: playlistID)?.trackIDs ?? []

        // The cheap question first. A snapshot that hasn't moved means Spotify's
        // half is unchanged, so unless this link also pushes and the local half
        // *has* moved, there is nothing to do and nothing to fetch.
        if !force, let known = link.snapshotID {
            let current = try await client.fetchSnapshotID(playlistID: link.sourceID,
                                                           accessToken: token)
            let remoteSettled = current == known
            let localSettled  = !link.direction.pushes || localIDs == (link.syncedIDs ?? [])
            guard !(remoteSettled && localSettled) else { return }
        }

        let remote = try await client.fetchContents(
            of: SpotifyLibraryItem(sourceID: link.sourceID,
                                   kind: .playlist,
                                   name: link.name,
                                   subtitle: "",
                                   trackCount: 0,
                                   coverURL: nil),
            accessToken: token
        )

        var owned = libraryService.ownedRecordingIndex
        let remoteIDs = await importService.importTracks(remote.tracks, owned: &owned)
        guard !Task.isCancelled else { throw CancellationError() }

        // Spotify's rows come back with their URIs attached, so every song that
        // is already on both ends gets its URI recorded for free. That is what
        // keeps a push from re-searching the whole playlist every time.
        var uris = link.uriByTrack ?? [:]
        for (id, track) in zip(remoteIDs, remote.tracks) {
            if let uri = track.uri { uris[id.uuidString] = uri }
        }
        link.uriByTrack = uris

        let merged: [UUID]
        switch link.direction {
        case .pull: merged = remoteIDs
        case .push: merged = localIDs
        case .both: merged = Self.merge(base: link.syncedIDs ?? [],
                                        local: localIDs,
                                        remote: remoteIDs)
        }

        // --- Mixtape's half ---
        if merged != localIDs {
            // `setTracks` goes around `isEditable` on purpose — this is the
            // source speaking, which is the one edit a mirror accepts.
            libraryService.setTracks(merged, inPlaylist: playlistID)
            importService.finaliseImport()
        }

        // --- Spotify's half ---
        if link.direction.pushes, merged != remoteIDs {
            let pushURIs = try await resolveURIs(for: merged, link: &link)
            // A song with no match on Spotify can't be written there, but it is
            // still a song the user has — so it stays in the merged list here
            // and is simply absent from Spotify's copy. Blocking the whole push
            // on one unmatchable track would strand every other change.
            try await client.replacePlaylistItems(uris: pushURIs,
                                                  inPlaylist: link.sourceID,
                                                  accessToken: token)
            // The write moved Spotify on, so the snapshot just fetched is stale.
            link.snapshotID = try? await client.fetchSnapshotID(playlistID: link.sourceID,
                                                                accessToken: token)
        } else {
            link.snapshotID = remote.snapshotID
        }

        try await syncDetails(playlistID, link: &link, remote: remote, token: token)

        link.name      = remote.name
        link.syncedIDs = merged
    }

    /// The parts of a playlist that aren't its songs: title, description, cover.
    ///
    /// Same three-way rule as the track list, against the same kind of base
    /// (`syncedName` and friends): whichever side moved since the last agreement
    /// is the side that wins, and a side that didn't move never overwrites one
    /// that did. When both moved, Spotify's wins — it's the copy other people
    /// can see.
    ///
    /// Everything here is best-effort. A cover that Spotify won't take, or a
    /// grant made before covers were part of the picture, must not fail a sync
    /// that has already moved the songs.
    private func syncDetails(_ playlistID: UUID,
                             link: inout Link,
                             remote: SpotifyPlaylist,
                             token: String) async throws {
        guard let local = libraryService.playlist(id: playlistID) else { return }

        let remoteDescription = remote.description ?? ""
        let localDescription  = local.description ?? ""
        let remoteCover       = remote.coverURL?.absoluteString
        let localCoverHash    = local.artworkData?.hashValue

        let remoteNameMoved  = remote.name != (link.syncedName ?? link.name)
        let remoteDescMoved  = remoteDescription != (link.syncedDescription ?? remoteDescription)
        let remoteCoverMoved = remoteCover != link.syncedCoverURL

        var pulledName = local.name
        var pulledDescription = localDescription
        var pushedCover = false

        // --- Mixtape's half ---
        if link.direction.pulls {
            if remoteNameMoved { pulledName = remote.name }
            if remoteDescMoved { pulledDescription = remoteDescription }
            if pulledName != local.name || pulledDescription != localDescription {
                libraryService.setPlaylistDetails(id: playlistID,
                                                  name: pulledName,
                                                  description: pulledDescription.isEmpty ? nil : pulledDescription)
            }
            if remoteCoverMoved, let cover = remote.coverURL,
               let data = try? await Self.download(cover) {
                libraryService.setPlaylistArtwork(id: playlistID, data: data)
                link.syncedCoverHash = data.hashValue
            }
        }

        // --- Spotify's half ---
        if link.direction.pushes {
            let name = pulledName != remote.name && !remoteNameMoved ? pulledName : nil
            let desc = pulledDescription != remoteDescription && !remoteDescMoved ? pulledDescription : nil
            if name != nil || desc != nil {
                try? await client.updatePlaylistDetails(playlistID: link.sourceID,
                                                        name: name, description: desc,
                                                        accessToken: token)
            }
            // Only a cover that changed *here* since the last agreement, and
            // only when Spotify's didn't change too.
            if !remoteCoverMoved, let art = local.artworkData, localCoverHash != link.syncedCoverHash {
                if let jpeg = ImageDownsampler.downsampledJPEG(from: art, maxDimension: 640,
                                                               compressionQuality: 0.7) {
                    do {
                        try await client.uploadPlaylistCover(jpeg, playlistID: link.sourceID,
                                                             accessToken: token)
                        link.syncedCoverHash = localCoverHash
                        // The upload replaced the image, so the URL fetched a
                        // moment ago is already stale. Leaving the recorded one
                        // untouched makes the next pass read Spotify's new URL as
                        // *their* change and pull our own picture back down; the
                        // flag stops that.
                        pushedCover = true
                    } catch {
                        print("[SpotifyFollow] Cover not sent for \(link.name): \(error)")
                    }
                }
            }
        }

        // The new agreement: `pulledName`/`pulledDescription` already hold the
        // value that won, whichever side it came from. The cover URL is left nil
        // by a push we just made — Spotify's image has changed and we haven't
        // seen its new URL yet, so the next pass reads it rather than guessing.
        link.syncedName        = pulledName
        link.syncedDescription = pulledDescription
        link.syncedCoverURL    = pushedCover ? nil : remoteCover
        if link.syncedCoverHash == nil { link.syncedCoverHash = localCoverHash }
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    /// The three-way merge, as sets against the last agreed-on list.
    ///
    /// Anything added on either side since the base is added; anything deleted
    /// on either side is deleted; a song deleted on one side and untouched on
    /// the other goes, because "untouched" is not a vote to keep it. Order
    /// follows the local list, with songs new on Spotify appended in Spotify's
    /// order, so a merge never silently reshuffles a playlist somebody arranged.
    static func merge(base: [UUID], local: [UUID], remote: [UUID]) -> [UUID] {
        let baseSet = Set(base), localSet = Set(local), remoteSet = Set(remote)

        let added   = localSet.subtracting(baseSet).union(remoteSet.subtracting(baseSet))
        let removed = baseSet.subtracting(localSet).union(baseSet.subtracting(remoteSet))
        let wanted  = baseSet.union(added).subtracting(removed)

        var out: [UUID] = []
        var seen: Set<UUID> = []
        for id in local where wanted.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        for id in remote where wanted.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    /// Spotify URIs for a merged list, searching only for the songs that don't
    /// already have one recorded.
    ///
    /// Only confident matches are taken. An uncertain guess is fine to offer
    /// someone in the export sheet, where they can look at it and untick it; it
    /// is not fine to write into their Spotify account on a timer with nobody
    /// watching.
    private func resolveURIs(for trackIDs: [UUID], link: inout Link) async throws -> [String] {
        var known = link.uriByTrack ?? [:]

        let unknown = trackIDs
            .filter { known[$0.uuidString] == nil }
            .compactMap { libraryService.track(id: $0) }

        if !unknown.isEmpty {
            let plan = try await exportService.plan(name: link.name, tracks: unknown)
            for candidate in plan.confident {
                if let uri = candidate.match?.uri { known[candidate.track.id.uuidString] = uri }
            }
            // A song we couldn't look up is not a song Spotify doesn't have,
            // and the push that follows *replaces* the remote list — so
            // proceeding would delete songs from the user's Spotify playlist on
            // the strength of a lookup that never happened, then record the
            // result as agreed and never revisit it. Stop instead; the sync
            // runs again, and by then the limit has lifted.
            if let reason = plan.uncheckedReason {
                switch reason {
                case .rateLimited(let wait): throw SpotifyPlaylistError.rateLimited(retryAfter: wait)
                case .unreachable: throw SpotifyPlaylistError.network
                }
            }
        }
        link.uriByTrack = known
        return trackIDs.compactMap { known[$0.uuidString] }
    }

    /// Liked Songs mirrors into Favourites, which is *not* a read-only list — it
    /// is the user's own, and Mixtape's hearts and Spotify's live in it together.
    ///
    /// So this is a mirror of Spotify's half only: a song Spotify no longer lists
    /// is un-hearted here only if this link is what hearted it in the first place
    /// (`contributedIDs`). A song the user hearted in Mixtape is never touched by
    /// anything happening on Spotify.
    /// Sending the other way is *additive and only additive*. Spotify's Liked
    /// Songs and Mixtape's Favourites are both real lists that their owner
    /// curates directly, so the playlist rule — Mixtape's copy replaces
    /// Spotify's — would be destructive here: it would unlike, on Spotify,
    /// every song the user never had in Mixtape. A heart made here is added
    /// there; a heart removed here is left alone.
    private func syncLikedSongs(link: inout Link, token: String, force: Bool) async throws {
        // Push before the early-out. Spotify's count not having moved says
        // nothing about whether *this* side has new hearts to send, and
        // returning here used to mean a two-way link never pushed at all.
        if link.direction.pushes {
            try await pushNewFavourites(link: &link, token: token)
        }

        guard link.direction.pulls else { return }

        if !force, let known = link.likedCount {
            let current = try await client.fetchLikedSongsCount(accessToken: token)
            guard current != known else { return }
        }

        let remote = try await client.fetchContents(
            of: SpotifyLibraryItem(sourceID: SpotifyLibraryItem.likedSongsID,
                                   kind: .likedSongs,
                                   name: link.name,
                                   subtitle: "",
                                   trackCount: 0,
                                   coverURL: nil),
            accessToken: token
        )

        var owned = libraryService.ownedRecordingIndex
        let ids   = await importService.importTracks(remote.tracks, owned: &owned)
        guard !Task.isCancelled else { throw CancellationError() }

        let wanted   = Set(ids)
        let current  = Set(libraryService.playlist(id: Playlist.favouritesID)?.trackIDs ?? [])
        let previous = Set(link.contributedIDs ?? [])

        let toAdd    = ids.filter { !current.contains($0) }
        let toRemove = previous.subtracting(wanted).intersection(current)

        if !toAdd.isEmpty {
            libraryService.addTracks(ids: toAdd, toPlaylist: Playlist.favouritesID)
        }
        if !toRemove.isEmpty {
            libraryService.removeTracks(ids: Array(toRemove), fromPlaylist: Playlist.favouritesID)
        }

        link.contributedIDs = ids
        link.likedCount     = remote.tracks.count

        if !toAdd.isEmpty { importService.finaliseImport() }
    }

    /// Adds the favourites Spotify didn't put here to Spotify's Liked Songs.
    ///
    /// The candidate set is Favourites minus `contributedIDs` — everything this
    /// link didn't contribute is, by definition, a heart made in Mixtape. Once
    /// a song is saved on Spotify the next pull lists it and records it as
    /// contributed, which is what stops it being offered again on every tick;
    /// until that pull happens the count guard keeps this cheap.
    ///
    /// Unmatched songs are skipped rather than fatal: one song Spotify has no
    /// record of must not strand the rest.
    private func pushNewFavourites(link: inout Link, token: String) async throws {
        // Nothing has been pulled yet, so there is no way to tell a heart made
        // here from one of Spotify's own — every favourite would look local and
        // the first sync would push the whole list back at the account it just
        // came from. Let the pull below establish the baseline first; the next
        // tick pushes for real.
        guard let contributedList = link.contributedIDs else { return }

        let favourites = libraryService.playlist(id: Playlist.favouritesID)?.trackIDs ?? []
        let contributed = Set(contributedList)
        let mine = favourites.filter { !contributed.contains($0) }
        guard !mine.isEmpty else { return }

        let uris = try await resolveURIs(for: mine, link: &link)
        guard !uris.isEmpty else { return }

        _ = try await exportService.pushLikes(uris: uris)

        // Spotify lists them now, so they are this link's contribution too —
        // which also means the next pull won't re-offer them, and an unlike on
        // Spotify later un-hearts them here like any other mirrored song.
        // Deduped on the way in: this is a record of *which* songs came from
        // this link, not of how many times each was seen.
        var seen: Set<UUID> = []
        link.contributedIDs = (contributedList + mine).filter { seen.insert($0).inserted }
    }

    // MARK: - Reset

    private func forgetAllLinks(push: Bool = true) {
        // A wipe is a removal and needs the same record an unlink does, or the
        // next session refresh adopts the links straight back. An account
        // switch (`push: false`) is the opposite case: the tombstones belong to
        // the user signing out, and keeping them would make this device refuse
        // the incoming user's links forever.
        if push {
            for (id, link) in links { unlinked[id] = contributions(of: link, playlistID: id) }
        } else {
            unlinked.removeAll()
        }
        links.removeAll()
        lastSynced.removeAll()
        failures.removeAll()
        save(push: push)
    }

    /// Replaces the links with the account's own when a different user signs in.
    ///
    /// Local-only on the way out: the links being dropped belong to the account
    /// signing *out*, and the session is already the new one, so pushing the
    /// empty map would delete the incoming user's links from their account.
    public func accountDidChange(remote raw: String?) {
        forgetAllLinks(push: false)
        adoptRemote(raw)
    }

    // MARK: - Persistence

    private static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        let dir = base.appendingPathComponent("Mixtape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spotify-follows.json")
    }()

    private static func load() -> [UUID: Link] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Link].self, from: data)
        else { return [:] }
        return decoded.reduce(into: [:]) { out, pair in
            if let id = UUID(uuidString: pair.key) { out[id] = pair.value }
        }
    }

    private func save(push: Bool = true) {
        let encodable = links.reduce(into: [String: Link]()) { $0[$1.key.uuidString] = $1.value }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? data.write(to: Self.url, options: .atomic)
        guard push, !isApplyingRemote else { return }
        schedulePush()
    }

    // MARK: - Account sync

    /// Set by `AppDependencies` — writes the encoded links into `user_metadata`.
    public var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private var pushTask: Task<Void, Never>?

    /// The account's copy, taken as authoritative on sign-in and on every
    /// session refresh — the same contract the import ledger uses.
    ///
    /// This device's `contributedIDs`, `syncedIDs` and `uriByTrack` survive the
    /// adoption: they are not in the payload, and throwing away the only copy
    /// of the agreed base would make the next sync re-add everything both ways.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let remote = try? JSONDecoder().decode([String: Link].self, from: data)
        else { return }
        var merged: [UUID: Link] = [:]
        var stale = false
        for (key, var link) in remote {
            guard let id = UUID(uuidString: key) else { continue }
            // A link the user removed here is not a link this device is
            // missing. See `unlinked`.
            if unlinked[id] != nil { stale = true; continue }
            let local = links[id]
            link.contributedIDs = link.contributedIDs ?? local?.contributedIDs
            link.syncedIDs      = link.syncedIDs      ?? local?.syncedIDs
            link.uriByTrack     = link.uriByTrack     ?? local?.uriByTrack
            merged[id] = link
        }
        if merged != links {
            isApplyingRemote = true
            links = merged
            lastSynced = links.compactMapValues(\.lastSyncedAt)
            // A pulled playlist is read-only here and a pushed one isn't, and the
            // playlist rows arriving on a new device know nothing about that.
            for (id, link) in links { applyOrigin(for: link, playlistID: id) }
            save()
            isApplyingRemote = false
        }
        // The account still lists something this device unlinked: the push that
        // was meant to say so lost the race, so say it again.
        if stale { schedulePush() }
    }

    // MARK: Removed links

    /// Links the user removed on this device.
    ///
    /// `adoptRemote` takes the account's copy as authoritative, and a deletion
    /// is invisible in that model: the removed link is simply absent from the
    /// map, which reads exactly like a device that never had it. `authState`'s
    /// `didSet` adopts on every session refresh, so any refresh landing before
    /// the debounced push did put the link straight back — and the next sync
    /// pass re-imported every song with it, about fifteen seconds after the
    /// user had removed them.
    ///
    /// Kept in defaults rather than the links file so the file stays the one
    /// thing it is; it is a handful of UUIDs, and it is cleared the moment the
    /// same playlist is linked again.
    /// The value is what that link had put into the playlist, so the offer to
    /// take those songs back out survives the unlink. It used to be a plain
    /// `Set` of ids, and dropping the link dropped `contributedIDs` with it:
    /// once unlinked there was no longer anything that knew which of 2,129
    /// liked songs had come from Spotify, and the only control that could
    /// remove them lived on a dialog that no longer had a reason to open.
    private var unlinked: [UUID: [UUID]] = SpotifyFollowService.loadUnlinked() {
        didSet {
            UserDefaults.standard.set(
                unlinked.reduce(into: [String: [String]]()) { $0[$1.key.uuidString] = $1.value.map(\.uuidString) },
                forKey: Self.unlinkedKey)
        }
    }

    private static let unlinkedKey = "mix.spotifyUnlinkedPlaylists"

    private static func loadUnlinked() -> [UUID: [UUID]] {
        let stored = UserDefaults.standard.object(forKey: unlinkedKey)
        // The `[String]` shape shipped first; a device upgrading over it keeps
        // its tombstones and loses only the contribution lists it never had.
        if let ids = stored as? [String] {
            return Dictionary(uniqueKeysWithValues: ids.compactMap(UUID.init(uuidString:)).map { ($0, []) })
        }
        guard let map = stored as? [String: [String]] else { return [:] }
        return map.reduce(into: [UUID: [UUID]]()) { out, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            out[id] = pair.value.compactMap(UUID.init(uuidString:))
        }
    }

    /// Debounced: one sync pass touches several links and that is one account
    /// update, not one per playlist.
    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            var stripped: [String: Link] = [:]
            for (id, var link) in links {
                link.contributedIDs = nil
                link.syncedIDs      = nil
                link.uriByTrack     = nil
                stripped[id.uuidString] = link
            }
            guard let data = try? JSONEncoder().encode(stripped),
                  let raw  = String(data: data, encoding: .utf8)
            else { return }
            pushWriter?(raw)
        }
    }
}
