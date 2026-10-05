// Single source of truth for the in-memory library: reads the SwiftData repositories and publishes
// collections for the views.

import Foundation
import SwiftData
import Combine
import OSLog

@MainActor
public final class LibraryService: ObservableObject {

    // MARK: - Published Library State

    @Published public private(set) var tracks:    [Track]    = [] {
        didSet {
            revision &+= 1
            trackRevision &+= 1
            rebuildTrackCoverIndex()
            rebuildTrackIndex()
            // Dropped, not rebuilt: building it is expensive and most refreshes never need it. Rebuilt on first read.
            cachedRecordingIndex = nil
        }
    }

    // MARK: - Offline Filter

    /// Whether there's a network. Nothing is hidden: unplayable songs draw grey. The Downloaded filter turns
    /// on when this goes true.
    @Published public var offlineOnly: Bool = false

    /// The Downloaded filter, a user choice. While true the display accessors below hide songs with no local file.
    /// `tracks` itself is never filtered: sync, smart-playlist generators and the Spotify push all read it.
    @Published public var downloadedOnly: Bool = false {
        // Memo caches keyed on `revision` can't otherwise tell the same ids now resolve to fewer songs.
        didSet {
            guard oldValue != downloadedOnly else { return }
            revision &+= 1
            trackRevision &+= 1
        }
    }

    /// What plays offline. Supplied by `AppDependencies` so the library holds no download manager reference.
    public var offlinePlayableIDs: () -> Set<UUID> = { [] }

    /// `tracks` minus what can't play offline. Display lists read this; anything that computes reads `tracks`.
    public var displayTracks: [Track] {
        guard downloadedOnly else { return tracks }
        let playable = offlinePlayableIDs()
        return tracks.filter { playable.contains($0.id) }
    }

    /// `track(id:)` for display lists: nil offline for a song that isn't here. Playback uses `track(id:)`.
    public func displayTrack(id: UUID) -> Track? {
        guard let t = track(id: id) else { return nil }
        guard downloadedOnly else { return t }
        return offlinePlayableIDs().contains(id) ? t : nil
    }

    /// Bumped whenever `tracks` or `playlists` is replaced, for views caching derived lists. Favourites are a
    /// playlist edit, hence both. Not `@Published`: it moves in lockstep with them.
    public private(set) var revision: UInt64 = 0

    /// Bumped only when `tracks` is replaced. For caches keyed on the track array plus an explicit id list:
    /// playing a song is a playlist write, so `revision` would invalidate them on every press.
    public private(set) var trackRevision: UInt64 = 0
    @Published public private(set) var albums:    [Album]    = []
    @Published public private(set) var artists:   [Artist]   = []
    /// Playlists, with Favourites always pinned at index 0.
    @Published public private(set) var playlists: [Playlist] = [] {
        didSet { revision &+= 1 }
    }

    // MARK: - Dependencies

    private let trackRepo:    TrackRepository
    private let albumRepo:    AlbumRepository
    private let artistRepo:   ArtistRepository
    private let playlistRepo: PlaylistRepository
    private let favoriteRepo: FavoriteRepository
    private let deviceID:     String

    /// Reads the library off the main actor, see `refreshOffMain()` and `LibrarySnapshotReader`.
    private let snapshotReader = LibrarySnapshotReader()

    // MARK: - Local change signal

    /// Fires when something changed the library, not when a refresh merely republished it. The sync push
    /// watches this; `objectWillChange` is for view invalidation only.
    public let localChanges = PassthroughSubject<Void, Never>()

    /// Non-zero while a refresh pass republishes. A counter because passes can overlap in `loadForDisplay`.
    private var refreshDepth = 0

    /// Forwards `objectWillChange` to `localChanges`, minus the republishes.
    private var localChangeForward: AnyCancellable?

    private func startLocalChangeForwarding() {
        localChangeForward = objectWillChange
            .sink { [weak self] _ in
                guard let self, self.refreshDepth == 0 else { return }
                self.localChanges.send()
            }
    }

    /// Called with the selection just before it leaves the library, while still in `tracks`. Installed by
    /// `AppDependencies` for downloads and playback, which this service doesn't own. Before, not after:
    /// `DownloadManager.removeDownloads(for:)` looks the tracks up here. Batched to avoid per-song disk work.
    public var onTracksWillDelete: ((Set<UUID>) -> Void)?

    /// A playlist from outside was just created (import, Spotify transfer, saved share). Only fired for
    /// `imported: true`, never for playlists arriving by sync, which would download the whole library.
    public var onPlaylistImported: ((UUID) -> Void)?

    // MARK: - Init

    public init(
        trackRepo:    TrackRepository,
        albumRepo:    AlbumRepository,
        artistRepo:   ArtistRepository,
        playlistRepo: PlaylistRepository,
        favoriteRepo: FavoriteRepository,
        deviceID:     String
    ) {
        self.trackRepo    = trackRepo
        self.albumRepo    = albumRepo
        self.artistRepo   = artistRepo
        self.playlistRepo = playlistRepo
        self.favoriteRepo = favoriteRepo
        self.deviceID     = deviceID

        startLocalChangeForwarding()
        ensureSystemPlaylists()
        observePinChanges()
    }

    /// Prepares a freshly opened store (launch or account switch) and republishes. Favourites must exist first.
    public func storeDidOpen() {
        ensureSystemPlaylists()
        // Every cover was keyed on a row in the file just closed.
        noteAllArtworkChanged()
        refresh()
    }

    private func ensureSystemPlaylists() {
        try? playlistRepo.ensureFavourites(deviceID: deviceID)
        // Not seeded: All Songs is derived in `refresh()` (see `heldTrackIDs`).
        _ = try? playlistRepo.ensureAllSongs(deviceID: deviceID)
    }

