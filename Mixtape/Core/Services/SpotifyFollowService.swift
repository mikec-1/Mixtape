// Keeps imported Spotify playlists in sync with the account they came from.
// Spotify has no webhooks, so we poll `snapshot_id`, which is cheap and only
// changes on edit; the full read happens only when it moves.
// Link identity (Spotify id, name, direction) syncs via `user_metadata` like
// `SpotifyImportLedger`. The bulk fields (`contributedIDs`, `syncedIDs`,
// `uriByTrack`) are too big for that and stay on device; without them the next
// sync treats both sides as additions, so nothing is deleted.

import Foundation
import Combine
import OSLog

@MainActor
public final class SpotifyFollowService: ObservableObject {

    // MARK: - Link

    public struct Link: Codable, Sendable, Hashable {

        public enum Kind: String, Codable, Sendable {
            case playlist
            case likedSongs
        }

        /// Which way changes travel. Shown as two toggles; both on is a real three-way
        /// merge (see `merge`).
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
        /// Name on Spotify when linked, for the byline and error messages.
        public var name: String
        /// Spotify's version marker at the last successful check. Playlists only.
        public var snapshotID: String?
        /// Liked Songs total at the last check. Stands in for a snapshot id, which Liked Songs lacks.
        public var likedCount: Int?
        /// Library ids this link put into Favourites (Liked Songs only). An unlike on
        /// Spotify only un-hearts songs listed here, never ones hearted in Mixtape.
        public var contributedIDs: [UUID]?
        public var lastSyncedAt: Date?

        /// Optional so pre-direction links decode as `pull`. Synthesised Codable ignores
        /// defaults when decoding, hence the accessor fallback.
        public var directionRaw: String? = nil

        public var direction: Direction {
            get { directionRaw.flatMap(Direction.init(rawValue:)) ?? .pull }
            set { directionRaw = newValue.rawValue }
        }

        /// The track list both sides agreed on at the last sync: the three-way merge base.
        public var syncedIDs: [UUID]? = nil

        /// Track id -> matched Spotify URI, so a push doesn't re-search. String keys
        /// because UUID keys don't encode as a JSON object.
        public var uriByTrack: [String: String]? = nil

        /// Name, description and cover both sides agreed on last, so a sync knows which
        /// side changed. Covers compare by Spotify's image URL there and a byte hash here,
        /// since Spotify re-encodes uploads.
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

    /// Set by `AppDependencies` so auth can hand over the account's copy. Not a singleton.
    public private(set) static weak var shared: SpotifyFollowService?

    private var links: [UUID: Link] = [:]
    /// Playlists from the last publish, so a deletion isn't confused with a library
    /// that hasn't loaded yet.
    private var seenPlaylistIDs: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var localEdits: AnyCancellable?

    /// Background check interval. The unchanged case is one tiny request per playlist.
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

        // After a wipe, drop links so the next tick doesn't restore deleted songs.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let reset = UserDataReset.from(note)
                // An account switch isn't a wipe; the links are already the new user's.
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

    /// Changes a link's direction. Also moves the origin, since only `pull` is read-only.
    public func setDirection(_ direction: Link.Direction, forPlaylist playlistID: UUID) {
        guard var link = links[playlistID], link.direction != direction else { return }
        link.direction = direction
        // Drop the old base so the next sync treats both sides as additions and deletes nothing.
        link.syncedIDs = nil
        links[playlistID] = link
        applyOrigin(for: link, playlistID: playlistID)
        save()
    }

    /// Read-only only for pull. Push and two-way stay editable. Liked Songs syncs
    /// into Favourites, which is always editable.
    private func applyOrigin(for link: Link, playlistID: UUID) {
        guard link.kind == .playlist else { return }
        libraryService.setOrigin(link.direction == .pull ? .spotifyMirror : .owned,
                                 forPlaylist: playlistID)
    }

    /// Stops following. Keeps the songs.
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

    /// What this link added to an owned list (Favourites). Only meaningful for Liked Songs.
    public func contributionCount(playlistID: UUID) -> Int {
        importedSongs(playlistID: playlistID).count
    }

    /// Songs an import put here that are still present, even after unlinking
    /// (the tombstone keeps the list).
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

    /// Contributed songs still in the playlist, deduped (`contributedIDs` is append-only).
    private func contributedSongs(link: Link, playlistID: UUID) -> [UUID] {
        let current = Set(libraryService.playlist(id: playlistID)?.trackIDs ?? [])
        var seen: Set<UUID> = []
        return (link.contributedIDs ?? []).filter { current.contains($0) && seen.insert($0).inserted }
    }

