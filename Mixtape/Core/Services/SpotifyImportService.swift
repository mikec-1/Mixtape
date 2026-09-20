// SpotifyImportService.swift
// Mixtape
//
// Rebuilds a Spotify playlist locally — same name, cover and songs. Tracks come in
// as online Tracks (no file), so they import instantly and resolve audio on first
// play like any Discover track. Fetching happens in SpotifyClient; this is just the
// "turn a SpotifyPlaylist into library rows" half.

import Foundation
import OSLog

@MainActor
public final class SpotifyImportService {

    /// Bumped to abandon every run in flight, wherever it was started from.
    ///
    /// "Clear Everything" has no reference to whichever screen kicked off an
    /// import — the sheet, or the Settings connection — and a token on the type
    /// is a great deal less machinery than threading a handle to both. A run
    /// notices at its next chunk boundary and stops without placing what's left.
    public private(set) static var stopGeneration = 0

    public static func cancelAllRuns() { stopGeneration += 1 }

    /// Everything the run in progress brought into being, so a stop can undo it.
    ///
    /// Only rows this run *created*: a song the library already had is left
    /// alone, because the user didn't get it from this import and shouldn't lose
    /// it to cancelling one.
    private var runFreshTrackIDs: [UUID] = []
    private var runCreatedPlaylistIDs: [UUID] = []

    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
        /// Every song is in; what's left is the one big write that places them.
        public var isFinishing = false
    }

    /// Cover downloads allowed in flight at once. Enough to keep the pipe busy,
    /// few enough that a big import doesn't look like a denial-of-service.
    private static let artworkConcurrency = 6

    /// Distinct covers held in memory between playlists. A library migration
    /// walks the same records over and over — the album a playlist opens with is
    /// very often the album three other playlists open with — so the cache earns
    /// its keep across playlists, not just within one. Capped because the whole
    /// point is to survive a large library, and unbounded growth is how that
    /// stops being true.
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
        let signpost = MixSignpost.importing.beginInterval("import-spotify",
                                                           id: MixSignpost.importing.makeSignpostID())
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MixSignpost.importing.endInterval("import-spotify", signpost)
            MixLog.importing.notice("import-spotify finished in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms")
        }
        // What the library already holds, snapshotted before anything is
        // written. `stableTrackID` alone only recognises a song this app saved
        // from a catalogue that spells it exactly the way Spotify does — an
        // imported file, or the same song saved from Deezer under a slightly
        // different title, would land here as a second copy of a song the user
        // is looking at in their library.
        var owned = libraryService.ownedRecordingIndex
        let created = await addPlaylist(playlist, owned: &owned, onProgress: onProgress)
        finaliseImport()
        return created
    }

    /// Rebuild one playlist, leaving the library-wide bookkeeping to the caller.
    ///
    /// `owned` is threaded in rather than rebuilt here because it can't be
    /// rebuilt here: `libraryService.tracks` only changes when `refresh()` runs,
    /// so a batch that sensibly defers its refresh would hand every playlist the
    /// same stale snapshot and re-import songs the previous playlist just added.
    /// Carrying one index through the whole run fixes that and skips rebuilding
    /// a full-library index per playlist into the bargain.
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

    /// Import songs straight into Favourites.
    ///
    /// Spotify's Liked Songs isn't a playlist — it's the account's saved-songs
    /// collection, reached through its own endpoint — and Mixtape already has
    /// the same idea under a different name. Recreating it as an ordinary
    /// playlist called "Liked Songs" would leave someone with two Favourites,
    /// one of which doesn't fill the heart in.
    ///
    /// Returns how many songs ended up there.
    @discardableResult
    func addToFavourites(
        _ tracks: [SpotifyPlaylistTrack],
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Int {
        let ids = await importTracks(tracks, owned: &owned, onProgress: onProgress)
        // Goes through `addTracks` rather than `toggleFavourite` per song
        // because this path keeps the FavoriteEntity rows in step in one write,
        // and because toggling something already favourited would un-favourite
        // it — re-running a migration would empty the hearts it filled.
        libraryService.addTracks(ids: ids, toPlaylist: Playlist.favouritesID)
        return ids.count
    }

    /// Import songs into the library and nowhere else.
    ///
    /// This is the saved-album path. Mixtape already derives albums from track
    /// metadata — `refresh()` builds the Album row out of the songs themselves —
    /// so creating a playlist named after the record as well would leave someone
    /// holding the same album twice under two different ideas of what it is.
    ///
    /// Returns how many songs were listed.
    @discardableResult
    func addToLibrary(
        _ tracks: [SpotifyPlaylistTrack],
        owned: inout LibraryTrackIndex,
        onProgress: ((Progress) -> Void)? = nil
    ) async -> Int {
        let ids = await importTracks(tracks, owned: &owned, onProgress: onProgress)
        // Saving the record is what holds these songs in the library, exactly
        // as it does for an album saved from Discover. Nothing else would:
        // they're metadata-only rows, nobody liked them, and by the paragraph
        // above they deliberately get no playlist of their own.
        //
        // Grouped rather than one call per song because a compilation is
        // several records wearing one Spotify album, and because `persist()`
        // is a whole-dictionary write.
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

    /// Turn fetched Spotify tracks into library rows, returning their ids in the
    /// order they were given — reusing an existing row wherever the library
    /// already holds the song.
    ///
    /// Placement is left to the caller: the same songs go to a new playlist, or
    /// to Favourites, depending on what was ticked — and `SpotifyFollowService`
    /// calls it with a followed playlist's current contents, which is the same
    /// question asked a second time.
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

        // Worked in chunks, for two reasons that turn out to be the same one.
        //
        // This runs on the main actor, and the body of the loop has no
        // suspension points at all — so importing two thousand songs used to
        // hold the main thread for the entire run. That's the beach ball, and
        // it's also why the progress it was faithfully reporting never drew:
        // SwiftUI never got the chance. Chunking gives the artwork fetch and the
        // `Task.yield()` below back to the run loop regularly, so the window
        // stays alive and the bar actually moves.
        //
        // Fetching covers a chunk at a time also means the first songs land
        // seconds in rather than after every cover in the library is in hand.
        let chunkSize = 50

        let generation = Self.stopGeneration

        for chunkStart in stride(from: 0, to: total, by: chunkSize) {
            if Task.isCancelled || Self.stopGeneration != generation { break }

            let chunk   = Array(items[chunkStart ..< min(chunkStart + chunkSize, total)])
            let artwork = await fetchArtwork(for: chunk)

            for (position, item) in chunk.enumerated() {
                // Stopping between items isn't enough when one of them is a
                // five-thousand-song Liked Songs. Whatever got this far is kept
                // and placed — a stop should leave the library short, not
                // inconsistent.
                if Task.isCancelled { break }

                // Already in the library: use *that* row and leave it completely
                // alone — its file, its artwork and its downloaded copy all stay
                // whatever the user made them.
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
                // A playlist that lists the same song twice under two spellings
                // is still one song in the library.
                owned.insert(track)

                completed += 1
            }

            // Once per chunk rather than once per song: two thousand writes to
            // an @Published property is its own kind of freeze.
            onProgress?(Progress(completed: completed, total: total))
            await Task.yield()
        }

        // Let the bar paint its own last frame before the write below, which is
        // one big synchronous save rather than something progress can be
        // reported from. It covers the caller's placement write too — that one
        // is the larger of the two on a library-sized import.
        onProgress?(Progress(completed: completed, total: total, isFinishing: true))
        await Task.yield()

        // A wipe that landed mid-run means there is nothing to add these to —
        // reporting them now is how a cleared library comes back half-full.
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
        /// The same question asked of the whole job rather than of this item:
        /// songs done across every item, out of every song selected. For one
        /// item this is the item's own count, which is why the display only
        /// draws a second bar when there's more than one.
        /// Which half of the work the count refers to. Fetching a 2,000-song
        /// Liked Songs is forty round trips before the first song is imported,
        /// and a bar that sat at zero for all of it read as a hang.
        public var phase: Phase = .importing

        public enum Phase: Sendable { case fetching, importing, finishing }

        /// The same question asked of the whole job rather than of this item:
        /// songs done across every item, out of every song selected. For one
        /// item this equals the item's own count, which is why the display only
        /// draws a second bar when there's more than one.
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
        /// Items that couldn't be read, and why. A migration keeps going past
        /// these — one unreadable playlist shouldn't cost someone the other
        /// fifty-nine.
        public var failures: [Failure] = []
        /// True when the run stopped early because it was cancelled.
        public var wasCancelled = false
        /// Where each imported item landed, keyed by `SpotifyLibraryItem.id`.
        ///
        /// Only what a follow link needs: which local playlist now stands for
        /// which Spotify source. Liked Songs maps to Favourites. Saved albums
        /// aren't here — an album's track list is fixed, so following one would
        /// be a check that can never come back with anything.
        public var destinations: [String: UUID] = [:]
        /// Ids of the items that finished, including albums — which have no
        /// destination playlist and so can't be recognised from `destinations`.
        /// The import ledger is written from this.
        public var completedItemIDs: [String] = []
        /// Spotify's track ids per finished item, for the ledger's exact
        /// "+9 −2". Only knowable here — this is the one place that reads
        /// every track of every chosen item.
        public var sourceTrackIDs: [String: [String]] = [:]
    }

    /// Bring a chosen set of Spotify library items across, one after another.
    ///
    /// Sequential on purpose. The parallelism that matters is already inside
    /// each item — bounded cover downloads — and running whole playlists
    /// concurrently would multiply the request rate against Spotify's limit
    /// while making the progress display meaningless and the dedup index a
    /// contended mess. Songs shared between playlists are recognised because one
    /// `LibraryTrackIndex` is carried through the entire run.
    ///
    /// Cancellation is honoured between items and inside each fetch, and a
    /// stopped run is undone: every song and playlist this run created is
    /// removed again by `rollbackRun`. Stop means stop, not "keep the half you
    /// got" — see the comment there for what it deliberately doesn't touch.
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

        // Spotify's own counts, for a total to measure against before a single
        // item has been read. Corrected as real track lists arrive.
        let grandTotal = items.reduce(0) { $0 + $1.trackCount }
        var songsDone  = 0

        let generation = Self.stopGeneration

        for (offset, item) in items.enumerated() {
            guard !Task.isCancelled, Self.stopGeneration == generation else {
                result.wasCancelled = true
                break
            }

            // Announce the item before fetching it, so a big playlist doesn't
            // sit on the previous one's name while it downloads.
            func report(_ done: Int, _ total: Int,
                        phase: MigrationProgress.Phase = .importing) {
                onProgress?(MigrationProgress(
                    itemIndex:      offset + 1,
                    itemCount:      items.count,
                    itemName:       item.name,
                    songsCompleted: done,
                    songsTotal:     total,
                    phase:          phase,
                    // Songs, not items. Counting finished items instead made a
                    // sixty-playlist job jump in sixtieths and a one-item job
                    // never move at all, when the honest measure — how many of
                    // the songs you asked for are in — was there all along.
                    overallCompleted: songsDone + (phase == .fetching ? 0 : done),
                    overallTotal:     max(grandTotal, songsDone + total)
                ))
            }
            report(0, item.trackCount, phase: .fetching)

            do {
                // `fetchContents` reports as it pages. The callback arrives off
                // the main actor, so it hops back rather than reporting from
                // wherever the client happens to be.
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

                // Cancelling *inside* an item returns from the import normally,
                // so without this the loop would fall off the end with
                // `wasCancelled` never set — which for the commonest import of
                // all, a single Liked Songs, meant a stop that kept everything.
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
                // Cancelling mid-fetch surfaces as a thrown error, which isn't a
                // failure worth reporting as one.
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
        //
        // It used to keep whatever had already landed, on the reasoning that a
        // half-migration someone chose to stop is a result rather than a mess.
        // In practice it isn't: pressing Stop 600 songs into a 2,200-song run
        // meant 600 songs you didn't ask for and now have to find and delete by
        // hand. Stop means undo.
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

    /// Takes back everything this run created: the songs it added, and any
    /// playlist it made to hold them.
    ///
    /// Songs the library already had are untouched — `runFreshTrackIDs` only
    /// ever collects rows this run brought into existence, so a cancelled import
    /// can't take a song the user has had for a year with it. Favourites and
    /// All Songs clean themselves up, because `deleteTracks` removes the rows
    /// every playlist's list points at.
    private func rollbackRun() {
        let tracks    = runFreshTrackIDs
        let playlists = runCreatedPlaylistIDs
        runFreshTrackIDs = []
        runCreatedPlaylistIDs = []

        if !tracks.isEmpty { libraryService.deleteTracks(ids: tracks) }
        libraryService.deletePlaylists(ids: playlists)
        if !tracks.isEmpty || !playlists.isEmpty {
            print("[SpotifyImport] \u{21A9} Stopped — removed \(tracks.count) song(s) and \(playlists.count) playlist(s)")
        }
    }

    /// The library-wide work that only needs doing once, however many playlists
    /// arrived. `refresh()` re-reads and cross-references the entire library, so
    /// running it per playlist means running it sixty times to reach the state
    /// one run would have reached.
    func finaliseImport() {
        libraryService.refresh()
        // These tracks never touch ImportService, so their artist rows are
        // created by `refresh()` wearing an album cover. Fetch the real photos.
        libraryService.scheduleArtistImageBackfill()
    }

    /// Album thumbnails aligned to `tracks` (nil where missing), each distinct
    /// image downloaded once.
    ///
    /// Playlists are full of albums, and an album is one cover: a record with
    /// twelve tracks on the playlist used to mean twelve identical downloads,
    /// all launched at the same instant, because the old version added one task
    /// per *track*. Asking per distinct URL instead — and only for the ones not
    /// already in hand — is most of the difference between importing a library
    /// and being throttled off Spotify while trying to.
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

        // Shrunk before it is cached or stored: a Spotify import is thousands
        // of covers, and every one of them stays resident in the library's
        // published rows once it lands.
        let downloaded = await mapConcurrently(missing, limit: Self.artworkConcurrency) { [session] url in
            let raw = try? await session.data(from: url).0
            return ImageDownsampler.artworkJPEG(from: raw)
        }

        for (url, data) in zip(missing, downloaded) {
            guard let data else { continue }
            for index in wanted[url] ?? [] { result[index] = data }
            // Past the cap we stop remembering rather than start forgetting:
            // whatever a long migration has already seen is likelier to come
            // round again than whatever it hasn't reached yet.
            if artworkCache.count < Self.artworkCacheLimit { artworkCache[url] = data }
        }
        return result
    }
}
