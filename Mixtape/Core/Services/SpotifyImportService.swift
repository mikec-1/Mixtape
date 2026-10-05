// Rebuilds a Spotify playlist locally (name, cover, songs). Tracks are online-only and
// resolve audio on first play like Discover tracks. Fetching lives in SpotifyClient.

import Foundation
import OSLog

@MainActor
public final class SpotifyImportService {

    /// Bumped to stop every run in flight, e.g. by Clear Everything. Runs check it at each chunk.
    public private(set) static var stopGeneration = 0

    public static func cancelAllRuns() { stopGeneration += 1 }

    /// Rows this run created, so a stop can undo them. Songs already in the library aren't included.
    private var runFreshTrackIDs: [UUID] = []
    private var runCreatedPlaylistIDs: [UUID] = []

    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
        /// Every song is in; what's left is the one big write that places them.
        public var isFinishing = false
    }

    /// Cover downloads in flight at once.
    private static let artworkConcurrency = 6

    /// Covers cached across playlists, since many playlists share albums. Capped to bound memory.
    private static let artworkCacheLimit = 500

    private let trackRepo: TrackRepository
    private let libraryService: LibraryService
    private let deviceID: String
    private let session: URLSession

    /// Album art already downloaded this session, keyed by its Spotify URL.
    private var artworkCache: [URL: Data] = [:]

    public init(
        trackRepo: TrackRepository,
        libraryService: LibraryService,
        deviceID: String,
        session: URLSession = .shared
    ) {
        self.trackRepo      = trackRepo
        self.libraryService = libraryService
        self.deviceID       = deviceID
        self.session        = session
    }

    @discardableResult
    public func importPlaylist(
        _ playlist: SpotifyPlaylist,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Playlist {
        SupabaseSyncService.allowBulk("spotify-import")
        let signpost = MixSignpost.importing.beginInterval("import-spotify",
                                                           id: MixSignpost.importing.makeSignpostID())
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MixSignpost.importing.endInterval("import-spotify", signpost)
            MixLog.importing.notice("import-spotify finished in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms")
        }
        // Snapshot of the library before writing. `stableTrackID` alone misses the same song
        // imported from a file or saved under a slightly different title.
        var owned = libraryService.ownedRecordingIndex
        let created = await addPlaylist(playlist, owned: &owned, onProgress: onProgress)
        finaliseImport()
        return created
    }

    /// Rebuilds one playlist. `owned` is passed in because `libraryService.tracks` only updates
    /// on `refresh()`, so a batch needs one index carried through the whole run.
    @discardableResult
    func addPlaylist(
        _ playlist: SpotifyPlaylist,
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Playlist {
        var coverData: Data? = nil
        if let coverURL = playlist.coverURL {
            coverData = try? await session.data(from: coverURL).0
        }

        // Create it first so it shows up immediately, even if some songs fail.
        let created = libraryService.createPlaylist(
            name:        playlist.name,
            description: playlist.description,
            artworkData: coverData,
            imported:    true
        )

        runCreatedPlaylistIDs.append(created.id)
        let ids = await importTracks(playlist.tracks, owned: &owned, onProgress: onProgress)
        libraryService.addTracks(ids: ids, toPlaylist: created.id)
        return created
    }

    /// Imports songs into Favourites. Liked Songs maps onto Favourites instead of becoming
    /// a second "Liked Songs" playlist. Returns how many songs landed.
    @discardableResult
    func addToFavourites(
        _ tracks: [SpotifyPlaylistTrack],
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Int {
        let ids = await importTracks(tracks, owned: &owned, onProgress: onProgress)
        // `addTracks`, not `toggleFavourite`: toggling an existing favourite would remove it on a re-run.
        SupabaseSyncService.allowBulk("spotify-import")
        libraryService.addTracks(ids: ids, toPlaylist: Playlist.favouritesID)
        return ids.count
    }

    /// Imports songs into the library only (saved albums). Albums are derived from track
    /// metadata, so no playlist is made. Returns how many songs were listed.
    @discardableResult
    func addToLibrary(
        _ tracks: [SpotifyPlaylistTrack],
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Int {
        let ids = await importTracks(tracks, owned: &owned, onProgress: onProgress)
        // Saving the album is what keeps these songs in the library. Grouped per album because
        // a compilation spans several records and `persist()` writes the whole dictionary.
        var byAlbum: [String: (title: String, artist: String, ids: [UUID])] = [:]
        for (track, id) in zip(tracks, ids) {
            let key = track.albumTitle + "\u{1}" + track.artistName
            byAlbum[key, default: (track.albumTitle, track.artistName, [])].ids.append(id)
        }
        for album in byAlbum.values {
            SavedAlbumsService.shared.setSaved(true, title: album.title, artistName: album.artist)
            SavedAlbumsService.shared.markAlbumOnly(album.ids, title: album.title, artistName: album.artist)
        }
        return ids.count
    }

    /// Turns fetched Spotify tracks into library rows, returning ids in the given order and
    /// reusing existing rows. Placement is up to the caller (playlist, Favourites, or
    /// `SpotifyFollowService`).
    func importTracks(
        _ items: [SpotifyPlaylistTrack],
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> [UUID] {
        let total = items.count
        var completed = 0

        var ids: [UUID] = []
        var fresh: [UUID] = []
        ids.reserveCapacity(total)

        // Chunked so the main actor yields to the run loop between chunks (the progress bar
        // redraws) and the first songs land before every cover is fetched.
        let chunkSize = 50

        let generation = Self.stopGeneration

        for chunkStart in stride(from: 0, to: total, by: chunkSize) {
            if Task.isCancelled || Self.stopGeneration != generation { break }

            let chunk   = Array(items[chunkStart ..< min(chunkStart + chunkSize, total)])
            let artwork = await fetchArtwork(for: chunk)

            for (position, item) in chunk.enumerated() {
                // Also checked inside an item, for huge ones. What's done so far is still placed.
                if Task.isCancelled { break }

                // Already in the library: reuse that row and leave it untouched.
                if let existing = owned.match(title: item.title,
                                              artistName: item.artistName,
                                              duration: item.duration) {
                    ids.append(existing.id)
                    completed += 1
                    continue
                }

                let online = OnlineTrack(
                    title:      item.title,
                    artistName: item.artistName,
                    albumTitle: item.albumTitle,
                    duration:   item.duration,
                    artworkURL: item.artworkURL,
                    isExplicit: item.isExplicit
                )
                let track = online.asTrack(artworkData: artwork[position], deviceID: deviceID)

                try? trackRepo.save(track) // stableTrackID dedupes re-imports
                ids.append(track.id)
                fresh.append(track.id)
                // Same song listed twice under two spellings.
                owned.insert(track)

                completed += 1
            }

            // Once per chunk to avoid thousands of @Published writes.
            onProgress?(Progress(completed: completed, total: total))
            await Task.yield()
        }

        // Let the bar paint its last frame before the big synchronous save.
        onProgress?(Progress(completed: completed, total: total, isFinishing: true))
        await Task.yield()

        // Library was wiped mid-run, nothing to add these to.
        guard Self.stopGeneration == generation else { return [] }
        runFreshTrackIDs.append(contentsOf: fresh)
        return ids
    }

    // MARK: - Whole-Library Migration

    /// Where a migration has got to, for a two-level progress display: which
    /// item out of how many, and how far into that item's songs.
    public struct MigrationProgress: Sendable {
        /// 1-based, for showing "3 of 12" without arithmetic at the call site.
        public var itemIndex: Int
        public var itemCount: Int
        public var itemName: String
        public var songsCompleted: Int
        public var songsTotal: Int
        /// Which half of the work the count refers to, so the bar moves while fetching.
        public var phase: Phase = .importing

        public enum Phase: Sendable { case fetching, importing, finishing }

        /// Songs done across the whole job. Equals the item's count for one item, so the
        /// second bar only shows for several.
        public var overallCompleted: Int = 0
        public var overallTotal: Int = 0
    }

    /// What a finished (or stopped) migration actually did.
    public struct MigrationResult: Sendable {
        public struct Failure: Sendable, Identifiable {
            public var id: String { name }
            public let name: String
            public let reason: String
        }
        /// Items brought across in full.
        public var importedCount = 0
        /// Songs added across all of them, counting a song once per item that
        /// listed it.
        public var songCount = 0
        /// Items that couldn't be read, and why. The migration continues past them.
        public var failures: [Failure] = []
        /// True when the run stopped early because it was cancelled.
        public var wasCancelled = false
        /// Local playlist per imported item, keyed by `SpotifyLibraryItem.id`, for follow links.
        /// Liked Songs maps to Favourites. Albums are left out since their track list is fixed.
        public var destinations: [String: UUID] = [:]
        /// Finished item ids, including albums. The import ledger is written from this.
        public var completedItemIDs: [String] = []
        /// Spotify track ids per finished item, for the ledger's "+9 -2".
        public var sourceTrackIDs: [String: [String]] = [:]
    }

    /// Imports the chosen Spotify items one at a time. Sequential to stay under Spotify's
    /// rate limit and keep progress readable; one `LibraryTrackIndex` dedups across the run.
    /// A stopped run is undone by `rollbackRun`.
    public func migrate(
        _ items: [SpotifyLibraryItem],
        using client: SpotifyClient,
        accessToken: String,
        onProgress: ((MigrationProgress) -> Void)? = nil
    ) async -> MigrationResult {

        var owned  = libraryService.ownedRecordingIndex
        var result = MigrationResult()

        runFreshTrackIDs = []
        runCreatedPlaylistIDs = []

        // Spotify's counts, corrected as real track lists arrive.
        let grandTotal = items.reduce(0) { $0 + $1.trackCount }
        var songsDone  = 0

        let generation = Self.stopGeneration

        for (offset, item) in items.enumerated() {
            guard !Task.isCancelled, Self.stopGeneration == generation else {
                result.wasCancelled = true
                break
            }
            // Per item, so a long run keeps the confirmation open.
            SupabaseSyncService.allowBulk("spotify-import")

            // Announce the item before fetching so a big playlist doesn't show the previous name.
            func report(_ done: Int, _ total: Int,
                        phase: MigrationProgress.Phase = .importing) {
                onProgress?(MigrationProgress(
                    itemIndex:      offset + 1,
                    itemCount:      items.count,
                    itemName:       item.name,
                    songsCompleted: done,
                    songsTotal:     total,
                    phase:          phase,
                    // Counts songs, not items.
                    overallCompleted: songsDone + (phase == .fetching ? 0 : done),
                    overallTotal:     max(grandTotal, songsDone + total)
                ))
            }
            report(0, item.trackCount, phase: .fetching)

            do {
                // `fetchContents` reports off the main actor while paging, so hop back.
                let index      = offset + 1
                let itemCount  = items.count
                let itemName   = item.name
                let trackCount = item.trackCount
                let contents = try await client.fetchContents(
                    of: item,
                    accessToken: accessToken
                ) { fetched in
                    Task { @MainActor in
                        onProgress?(MigrationProgress(
                            itemIndex:      index,
                            itemCount:      itemCount,
                            itemName:       itemName,
                            songsCompleted: min(fetched, trackCount),
                            songsTotal:     max(trackCount, fetched),
                            phase:          .fetching
                        ))
                    }
                }
                let total    = contents.tracks.count

                switch item.kind {
                case .likedSongs:
                    await addToFavourites(contents.tracks, owned: &owned) { progress in
                        report(progress.completed, total,
                               phase: progress.isFinishing ? .finishing : .importing)
                    }
                    result.destinations[item.id] = Playlist.favouritesID
                case .album:
                    await addToLibrary(contents.tracks, owned: &owned) { progress in
                        report(progress.completed, total,
                               phase: progress.isFinishing ? .finishing : .importing)
                    }
                case .playlist:
                    let created = await addPlaylist(contents, owned: &owned) { progress in
                        report(progress.completed, total,
                               phase: progress.isFinishing ? .finishing : .importing)
                    }
                    result.destinations[item.id] = created.id
                }

                await Task.yield()

                // A cancel inside an item returns normally, so set `wasCancelled` here.
                if Task.isCancelled || Self.stopGeneration != generation {
                    result.wasCancelled = true
                    break
                }

                songsDone += total
                result.completedItemIDs.append(item.id)
                result.sourceTrackIDs[item.id] = contents.tracks.compactMap(\.uri)
                result.importedCount += 1
                result.songCount     += total

            } catch {
                // Cancelling mid-fetch throws; not a real failure.
                if Task.isCancelled {
                    result.wasCancelled = true
                    break
                }
                result.failures.append(.init(
                    name:   item.name,
                    reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ))
            }
        }

        // A stopped import leaves nothing behind.
        if result.wasCancelled {
            rollbackRun()
            result.importedCount = 0
            result.songCount     = 0
            result.destinations  = [:]
            result.completedItemIDs = []
            result.sourceTrackIDs   = [:]
        }

        finaliseImport()
        return result
    }

    /// Removes the songs and playlists this run created. `runFreshTrackIDs` only holds new rows,
    /// and `deleteTracks` cleans up Favourites and All Songs.
    private func rollbackRun() {
        let tracks    = runFreshTrackIDs
        let playlists = runCreatedPlaylistIDs
        runFreshTrackIDs = []
        runCreatedPlaylistIDs = []

        SupabaseSyncService.allowBulk("import-stop")
        if !tracks.isEmpty { libraryService.deleteTracks(ids: tracks) }
        libraryService.deletePlaylists(ids: playlists)
        if !tracks.isEmpty || !playlists.isEmpty {
            MixLog.importing.debug("[SpotifyImport] Stopped, removed \(tracks.count) song(s) and \(playlists.count) playlist(s)")
        }
    }

    /// Library-wide work done once per run, since `refresh()` re-reads the whole library.
    func finaliseImport() {
        libraryService.refresh()
        // These tracks skip ImportService, so fetch real artist photos.
        libraryService.scheduleArtistImageBackfill()
    }

    /// Album thumbnails aligned to `tracks` (nil where missing). Each distinct URL is
    /// downloaded once, skipping ones already cached.
    private func fetchArtwork(for tracks: [SpotifyPlaylistTrack]) async -> [Data?] {
        var result = [Data?](repeating: nil, count: tracks.count)

        var wanted: [URL: [Int]] = [:]
        for (index, track) in tracks.enumerated() {
            guard let url = track.artworkURL else { continue }
            wanted[url, default: []].append(index)
        }
        guard !wanted.isEmpty else { return result }

        var missing: [URL] = []
        for (url, positions) in wanted {
            guard let cached = artworkCache[url] else {
                missing.append(url)
                continue
            }
            for index in positions { result[index] = cached }
        }
        guard !missing.isEmpty else { return result }

        // Downsampled before caching; thousands of covers stay resident in the library rows.
        let downloaded = await mapConcurrently(missing, limit: Self.artworkConcurrency) { [session] url in
            let raw = try? await session.data(from: url).0
            return ImageDownsampler.artworkJPEG(from: raw)
        }

        for (url, data) in zip(missing, downloaded) {
            guard let data else { continue }
            for index in wanted[url] ?? [] { result[index] = data }
            // Past the cap, keep what's cached rather than evicting it.
            if artworkCache.count < Self.artworkCacheLimit { artworkCache[url] = data }
        }
        return result
    }
}