    /// Unlinks and removes the songs this link contributed, together, or the next
    /// pull would add them back. Songs still held by the user's own playlists, saved
    /// albums or files stay; `removeTracks` sweeps the rest.
    @discardableResult
    public func unlinkRemovingImports(playlistID: UUID) -> Int {

        SupabaseSyncService.allowBulk("spotify-unlink")
        let mine = importedSongs(playlistID: playlistID)
        unlink(playlistID: playlistID)
        // Emptied, not removed: the key stops `adoptRemote` restoring the link.
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

    /// Pushes local edits to two-way/push links right away instead of waiting for
    /// the timer. Debounced, since a drag of 20 songs publishes 20 times.
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
            // No base yet: the timer's pass establishes one first.
            guard let base = link.syncedIDs,
                  let playlist = playlists.first(where: { $0.id == id }),
                  playlist.trackIDs != base
            else { return nil }
            return id
        }
        for id in due { await sync(playlistID: id, force: true) }
    }

    /// Deleting a push-linked playlist unfollows it on Spotify (Spotify has no
    /// delete). Pull links only lose the local copy. Only reacts to a playlist going
    /// away, never to one missing, so an empty library at launch deletes nothing.
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
                // Deleted here regardless; a failed Spotify write just leaves their copy.
                MixLog.sync.error("[SpotifyFollow] Couldn't remove \(link.name) from Spotify: \(error)")
            }
        }
        save()
    }

    // MARK: - Syncing

    /// Syncs every link. Serialised so the timer and a manual sync can't both write rows.
    public func syncAll(force: Bool = false) async {
        guard isAvailable, !links.isEmpty else { return }
        await withRunning {
            for (playlistID, _) in self.links {
                await self.syncOne(playlistID: playlistID, force: force)
            }
        }
    }

    /// Syncs one link. `force` skips the snapshot check ("Sync now").
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

        // Playlist deleted locally since linking: drop the link, and for push links
        // unfollow on Spotify too. Races `propagateLocalDeletions`, so both handle it.
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
            // Gone from Spotify (deleted or made private). Pull links delete the local
            // copy; push-only links keep it.
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
            // A failed check never unfollows; it reports the error.
            failures[playlistID] = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
        }
    }

    /// Syncs one playlist. `pull`: Spotify wins, read-only here. `push`: the
    /// reverse. `both`: three-way merge against `syncedIDs`.
    private func syncPlaylist(_ playlistID: UUID,
                              link: inout Link,
                              token: String,
                              force: Bool) async throws {
        let localIDs = libraryService.playlist(id: playlistID)?.trackIDs ?? []

        // Snapshot unchanged and nothing to push: done.
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

        // Record URIs for songs present on both sides, so pushes don't re-search them.
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
            // `setTracks` bypasses `isEditable`: the source is allowed to write a mirror.
            libraryService.setTracks(merged, inPlaylist: playlistID)
            importService.finaliseImport()
        }

        // --- Spotify's half ---
        if link.direction.pushes, merged != remoteIDs {
            let pushURIs = try await resolveURIs(for: merged, link: &link)
            // Unmatched songs stay here and are just absent on Spotify.
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

    /// Title, description and cover, with the same three-way rule: the side that
    /// moved since the last agreement wins; if both moved, Spotify wins.
    /// Best-effort: failures here never fail the song sync.
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
            // Push the cover only if it changed here and not on Spotify.
            if !remoteCoverMoved, let art = local.artworkData, localCoverHash != link.syncedCoverHash {
                if let jpeg = ImageDownsampler.downsampledJPEG(from: art, maxDimension: 640,
                                                               compressionQuality: 0.7) {
                    do {
                        try await client.uploadPlaylistCover(jpeg, playlistID: link.sourceID,
                                                             accessToken: token)
                        link.syncedCoverHash = localCoverHash
                        // The fetched URL is stale after an upload; the flag stops the next pass
                        // reading it as a remote change.
                        pushedCover = true
                    } catch {
                        let name = link.name   // a log message can't capture an inout
                        MixLog.sync.error("[SpotifyFollow] Cover not sent for \(name): \(error)")
                    }
                }
            }
        }

        // Record the new agreement. Cover URL stays nil after a push until we see Spotify's new one.
        link.syncedName        = pulledName
        link.syncedDescription = pulledDescription
        link.syncedCoverURL    = pushedCover ? nil : remoteCover
        if link.syncedCoverHash == nil { link.syncedCoverHash = localCoverHash }
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    /// Three-way merge: adds from either side are kept, deletes from either side
    /// win. Local order first, then new Spotify songs in Spotify order.
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

    /// Spotify URIs for a merged list, searching only unmatched songs. Only
    /// confident matches; nobody reviews a timed write.
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
            // Stop on unchecked lookups: the push replaces the remote list, so it would
            // delete songs based on a lookup that never happened.
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

    /// Liked Songs <-> Favourites. Pull only un-hearts songs this link
    /// contributed. Push only ever adds, since both lists are curated directly.
    private func syncLikedSongs(link: inout Link, token: String, force: Bool) async throws {
        // Push before the early-out; an unchanged Spotify count says nothing about local hearts.
        if link.direction.pushes {
            try await pushNewFavourites(link: &link, token: token)
        }

        guard link.direction.pulls else { return }
        // Without this link's last list (`contributedIDs` stays on device, so a new install has none) every
        // Spotify like missing here looks new. The device that linked keeps syncing; here only a sync the user
        // asks for runs.
        guard link.contributedIDs != nil || force else { return }

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

        // Only songs liked on Spotify since the last sync, so one unliked here isn't brought back.
        let toAdd    = ids.filter { !current.contains($0) && !previous.contains($0) }
        let toRemove = previous.subtracting(wanted).intersection(current)

        // Linking and Sync Now may change more than 50 likes; a background sync is refused past that.
        if force { SupabaseSyncService.allowBulk("spotify-sync") }
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

    /// Adds Mixtape-made hearts (Favourites minus `contributedIDs`) to Liked Songs.
    /// Once pulled back they count as contributed and aren't offered again.
    /// Unmatched songs are skipped.
    private func pushNewFavourites(link: inout Link, token: String) async throws {
        // No pull yet, so every favourite would look local. Wait for the baseline.
        guard let contributedList = link.contributedIDs else { return }

        let favourites = libraryService.playlist(id: Playlist.favouritesID)?.trackIDs ?? []
        let contributed = Set(contributedList)
        let mine = favourites.filter { !contributed.contains($0) }
        guard !mine.isEmpty else { return }

        let uris = try await resolveURIs(for: mine, link: &link)
        guard !uris.isEmpty else { return }

        _ = try await exportService.pushLikes(uris: uris)

        // Now contributed, deduped.
        var seen: Set<UUID> = []
        link.contributedIDs = (contributedList + mine).filter { seen.insert($0).inserted }
    }

    // MARK: - Reset

    private func forgetAllLinks(push: Bool = true) {
        // A wipe tombstones links like an unlink. An account switch (`push: false`)
        // must not, or the incoming user's links would be refused.
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

    /// Swaps in the new account's links. Local-only: pushing now would overwrite
    /// the incoming user's links.
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

    /// Writes the encoded links to `user_metadata`.
    public var pushWriter: ((String) -> Void)?

    private var isApplyingRemote = false
    private var pushTask: Task<Void, Never>?

    /// Adopts the account's copy on sign-in and refresh. Local bulk fields survive
    /// since they aren't in the payload.
    public func adoptRemote(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let remote = try? JSONDecoder().decode([String: Link].self, from: data)
        else { return }
        var merged: [UUID: Link] = [:]
        var stale = false
        for (key, var link) in remote {
            guard let id = UUID(uuidString: key) else { continue }
            // Unlinked here; see `unlinked`.
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
            // New devices need the read-only flag set from the link direction.
            for (id, link) in links { applyOrigin(for: link, playlistID: id) }
            save()
            isApplyingRemote = false
        }
        // The account still has a link we removed; push again.
        if stale { schedulePush() }
    }

    // MARK: Removed links

    /// Links removed on this device, with the songs each had contributed.
    /// `adoptRemote` can't see deletions, so without this a refresh before the
    /// debounced push would restore the link and re-import its songs. Kept in
    /// defaults; cleared when the playlist is linked again.
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
        // Old `[String]` format: keep the tombstones, without contribution lists.
        if let ids = stored as? [String] {
            return Dictionary(uniqueKeysWithValues: ids.compactMap(UUID.init(uuidString:)).map { ($0, []) })
        }
        guard let map = stored as? [String: [String]] else { return [:] }
        return map.reduce(into: [UUID: [UUID]]()) { out, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            out[id] = pair.value.compactMap(UUID.init(uuidString:))
        }
    }

    /// Debounced: one account write per sync pass.
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