    /// Pin order is decided in `refreshPlaylists`, so a pin toggle has to come back through here.
    private func observePinChanges() {
        pinObserver = NotificationCenter.default.addObserver(
            forName: .mixPlaylistPinsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPlaylists() }
        }
    }

    private var pinObserver: NSObjectProtocol?

    deinit {
        if let pinObserver { NotificationCenter.default.removeObserver(pinObserver) }
    }

    /// Moves never-uploaded originals out of the purgeable `Library/Caches/Music/` folder an earlier build
    /// used; the cache copy is the only one. Not called from `init`: runs after launch off the published tracks.
    public func reclaimNeverUploadedAudioFromCache() {
        let tracks = self.tracks
        let atRisk = tracks.filter {
            !$0.file.uploaded
                && ($0.file.remoteKey?.isEmpty ?? true)
                && !$0.file.localPath.isEmpty
                && !$0.isOnline
        }
        let filenames = Set(atRisk.map { ($0.file.localPath as NSString).lastPathComponent })
        guard !filenames.isEmpty else { return }
        Task.detached(priority: .utility) {
            _ = AudioPaths.reclaimFromCache(filenames: filenames)
        }
    }

    // MARK: - Refresh

    /// What the library is busy doing, for the sidebar and Library tab spinners.
    public enum Activity: Equatable {
        case idle
        /// `detail` is the count when there is one, e.g. "2,010 songs".
        case working(String, detail: String?)

        var label: String? {
            if case .working(let l, _) = self { return l }
            return nil
        }
        var detail: String? {
            if case .working(_, let d) = self { return d }
            return nil
        }
    }

    @Published public private(set) var activity: Activity = .idle

    /// Announces library work, cleared when the body returns or throws.
    func withActivity<T>(_ label: String, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        activity = .working(label, detail: detail)
        defer { activity = .idle }
        return try body()
    }

    /// Same, for work that spans awaits. `refresh()` stays quiet while one is standing, so the user sees
    /// the operation's own label.
    public func beginActivity(_ label: String, detail: String? = nil) {
        activity = .working(label, detail: detail)
    }

    public func endActivity() {
        activity = .idle
    }

    /// A refresh that has been asked for but not run yet. See `scheduleRefresh`.
    private var pendingRefreshTask: Task<Void, Never>?

    /// Live track ids as of the last refresh that ran the repair passes. Nil until then, so launch repairs once.
    private var lastRepairedTrackIDs: Set<UUID>?

    /// Fetch cost of the last refresh and whether it ran repairs, for the refresh log line.
    private var fetchMilliseconds = 0
    private var didRunRepairs = false

    /// Asks for a refresh soon, coalescing bursts. A full refresh is expensive, so loops call this instead;
    /// callers that need current state now use `flushPendingRefresh()`.
    public func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Off the main actor: this runs 250 ms later, outside the write, so there's no read-your-write concern.
            await self?.refreshOffMain()
        }
    }

    /// Runs a pending scheduled refresh now; no-op otherwise.
    public func flushPendingRefresh() {
        guard pendingRefreshTask != nil else { return }
        refresh()
    }

    /// Whether `refresh()` has completed since launch. Screens want the library loaded, not re-read.
    public private(set) var hasLoaded = false

    /// What a screen calls on appear: playlists now, the rest a frame later, with the heavy read off the main
    /// actor. Repairs and publishing stay here because they use the main-actor repositories.
    public func loadForDisplay() async {
        guard !hasLoaded else { return }

        refreshPlaylists()
        activity = .working("Loading library", detail: nil)
        // A frame, not a yield: `Task.yield()` doesn't guarantee a run-loop pass, so nothing would paint.
        try? await Task.sleep(for: .milliseconds(16))

        await refreshOffMain()
        activity = .idle
    }

    /// Loads the library once; later calls do nothing. Safe from any `.task`/`.onAppear`.
    public func refreshIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    /// Re-reads everything from SwiftData and republishes. Albums and artists with no live tracks are soft-deleted.
    public func refresh() {
        guard !holdRefreshes else { pendingFullRefresh = true; return }
        let pass = beginRefreshPass()
        do {
            let fetchStarted = CFAbsoluteTimeGetCurrent()
            let allTracks  = try mixMainActivity("library-refresh/fetch-tracks")  { try trackRepo.fetchAll()  }
            let allAlbums  = try mixMainActivity("library-refresh/fetch-albums")  { try albumRepo.fetchAll()  }
            let allArtists = try mixMainActivity("library-refresh/fetch-artists") { try artistRepo.fetchAll() }
            apply(LibrarySnapshot(
                tracks:  allTracks,
                albums:  allAlbums,
                artists: allArtists,
                tracksWithArtwork: nil,
                fetchMilliseconds: Int((CFAbsoluteTimeGetCurrent() - fetchStarted) * 1000)
            ))
        } catch {
            MixLog.library.error("[LibraryService] refresh tracks/albums/artists failed: \(error)")
        }
        endRefreshPass(pass)
    }

    /// `refresh()` with the three bulk fetches off the main actor. Repairs and publishing stay here.
    /// Write paths keep the synchronous `refresh()`: a second context might not see their save yet.
    public func refreshOffMain() async {
        // The reader uses its own context and can't see unsaved `mainContext` changes, so save first.
        let context = trackRepo.modelContext
        if context.hasChanges { try? context.save() }

        let pass = beginRefreshPass()
        do {
            apply(try await snapshotReader.read(container: ModelStore.shared.container))
        } catch {
            MixLog.library.error("[LibraryService] refresh tracks/albums/artists failed: \(error)")
        }
        endRefreshPass(pass)
    }

    /// Shared start of both refresh paths: announce, publish the cheap collection, drop artwork caches.
    private func beginRefreshPass() -> RefreshPass {
        // Republishes until `endRefreshPass`, not edits. See `localChanges`.
        refreshDepth += 1

        // Whatever a pending refresh was going to do, this pass is doing now.
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil

        // Only if nothing else is announced: imports, syncs and wipes have better labels.
        let announced = activity == .idle
        if announced {
            activity = .working("Updating library",
                                detail: tracks.isEmpty ? nil : "\(tracks.count) songs")
        }

        // Playlists first: a cheap read, so the playlist list can draw before the expensive pass.
        refreshPlaylists()

        // Every cover write ends in a refresh, so drop the rows writers flagged. `noteAllArtworkChanged()` is
        // for when everything is stale (wipe, account switch, memory pressure).
        flushDirtyArtwork()

        return RefreshPass(
            signpost: MixSignpost.database.beginInterval("library-refresh",
                                                        id: MixSignpost.database.makeSignpostID()),
            started:  CFAbsoluteTimeGetCurrent(),
            announced: announced
        )
    }

    private func endRefreshPass(_ pass: RefreshPass) {
        refreshPlaylists()
        refreshDepth = max(0, refreshDepth - 1)
        if pass.announced { activity = .idle }
        MixSignpost.database.endInterval("library-refresh", pass.signpost)
        let ms = Int((CFAbsoluteTimeGetCurrent() - pass.started) * 1000)
        MixLog.database.info("library-refresh \(ms, privacy: .public) ms (fetch \(self.fetchMilliseconds, privacy: .public) ms, repairs \(self.didRunRepairs ? "yes" : "no", privacy: .public)), \(self.tracks.count, privacy: .public) tracks, \(self.albums.count, privacy: .public) albums, \(self.artists.count, privacy: .public) artists")
    }

    private struct RefreshPass {
        let signpost:  OSSignpostIntervalState
        let started:   CFAbsoluteTime
        let announced: Bool
    }

    /// The repair-and-publish half of a refresh, given rows read elsewhere. Main actor: the repairs use
    /// main-actor repositories and the results are `@Published`.
    private func apply(_ snapshot: LibrarySnapshot) {
        mixMainActivity("library-refresh/apply") { applyOnMain(snapshot) }
    }

    private func applyOnMain(_ snapshot: LibrarySnapshot) {
        // One commit for all the repair sweeps. See `RepositorySaveBatch`.
        RepositorySaveBatch.run(trackRepo.modelContext) { applyOnMainBody(snapshot) }
    }

    private func applyOnMainBody(_ snapshot: LibrarySnapshot) {
            let allTracks  = snapshot.tracks
            let allAlbums  = snapshot.albums
            let allArtists = snapshot.artists
            fetchMilliseconds = snapshot.fetchMilliseconds
            // Only after a successful read, so `refreshIfNeeded` can retry after a throw.
            hasLoaded = true

            let liveIDs = Set(allTracks.map(\.id))

            // The repairs are migrations and only matter when the live track set changed since they last ran.
            let repairsNeeded = liveIDs != lastRepairedTrackIDs
            if repairsNeeded { lastRepairedTrackIDs = liveIDs }
            didRunRepairs = repairsNeeded

            // Sweep albums: soft-delete any whose trackIDs contain no live tracks
            if repairsNeeded {
            mixMainActivity("library-refresh/sweep-buckets") {
            for var album in allAlbums {
                // Count first; build the list only when it differs.
                let liveCount = album.trackIDs.count(where: liveIDs.contains)
                if liveCount == album.trackIDs.count, liveCount > 0 { continue }
                let live = album.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else if live.count != album.trackIDs.count {
                    // Prune stale IDs while we're here
                    album.trackIDs = live
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }

            // Sweep artists: same
            for var artist in allArtists {
                let liveCount = artist.trackIDs.count(where: liveIDs.contains)
                if liveCount == artist.trackIDs.count, liveCount > 0 { continue }
                let live = artist.trackIDs.filter { liveIDs.contains($0) }
                if live.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else if live.count != artist.trackIDs.count {
                    artist.trackIDs = live
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }

            }
            // Split rows named after a whole credit ("c4rl, Yungpalo") so each artist gets a page.
            }

            var artistsNow = allArtists
            var albumsNow  = allAlbums
            if repairsNeeded { beginRepairCollection() }

            if repairsNeeded, mixMainActivity("library-refresh/repair-composite-artists", { splitCompositeArtists(artistsNow) }) {
                artistsNow = mergeRepairedArtists(into: artistsNow)
            }

            // Adopt tracks no artist row claims: only import creates artist rows, so synced tracks were missing.
            if repairsNeeded, mixMainActivity("library-refresh/adopt-orphan-tracks", { adoptOrphanTracks(allTracks, knownArtists: artistsNow) }) {
                artistsNow = mergeRepairedArtists(into: artistsNow)
                // New rows use an album cover until a real photo is fetched.
                scheduleArtistImageBackfill()
            }

            // Same for albums. Runs after the artist pass so the artist rows exist.
            if repairsNeeded, mixMainActivity("library-refresh/adopt-orphan-albums", { adoptOrphanAlbums(allTracks, knownAlbums: albumsNow) }) {
                albumsNow  = mergeRepairedAlbums(into: albumsNow)
                artistsNow = mergeRepairedArtists(into: artistsNow)
            }

            mixMainActivity("library-refresh/publish-tracks") {
                // Only assign when changed: `@Published` announces on assignment, and republishing an equal library
                // re-renders every observer. The compare is cheap (no artwork blobs in these rows).
                let tracksChanged = tracks != allTracks
                if tracksChanged {
                    // Use the reader's cover answer when it has one; the `didSet` version is a full-table fetch.
                    if let covers = snapshot.tracksWithArtwork {
                        suppressCoverIndexRebuild = true
                        tracks = allTracks
                        suppressCoverIndexRebuild = false
                        tracksWithArtwork = covers
                    } else {
                        tracks = allTracks
                    }
                } else if let covers = snapshot.tracksWithArtwork, tracksWithArtwork != covers {
                    // Same songs, different covers: a sync that downloaded artwork.
                    tracksWithArtwork = covers
                }
            }
            // `contains(where:)` rather than `filter`, to avoid an allocation per bucket.
            mixMainActivity("library-refresh/publish-buckets") {
                // Same reasoning as `publish-tracks`: announce only a change.
                let liveAlbums  = dedupeAlbums(albumsNow.filter { $0.trackIDs.contains(where: liveIDs.contains) },
                                               persist: repairsNeeded)
                let liveArtists = artistsNow.filter { $0.trackIDs.contains(where: liveIDs.contains) }
                if albums  != liveAlbums  { albums  = liveAlbums }
                if artists != liveArtists { artists = liveArtists }
            }

            // Playlists holding ids for songs that are gone. See the method.
            if repairsNeeded { mixMainActivity("library-refresh/prune-playlists") { prunePlaylistsOfDeletedTracks(allTracks) } }

            // All Songs is rebuilt on every refresh so it matches exactly what this device holds, synced tracks included.
            mixMainActivity("library-refresh/all-songs") {
                if var allSongs = try? playlistRepo.fetch(id: Playlist.allSongsID) {
                    let albumOnly = SavedAlbumsService.shared.albumOnlyIDs
                    let held      = heldTrackIDs()
                    // Album-only songs are held but not listed, like Spotify keeps a saved album out of Liked Songs.
                    let expectedIDs = allTracks.sorted { $0.dateImported < $1.dateImported }.map(\.id)
                        .filter { held.contains($0) && !albumOnly.contains($0) }
                    if allSongs.trackIDs != expectedIDs {
                        allSongs.trackIDs = expectedIDs
                        try? playlistRepo.save(allSongs)
                    }
                }
            }
    }

    // MARK: - Incremental publish

    /// Publishes rows this device just wrote without re-reading the library. Skips the repair sweeps, which
    /// catch staleness fresh rows can't have; the next full refresh still runs them. Callers update album
    /// and artist buckets themselves (`ImportService` does).
    public func insertLocally(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }

        // Anything already published is an update, e.g. a save over a soft-deleted row.
        var byID = Dictionary(uniqueKeysWithValues: newTracks.map { ($0.id, $0) })
        var merged = tracks
        for i in merged.indices {
            if let replacement = byID.removeValue(forKey: merged[i].id) { merged[i] = replacement }
        }
        let appended = newTracks.filter { byID[$0.id] != nil }
        merged.append(contentsOf: appended)

        // From the rows in hand, not `rebuildTrackCoverIndex`'s full-table fetch.
        var covers = tracksWithArtwork
        for track in newTracks where track.artworkData != nil { covers.insert(track.id) }

        // Otherwise the `didSet` runs that fetch and discards `covers`.
        suppressCoverIndexRebuild = true
        tracks = merged           // rebuilds the id and recording indexes
        suppressCoverIndexRebuild = false
        tracksWithArtwork = covers

        // Doesn't extend All Songs: these rows aren't held yet. The like or playlist that holds them schedules
        // the refresh that lists them.
        refreshPlaylists()
    }

    /// Republishes the album and artist arrays only, for callers that filed new rows after `insertLocally`.
    public func publishBuckets() {
        let liveIDs = Set(tracks.lazy.filter { !$0.isDeleted }.map(\.id))
        albums  = dedupeAlbums(((try? albumRepo.fetchAll())  ?? albums)
            .filter { $0.trackIDs.contains(where: liveIDs.contains) }, persist: false)
        artists = ((try? artistRepo.fetchAll()) ?? artists)
            .filter { $0.trackIDs.contains(where: liveIDs.contains) }
    }

    /// One row per album. Different import paths could each create a row for the same album; keeps the one
    /// with artwork (then most songs), folds the others' songs in, and with `persist` soft-deletes the rest.
    private func dedupeAlbums(_ rows: [Album], persist: Bool) -> [Album] {
        var winners: [String: Album] = [:]
        var order: [String] = []
        var losers: [Album] = []
        var touched = Set<String>()
        for row in rows {
            let key = SavedAlbumsService.key(title: row.title, artistName: row.artistName)
            guard var kept = winners[key] else { winners[key] = row; order.append(key); continue }
            func score(_ a: Album) -> (Int, Int) { ((a.artworkKey != nil || a.artworkData != nil) ? 1 : 0, a.trackIDs.count) }
            var loser = row
            if score(row) > score(kept) { swap(&kept, &loser) }
            for id in loser.trackIDs where !kept.trackIDs.contains(id) { kept.trackIDs.append(id) }
            winners[key] = kept
            losers.append(loser)
            touched.insert(key)
        }
        guard !losers.isEmpty else { return rows }
        if persist {
            for loser in losers { try? albumRepo.softDelete(id: loser.id) }
            for key in touched { if var w = winners[key] { w.sync.markModified(); try? albumRepo.save(w) } }
        }
        return order.compactMap { winners[$0] }
    }

    /// Drops playlist entries whose track was deleted for good, e.g. by a delete arriving over sync (local
    /// deletes already purge playlists). Leaves alone ids with no local row (not pulled yet) and restore
    /// candidates (`isResurrected`). Only playlists this device may edit.
    private func prunePlaylistsOfDeletedTracks(_ liveTracks: [Track]) {
        // Tombstones first, bailing on an empty set before fetching playlists (the common case).
        // Everything tombstoned, minus the ones we might still put back.
        let goneForGood = mixMainActivity("library-refresh/prune ▸ fetch-tombstones") {
            Set(
                ((try? trackRepo.fetchSoftDeleted()) ?? [])
                    .filter { !Self.isResurrected($0) }
                    .map(\.id)
            )
        }
        guard !goneForGood.isEmpty else { return }

        guard let all = mixMainActivity("library-refresh/prune ▸ fetch-playlists", {
            try? playlistRepo.fetchAll()
        }) else { return }

        let liveIDs = Set(liveTracks.map(\.id))

        for var playlist in all where playlist.isEditable || playlist.isSystem {
            guard !playlist.trackIDs.isEmpty else { continue }
            let kept = playlist.trackIDs.filter { !goneForGood.contains($0) || liveIDs.contains($0) }
            guard kept.count != playlist.trackIDs.count else { continue }
            let dropped = Set(playlist.trackIDs).subtracting(kept)
            playlist.trackIDs = kept
            // Touched so other devices hear about the removal.
            playlist.touch()
            try? playlistRepo.save(playlist)
            // The songs the cover was built from changed, same as a local delete.
            rebakeDerivedCover(forPlaylist: playlist.id)
            // Favourites has its own rows; a heart that outlives the song comes back when an id matches again.
            if playlist.isFavourites {
                for id in dropped { try? favoriteRepo.remove(trackID: id) }
            }
        }
    }

    // MARK: - Repair bookkeeping

    /// Rows the repair passes wrote, so `apply` doesn't re-read the store after each pass.
    private var repairedArtists: [UUID: Artist] = [:]
    private var repairedAlbums:  [UUID: Album]  = [:]
    private var retiredArtists:  Set<UUID>      = []

    private func beginRepairCollection() {
        repairedArtists.removeAll(keepingCapacity: true)
        repairedAlbums.removeAll(keepingCapacity: true)
        retiredArtists.removeAll(keepingCapacity: true)
    }

    /// Blobs dropped: `findOrCreate` reads the whole row, but the published arrays carry no artwork.
    private func noteRepaired(_ artist: Artist) {
        var row = artist
        row.artworkData = nil
        repairedArtists[row.id] = row
    }

    private func noteRepaired(_ album: Album) {
        var row = album
        row.artworkData = nil
        repairedAlbums[row.id] = row
    }

    private func mergeRepairedArtists(into rows: [Artist]) -> [Artist] {
        guard !repairedArtists.isEmpty || !retiredArtists.isEmpty else { return rows }
        var pending = repairedArtists
        var merged = rows.compactMap { row -> Artist? in
            if retiredArtists.contains(row.id) { pending[row.id] = nil; return nil }
            return pending.removeValue(forKey: row.id) ?? row
        }
        // Rows `findOrCreate` invented are in neither the fetch nor the list.
        merged.append(contentsOf: pending.values.filter { !retiredArtists.contains($0.id) })
        return merged
    }

    private func mergeRepairedAlbums(into rows: [Album]) -> [Album] {
        guard !repairedAlbums.isEmpty else { return rows }
        var pending = repairedAlbums
        var merged = rows.map { pending.removeValue(forKey: $0.id) ?? $0 }
        merged.append(contentsOf: pending.values)
        return merged
    }

    /// Splits rows named after several credits into one per artist and retires the composite.
    /// Returns true if anything was written.
    private func splitCompositeArtists(_ knownArtists: [Artist]) -> Bool {
        var didWrite = false

        for composite in knownArtists where !composite.isDeleted {
            let credits = ImportService.creditedArtists(from: composite.name)
            guard credits.count > 1 else { continue }

            for name in credits {
                guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                      artist.id != composite.id else { continue }

                var modified = false
                for id in composite.trackIDs where !artist.trackIDs.contains(id) {
                    artist.trackIDs.append(id)
                    modified = true
                }
                for id in composite.albumIDs where !artist.albumIDs.contains(id) {
                    artist.albumIDs.append(id)
                    modified = true
                }
                // `composite` came from the bulk fetch without a blob; only the store has it.
                if artist.artworkData == nil,
                   let art = ArtworkProvider.shared.data(for: .artist(composite.id)) {
                    artist.artworkData = art
                    noteArtworkChanged(.artist(artist.id))
                    modified = true
                }
                guard modified else { continue }
                artist.sync.markModified()
                try? artistRepo.save(artist)
                noteRepaired(artist)
                didWrite = true
            }

            // The composite's tracks are on the individual rows now, so retiring it orphans nothing.
            try? artistRepo.softDelete(id: composite.id)
            retiredArtists.insert(composite.id)
            didWrite = true
        }
        return didWrite
    }

    /// Files every track that isn't in any artist row under each of its credited
    /// artists, creating rows as needed. Returns true if anything was written.
    private func adoptOrphanTracks(_ allTracks: [Track], knownArtists: [Artist]) -> Bool {
        var claimed = Set<UUID>()
        for artist in knownArtists where !artist.isDeleted {
            claimed.formUnion(artist.trackIDs)
        }

        // Grouped by artist so each row is fetched and saved once. A featured track goes under every credited
        // artist, like the import path.
        var byArtist: [String: [UUID]] = [:]
        // Edits stay out of buckets: they don't sync, so other devices would prune them and push back.
        for track in allTracks where !claimed.contains(track.id) && track.origin != .edit {
            for name in ImportService.creditedArtists(from: track.artistName) {
                byArtist[name, default: []].append(track.id)
            }
        }
        guard !byArtist.isEmpty else { return false }

        for (name, trackIDs) in byArtist {
            guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID) else { continue }
            let missing = trackIDs.filter { !artist.trackIDs.contains($0) }
            guard !missing.isEmpty else { continue }
            artist.trackIDs.append(contentsOf: missing)
            // Give a freshly created row a face, so it isn't a blank circle.
            if artist.artworkData == nil,
               let art = allTracks.lazy.filter({ missing.contains($0.id) })
                   .compactMap({ ArtworkProvider.shared.data(for: .track($0.id)) }).first {
                artist.artworkData = art
                noteArtworkChanged(.artist(artist.id))
            }
            artist.sync.markModified()
            try? artistRepo.save(artist)
            noteRepaired(artist)
        }
        return true
    }

    /// An album row's bucket: title plus primary artist, the key `ImportService.updateAlbum(for:)` uses.
    private struct AlbumKey: Hashable {
        let title: String
        let artistName: String
    }

    /// Files every track that isn't in any album row under its (album title,
    /// primary artist) bucket, creating rows as needed. Returns true if anything
    /// was written.
    private func adoptOrphanAlbums(_ allTracks: [Track], knownAlbums: [Album]) -> Bool {
        var claimed = Set<UUID>()
        for album in knownAlbums where !album.isDeleted {
            claimed.formUnion(album.trackIDs)
        }

        // Grouped so each album row is saved once. By primary artist, so a featured track stays on the
        // headliner's album, like the import path.
        var byAlbum: [AlbumKey: [UUID]] = [:]
        for track in allTracks where !claimed.contains(track.id) && track.origin != .edit {
            // A single has no album; an album called "" would be a permanent blank tile.
            guard !track.albumTitle.isEmpty else { continue }
            let key = AlbumKey(
                title:      track.albumTitle,
                artistName: ImportService.primaryArtistName(from: track.artistName)
            )
            byAlbum[key, default: []].append(track.id)
        }
        guard !byAlbum.isEmpty else { return false }

        for (key, trackIDs) in byAlbum {
            guard var album = try? albumRepo.findOrCreate(
                title:      key.title,
                artistName: key.artistName,
                deviceID:   deviceID
            ) else { continue }

            let missing = trackIDs.filter { !album.trackIDs.contains($0) }
            guard !missing.isEmpty else { continue }
            album.trackIDs.append(contentsOf: missing)

            // Give a new row a cover and year so it isn't blank.
            let adopted = allTracks.filter { missing.contains($0.id) }
            if album.artworkData == nil {
                album.artworkData = adopted.lazy
                    .compactMap { ArtworkProvider.shared.data(for: .track($0.id)) }.first
                if album.artworkData != nil { noteArtworkChanged(.album(album.id)) }
            }
            if album.year == nil {
                album.year = adopted.compactMap(\.year).first
            }

            album.sync.markModified()
            try? albumRepo.save(album)
            noteRepaired(album)
            linkAlbum(album, toArtistsCreditedOn: adopted)
        }
        return true
    }

    /// Links the album to every credited artist, like `attachTrack` on import: artist pages list albums by `albumIDs`.
    private func linkAlbum(_ album: Album, toArtistsCreditedOn tracks: [Track]) {
        var names = Set<String>()
        for track in tracks {
            names.formUnion(ImportService.creditedArtists(from: track.artistName))
        }
        for name in names {
            guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                  !artist.albumIDs.contains(album.id) else { continue }
            artist.albumIDs.append(album.id)
            artist.sync.markModified()
            try? artistRepo.save(artist)
            noteRepaired(artist)
        }
    }

    /// Stores a pin on the playlist row. `PlaylistMetadataService` writes back through this, see `pinWriter`.
    public func setPlaylistPinned(id: UUID, pinned: Bool) {
        guard let playlist = try? playlistRepo.fetch(id: id), playlist.isPinned != pinned else { return }
        mutatePlaylist(id: id) {
            $0.isPinned = pinned
            // Touched so the other device hears about it.
            $0.touch()
        }
        refreshPlaylists()
    }

    /// Stores the user's arrangement. `ids` is the whole visible order, so the first drag describes the full
    /// list. Unnamed rows keep their index; only rows that actually move are touched.
    public func setPlaylistOrder(_ ids: [UUID]) {
        for (index, id) in ids.enumerated() {
            guard let playlist = try? playlistRepo.fetch(id: id),
                  playlist.sortIndex != index else { continue }
            mutatePlaylist(id: id) {
                $0.sortIndex = index
                // Touched so the other device hears about it.
                $0.touch()
            }
        }
        refreshPlaylists()
    }

    public func refreshPlaylists() {
        guard !holdRefreshes else { pendingPlaylistRefresh = true; return }
        mixMainActivity("library-refresh/playlists") { refreshPlaylistsBody() }
    }

    // MARK: - Coalesced refreshes

    private var refreshHoldDepth = 0
    private var pendingFullRefresh = false
    private var pendingPlaylistRefresh = false
    private var holdRefreshes: Bool { refreshHoldDepth > 0 }

    /// Runs `body` with refreshes held, then does at most one of each. Several write paths refresh per item,
    /// and the reads are idempotent, so collapsing them is free.
    @discardableResult
    public func coalescingRefreshes<T>(_ body: () -> T) -> T {
        refreshHoldDepth += 1
        let result = body()
        refreshHoldDepth -= 1
        guard refreshHoldDepth == 0 else { return result }

        let full = pendingFullRefresh
        let playlists = pendingPlaylistRefresh
        pendingFullRefresh = false
        pendingPlaylistRefresh = false
        // Off the main actor: the batch's writes are already saved through `mainContext`, so the
        // `refreshOffMain()` caveat doesn't apply.
        if playlists { refreshPlaylists() }
        if full {
            Task { [weak self] in await self?.refreshOffMain() }
        }
        return result
    }

    private func refreshPlaylistsBody() {
        invalidateFavouriteIndex()
        do {
            var all = try playlistRepo.fetchAll()
            let meta = PlaylistMetadataService.shared

            // Pins used to live in UserDefaults (per device). Hand those to the rows once so upgrading keeps them.
            if let legacy = meta.consumeLegacyPins() {
                // A device that never pinned still expects the two system playlists on top.
                let carried = legacy.isEmpty
                    ? [Playlist.allSongsID, Playlist.favouritesID]
                    : Array(legacy)
                for i in all.indices where carried.contains(all[i].id) && !all[i].isPinned {
                    all[i].isPinned = true
                    all[i].touch()
                    try? playlistRepo.save(all[i])
                }
            }

            // Same for the Mac's old UserDefaults drag order. See `Playlist.sortIndex`.
            if let legacy = meta.consumeLegacySidebarOrder(), !legacy.isEmpty {
                let position = Dictionary(uniqueKeysWithValues:
                    legacy.enumerated().map { ($0.element, $0.offset) })
                for i in all.indices {
                    guard let index = position[all[i].id],
                          all[i].sortIndex != index else { continue }
                    all[i].sortIndex = index
                    all[i].touch()
                    try? playlistRepo.save(all[i])
                }
            }

            // The rows own this; the service is a published mirror of them.
            meta.adoptPins(Set(all.filter(\.isPinned).map(\.id)))

            // Pinned Playlists
            var pinned = all.filter(\.isPinned)
            // The user's arrangement first; then alphabetical, with All Songs and Favourites first among the rest.
            pinned.sort { a, b in
                Self.arranged(a, b) {
                    if $0.isAllSongs { return true }
                    if $1.isAllSongs { return false }
                    if $0.isFavourites { return true }
                    if $1.isFavourites { return false }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }

            // Unpinned Playlists
            var unpinned = all.filter { !$0.isPinned }
            // Arrangement first, then last played (newest first) for the rest.
            unpinned.sort { a, b in
                Self.arranged(a, b) {
                    let dateA = meta.playlistLastPlayedDates[$0.id] ?? Date.distantPast
                    let dateB = meta.playlistLastPlayedDates[$1.id] ?? Date.distantPast
                    if dateA != dateB { return dateA > dateB }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            
            // Runs often with the same answer, and an identical assignment still republishes. See `publish-tracks`.
            var ordered = pinned + unpinned
            // Playlists draw before the songs load at launch; until then the raw count beats "0 songs".
            if !tracks.isEmpty {
                for i in ordered.indices {
                    ordered[i].liveCount = ordered[i].trackIDs.count { trackIndex[$0] != nil }
                }
            }
            if playlists != ordered { playlists = ordered }
        } catch {
            MixLog.library.error("[LibraryService] refresh playlists failed: \(error)")
        }
    }

    /// Orders by the user's arrangement, then by a rule for unarranged playlists. Arranged always outranks
    /// unarranged, so dragged rows stay put and the rest follow in their usual order.
    private static func arranged(_ a: Playlist,
                                 _ b: Playlist,
                                 fallback: (Playlist, Playlist) -> Bool) -> Bool {
        switch (a.sortIndex, b.sortIndex) {
        case let (x?, y?): return x == y ? fallback(a, b) : x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return fallback(a, b)
        }
    }

    // MARK: - Clear

    /// Extra work to stop when the library stops its own. Installed by `AppDependencies`: artwork compaction
    /// owns a `ModelContext` the library doesn't know about, and a wipe has to stop it.
    public var onCancelBackgroundWork: (() -> Void)?

    /// Stops this service's own background work (artist photos, cover backfill).
    public func cancelBackgroundWork() {
        artistImageBackfillTask?.cancel()
        artistImageBackfillTask = nil
        cancelArtworkBackfill()
        onCancelBackgroundWork?()
    }

    /// Empties the local library; only All Songs and Favourites survive, emptied.
    /// Listening history is `ListeningStatsService.resetHistory()`'s job.
    public func clearAll() {
        cancelBackgroundWork()
        // Nothing survives, so every cached cover is stale.
        noteAllArtworkChanged()
        do {
            try trackRepo.deleteAll()
            try albumRepo.deleteAll()
            try artistRepo.deleteAll()
        } catch {
            MixLog.library.error("[LibraryService] clearAll failed: \(error)")
        }
        // Favourites are their own rows; without this the hearts come back when a matching song is reimported.
        try? favoriteRepo.deleteAll()

        // Both audio directories (Library/Caches/Music/ and the legacy Documents/Music/).
        SupabaseFileStorageService.purgeLocalAudio()

        // Soft-delete, so the tombstones reach any device the server delete missed.
        if let all = try? playlistRepo.fetchAll() {
            for playlist in all where !playlist.isSystem {
                try? playlistRepo.softDelete(id: playlist.id)
            }
        }
        // Reset system playlists to empty (keep the playlists, wipe their track lists)
        for systemID in [Playlist.favouritesID, Playlist.allSongsID] {
            if var p = try? playlistRepo.fetch(id: systemID) {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }
        refresh()
    }

    /// Stands the local store down so a full pull can rebuild it from the server.
    /// See `PlaylistRepository.yieldFavouritesToServer`.
    public func prepareForFullResync() {
        // The local rows are about to be replaced wholesale from the server.
        noteAllArtworkChanged()
        try? playlistRepo.yieldFavouritesToServer()
    }

    /// Restores songs a full re-sync tombstoned by mistake. A song deleted and saved again returns under the
    /// same id, so an old server tombstone could kill it. Only rows imported after the server's delete
    /// qualify (see `isResurrected`). Marked modified so the server drops the tombstone.
    @discardableResult
    /// Whether a tombstone was applied by mistake: the row was imported after the server's delete.
    /// Excludes this device's unpushed deletes and genuine deletes from other devices. Used by
    /// `restoreResurrectedTracks` and `prunePlaylistsOfDeletedTracks`.
    private static func isResurrected(_ track: Track) -> Bool {
        guard track.sync.status != .deleted else { return false }
        guard let serverSaidDeleted = track.sync.serverModifiedAt else { return false }
        return track.dateImported > serverSaidDeleted
    }

    public func restoreResurrectedTracks() -> Int {
        restore(((try? trackRepo.fetchSoftDeleted()) ?? []).filter(Self.isResurrected))
    }

    /// Which of `ids` a restore would actually bring back. Anything offering a restore must count these,
    /// not every id a playlist can't show.
    public func resurrectableTrackIDs(among ids: [UUID]) -> [UUID] {
        resurrectable(among: ids).map(\.id)
    }

    /// Restores exactly what `resurrectableTrackIDs` names, so a caller's count matches the result.
    @discardableResult
    public func restoreTracks(ids: [UUID]) -> Int {
        restore(resurrectable(among: ids))
    }

    private func resurrectable(among ids: [UUID]) -> [Track] {
        guard !ids.isEmpty, let rows = try? trackRepo.fetch(ids: ids) else { return [] }
        return rows.values.filter { $0.isDeleted && Self.isResurrected($0) }
    }

    private func restore(_ tracks: [Track]) -> Int {
        var restored = 0
        for var track in tracks {
            track.isDeleted = false
            track.sync.markModified()
            try? trackRepo.save(track)
            restored += 1
        }
        if restored > 0 {
            MixLog.library.debug("[LibraryService] Restored \(restored) track(s) tombstoned by a stale server record")
            refresh()
        }
        return restored
    }

    // MARK: - Bulk Delete (Settings actions)

    /// Deletes every track, album, and artist from the local store.
    /// All playlist trackID arrays are emptied; the playlists themselves remain.
    /// Call `syncService.deleteAllServerTracks()` BEFORE this to push the deletion.
    public func deleteAllTracks() {
        do { try trackRepo.deleteAll() } catch {
            MixLog.library.error("[LibraryService] deleteAllTracks, trackRepo.deleteAll failed: \(error)")
        }
        do { try albumRepo.deleteAll() } catch {
            MixLog.library.error("[LibraryService] deleteAllTracks, albumRepo.deleteAll failed: \(error)")
        }
        do { try artistRepo.deleteAll() } catch {
            MixLog.library.error("[LibraryService] deleteAllTracks, artistRepo.deleteAll failed: \(error)")
        }
        try? favoriteRepo.deleteAll()

        // Remove local audio: both the cache and the legacy Documents path.
        SupabaseFileStorageService.purgeLocalAudio()

        // Empty every playlist's track list (keeps the playlist structures intact).
        if let all = try? playlistRepo.fetchAll() {
            for var p in all where !p.trackIDs.isEmpty {
                p.trackIDs = []
                p.touch()
                try? playlistRepo.save(p)
            }
        }

        refresh()
    }

    /// Soft-deletes all user-created playlists locally. System playlists
    /// (All Songs, Favourites) are kept. Tracks are untouched.
    /// Call `syncService.deleteAllServerUserPlaylists()` BEFORE this to push the deletion.
    public func deleteAllUserPlaylists() {
        guard let all = try? playlistRepo.fetchAll() else { return }
        for playlist in all where !playlist.isSystem {
            try? playlistRepo.softDelete(id: playlist.id)
        }
        refreshPlaylists()
    }

    // MARK: - Favourites

    /// Cached favourite ids. Nil means not loaded, see `invalidateFavouriteIndex`.
    private var favouriteIDCache: Set<UUID>?

    /// Drops the cached favourites. Called from `refreshPlaylists()`, which every favourite change ends with.
    private func invalidateFavouriteIndex() {
        favouriteIDCache = nil
    }

    /// The whole set, for callers (Home's shelves) that would otherwise ask per track.
    public func favouriteIDs() -> Set<UUID> {
        if let cached = favouriteIDCache { return cached }
        let ids = Set((try? favoriteRepo.allFavouritedIDs()) ?? [])
        favouriteIDCache = ids
        return ids
    }

    /// Answered from the in-memory set: every visible row asks this during layout.
    public func isFavourited(trackID: UUID) -> Bool {
        favouriteIDs().contains(trackID)
    }

    @discardableResult
    public func toggleFavourite(trackID: UUID) -> Bool {
        // Don't favourite a deleted track, e.g. from a stale mini player.
        guard track(id: trackID) != nil else { return false }
        if isFavourited(trackID: trackID) {
            try? favoriteRepo.remove(trackID: trackID)
            favouriteIDCache?.remove(trackID)
            mutatePlaylist(id: Playlist.favouritesID) { $0.removeTrack(trackID) }
            // Unliking removes a song only the like was holding. Songs held by a playlist, saved album or local file stay.
            if orphanedTrackIDs(among: [trackID]).isEmpty {
                refreshPlaylists()  // publish so the heart and Favourites update now
            } else {
                deleteTracks(ids: [trackID])
            }
            return false
        } else {
            addFavourite(trackID)
            refreshPlaylists()  // publish so the heart and Favourites update now
            return true
        }
    }

    /// The like without the publish. Shared with `saveToLibrary`, whose row isn't in the index yet.
    private func addFavourite(_ trackID: UUID) {
        try? favoriteRepo.add(trackID: trackID, deviceID: deviceID)
        favouriteIDCache?.insert(trackID)
        mutatePlaylist(id: Playlist.favouritesID) { $0.addTrack(trackID) }
        // Liked on its own, so it is a library song now rather than its album's.
        SavedAlbumsService.shared.promote(trackID)
    }

    // MARK: - Lookups (used by clickable now-playing / inspector navigation)

    /// Library album matching `title`, preferring one that contains the asking track, then an exact artist
    /// match. No title-only fallback: titles collide across unrelated albums.
    public func album(title: String, artistName: String, containing trackID: UUID? = nil) -> Album? {
        guard !title.isEmpty else { return nil }
        let matches = albums.filter { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        if let trackID, let owned = matches.first(where: { $0.trackIDs.contains(trackID) }) { return owned }
        return matches.first { $0.artistName.localizedCaseInsensitiveCompare(artistName) == .orderedSame }
    }

    /// The library artist whose name matches `name`.
    public func artist(named name: String) -> Artist? {
        guard !name.isEmpty else { return nil }
        return artists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// A song the user just saved, from Discover or the player. Save and Like are one action, as on Spotify:
    /// the row is metadata only, so the like is what holds it (All Songs is derived, see `heldTrackIDs`).
    /// Imports don't come through here; files are held by being files. `scheduleRefresh()` because callers loop.
    public func saveToLibrary(trackID: UUID) {
        guard !SavedAlbumsService.shared.albumOnlyIDs.contains(trackID),
              !isFavourited(trackID: trackID) else { return }
        addFavourite(trackID)
        scheduleRefresh()
    }

    // MARK: - Playlist Management

    /// `id` is settable only to restore a playlist you published and no longer have: the server row points at
    /// the old id, so a fresh uuid would leave it advertising a playlist the library can't show.
    /// `origin`/`ownerName` mark a playlist from outside (saved mix, someone else's); defaults mean "mine".
    /// `imported` means it arrived from elsewhere and fires `onPlaylistImported`. Separate from `origin`: a
    /// Spotify or file import is `.owned` but still arrived, and arrival is what auto-download cares about.
    public func createPlaylist(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        artworkData: Data? = nil,
        origin: PlaylistOrigin = .owned,
        ownerName: String? = nil,
        imported: Bool = false
    ) -> Playlist {
        let p = Playlist(
            id:          id,
            name:        name,
            description: description,
            artworkData: artworkData,
            origin:      origin,
            ownerName:   ownerName,
            sync:        SyncMetadata(deviceID: deviceID)
        )
        try? playlistRepo.save(p)
        refreshPlaylists()
        // After the refresh, so listeners can find the playlist.
        if imported { onPlaylistImported?(p.id) }
        return p
    }

    public func deletePlaylist(id: UUID) {
        deletePlaylists(ids: [id])
    }

    /// Deletes playlists and the songs left holding nothing. Batched because `deleteTracks` scans every
    /// playlist, album and artist once per call, and a song held only by two deleted playlists is an orphan.
    public func deletePlaylists(ids: [UUID]) {
        let targets = ids.filter { $0 != Playlist.favouritesID && $0 != Playlist.allSongsID }
        guard !targets.isEmpty else { return }

        // Its stored sort and transition go with it.
        for id in targets {
            PlaylistTrackSortService.shared.forget(playlistID: id)
            PlaylistTransitionService.shared.forget(playlistID: id)
        }

        coalescingRefreshes {
            var held: [UUID] = []
            for id in targets {
                // Deleting a subscription un-saves it, so the link goes too, or saving it again finds the dead link.
                // Here because there are five ways to delete a playlist. Owner links are left for `deletePublished`.
                if PlaylistSharingService.shared.linkedShare(forLocalPlaylist: id)?.isViewer == true {
                    PlaylistSharingService.shared.setLinkedShare(nil, forLocalPlaylist: id)
                }

                // Collected before the delete; `fetchAll` skips tombstones, so these no longer count as held.
                held += (try? playlistRepo.fetch(id: id))?.trackIDs ?? []
                try? playlistRepo.softDelete(id: id)
            }

            let orphans = mixMainActivity("playlist-delete/find-orphans") {
                orphanedTrackIDs(among: held)
            }
            mixMainActivity("playlist-delete/delete-tracks") { deleteTracks(ids: orphans) }
            refreshPlaylists()
        }

        // Same scoped measurement as the mix save, for the same reason: deleting
        // a handful of playlists stalls the app and nothing in the path says
        // where the time goes.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            MainThreadActivity.shared.logReport("playlist-delete")
        }
    }

    /// Songs that would leave the library with this playlist, for the delete confirmation.
    public func songCountRemovedWithPlaylist(id: UUID) -> Int {
        guard id != Playlist.favouritesID, id != Playlist.allSongsID,
              let playlist = try? playlistRepo.fetch(id: id)
        else { return 0 }
        return orphanedTrackIDs(among: playlist.trackIDs, ignoring: id).count
    }

    /// The songs in `trackIDs` nothing else holds: no user playlist and not favourited. All Songs doesn't
    /// count; Favourites and `FavoriteEntity` both do (two records of the same fact).
    private func orphanedTrackIDs(among trackIDs: [UUID], ignoring excluded: UUID? = nil) -> [UUID] {
        guard !trackIDs.isEmpty else { return [] }
        let held = heldTrackIDs(ignoring: excluded)
        return trackIDs.filter { !held.contains($0) }
    }

    /// Songs the library holds: a like, a playlist, a saved album, or being one of the user's own files.
    /// All Songs is derived from this set, so a song that falls out of all four is simply gone.
    /// One read, not one per song: the delete confirmation asks this while on screen.
    private func heldTrackIDs(ignoring excluded: UUID? = nil) -> Set<UUID> {
        // Favourites and `FavoriteEntity` record the same fact; either one holds.
        var held = Set((try? favoriteRepo.allFavouritedIDs()) ?? [])
        for playlist in (try? playlistRepo.fetchAll()) ?? []
        where !playlist.isAllSongs && playlist.id != excluded {
            held.formUnion(playlist.trackIDs)
        }
        held.formUnion(SavedAlbumsService.shared.albumOnlyIDs)
        // Imported, watched and unresolvable-share rows: the file or snapshot is the point, not a like.
        held.formUnion(tracks.lazy.filter { !$0.isOnline }.map(\.id))
        return held
    }

    /// Songs a deleted playlist left behind: in a tombstoned playlist, no live one, not favourited.
    /// Catches strays from before `deletePlaylists` swept them. Scoped to tombstones: a Discover save is in
    /// no playlist either, but someone put it there.
    public func orphansFromDeletedPlaylists() -> [UUID] {
        let stranded = Set((try? playlistRepo.fetchDeleted())?.flatMap(\.trackIDs) ?? [])
        guard !stranded.isEmpty else { return [] }
        // Only ids that still have a live row; old tombstones name long-deleted songs too.
        return orphanedTrackIDs(among: stranded.filter { trackIndex[$0] != nil })
    }

    /// Deletes them, and says how many went.
    @discardableResult
    public func cleanUpOrphanedSongs() -> Int {
        let orphans = orphansFromDeletedPlaylists()
        guard !orphans.isEmpty else { return 0 }
        deleteTracks(ids: orphans)
        return orphans.count
    }

    /// The `isEditable` guards here and below are a backstop; the screens already hide these actions for
    /// read-only playlists, but there's no single editing screen.
    public func renamePlaylist(id: UUID, newName: String) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id) { $0.name = newName; $0.touch() }
        refreshPlaylists()
    }

    /// Start, remove or rename a side. See `Playlist.sides`.
    public func editSides(ofPlaylist id: UUID, _ body: (inout Playlist) -> Void) {
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id, body: body)
        refreshPlaylists()
    }

    /// Sets the liner notes, pushing them to a shared playlist like its songs.
    public func setNotes(_ notes: PlaylistNotes, ofPlaylist id: UUID) {
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id) { $0.notes = notes; $0.touch() }
        refreshPlaylists()
        pushIfShared(id)
    }

    public func updatePlaylist(id: UUID, name: String, description: String?, artworkData: Data?) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        guard playlist(id: id)?.isEditable != false else { return }
        mutatePlaylist(id: id) { 
            $0.name = name
            $0.description = description
            $0.artworkData = artworkData
            // An empty picker means "no cover", not "pick one for me".
            $0.coverKind   = artworkData == nil ? PlaylistCoverKind.none : .chosen
            $0.touch()
        }
        bakedCoverSources[id] = nil
        invalidateCover(playlistID: id)
        refreshPlaylists()
    }

    /// Replaces a playlist's whole track list, editable or not. For the source speaking (filling a saved mix,
    /// pulling an owner's latest order). User edits go through `addTrack`/`removeTrack`.
    public func setTracks(_ trackIDs: [UUID], inPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) {
            guard $0.trackIDs != trackIDs else { return }
            $0.trackIDs = trackIDs
            $0.touch()
        }
        invalidateCover(playlistID: playlistID)
        rebakeDerivedCover(forPlaylist: playlistID)
        refreshPlaylists()
    }

    /// Changes who owns a playlist and whether it's editable. Only for links being made or broken
    /// (following a Spotify playlist makes it a read-only mirror).
    public func setOrigin(_ origin: PlaylistOrigin, forPlaylist playlistID: UUID) {
        mutatePlaylist(id: playlistID) {
            guard $0.origin != origin else { return }
            $0.origin = origin
            $0.touch()
        }
        refreshPlaylists()
    }

    /// An independent copy of a playlist: same track ids (not copied songs), same cover. The copy is `.owned`,
    /// unlinked and unpublished.
    @discardableResult
    public func duplicatePlaylist(id: UUID) -> Playlist? {
        guard let source = playlist(id: id), !source.isDeleted else { return nil }

        let copy = createPlaylist(name: Self.copyName(for: source.name,
                                                      taken: playlists.map(\.name)),
                                  description: source.description,
                                  artworkData: source.artworkData)
        // `setTracks`, not `addTrack`: order matters and `addTrack` refuses some copyable playlists.
        setTracks(source.trackIDs, inPlaylist: copy.id)
        return playlist(id: copy.id) ?? copy
    }

    /// "Mix" -> "Mix (Copy)" -> "Mix (Copy 2)".
    static func copyName(for name: String, taken: [String]) -> String {
        let existing = Set(taken.map { $0.lowercased() })
        let first = "\(name) (Copy)"
        guard existing.contains(first.lowercased()) else { return first }
        var n = 2
        while existing.contains("\(name) (Copy \(n))".lowercased()) { n += 1 }
        return "\(name) (Copy \(n))"
    }

    /// Renames a playlist and sets its description without the editable check, for a followed playlist
    /// adopting its source's title.
    public func setPlaylistDetails(id: UUID, name: String, description: String?) {
        guard id != Playlist.favouritesID && id != Playlist.allSongsID else { return }
        mutatePlaylist(id: id) {
            guard $0.name != name || $0.description != description else { return }
            $0.name = name
            $0.description = description
            $0.touch()
        }
        refreshPlaylists()
    }

    /// Sets a cover without the editable check. For a read-only playlist adopting its published cover.
    public func setPlaylistArtwork(id: UUID, data: Data?) {
        // A cover arriving here was chosen by someone. Removing one means "no picture", so nothing is composed
        // in its place; `generateDefaultCover(forPlaylist:)` is how the user asks for one.
        mutatePlaylist(id: id) {
            $0.artworkData = data
            $0.coverKind   = data == nil ? PlaylistCoverKind.none : .chosen
            $0.touch()
        }
        bakedCoverSources[id] = nil
        invalidateCover(playlistID: id)
        refreshPlaylists()
    }

    // MARK: - Track <-> Playlist

    public func addTrack(id trackID: UUID, toPlaylist playlistID: UUID) {
        addTracks(ids: [trackID], toPlaylist: playlistID)
    }

    /// Adds a selection in one write. A loop over `addTrack` would save, republish and upload per row, and
    /// a shared playlist could end up with whichever partial list uploaded last.
    public func addTracks(ids trackIDs: [UUID], toPlaylist playlistID: UUID) {
        guard !trackIDs.isEmpty, playlist(id: playlistID)?.isEditable != false else { return }
        mutatePlaylist(id: playlistID) { pl in
            pl.addTracks(trackIDs)
        }
        // Keep FavoriteEntity in sync when adding to Favourites from a context menu
        if playlistID == Playlist.favouritesID {
            try? favoriteRepo.add(trackIDs: trackIDs, deviceID: deviceID)
        }
        invalidateCover(playlistID: playlistID)
        rebakeDerivedCover(forPlaylist: playlistID)
        refreshPlaylists()
        pushIfShared(playlistID)
    }

    /// Removes a track from one playlist, and from the library if that playlist was its last holder.
    public func removeTrack(id trackID: UUID, fromPlaylist playlistID: UUID) {
        removeTracks(ids: [trackID], fromPlaylist: playlistID)
    }

    /// Removes a selection from one playlist in one write, and from the library for songs this playlist was
    /// the last holder of. `deleteTracks(ids:)` is the unconditional form.
    public func removeTracks(ids trackIDs: [UUID], fromPlaylist playlistID: UUID) {
        guard !trackIDs.isEmpty, playlist(id: playlistID)?.isEditable != false else { return }
        // One commit; each repository write commits on its own otherwise.
        RepositorySaveBatch.run(trackRepo.modelContext) {
            mutatePlaylist(id: playlistID) { pl in pl.removeTracks(trackIDs) }
            if playlistID == Playlist.favouritesID {
                try? favoriteRepo.remove(trackIDs: trackIDs)
            }
            // Same rule as unliking: a song nothing holds is gone, not "in the library but in no list".
            let orphans = orphanedTrackIDs(among: trackIDs)
            if !orphans.isEmpty { deleteTracks(ids: orphans) }
            invalidateCover(playlistID: playlistID)
            rebakeDerivedCover(forPlaylist: playlistID)
            refreshPlaylists()
        }
        pushIfShared(playlistID)
    }

    /// Uploads a shared playlist's new track list, if it is one. Lives here because many screens edit
    /// playlists. Not called from `reconcileSharedPlaylist` (the pull side), which would loop. A subscribed
    /// playlist never pushes: it follows the owner's list, it doesn't overwrite it.
    private func pushIfShared(_ playlistID: UUID) {
        guard playlistID != Playlist.favouritesID,
              playlist(id: playlistID)?.isEditable != false,
              PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlistID) != nil
        else { return }

        Task { [weak self] in
            guard let self else { return }
            await PlaylistSharingService.shared.pushLocalChanges(localPlaylistID: playlistID,
                                                                 libraryService: self)
        }
    }

    // MARK: - Shared / Collaborative Playlists

    /// The online search key a shared snapshot came from, when provable. First the owner's
    /// `SharedTrackMeta.sourceKey`, which survives renames. Otherwise recompute `stableID(for:)` from the
    /// snapshot's title|artist: if it matches the stored id, the song came from Discover. A key makes the row
    /// playable, since the resolver rebuilds audio from title and artist.
    private static func onlineKey(for meta: PlaylistSharingService.SharedTrackMeta) -> String? {
        if let declared = meta.sourceKey, !declared.isEmpty { return declared }
        return OnlineTrack.identityKey(title: meta.title,
                                       artistName: meta.artist,
                                       matching: meta.id)
    }

    /// Imports a metadata-only track from a shared snapshot so the song still appears in the playlist.
    /// A Discover song is minted online (key in `fileHash`, like `OnlineTrack.asTrack`) and streams.
    /// Anything else is a placeholder with an empty `fileHash`: someone else's local file.
    /// An existing row is kept. Returns `meta.id`.
    @discardableResult
    public func importSharedTrack(meta: PlaylistSharingService.SharedTrackMeta) -> UUID {
        if var existing = ((try? trackRepo.fetch(id: meta.id)) ?? nil), !existing.isDeleted {
            // Except a placeholder this snapshot can now prove is playable; otherwise old rows imported before
            // `sourceKey` and `edit` stayed dead forever.
            let fresh = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
            if existing.isUnresolvableShare, !fresh.isUnresolvableShare {
                existing.file = fresh.file
                existing.edit = fresh.edit
                existing.sync.markModified()
                try? trackRepo.save(existing)
            }
            return existing.id
        }
        let imported = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
        try? trackRepo.save(imported)
        return imported.id
    }

    /// The row a snapshot entry becomes. Pure, so the reconciler can build a batch and commit once.
    /// An edit is rebuilt here from its recipe; with a source key it's resolvable; otherwise unresolvable.
    private static func sharedTrackRow(meta: PlaylistSharingService.SharedTrackMeta,
                                       deviceID: String) -> Track {
        let provenance: FileProvenance = {
            if meta.edit != nil { return .editPlaceholder }
            guard let key = onlineKey(for: meta) else {
                return FileProvenance(fileHash: "", fileSize: 0, localPath: "",
                                      remoteKey: nil, uploaded: false, downloadedAt: nil,
                                      origin: .unresolvableShare, sourceRef: nil)
            }
            var online = FileProvenance.onlinePlaceholder(sourceRef: key)
            online.fileHash = key
            return online
        }()
        return Track(
            id: meta.id,
            title: meta.title,
            artistName: meta.artist,
            albumTitle: meta.album,
            duration: meta.duration,
            sync: SyncMetadata(deviceID: deviceID),
            file: provenance,
            edit: meta.edit
        )
    }

    /// Makes a local shared playlist match a remote snapshot. Known ids link directly; unknown ones are
    /// imported from snapshot metadata (streamable if from Discover, a placeholder otherwise). The playlist's
    /// `trackIDs` are then set to the remote order.
    /// `ownerID` finds the owner's covers; optional because some callers reconcile a row they didn't fetch.
    /// `dedupeAgainstLibrary` points songs the user already owns at their own row instead of importing a
    /// duplicate. Off for collaborative paths, whose ids get pushed back to the shared row; on for save,
    /// copy and follow, which are pull-only.
    public func reconcileSharedPlaylist(
        localPlaylistID: UUID,
        remoteTrackIDs: [UUID],
        remoteTrackMeta: [PlaylistSharingService.SharedTrackMeta],
        ownerID: UUID? = nil,
        dedupeAgainstLibrary: Bool = false,
        notes: PlaylistNotes? = nil
    ) {
        let metaByID = Dictionary(remoteTrackMeta.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A set, not `track(id:)` per song, which walks the whole library.
        let liveIDs = Set(tracks.map(\.id))

        // One query and one transaction for the whole snapshot.
        let storedByID = (try? trackRepo.fetch(ids: remoteTrackIDs)) ?? [:]
        var imported: [UUID] = []
        var writes: [Track] = []
        // The user's own songs, under their own ids. Only when asked, see `dedupeAgainstLibrary`.
        var owned = dedupeAgainstLibrary ? LibraryTrackIndex(tracks: tracks) : nil
        // Remote order with owned songs swapped for the user's copy.
        var resolvedTrackIDs: [UUID] = []
        // Owner's id to ours, so a note follows its song.
        var swapped: [UUID: UUID] = [:]
        for trackID in remoteTrackIDs {
            guard let meta = metaByID[trackID] else {
                // No metadata to match on, so carry the id through as given.
                resolvedTrackIDs.append(trackID)
                continue
            }
            let stored = storedByID[trackID]
            // Placeholders get rebuilt too; a re-shared snapshot may upgrade them (see `sharedTrackRow`).
            if !liveIDs.contains(trackID), stored == nil {
                // Nothing under the owner's id, but maybe the same song under ours. Point at that row.
                // Not for an edit, whose title can match the original's.
                if meta.edit == nil, let existing = owned?.match(title: meta.title,
                                               artistName: meta.artist,
                                               duration: meta.duration) {
                    resolvedTrackIDs.append(existing.id)
                    swapped[trackID] = existing.id
                    continue
                }
                let row = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
                writes.append(row)
                imported.append(trackID)
                // One row even if the snapshot lists the song twice under two spellings.
                owned?.insert(row)
            } else if stored?.isUnresolvableShare == true {
                let fresh = Self.sharedTrackRow(meta: meta, deviceID: deviceID)
                if var row = stored, !row.isDeleted, !fresh.isUnresolvableShare {
                    row.file = fresh.file
                    row.edit = fresh.edit
                    row.sync.markModified()
                    writes.append(row)
                } else if stored?.isDeleted == true {
                    writes.append(fresh)
                }
            }
            resolvedTrackIDs.append(trackID)
        }
        try? trackRepo.save(writes)

        // Match the remote order exactly. Stable: same snapshot and library give the same ids.
        mutatePlaylist(id: localPlaylistID) { playlist in
            if playlist.trackIDs != resolvedTrackIDs {
                playlist.trackIDs = resolvedTrackIDs
                playlist.touch()
            }
            if var mapped = notes {
                for (from, to) in swapped {
                    guard let note = mapped[song: from] else { continue }
                    mapped[song: from] = nil
                    mapped[song: to] = note
                }
                if playlist.notes != mapped {
                    playlist.notes = mapped
                    playlist.touch()
                }
            }
        }

        refresh()

        // Covers after the list is on screen; the snapshot has no artwork and waiting would look like a hang.
        // A local `ITunesSearchClient` is fine: it's stateless and artist photos aren't needed here.
        guard !imported.isEmpty else { return }
        scheduleArtworkBackfill(trackIDs: imported,
                                publishedBy: ownerID,
                                using: ITunesSearchClient())
    }

    // MARK: - Delete Single Track From Library

    /// Soft-deletes a track, removes its file, strips it from every playlist and from its album and artist
    /// buckets, soft-deleting those if they empty.
    public func deleteTrack(id: UUID) {
        deleteTracks(ids: [id])
    }

    /// The same for a set. Not a loop over `deleteTrack`: every playlist, album and artist is walked and saved
    /// per call, and deleting a playlist cascades into all its songs.
    public func deleteTracks(ids: [UUID]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }

        // One commit for the whole deletion. See `RepositorySaveBatch`.
        RepositorySaveBatch.run(trackRepo.modelContext) { deleteTracksBody(doomed) }
    }

    private func deleteTracksBody(_ doomed: Set<UUID>) {
        // While the rows still exist, see `onTracksWillDelete`.
        onTracksWillDelete?(doomed)

        // Files first, while the rows naming them are readable. Export folder copies are the user's and stay.
        for id in doomed {
            if let localPath = track(id: id)?.file.localPath {
                AudioPaths.removeAllCopies(ofLocalPath: localPath)
            }
        }

        let deleted: Set<UUID>
        do {
            deleted = try trackRepo.softDelete(ids: Array(doomed))
        } catch {
            MixLog.library.error("[LibraryService] deleteTracks failed: \(error)")
            return
        }
        guard !deleted.isEmpty else { return }
        try? favoriteRepo.remove(trackIDs: Array(deleted))

        // Purge from every playlist (including Favourites)
        var coversToRebake: [UUID] = []
        if var all = try? playlistRepo.fetchAll() {
            for i in all.indices where all[i].trackIDs.contains(where: deleted.contains) {
                all[i].trackIDs.removeAll(where: deleted.contains)
                all[i].touch()
                try? playlistRepo.save(all[i])
                coversToRebake.append(all[i].id)
            }
        }

        // A derived cover is composed from the songs, so rebake the playlists that lost one or the deleted song
        // stays on the cover everywhere. `rebakeDerivedCover` skips covers that aren't ours.
        for id in coversToRebake { rebakeDerivedCover(forPlaylist: id) }

        // Remove from album buckets, soft-deleting emptied albums. From the published array, not `fetchAll()`:
        // a bucket missing from it holds no live track, and the refresh sweep tidies those.
        do {
            for var album in albums where album.trackIDs.contains(where: deleted.contains) {
                album.trackIDs.removeAll(where: deleted.contains)
                if album.trackIDs.isEmpty {
                    try? albumRepo.softDelete(id: album.id)
                } else {
                    album.sync.markModified()
                    try? albumRepo.save(album)
                }
            }
        }

        // Same for artist buckets.
        do {
            for var artist in artists where artist.trackIDs.contains(where: deleted.contains) {
                artist.trackIDs.removeAll(where: deleted.contains)
                if artist.trackIDs.isEmpty {
                    try? artistRepo.softDelete(id: artist.id)
                } else {
                    artist.sync.markModified()
                    try? artistRepo.save(artist)
                }
            }
        }

        refresh()
    }

    // MARK: - Convenience Accessors

    /// The library's row for an id, via a dictionary rebuilt with `tracks`. Called per song in loops.
    public func track(id: UUID) -> Track? {
        guard let i = trackIndex[id], i < tracks.count else { return nil }
        return tracks[i]
    }

    /// Owned-recording lookup by name rather than row id. Online ids hash "title|artist" and catalogues
    /// spell both differently (Deezer's "Ran To Atlanta" by "Drake" vs Spotify's version with features).
    /// Read from view bodies; built on demand and dropped when `tracks` is replaced (see its `didSet`).
    private var cachedRecordingIndex: LibraryTrackIndex?

    /// The current recording index, rebuilt if it was dropped.
    private var recordingIndex: LibraryTrackIndex {
        if let cachedRecordingIndex { return cachedRecordingIndex }
        let built = LibraryTrackIndex(tracks: tracks)
        cachedRecordingIndex = built
        return built
    }

    /// A copy of the recording index for callers that insert as they write (imports, saved mixes, Spotify
    /// pulls). Value semantics keep their inserts private; copy-on-write makes the copy free.
    public var ownedRecordingIndex: LibraryTrackIndex { recordingIndex }

    /// The library's copy of a song by name, or nil. Pass the duration when known so a radio edit and a
    /// club mix aren't treated as the same recording.
    public func track(matching title: String,
                      artistName: String,
                      duration: TimeInterval = 0) -> Track? {
        recordingIndex.match(title: title, artistName: artistName, duration: duration)
    }

    /// Track id -> position in `tracks`, rebuilt in the same `didSet`.
    private var trackIndex: [UUID: Int] = [:]

    private func rebuildTrackIndex() {
        var index: [UUID: Int] = [:]
        index.reserveCapacity(tracks.count)
        for (i, track) in tracks.enumerated() { index[track.id] = i }
        trackIndex = index
    }

    public func album(id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    public func artist(id: UUID) -> Artist? {
        artists.first { $0.id == id }
    }

    public func tracks(in album: Album) -> [Track] {
        // All tracks, not `displayTracks`, so the Downloaded filter doesn't empty album pages. Rows gray out.
        let ids = Set(album.trackIDs)
        return tracks
            .filter { ids.contains($0.id) }
            .sorted {
                let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
                if d0 != d1 { return d0 < d1 }
                return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
            }
    }

    public func tracks(by artist: Artist) -> [Track] {
        let ids = Set(artist.trackIDs)
        return tracks.filter { ids.contains($0.id) }
    }

    // MARK: - Playlist Covers

    /// Ids of tracks that have a cover, never the bytes. The bulk fetch carries no artwork, and the store can
    /// answer "has a cover" without loading every blob. Bytes are fetched per row when drawn.
    private var tracksWithArtwork: Set<UUID> = []

    /// Set by `insertLocally`, which builds the cover index from rows it already has.
    private var suppressCoverIndexRebuild = false

    private func rebuildTrackCoverIndex() {
        guard !suppressCoverIndexRebuild else { return }
        tracksWithArtwork = ArtworkProvider.shared.trackIDsWithArtwork()
        // `mosaics` isn't cleared: entries are keyed by their sources, so stale ones are caught on read.
    }

    /// Composed 2x2s. Composing decodes four JPEGs and rows ask on every redraw.
    private var mosaics: [UUID: (sources: [CoverFingerprint], data: Data)] = [:]

    /// Enough to tell covers apart without hashing the image, so a one-album playlist doesn't get four copies.
    private struct CoverFingerprint: Hashable {
        let count: Int
        let head:  Int
        let tail:  Int

        init(_ data: Data) {
            count = data.count
            head  = data.prefix(64).hashValue
            tail  = data.suffix(64).hashValue
        }
    }

    /// The picture a playlist wears. A chosen cover wins; otherwise the first song's cover, or a 2x2 once
    /// there are four different ones. Nil for All Songs and Favourites unless given one: they wear a glyph.
    public func coverData(for playlist: Playlist) -> Data? {
        if let own = playlist.displayArtwork { return own }
        guard !playlist.isSystem else { return nil }
        // A cover the user deleted stays deleted. See `PlaylistCoverKind.none`.
        guard playlist.coverKind != PlaylistCoverKind.none else { return nil }

        let covers = borrowableCovers(in: playlist)
        guard let first = covers.first else { return nil }
        guard covers.count >= 4 else { return first }

        let fingerprints = covers.map(CoverFingerprint.init)
        if let cached = mosaics[playlist.id], cached.sources == fingerprints {
            return cached.data
        }
        // 512, not the 640 a mix is baked at: composed while drawing, largest view is a 200pt hero.
        guard let composed = MixCoverArt.compose(tiles: covers, side: 512) else { return first }
        mosaics[playlist.id] = (fingerprints, composed)
        return composed
    }

    /// Up to four different covers from the front of the playlist, skipping songs without artwork.
    /// Bounded because this runs while a row draws.
    private func borrowableCovers(in playlist: Playlist, limit: Int = 4) -> [Data] {
        var found: [Data] = []
        var seen = Set<CoverFingerprint>()
        for ref in coverRefs(forPlaylistID: playlist.id) {
            guard let art = ArtworkProvider.shared.data(for: ref),
                  seen.insert(CoverFingerprint(art)).inserted
            else { continue }
            found.append(art)
            if found.count == limit { break }
        }
        return found
    }

    // MARK: - Derived covers

    /// Forgets a playlist's cover in every cache: the mosaic here, `ArtworkProvider`'s bytes and
    /// `ArtworkImageLoader`'s images (all sizes, row and mosaic keys). `refreshPlaylists()` otherwise clears
    /// none of them. Also needed when the track list changes, since coverless playlists borrow from songs.
    private func invalidateCover(playlistID: UUID) {
        mosaics[playlistID] = nil
        ArtworkProvider.shared.invalidate(.playlist(playlistID))
        ArtworkImageLoader.shared.invalidate(.playlist(playlistID))
    }

    // MARK: - Artwork invalidation

    /// Covers written since the last refresh.
    private var dirtyArtwork: Set<ArtworkRef> = []

    /// Every cover is stale (wipe, account switch).
    private var allArtworkDirty = false

    /// Records that one row's cover has changed. The next refresh drops it.
    public func noteArtworkChanged(_ ref: ArtworkRef) {
        dirtyArtwork.insert(ref)
    }

    /// A playlist cover that arrived from elsewhere, usually sync. Clears the image caches and the mosaic
    /// this service composes; the sidebar reads the mosaic.
    public func noteCoverChanged(playlistID: UUID) {
        mosaics[playlistID] = nil
        bakedCoverSources[playlistID] = nil
        dirtyArtwork.insert(.playlist(playlistID))
    }

    /// Marks every cover stale. Only for library-wide changes; per-row writes name their row.
    public func noteAllArtworkChanged() {
        allArtworkDirty = true
    }

    private func flushDirtyArtwork() {
        if allArtworkDirty {
            ArtworkProvider.shared.invalidateAll()
            ArtworkImageLoader.shared.invalidateAll()
            allArtworkDirty = false
            dirtyArtwork.removeAll()
            return
        }
        guard !dirtyArtwork.isEmpty else { return }
        // Both take the whole set: each costs a redraw of every cover on screen.
        ArtworkProvider.shared.invalidate(dirtyArtwork)
        ArtworkImageLoader.shared.invalidate(dirtyArtwork)
        dirtyArtwork.removeAll()
    }

    /// Tiles each baked cover was made from, so an add that can't change the first four skips re-composing
    /// and re-uploading. In memory, so the first edit after launch always re-composes.
    private var bakedCoverSources: [UUID: [CoverFingerprint]] = [:]

    /// Composes a playlist's borrowed cover and stores it as its own, so every device shows the same picture
    /// instead of whatever subset of artwork each one holds. Refuses chosen covers and the system playlists.
    /// - Returns: whether it wrote anything.
    @discardableResult
    public func rebakeDerivedCover(forPlaylist playlistID: UUID) -> Bool {
        guard let playlist = try? playlistRepo.fetch(id: playlistID),
              !playlist.isSystem, !playlist.isDeleted else { return false }
        // `.chosen` is the user's picture and `.none` their choice to have none.
        guard playlist.coverKind == .derived else { return false }

        let tiles = borrowableCovers(in: playlist)
        guard let first = tiles.first else { return false }

        let fingerprints = tiles.map(CoverFingerprint.init)
        if bakedCoverSources[playlistID] == fingerprints, playlist.displayArtwork != nil {
            return false
        }

        // 640, the mix bake size: this one is stored and synced. Under four different tiles, the first cover.
        let baked = tiles.count >= 4 ? MixCoverArt.compose(tiles: tiles, side: 640) : first
        guard let baked else { return false }

        bakedCoverSources[playlistID] = fingerprints
        guard baked != playlist.displayArtwork else { return false }

        mutatePlaylist(id: playlistID) {
            $0.artworkData = baked
            $0.coverKind   = .derived
            $0.touch()
        }
        invalidateCover(playlistID: playlistID)
        return true
    }

    /// "Generate Cover": compose one from the songs now. The way back from `.none`, and it replaces any
    /// cover, chosen or not, because that's what the command says.
    @discardableResult
    public func generateDefaultCover(forPlaylist playlistID: UUID) -> Bool {
        mutatePlaylist(id: playlistID) {
            $0.artworkData = nil
            $0.coverKind   = .derived
            $0.touch()
        }
        bakedCoverSources[playlistID] = nil
        let baked = rebakeDerivedCover(forPlaylist: playlistID)
        invalidateCover(playlistID: playlistID)
        refreshPlaylists()
        return baked
    }

    /// Whether "Generate Cover" would produce anything: not for system playlists or songs with no artwork.
    public func canGenerateCover(forPlaylist playlistID: UUID) -> Bool {
        guard let playlist = playlist(id: playlistID),
              !playlist.isSystem, !playlist.isDeleted else { return false }
        return playlist.trackIDs.contains { tracksWithArtwork.contains($0) }
    }

    /// The songs a playlist would borrow its cover from, as refs. `AsyncArtworkImage` hands these to
    /// `ArtworkImageLoader`, which composes off the render path. Empty for the system playlists.
    /// - Parameter candidates: refs to return, not tiles. A one-album playlist needs enough candidates to
    /// find four different pictures, and that check needs the bytes, so it happens downstream.
    public func coverRefs(forPlaylistID id: UUID, candidates: Int = 12) -> [ArtworkRef] {
        guard let playlist = playlist(id: id), !playlist.isSystem,
              playlist.coverKind != PlaylistCoverKind.none else { return [] }
        return coverRefs(forTrackIDs: playlist.trackIDs, candidates: candidates)
    }

    /// The same rule for a list that isn't a stored playlist, e.g. a smart playlist.
    public func coverRefs(forTrackIDs trackIDs: [UUID], candidates: Int = 12) -> [ArtworkRef] {
        var found: [ArtworkRef] = []
        for trackID in trackIDs.prefix(24) where tracksWithArtwork.contains(trackID) {
            found.append(.track(trackID))
            if found.count == candidates { break }
        }
        return found
    }

    // MARK: - Artist Profile Photos

    /// One client for the session so the token and image URLs stay cached across backfills.
    private static let artistImageClient = SpotifyClient()

    /// Names Spotify has no artist for, so they aren't re-queried after every import.
    private var artistImageMisses: Set<String> = []

    private var artistImageBackfillTask: Task<Void, Never>?

    /// True when the row shows an album-cover stand-in from import (byte-identical to the cover) rather than
    /// a real photo.
    private func hasPlaceholderImage(_ artist: Artist) -> Bool {
        guard let art = artist.artworkData else { return true }
        let ids = Set(artist.trackIDs)
        return tracks.contains { ids.contains($0.id) && $0.artworkData == art }
    }

    /// Coalesced: import calls this per track, the work runs once after the last one.
    public func scheduleArtistImageBackfill() {
        artistImageBackfillTask?.cancel()
        artistImageBackfillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.backfillArtistImages()
        }
    }

    /// Replaces album-cover stand-ins with the artist's Spotify photo. The only way profile photos are fetched.
    public func backfillArtistImages() async {
        // Rows sharing a search term ("Drake", "Drake feat. 21 Savage") share one lookup.
        var byQuery: [String: [Artist]] = [:]
        for artist in artists where !artist.isDeleted && hasPlaceholderImage(artist) {
            let query = ImportService.primaryArtistName(from: artist.name)
            guard !query.isEmpty, !artistImageMisses.contains(query.lowercased()) else { continue }
            byQuery[query, default: []].append(artist)
        }
        guard !byQuery.isEmpty else { return }

        let queries  = Array(byQuery.keys)
        var didWrite = false
        var index    = 0

        // Chunked, or a first import's hundreds of searches earn a 429.
        while index < queries.count {
            guard !Task.isCancelled else { break }
            let chunk = Array(queries[index ..< min(index + 8, queries.count)])
            index += 8

            let urls = await Self.artistImageClient.artistImages(for: chunk)
            // Nothing back for a whole chunk usually means offline or a dead token, so don't record misses.
            let reachable = !urls.isEmpty

            for name in chunk {
                guard let url = urls[name] else {
                    if reachable { artistImageMisses.insert(name.lowercased()) }
                    continue
                }
                guard let (raw, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let data = ImageDownsampler.artworkJPEG(from: raw) else { continue }

                for artist in byQuery[name] ?? [] {
                    guard var stored = try? artistRepo.fetch(id: artist.id) else { continue }
                    stored.artworkData = data
                    stored.sync.markModified()
                    try? artistRepo.save(stored)
                    noteArtworkChanged(.artist(stored.id))
                    didWrite = true
                }
            }
        }

        if didWrite { refresh() }
    }

    // MARK: - Placeholder Track Artwork

    /// The one cover backfill allowed in flight, so it can be cancelled and runs don't overlap.
    private var artworkBackfillTask: Task<Void, Never>?

    /// Catalogue lookups one automatic backfill may make. They're sequential (iTunes 403s bursts), so an
    /// unbounded run is an hour of traffic. Settings' "Find Missing Covers" is the unbounded version.
    public static let automaticCatalogueLookupLimit = 250

    /// Runs a backfill as the single owned background job, replacing the previous one. Bounded, and
    /// cancelled by `cancelBackgroundWork()`.
    public func scheduleArtworkBackfill(trackIDs: [UUID],
                                        publishedBy ownerID: UUID?,
                                        using catalogue: ITunesSearchClient,
                                        directCovers: [UUID: URL] = [:]) {
        artworkBackfillTask?.cancel()
        artworkBackfillTask = Task { [weak self] in
            await self?.backfillPlaceholderArtwork(
                trackIDs:             trackIDs,
                publishedBy:          ownerID,
                using:                catalogue,
                directCovers:         directCovers,
                catalogueLookupLimit: Self.automaticCatalogueLookupLimit
            )
        }
    }

    public func cancelArtworkBackfill() {
        artworkBackfillTask?.cancel()
        artworkBackfillTask = nil
    }

    /// Fills in cover art for tracks that arrived as metadata only (e.g. a playlist from someone's profile;
    /// the owner's covers live in their private bucket). Sources in order: `directCovers` URLs the caller
    /// already knows, the owner's published covers, then the catalogue. Results are written to the track.
    /// `replacingExisting` re-fetches every track, not just blank ones (the manual repair). Nothing is cleared:
    /// a track keeps its cover unless a lookup replaces it.
    /// `catalogueLookupLimit` bounds the catalogue pass; nil (the user-run repairs) means unlimited.
    /// Returns the number of tracks written.
    @discardableResult
    public func backfillPlaceholderArtwork(trackIDs: [UUID],
                                           publishedBy ownerID: UUID?,
                                           using catalogue: ITunesSearchClient,
                                           directCovers: [UUID: URL] = [:],
                                           replacingExisting: Bool = false,
                                           catalogueLookupLimit: Int? = nil) async -> Int {
        let pending = trackIDs.compactMap { id -> Track? in
            guard let track = track(id: id), !track.isDeleted,
                  replacingExisting || track.artworkData == nil else {
                return nil
            }
            return track
        }
        guard !pending.isEmpty, !Task.isCancelled else { return 0 }

        var found: [UUID: Data] = [:]

        // Pass zero: covers whose URL the caller already has, e.g. a mix saved from Discover.
        if !directCovers.isEmpty {
            let jobs = pending.compactMap { track in
                directCovers[track.id].map { (track.id, $0) }
            }
            found.merge(await Self.fetchImages(jobs)) { a, _ in a }
        }

        // Pass one: the owner's covers, straight out of the public bucket.
        if let ownerID {
            let jobs = pending.compactMap { track -> (UUID, URL)? in
                guard found[track.id] == nil,
                      let url = PlaylistSharingService.trackCoverURL(ownerID: ownerID,
                                                                    trackID: track.id)
                else { return nil }
                return (track.id, url)
            }
            found.merge(await Self.fetchImages(jobs)) { a, _ in a }
        }

        // Pass two: the catalogue, for whatever the owner never published. One at a time: iTunes throttles
        // bursts, and a throttled 403 looks like "not found", so parallel lookups silently dropped covers.
        var lookups = 0
        for track in pending where found[track.id] == nil {
            // Checked every iteration so a cancel stops it now.
            guard !Task.isCancelled else { break }
            if let limit = catalogueLookupLimit, lookups >= limit { break }
            lookups += 1
            if let data = await Self.catalogueArtwork(for: track, catalogue: catalogue) {
                found[track.id] = data
            }
        }

        let storedByID = (try? trackRepo.fetch(ids: Array(found.keys))) ?? [:]
        var updates: [Track] = []
        for (id, data) in found {
            guard var stored = storedByID[id] else { continue }
            // Same bytes isn't a change; writing would push a no-op on the next sync.
            guard stored.artworkData != data else { continue }
            stored.artworkData = data
            stored.sync.markModified()
            noteArtworkChanged(.track(stored.id))
            updates.append(stored)
        }
        try? trackRepo.save(updates)
        let written = updates.count

        if written > 0 {
            propagateArtworkToContainers(from: Array(found.keys))
            // `insertLocally`, not `refresh()`: a full re-read here stalls the main actor while the user scrolls.
            // It merges by id, so updates publish like inserts.
            insertLocally(updates)
        }
        return written
    }

    /// Cover art for one track from Discover's catalogue: Deezer first (Discover is Deezer), then iTunes.
    private static func catalogueArtwork(for track: Track,
                                         catalogue: ITunesSearchClient) async -> Data? {
        guard let url = await catalogueArtworkURL(for: track, catalogue: catalogue) else { return nil }
        return await fetchImage(url)
    }

    /// A cover URL for a track with no stored bytes. Continuity needs the address, not pixels: the web
    /// client loads it itself. Callers memoize; this is a couple of round trips.
    static func catalogueArtworkURL(for track: Track,
                                    catalogue: ITunesSearchClient) async -> URL? {
        var track = track
        // An edit wears its original's cover; its own title finds some other song.
        if let edit = track.edit {
            let parts = edit.sourceRef.split(separator: "|", maxSplits: 1).map(String.init)
            if let title = parts.first, !title.isEmpty { track.title = title }
            if parts.count > 1 { track.artistName = parts[1] }
        }
        let primaryArtist = ImportService.primaryArtistName(from: track.artistName)
        let query = "\(track.title) \(primaryArtist)".trimmingCharacters(in: .whitespaces)

        // Twelve: the exact song can rank under a remix or live version.
        let popular = await catalogue.searchPopular(query: query, limit: 12)
        if let hit = popular.first(where: { isSameSong(track, primaryArtist: primaryArtist, as: $0) }),
           let raw = hit.artworkUrl100,
           let url = catalogue.artworkURL(from: raw, size: 1000) {
            return url
        }

        guard let hit = try? await catalogue.search(title: track.title,
                                                    artist: track.artistName).first,
              let raw = hit.artworkUrl100
        else { return nil }
        return catalogue.artworkURL(from: raw, size: 1000)
    }

    /// Whether a search hit really is this song. Deezer answers something for almost any query, and a wrong
    /// cover looks correct. Title must match; artist loosely ("A, B & C" comes back as "A").
    private static func isSameSong(_ track: Track,
                                   primaryArtist: String,
                                   as hit: ITunesTrackResult) -> Bool {
        guard DiscoverNameMatch.sameName(track.title, hit.trackName) else { return false }
        guard !primaryArtist.isEmpty else { return true }
        if DiscoverNameMatch.sameName(primaryArtist, hit.artistName) { return true }

        let mine  = DiscoverNameMatch.normalize(track.artistName)
        let their = DiscoverNameMatch.normalize(hit.artistName)
        guard !mine.isEmpty, !their.isEmpty else { return false }
        return mine.contains(their) || their.contains(mine)
    }

    /// Downloads covers six at a time.
    private static func fetchImages(_ jobs: [(UUID, URL)]) async -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for start in stride(from: 0, to: jobs.count, by: 6) {
            let chunk = Array(jobs[start..<min(start + 6, jobs.count)])
            let batch = await withTaskGroup(of: (UUID, Data?).self) { group in
                for (id, url) in chunk {
                    group.addTask { (id, await fetchImage(url)) }
                }
                var landed: [UUID: Data] = [:]
                for await (id, data) in group {
                    if let data { landed[id] = data }
                }
                return landed
            }
            out.merge(batch) { a, _ in a }
        }
        return out
    }

    /// Downloads a cover and downsamples it to the stored size; every blob stays resident in the published arrays.
    static func fetchImage(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return ImageDownsampler.artworkJPEG(from: data)
    }

    /// Pushes new track covers up to their album and artist rows. Those only take a picture when they adopt
    /// a track, so rows created before the artwork arrived stayed grey.
    private func propagateArtworkToContainers(from trackIDs: [UUID]) {
        for id in trackIDs {
            guard let track = track(id: id), let art = track.artworkData else { continue }

            if !track.albumTitle.isEmpty,
               var album = try? albumRepo.findOrCreate(
                   title:      track.albumTitle,
                   artistName: ImportService.primaryArtistName(from: track.artistName),
                   deviceID:   deviceID
               ), album.artworkData == nil {
                album.artworkData = art
                album.sync.markModified()
                try? albumRepo.save(album)
                noteArtworkChanged(.album(album.id))
            }

            for name in ImportService.creditedArtists(from: track.artistName) {
                guard var artist = try? artistRepo.findOrCreate(name: name, deviceID: deviceID),
                      artist.artworkData == nil else { continue }
                artist.artworkData = art
                artist.sync.markModified()
                try? artistRepo.save(artist)
                noteArtworkChanged(.artist(artist.id))
            }
        }
    }

    public func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Private Helpers

    private func mutatePlaylist(id: UUID, body: (inout Playlist) -> Void) {
        guard var p = try? playlistRepo.fetch(id: id) else { return }
        body(&p)
        try? playlistRepo.save(p)
    }
}

// touch() is defined on Playlist directly (see Core/Models/Playlist.swift)
