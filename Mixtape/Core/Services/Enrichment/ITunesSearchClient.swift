// ITunesSearchClient.swift
// Mixtape — Core/Services/Enrichment
//
// Thin async wrapper around the public iTunes Search + Lookup APIs.
// No API key required.
//
// Search strategy (when artist is known):
//   1. Find the artist's iTunes ID via entity=musicArtist search
//   2. Look up ALL their songs via /lookup?id=artistId&entity=song
//   3. Score those songs against the stripped title → guaranteed correct artist
//   + Title-only search runs in parallel as a fallback for title matches
//     when no artist is known or artist lookup fails.
//
// Artwork URL trick: swap "100x100bb" → "600x600bb" in artworkUrl100.

import Foundation
import OSLog
// MARK: - Public result model

public struct ITunesTrackResult: Decodable, Sendable {
    public let trackName:        String
    public let artistName:       String
    public let collectionName:   String?
    public let artworkUrl100:    String?
    public let releaseDate:      String?    // "2014-07-01T07:00:00Z"
    public let trackNumber:      Int?
    public let primaryGenreName: String?
    public let trackTimeMillis:  Int?       // canonical track length, used to reject mismatched YouTube videos
    public var sourceID:         Int? = nil // Deezer track id when sourced from Deezer; absent for iTunes results
    public var isExplicit:       Bool = false // true when the track has explicit lyrics
}

// MARK: - Deezer response models (artist image lookup)

private struct DeezerArtistResponse: Decodable {
    let data: [DeezerArtist]
}

private struct DeezerArtist: Decodable {
    let name:           String
    /// Only `/artist/{id}` carries it; search listings don't.
    let nb_fan:         Int?
    let picture_xl:     String?
    let picture_medium: String?
}

// MARK: - Deezer error envelope

/// What Deezer sends instead of the thing you asked for.
///
/// It answers with HTTP 200 either way — the failure is in the body, as
/// `{"error":{"type":…,"message":…,"code":…}}`. So a decode failure on a Deezer
/// response is usually not malformed JSON; it's Deezer saying no in the only way
/// it says it, and the old handling turned every one of those into an empty list
/// with `The data couldn't be read because it is missing.` in the log.
private struct DeezerErrorEnvelope: Decodable {

    struct Payload: Decodable {
        let type:    String?
        let message: String?
        let code:    Int?
    }

    let error: Payload

    /// Worth asking again in a moment. Code 4 is the quota (Deezer allows about
    /// fifty requests per five seconds per IP, and a mix build fans out well past
    /// that); 700 is its "service busy". Everything else — 800 "no data", a bad
    /// id, a missing endpoint — will say exactly the same thing on a retry.
    var isTransient: Bool {
        switch error.code {
        case 4, 700: return true
        default:     return error.message?.localizedCaseInsensitiveContains("quota") == true
        }
    }

    var describedError: String {
        let text = error.message ?? error.type ?? "unknown error"
        guard let code = error.code else { return text }
        return "\(text) (code \(code))"
    }
}

/// Spaces Deezer requests far enough apart to stay inside the quota.
///
/// The build asks for a radio, a top-tracks list and a related-artists list per
/// seed artist, all concurrently, and the burst is what trips the limit rather
/// than the total. Each caller claims the next slot synchronously and only then
/// sleeps, so slots are handed out in arrival order and a caller sleeping never
/// blocks the next one from claiming its own.
actor RequestGate {

    /// Deezer: ~9 requests a second against a documented ceiling of ten.
    static let deezer = RequestGate(spacing: 0.11)

    private let spacing: TimeInterval
    private var nextSlot = Date.distantPast

    init(spacing: TimeInterval) { self.spacing = spacing }

    func waitForSlot() async {
        let now  = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(spacing)

        let delay = slot.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

/// A short-lived body cache in front of Deezer, and a queue of one per URL.
///
/// Typing asks the same question repeatedly. The type-ahead's debounce fires
/// `search/artist?q=…&limit=25`, and the full search's debounce asks for the
/// byte-identical URL a few tens of milliseconds later — where, without this,
/// it joined the back of the request gate behind everything the first search
/// had already queued and waited out a whole round trip for an answer that was
/// either in memory or already in the air. Coalescing is the half that matters
/// while typing; the TTL is what makes backspacing to a query you just ran
/// instant instead of a re-fetch.
///
/// Bodies are cached, not decoded values: the same URL is read into different
/// shapes by different callers, and `Data` is the one form they share.
private actor DeezerResponseCache {

    static let shared = DeezerResponseCache()

    private struct Entry { let body: Data; let at: Date }

    /// Long enough to cover a stretch of typing and correcting, short enough
    /// that a chart or a new release is never served from a previous session.
    private static let ttl: TimeInterval = 60
    private static let capacity = 240

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func body(for url: URL, fetch: @Sendable @escaping () async -> Data?) async -> Data? {
        let key = url.absoluteString

        if let hit = entries[key], Date().timeIntervalSince(hit.at) < Self.ttl { return hit.body }

        // Somebody is already asking this exact question. Wait on their answer
        // rather than spending a second gate slot to ask it again.
        if let running = inFlight[key] { return await running.value }

        let task = Task { await fetch() }
        inFlight[key] = task
        let body = await task.value
        inFlight[key] = nil

        if let body {
            // A flat cap rather than an LRU: this holds a session of searching,
            // and the cost of being wrong about which entry to drop is one
            // request. Clearing outright keeps the bookkeeping honest.
            if entries.count >= Self.capacity { entries.removeAll() }
            entries[key] = Entry(body: body, at: Date())
        }
        return body
    }

    /// Forgets a body that turned out to be a throttle notice rather than an
    /// answer, so the retry behind it asks Deezer again instead of re-reading
    /// the same refusal from memory for the rest of the minute.
    func forget(_ url: URL) { entries[url.absoluteString] = nil }
}

// MARK: - Deezer track-search models (popularity-ranked discover search)

private struct DeezerTrackSearchResponse: Decodable {
    let data: [DeezerTrack]
}

private struct DeezerTrack: Decodable {
    struct Artist: Decodable { let id: Int?; let name: String; let picture_xl: String?; let picture_big: String? }
    struct Album:  Decodable { let id: Int?; let title: String; let cover_xl: String?; let cover_big: String? }
    let id:       Int?       // Deezer track id (used to fetch contributors)
    let title:    String
    let duration: Int?       // seconds
    let rank:     Int?       // Deezer popularity score — higher = more popular
    let explicit_lyrics: Bool?  // true = explicit; optional because some endpoints omit it
    // Optional: /album/{id}/tracks responses omit `album`, and some omit `artist`.
    let artist:   Artist?
    let album:    Album?
    /// Main artist first, guests after. `/artist/{id}/top` carries these;
    /// search, the charts and `/album/{id}/tracks` do not — hence optional, and
    /// hence `withContributors`, which fills them in where it matters.
    let contributors: [Artist]?
}

// MARK: - Deezer track detail (contributors = main + featured artists)

private struct DeezerTrackDetail: Decodable {
    struct Contributor: Decodable {
        let id: Int
        let name: String
        let picture_xl: String?
        let picture_big: String?
    }
    struct Album: Decodable {
        let id: Int
        let title: String
        let cover_xl: String?
        let cover_big: String?
    }
    struct Artist: Decodable {
        let name: String
    }
    let contributors: [Contributor]?
    let album: Album?
    let artist: Artist?
}

// MARK: - Deezer browse models (artist / album search + catalogue)

private struct DeezerArtistSearchResponse: Decodable {
    struct Item: Decodable {
        let id: Int
        let name: String
        let nb_fan: Int?     // Deezer follower count — the only popularity signal
        // Deezer's own photo. Used only as the fallback when Spotify can't confirm
        // an artist of the same name (see `withSpotifyImages`).
        let picture_xl: String?
        let picture_big: String?
    }
    let data: [Item]
}

private struct DeezerAlbumSearchResponse: Decodable {
    struct Item: Decodable {
        struct Artist: Decodable { let id: Int?; let name: String }
        let id: Int
        let title: String
        let cover_xl: String?
        let cover_big: String?
        let artist: Artist?
        /// Present on `/artist/{id}/albums` but not on search or the charts,
        /// hence optional — see `artistAlbums`, which is the one caller that
        /// gets them and the one that needs them.
        let release_date: String?
        let record_type: String?
        let nb_tracks: Int?
    }
    let data: [Item]
}

/// A single album, from `/album/{id}`. The chart and search listings don't carry
/// `release_date` or `record_type`, and those two are the entire difference
/// between "an album" and "a *new* album" — so New releases resolves its
/// candidates one by one to get them.
private struct DeezerAlbumDetail: Decodable {
    struct Artist: Decodable { let id: Int?; let name: String }
    let id: Int
    let title: String
    let cover_xl: String?
    let cover_big: String?
    let artist: Artist?
    let release_date: String?
    /// "album" | "ep" | "single" | "compile"
    let record_type: String?
}

// MARK: - Deezer chart / genre browse models (Discover landing)

private struct DeezerChartArtistsResponse: Decodable {
    struct Item: Decodable {
        let id: Int
        let name: String
        let picture_xl: String?
        let picture_medium: String?
    }
    let data: [Item]
}

private struct DeezerGenreResponse: Decodable {
    struct Item: Decodable {
        let id: Int
        let name: String
        let picture_xl: String?
        let picture_medium: String?
    }
    let data: [Item]
}

// MARK: - Private response models

private struct SearchResponse: Decodable {
    let resultCount: Int
    let results:     [ITunesTrackResult]
}

private struct ArtistItem: Decodable {
    let artistId:   Int
    let artistName: String
}

private struct ArtistSearchResponse: Decodable {
    let resultCount: Int
    let results:     [ArtistItem]
}

/// Flexible item used for Lookup API responses which mix artist + track records.
private struct LookupItem: Decodable, Sendable {
    let wrapperType:      String
    let trackName:        String?
    let artistName:       String?
    let collectionName:   String?
    let artworkUrl100:    String?
    let releaseDate:      String?
    let trackNumber:      Int?
    let primaryGenreName: String?
    let trackTimeMillis:  Int?
}

private struct LookupResponse: Decodable, Sendable {
    let resultCount: Int
    let results:     [LookupItem]
}

/// Converts a raw lookup item to a track result.
/// Free function (not a method/property) to avoid Swift 6 actor-isolation inference.
private func trackResult(from item: LookupItem) -> ITunesTrackResult? {
    guard item.wrapperType == "track",
          let trackName  = item.trackName,
          let artistName = item.artistName else { return nil }
    return ITunesTrackResult(
        trackName:        trackName,
        artistName:       artistName,
        collectionName:   item.collectionName,
        artworkUrl100:    item.artworkUrl100,
        releaseDate:      item.releaseDate,
        trackNumber:      item.trackNumber,
        primaryGenreName: item.primaryGenreName,
        trackTimeMillis:  item.trackTimeMillis
    )
}

// MARK: - Client

public final class ITunesSearchClient: Sendable {

    private static let searchURL = "https://itunes.apple.com/search"
    private static let lookupURL = "https://itunes.apple.com/lookup"

    /// Spotify client used to resolve artist profile images — they're fresher than
    /// Deezer's, so they win when Spotify can *confirm* an artist of that name.
    /// Optional so non-Discover callers can construct without it.
    private let spotifyClient: SpotifyClient?

    public init(spotifyClient: SpotifyClient? = nil) {
        self.spotifyClient = spotifyClient
    }

    /// Upgrade a batch of artists to their Spotify profile photos, keeping the
    /// Deezer picture already on the value when Spotify has no verified match.
    ///
    /// Spotify's search is fuzzy — asking it for "DRA" hands back Drake — so
    /// `SpotifyClient` only returns an image when the Spotify artist's *name*
    /// matches the one asked for. Previously the unverified first hit was used and
    /// tiny artists rendered with a famous person's face. Falling back to Deezer's
    /// own photo (rather than nil) keeps small artists from becoming a wall of
    /// placeholders now that the verification rejects those wrong faces.
    ///
    /// The upgrade is cosmetic and it is not allowed to hold the page up. It
    /// costs one Spotify `/v1/search` per name and the fans-also-like row asks
    /// for twelve at a time, so when Spotify is rate-limiting — which it does,
    /// often — each of those twelve sits out its own `Retry-After` and a search
    /// that had every fact it needed in about a second spends another fifteen
    /// waiting for nicer photographs of them. So the lookup races a deadline:
    /// whatever arrived is used, and every name that didn't keeps the Deezer
    /// picture it already had. The page is complete either way, only slightly
    /// less crisp, and `SpotifyClient` caches what it resolves — so the second
    /// search for the same artists usually wins the race outright.
    private static let spotifyImageDeadline: TimeInterval = 0.8

    private func withSpotifyImages(_ artists: [OnlineArtist]) async -> [OnlineArtist] {
        guard let spotifyClient, !artists.isEmpty else { return artists }
        let names = artists.map(\.name)
        let images = await Self.orGiveUp(after: Self.spotifyImageDeadline, fallback: [:]) {
            await spotifyClient.artistImages(for: names)
        }
        return artists.map {
            OnlineArtist(id: $0.id, name: $0.name, imageURL: images[$0.name] ?? $0.imageURL)
        }
    }

    /// Runs `work`, but gives up waiting for it after `seconds` and returns
    /// `fallback` instead. Losing the race cancels the work — every step of it
    /// is a network call or a sleep, both of which unwind on cancellation, so
    /// the deadline is a real one rather than a hope.
    private static func orGiveUp<T: Sendable>(
        after seconds: TimeInterval,
        fallback: T,
        _ work: @Sendable @escaping () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }

    /// First usable Deezer artist photo. Deezer serves a grey silhouette at the
    /// md5 of an empty file for artists with no picture, so that URL is treated as
    /// "no image" and the app's own placeholder is used instead.
    private static func artistPicture(_ candidates: String?...) -> URL? {
        for raw in candidates {
            guard let raw, !raw.isEmpty,
                  !raw.contains("d41d8cd98f00b204e9800998ecf8427e"),
                  let url = URL(string: raw) else { continue }
            return url
        }
        return nil
    }

    // MARK: - Public API

    /// Search for songs matching `title`, optionally scoped to `artist`.
    ///
    /// When `artist` is supplied the pipeline is:
    ///   • Find artist ID (entity=musicArtist) across GB→US→AU→CA storefronts
    ///   • Fetch their full song catalogue via Lookup API
    ///   • Merge with a parallel title-only search for extra coverage
    ///
    /// When no artist is supplied, falls back to title-only search.
    public func search(title: String, artist: String?) async throws -> [ITunesTrackResult] {
        var all: [ITunesTrackResult] = []

        // Run title search and artist-catalogue lookup concurrently.
        // When no explicit artist is given (the Discover free-text box), the query
        // itself might BE an artist name (e.g. "drake"). Treat it as both a title
        // and an artist so an artist's catalogue surfaces instead of random songs
        // that merely contain the word.
        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            group.addTask { (try? await self.searchByTitle(title)) ?? [] }
            let artistGuess = artist ?? title
            group.addTask { (try? await self.searchByArtistCatalogue(artistGuess)) ?? [] }
            for try await results in group { all.append(contentsOf: results) }
        }

        // Dedup by trackName + artistName (case-insensitive)
        var seen = Set<String>()
        let unique = all.filter { r in
            let key = "\(r.trackName.lowercased())|\(r.artistName.lowercased())"
            return seen.insert(key).inserted
        }

        // Rank by relevance to the query. iTunes has no popularity/stream-count
        // field, so we approximate "show the obvious artist first": exact artist
        // matches lead, then partial artist matches, then title matches.
        let q = (artist ?? title).lowercased().trimmingCharacters(in: .whitespaces)
        return unique
            .map { ($0, Self.relevance(of: $0, query: q)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.trackName < $1.0.trackName }
            .map { $0.0 }
    }

    /// Higher = more relevant to `query` (already lowercased). Biases toward the
    /// artist the user most likely meant when typing a bare name like "drake".
    private static func relevance(of r: ITunesTrackResult, query q: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let artist = r.artistName.lowercased()
        let track  = r.trackName.lowercased()
        var score = 0
        if artist == q                              { score += 100 }   // "drake" → Drake
        else if artist.hasPrefix(q)                 { score += 70 }    // "drak" → Drake
        else if artist.contains(q)                  { score += 40 }    // "ovo drake"
        if track == q                               { score += 60 }    // exact song title
        else if track.hasPrefix(q)                  { score += 30 }
        else if track.contains(q)                   { score += 15 }
        return score
    }

    // MARK: - Popularity-ranked discover search (Deezer)

    /// Free-text search ordered by real-world popularity.
    ///
    /// Deezer's `/search` returns a `rank` (popularity score) per track, so a
    /// query like "drake" surfaces Drake's biggest songs — and an album/song name
    /// surfaces the famous version — instead of obscure artists who merely share
    /// the name. Returns `[]` on any failure so the caller can fall back to iTunes.
    ///
    /// Goes through `fetchTracks` rather than calling `URLSession` itself. It
    /// used to reach for the network directly, which quietly opted the busiest
    /// request in the app out of everything the shared path provides: the rate
    /// gate, the retry on a throttle notice, and — the reason this mattered —
    /// the response cache. The type-ahead and the full search ask `/search` the
    /// same question a few tens of milliseconds apart, and only a shared path
    /// can notice that and answer the second one for free.
    public func searchPopular(query: String, limit: Int = 40) async -> [ITunesTrackResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let rows = await fetchTracks(query: trimmed, limit: limit)
        guard !rows.isEmpty else { return [] }

        // Most-popular-first, mapped into the shared result model. The dedup by
        // title|artist that collapses the same song across albums — always
        // keeping the explicit cut — happens inside `fetchTracks`.
        return rows.map { t in
            ITunesTrackResult(
                trackName:        t.title,
                artistName:       t.artist?.name ?? "",
                collectionName:   t.album?.title,
                artworkUrl100:    t.album?.cover_xl ?? t.album?.cover_big,
                releaseDate:      nil,
                trackNumber:      nil,
                primaryGenreName: nil,
                trackTimeMillis:  t.duration.map { $0 * 1000 },
                sourceID:         t.id,
                isExplicit:       t.explicit_lyrics ?? false
            )
        }
    }

    // MARK: - Discover browse (Deezer artists / albums / catalogue)

    /// One round-trip-ish grouped search for the sectioned Discover UI: popular
    /// songs, matching artists, and matching albums. Each leg fails soft to [].
    ///
    /// Everything on the page hangs off a single *anchor* artist, so choosing it
    /// correctly is the whole ballgame: get it wrong and the albums row, the top
    /// tracks and "fans also like" all belong to a stranger.
    public func discoverSearch(query: String) async -> DiscoverResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return DiscoverResults() }

        // A search is a chain of somebody else's round trips, so when one feels
        // slow the only question worth asking is which link spent the time.
        // Console, filtered on category "search", answers it.
        let began = Date()
        // The row count travels with the timing: a stage that was fast because
        // Deezer returned nothing looks identical to a fast one that worked,
        // and only the count tells them apart.
        func elapsed(_ stage: String, _ rows: Int? = nil) {
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let count = rows.map { " \($0) rows" } ?? ""
            MixLog.search.info("\(stage, privacy: .public) \(ms)ms\(count, privacy: .public)")
        }

        async let songsRaw   = searchPopular(query: trimmed, limit: 25)
        async let candidates = fetchArtistCandidates(query: trimmed, limit: 25)

        let rawSongs = await songsRaw.map { r in
            OnlineTrack(
                title: r.trackName,
                artistName: r.artistName,
                albumTitle: r.collectionName ?? "",
                duration: r.trackTimeMillis.map { TimeInterval($0) / 1000 } ?? 0,
                artworkURL: r.artworkUrl100.flatMap { URL(string: $0) },
                sourceID: r.sourceID,
                isExplicit: r.isExplicit
            )
        }
        // Drop the same-name noise Deezer's broad full-text search mixes in, while
        // keeping the most-popular genuine match (which anchors everything below)
        // at the front.
        //
        // Note what is *not* happening here: credits. Deezer's search rows carry
        // no contributors, and asking for them costs one request per row — ten
        // of them, spent before the page even knew which songs it was going to
        // show. On an anchored query this whole list is then thrown away and
        // replaced by the artist's top tracks, which carry their contributors
        // natively, so those ten requests bought nothing at all. Relevance and
        // ranking read only the title and the artist name, so the credits can
        // wait until the songs are final — see the end of this method.
        elapsed("songs", rawSongs.count)
        let (relevant, songsAreRelevant) = relevantSongs(rawSongs, matching: trimmed)
        var songs = relevant

        // Rank the artist hits against the query *and* against who actually owns
        // the matching songs — the songs are free evidence, already fetched.
        let ranked = Self.rank(await candidates, for: trimmed,
                               corroboratingArtists: songs.prefix(10).map(\.artistName))
        elapsed("candidates", ranked.count)
        let topArtist = ranked.first
        let isArtistQuery = topArtist.map { Self.namesAnArtist($0, songs: songs) } ?? false

        var anchor: OnlineArtist?
        var topSong: OnlineTrack?
        var songArtists: [OnlineArtist] = []

        if isArtistQuery, let topArtist {
            anchor = topArtist.artist
            // Bare-artist query (e.g. "drake"): the songs list should be the
            // artist's OWN top tracks — not Deezer's full-text popularity search,
            // which mixes in same-name songs by other artists. This is the main
            // cause of "the first song is right but the rest are strangers".
            let top = await artistTopTracks(artistId: topArtist.id, limit: 25)
            if !top.isEmpty { songs = top }
        }

        // Song-centric query (a specific song, not an artist name): promote that
        // song to a wide hero and surface the artists ON it — the main artist plus
        // any featured artists — followed by more songs by the main artist. Skipped
        // when nothing genuinely matched, so a nonsense query shows its fuzzy song
        // hits without inventing an artist page around one of them.
        if !isArtistQuery, songsAreRelevant, let hero = songs.first {
            topSong = hero
            // Contributors give the real main + featured artists with their Deezer
            // ids, which is far more reliable than searching the printed name.
            if let trackID = hero.sourceID {
                songArtists = await trackContributors(trackID: trackID)
            }
            if songArtists.isEmpty, !hero.artistName.isEmpty {
                songArtists = await searchArtists(query: hero.artistName, limit: 1)
            }
            anchor = songArtists.first

            // "More songs by that artist" — the main artist's top tracks, minus the
            // hero itself. Falls back to the popularity list (filtered to the hero's
            // artist so we don't reintroduce same-name noise) if the lookup whiffs.
            if let mainArtistID = anchor?.id {
                let more = await artistTopTracks(artistId: mainArtistID, limit: 12)
                    .filter { $0.id != hero.id }
                songs = more.isEmpty
                    ? songs.filter { namesMatch($0.artistName, hero.artistName) }
                    : more
            }
        }

        elapsed("anchor", songs.count)

        // Albums section = the anchor artist's OWN catalogue (not a title match),
        // and the "fans also like" row = the anchor + its related artists.
        //
        // Both hang off the same id and neither reads the other, so they go out
        // together. Run one after the other they cost two round trips to answer
        // one question, and they sat at the end of a chain that had already
        // spent four.
        var albums: [OnlineAlbum] = []
        var artists: [OnlineArtist] = []
        if let resolved = anchor {
            async let albumsCall  = artistAlbums(artistId: resolved.id, artistName: resolved.name, limit: 12)
            async let relatedCall = relatedArtists(artistId: resolved.id, limit: 11)
            albums = await albumsCall
            let related = await relatedCall

            // Artist ids from search occasionally point at a dead duplicate profile
            // with no catalogue at all. Rather than render an empty page, fall back
            // to the artist behind the best matching song and try once more.
            if albums.isEmpty, songs.isEmpty, songsAreRelevant,
               let heroArtist = relevant.first?.artistName,
               let better = await searchArtists(query: heroArtist, limit: 1).first,
               better.id != resolved.id {
                anchor = better
                async let betterSongs   = artistTopTracks(artistId: better.id, limit: 25)
                async let betterAlbums  = artistAlbums(artistId: better.id, artistName: better.name, limit: 12)
                async let betterRelated = relatedArtists(artistId: better.id, limit: 11)
                songs  = await betterSongs
                albums = await betterAlbums
                var seen = Set([better.id])
                artists = [better] + (await betterRelated).filter { seen.insert($0.id).inserted }
            } else {
                var seen = Set([resolved.id])
                artists = [resolved] + related.filter { seen.insert($0.id).inserted }
            }
        }

        elapsed("albums+related", albums.count + artists.count)

        // Credits last, and only on the rows that survived.
        //
        // `withContributors` skips any row that already has them, and every
        // anchored path above ends with `artistTopTracks`, which carries them.
        // So in the common case this is free, and in the unanchored fallback it
        // never costs more than the songs actually on screen.
        songs = await withContributors(songs, limit: 10)
        if let hero = topSong {
            topSong = await withContributors([hero], limit: 1).first ?? hero
        }
        elapsed("done", songs.count)

        // An anchored page is matched by construction: the songs are that
        // artist's own top tracks, or the hero the query resolved to. Only the
        // unanchored fallback is a guess, and the page is told so.
        return DiscoverResults(songs: songs, artists: artists, albums: albums,
                               topSong: topSong, songArtists: songArtists,
                               anchorIsArtist: isArtistQuery && anchor != nil,
                               songsMatched: songsAreRelevant || anchor != nil)
    }

    /// Does the query name this ARTIST, rather than one of their songs?
    ///
    /// A name match alone isn't enough: searching a song title usually turns up a
    /// tiny artist named after it (Deezer has a 333-fan "God's Plan"), and letting
    /// that anchor the page replaced Drake's catalogue with theirs. So a strong
    /// name match must also be backed by *evidence the user meant that artist*:
    /// either they own several of the songs the same query matched, or they're
    /// popular enough that nobody typing the name meant anyone else. The exact-match
    /// bar is much lower because typing a name in full is itself strong intent —
    /// that's what lets "c4rl" and "thizzy" resolve to genuinely small artists.
    private static func namesAnArtist(_ candidate: ArtistCandidate, songs: [OnlineTrack]) -> Bool {
        guard candidate.tier >= DiscoverNameMatch.strong else { return false }
        let owned = songs.prefix(5).filter { DiscoverNameMatch.sameName($0.artistName, candidate.name) }.count
        if owned >= 2 { return true }
        return candidate.fans >= (candidate.tier == DiscoverNameMatch.exact ? 10_000 : 250_000)
    }

    // MARK: - Search-as-you-type

    /// Type-ahead rows for `query`. Cheap and cancellation-safe — the caller debounces.
    ///
    /// Two parallel round-trips (artists + tracks), ordered the way Spotify's
    /// dropdown reads: the best-matching artist first when the ranking finds a real
    /// one, then up to two query completions, then the matching songs. Images come
    /// straight from Deezer — verifying every name against Spotify would add a
    /// round-trip per keystroke, and a dropdown thumbnail isn't worth that.
    public func searchSuggestions(query: String, limit: Int = 16) async -> [SearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        // Both legs deliberately ask for the same slice `discoverSearch` asks
        // for. The dropdown needs far fewer rows than that, but an identical URL
        // is one the response cache can answer for free — and a full search is
        // almost always already in the air behind this one, because the two run
        // off the same keystroke. Asking a slightly bigger question that somebody
        // else is already asking is cheaper than asking a small new one.
        async let candidatesRaw = fetchArtistCandidates(query: trimmed, limit: 25)
        async let tracksRaw     = fetchTracks(query: trimmed, limit: 25)
        let (candidates, tracks) = await (candidatesRaw, tracksRaw)
        guard !Task.isCancelled else { return [] }

        let ranked = Self.rank(candidates, for: trimmed,
                               corroboratingArtists: tracks.compactMap { $0.artist?.name })
        let typed = DiscoverNameMatch.normalize(trimmed)
        var out: [SearchSuggestion] = []

        // 1. The artist — only when the ranking found a genuine name match, so a
        //    song-title query doesn't lead with whoever named themselves after it.
        let topArtist = ranked.first.flatMap { $0.tier >= DiscoverNameMatch.strong ? $0 : nil }
        if let topArtist {
            out.append(SearchSuggestion(id: "artist-\(topArtist.id)", kind: .artist(id: topArtist.id),
                                        title: topArtist.name, subtitle: "Artist",
                                        imageURL: topArtist.picture, isExplicit: false))
        }

        // 2. Completions of what's actually been typed — the full artist name and
        //    the top song's title, when they extend the query rather than repeat it.
        //    Tapping one re-runs the search; the rows above open the entity itself.
        var terms: [String] = []
        for text in [topArtist?.name, tracks.first?.title].compactMap({ $0 }) {
            let normalized = DiscoverNameMatch.normalize(text)
            guard normalized.hasPrefix(typed), normalized.count > typed.count,
                  !terms.contains(where: { DiscoverNameMatch.normalize($0) == normalized })
            else { continue }
            terms.append(text)
        }
        // Always leave room for songs; a dropdown of nothing but completions is useless.
        for term in terms.prefix(2) where out.count < max(limit - 2, 1) {
            out.append(SearchSuggestion(id: "term-\(term.lowercased())", kind: .term, title: term,
                                        subtitle: nil, imageURL: nil, isExplicit: false))
        }

        // 3. The album, when the query names one outright ("utopia") — otherwise a
        //    row per near-miss album title is just noise.
        if let album = tracks.lazy.compactMap(\.album).first(where: {
            $0.id != nil && DiscoverNameMatch.tier(name: $0.title, query: trimmed) >= DiscoverNameMatch.wordPrefix
        }), let albumID = album.id, out.count < max(limit - 2, 1) {
            let artist = tracks.first { $0.album?.id == albumID }?.artist?.name
            out.append(SearchSuggestion(id: "album-\(albumID)", kind: .album(id: albumID),
                                        title: album.title,
                                        subtitle: artist.map { "Album • \($0)" } ?? "Album",
                                        imageURL: (album.cover_xl ?? album.cover_big).flatMap(URL.init(string:)),
                                        isExplicit: false, artistName: artist))
        }

        // 4. The songs themselves, in Deezer's relevance order.
        var seen = Set<String>()
        for track in tracks where out.count < limit {
            guard let trackID = track.id else { continue }
            let artist = track.artist?.name ?? ""
            guard seen.insert("\(track.title.lowercased())|\(artist.lowercased())").inserted else { continue }
            out.append(SearchSuggestion(
                id: "track-\(trackID)", kind: .track(id: trackID), title: track.title,
                subtitle: artist.isEmpty ? "Song" : "Song • \(artist)",
                imageURL: (track.album?.cover_xl ?? track.album?.cover_big).flatMap(URL.init(string:)),
                isExplicit: track.explicit_lyrics ?? false,
                artistName: artist, albumTitle: track.album?.title,
                duration: track.duration.map(TimeInterval.init)
            ))
        }
        return Array(out.prefix(limit))
    }

    /// Raw Deezer track search, explicit versions preferred. Shared by the
    /// suggestions API, which needs the album/track ids `searchPopular` drops.
    private func fetchTracks(query: String, limit: Int) async -> [DeezerTrack] {
        guard let url = Self.deezerURL("search", query: query, limit: limit),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data)
    }

    // MARK: - Discover landing (charts / genres, shown before searching)

    /// One grouped fetch for the pre-search Discover landing: trending tracks,
    /// popular artists, new releases, and genre tiles. Each leg fails soft to []
    /// so a partial outage still yields a populated page.
    public func browseLanding() async -> BrowseLanding {
        async let trending = chartTracks(limit: 20)
        async let artists  = chartArtists(limit: 15)
        async let releases = newReleases(limit: 18)
        async let genreTiles = genres()
        return await BrowseLanding(trending: trending, artists: artists,
                                   newReleases: releases, genres: genreTiles)
    }

    /// Globally trending tracks (Deezer chart). Explicit version preferred.
    /// `genreId` 0 is Deezer's "all genres" chart, which is what makes this one
    /// function serve both the global chart and a scene's.
    public func chartTracks(genreId: Int = 0, limit: Int = 20) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/chart/\(genreId)/tracks?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                        contributors: t.contributors?.map(\.name) ?? [])
        }
    }

    /// Artists trending right now. Deezer's `/chart/0/artists` is an editorial
    /// selection that's often stale/irrelevant, so we instead derive the list from
    /// the *trending tracks* (the actual current hits) — the unique artists behind
    /// today's chart, in chart order. Falls back to the artists chart if that whiffs.
    public func chartArtists(limit: Int = 15) async -> [OnlineArtist] {
        // Pull a deep slice of the track chart so we have enough distinct artists.
        if let url = URL(string: "https://api.deezer.com/chart/0/tracks?limit=100"),
           let resp: DeezerTrackSearchResponse = await Self.getJSON(url) {
            var seen = Set<Int>()
            var artists: [OnlineArtist] = []
            for t in resp.data {
                guard let a = t.artist, let id = a.id, seen.insert(id).inserted else { continue }
                artists.append(OnlineArtist(id: id, name: a.name,
                                            imageURL: Self.artistPicture(a.picture_xl, a.picture_big)))
                if artists.count >= limit { break }
            }
            if !artists.isEmpty { return await withSpotifyImages(artists) }
        }
        // Fallback: Deezer's artist chart.
        guard let url = URL(string: "https://api.deezer.com/chart/0/artists?limit=\(limit)"),
              let resp: DeezerChartArtistsResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map {
            OnlineArtist(id: $0.id, name: $0.name,
                         imageURL: Self.artistPicture($0.picture_xl, $0.picture_medium))
        }
        return await withSpotifyImages(artists)
    }

    /// What actually came out lately, by people you've plausibly heard of.
    ///
    /// Deezer's album chart (`/chart/0/albums`) is an editorial list that is
    /// neither: it served a 1982 Clash reissue, a Vienna musical cast recording
    /// and a German comedian's greatest hits under the heading "New releases",
    /// none of which are new and none of which anybody asked for. It has no
    /// release dates on it either, so there was no way to filter it honestly.
    ///
    /// The track chart, on the other hand, is genuinely live — the same
    /// observation `chartArtists` is built on. The albums *behind* today's
    /// charting songs are by definition both current and recognisable, so this
    /// walks the chart in order, resolves each distinct album (the only endpoint
    /// that carries `release_date` and `record_type`), drops anything that isn't
    /// actually recent, and orders full-lengths and EPs ahead of singles.
    ///
    /// Chart position, not date, breaks ties within a tier: "new" is the filter,
    /// "known" is the sort — a stranger's album from last Friday is not a better
    /// answer than this month's number one.
    public func newReleases(limit: Int = 18) async -> [OnlineAlbum] {
        let candidates = await chartAlbumIDs(limit: 30)
        let details = await albumDetails(ids: candidates)

        let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: Date())
        var full: [OnlineAlbum] = []      // albums and EPs
        var singles: [OnlineAlbum] = []
        var seen = Set<String>()

        for detail in details {
            guard let released = Self.deezerDate(detail.release_date) else { continue }
            if let cutoff, released < cutoff { continue }
            let artist = detail.artist?.name ?? ""
            guard seen.insert("\(detail.title.lowercased())|\(artist.lowercased())").inserted
            else { continue }
            let album = OnlineAlbum(
                id: detail.id, title: detail.title, artistName: artist,
                coverURL: (detail.cover_xl ?? detail.cover_big).flatMap(URL.init(string:)),
                releaseDate: released, recordType: detail.record_type
            )
            if detail.record_type == "single" { singles.append(album) } else { full.append(album) }
        }

        let merged = Array((full + singles).prefix(limit))
        // Only if the chart itself was unreachable. A thin list is a real answer
        // (few albums cleared the date filter); an empty one means the fetch failed.
        return merged.isEmpty ? await chartAlbums(limit: limit) : merged
    }

    /// Distinct album ids behind the current track chart, in chart order.
    private func chartAlbumIDs(limit: Int) async -> [Int] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/tracks?limit=100"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        var seen = Set<Int>()
        var out: [Int] = []
        for track in resp.data {
            guard let id = track.album?.id, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= limit { break }
        }
        return out
    }

    /// `/album/{id}` for each id, concurrently, with the input order preserved —
    /// that order is the chart ranking, which is the whole relevance signal.
    private func albumDetails(ids: [Int]) async -> [DeezerAlbumDetail] {
        guard !ids.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, DeezerAlbumDetail?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    guard let url = URL(string: "https://api.deezer.com/album/\(id)") else {
                        return (index, nil)
                    }
                    return (index, await Self.getJSON(url))
                }
            }
            var slots = [DeezerAlbumDetail?](repeating: nil, count: ids.count)
            for await (index, detail) in group { slots[index] = detail }
            return slots.compactMap { $0 }
        }
    }

    /// Deezer's "yyyy-MM-dd". Parsed in UTC so the same string doesn't land on
    /// two different days either side of midnight.
    private static func deezerDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        var components = DateComponents()
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1900 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: components)
    }

    /// Deezer's editorial album chart. Only reached when the track chart is
    /// unreachable — see `newReleases` for why it can't be trusted on its own.
    public func chartAlbums(limit: Int = 15) async -> [OnlineAlbum] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/albums?limit=\(limit)"),
              let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }
        return resp.data.map {
            OnlineAlbum(id: $0.id, title: $0.title, artistName: $0.artist?.name ?? "",
                        coverURL: ($0.cover_xl ?? $0.cover_big).flatMap(URL.init(string:)))
        }
    }

    /// Music genres for the "Browse all" grid (Deezer). Drops the catch-all
    /// "All" pseudo-genre (id 0) so every tile opens a real genre.
    public func genres() async -> [BrowseGenre] {
        guard let url = URL(string: "https://api.deezer.com/genre"),
              let resp: DeezerGenreResponse = await Self.getJSON(url) else { return [] }
        return resp.data
            .filter { $0.id != 0 }
            .map { BrowseGenre(id: $0.id, name: $0.name,
                               pictureURL: ($0.picture_xl ?? $0.picture_medium).flatMap(URL.init(string:))) }
    }

    /// The most popular artists within a genre (the genre tile's detail page).
    ///
    /// Deezer's artist-scoped endpoints (`/chart/{id}/artists` AND
    /// `/genre/{id}/artists`) both ignore the genre id and return the same global
    /// editorial selection, so every tile looked identical. The genre's *track*
    /// chart (`/chart/{id}/tracks`), however, is genuinely genre-specific — so we
    /// derive the artist list from the unique artists behind that genre's trending
    /// tracks (in chart order), exactly like `chartArtists` does globally. Falls
    /// back to genre albums, then the global artist chart, if a genre has no tracks.
    public func genreArtists(genreId: Int, limit: Int = 30) async -> [OnlineArtist] {
        // Pull a deep slice of the genre's track chart for enough distinct artists.
        if let url = URL(string: "https://api.deezer.com/chart/\(genreId)/tracks?limit=100"),
           let resp: DeezerTrackSearchResponse = await Self.getJSON(url) {
            var seen = Set<Int>()
            var artists: [OnlineArtist] = []
            for t in resp.data {
                guard let a = t.artist, let id = a.id, seen.insert(id).inserted else { continue }
                artists.append(OnlineArtist(id: id, name: a.name,
                                            imageURL: Self.artistPicture(a.picture_xl, a.picture_big)))
                if artists.count >= limit { break }
            }
            if !artists.isEmpty { return await withSpotifyImages(artists) }
        }
        // Fallback 1: derive from the genre's album chart (also genre-specific).
        if let url = URL(string: "https://api.deezer.com/chart/\(genreId)/albums?limit=100"),
           let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) {
            var seen = Set<Int>()
            var artists: [OnlineArtist] = []
            for al in resp.data {
                guard let a = al.artist, let id = a.id, seen.insert(id).inserted else { continue }
                artists.append(OnlineArtist(id: id, name: a.name, imageURL: nil))
                if artists.count >= limit { break }
            }
            if !artists.isEmpty { return await withSpotifyImages(artists) }
        }
        // Fallback 2: Deezer's global artist chart (better than an empty page).
        guard let url = URL(string: "https://api.deezer.com/chart/\(genreId)/artists?limit=\(limit)"),
              let resp: DeezerChartArtistsResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map {
            OnlineArtist(id: $0.id, name: $0.name,
                         imageURL: Self.artistPicture($0.picture_xl, $0.picture_medium))
        }
        return await withSpotifyImages(artists)
    }

    // MARK: - Lyric search (NetEase → Deezer resolve)

    /// Search by *lyric*: NetEase's lyric-search (type 1006) finds songs whose
    /// words contain the query, then each hit is resolved to a playable Deezer
    /// track (artwork, sourceID) via the normal popularity search. Returns up to
    /// `limit` resolved tracks in relevance order; empty on any miss or for very
    /// short queries (a word or two is a title search, not a lyric).
    public func searchByLyrics(_ query: String, limit: Int = 8) async -> [OnlineTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 else { return [] }

        guard var comps = URLComponents(string: "https://music.163.com/api/search/get") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "type",  value: "1006"),     // 1006 = lyric search
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "s",     value: trimmed)
        ]
        guard let url = comps.url,
              let decoded: NetEaseLyricSearchResponse = await Self.getNetEaseJSON(url),
              let songs = decoded.result?.songs, !songs.isEmpty else { return [] }

        // Resolve each NetEase hit to a playable Deezer track (concurrently),
        // preserving relevance order.
        let hits = Array(songs.prefix(limit))
        let resolved: [OnlineTrack?] = await withTaskGroup(of: (Int, OnlineTrack?).self) { group in
            for (i, song) in hits.enumerated() {
                let title  = song.name ?? ""
                let artist = song.artists?.first?.name ?? ""
                group.addTask { (i, await self.resolveOnlineTrack(title: title, artist: artist)) }
            }
            var slots = [OnlineTrack?](repeating: nil, count: hits.count)
            for await (i, t) in group { slots[i] = t }
            return slots
        }
        // Drop misses and dedup by title|artist.
        var seen = Set<String>()
        return resolved.compactMap { $0 }.filter {
            seen.insert("\($0.title.lowercased())|\($0.artistName.lowercased())").inserted
        }
    }

    /// Resolve a (title, artist) pair to a playable Deezer OnlineTrack via search.
    private func resolveOnlineTrack(title: String, artist: String) async -> OnlineTrack? {
        guard !title.isEmpty else { return nil }
        let q = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard let r = await searchPopular(query: q, limit: 1).first else { return nil }
        return OnlineTrack(
            title: r.trackName,
            artistName: r.artistName,
            albumTitle: r.collectionName ?? "",
            duration: r.trackTimeMillis.map { TimeInterval($0) / 1000 } ?? 0,
            artworkURL: r.artworkUrl100.flatMap { URL(string: $0) },
            sourceID: r.sourceID,
            isExplicit: r.isExplicit
        )
    }

    private struct NetEaseLyricSearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                let name: String?
                let artists: [Artist]?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    /// NetEase needs a Referer + UA; the Deezer `getJSON` helper sends neither.
    private static func getNetEaseJSON<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[Lyrics] netease lyric search failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The contributors on a track — the main artist plus any featured artists,
    /// in Deezer's order. Used to render the artist row under a song hero.
    public func trackContributors(trackID: Int) async -> [OnlineArtist] {
        guard let url = URL(string: "https://api.deezer.com/track/\(trackID)"),
              let detail: DeezerTrackDetail = await Self.getJSON(url),
              let contributors = detail.contributors else { return [] }
        var seen = Set<Int>()
        let artists = contributors.compactMap { c -> OnlineArtist? in
            guard seen.insert(c.id).inserted else { return nil }
            return OnlineArtist(id: c.id, name: c.name,
                                imageURL: Self.artistPicture(c.picture_xl, c.picture_big))
        }
        return await withSpotifyImages(artists)
    }

    /// The credit and the cover Deezer keeps on the track record itself.
    ///
    /// A search row carries no contributors, and a row minted from the
    /// type-ahead dropdown carries nothing but what the dropdown showed — so a
    /// song played straight off a suggestion lost its guests ("UK Rap" became
    /// Dave alone) and had only one chance at a cover. One request, asked at
    /// the moment the song actually plays, not per row while typing.
    public static func trackDetail(trackID: Int) async -> (contributors: [String], coverURL: URL?) {
        guard let url = URL(string: "https://api.deezer.com/track/\(trackID)"),
              let detail: DeezerTrackDetail = await getJSON(url) else { return ([], nil) }
        return (detail.contributors?.map(\.name) ?? [],
                (detail.album?.cover_xl ?? detail.album?.cover_big).flatMap(URL.init(string:)))
    }

    /// Resolve the artist to open when a song's artist name is tapped. Prefers an
    /// exact contributor match (so tapping a featured artist opens *them*), then
    /// the track's main artist, then a name search — returning whichever resolves
    /// to a real Deezer artist id first.
    public func resolveArtist(name: String, trackID: Int?) async -> OnlineArtist? {
        if let trackID {
            let contributors = await trackContributors(trackID: trackID)
            if let match = contributors.first(where: { namesMatch($0.name, name) }) { return match }
            if let main = contributors.first { return main }
        }
        guard let hit = await searchArtists(query: name, limit: 1).first else { return nil }
        // Deezer's own answer for this spelling, written down so the rest of the
        // app can tell that a library credited "Digga" means this page — see
        // `ArtistAliases`. Deliberately not recorded on the `contributors.first`
        // line above: that one is an admitted miss ("we couldn't find that guest,
        // here's the main act"), and filing it would credit the guest's songs to
        // somebody else.
        ArtistAliases.record(local: name, canonical: hit.name)
        return hit
    }

    /// Resolve the album/EP a track belongs to, so tapping a song title can open
    /// it. Uses the Deezer track detail (carries its album) when we have the
    /// track id, falling back to an album search by "title artist".
    public func resolveAlbum(for track: OnlineTrack) async -> OnlineAlbum? {
        if let trackID = track.sourceID,
           let url = URL(string: "https://api.deezer.com/track/\(trackID)"),
           let detail: DeezerTrackDetail = await Self.getJSON(url),
           let album = detail.album {
            return OnlineAlbum(
                id: album.id,
                title: album.title,
                artistName: detail.artist?.name ?? track.artistName,
                coverURL: (album.cover_xl ?? album.cover_big).flatMap(URL.init(string:))
            )
        }
        // No track id (or detail missing the album) — search by album title.
        let query = "\(track.albumTitle) \(track.artistName)".trimmingCharacters(in: .whitespaces)
        guard !track.albumTitle.isEmpty else { return nil }
        let hits = await searchAlbums(query: query, limit: 5)
        // Title *and* artist first: "Discovery" is an album by Daft Punk and a
        // different one by Data Punk, and both come back for this query.
        return hits.first { namesMatch($0.title, track.albumTitle) && namesMatch($0.artistName, track.artistName) }
            ?? hits.first { namesMatch($0.title, track.albumTitle) }
            ?? hits.first
    }

    /// True when two names refer to the same thing loosely enough for UI wiring
    /// (equality or containment, after case/diacritic/punctuation folding). Used
    /// where over-matching is harmless — "does this song belong to that artist".
    /// The anchor decision needs the strict test, `DiscoverNameMatch.sameName`.
    private func namesMatch(_ name: String, _ query: String) -> Bool {
        let a = DiscoverNameMatch.normalize(name)
        let b = DiscoverNameMatch.normalize(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Meaningful lowercased word tokens of `text` (drops 1-char filler so "the",
    /// punctuation, and stray letters don't create spurious matches).
    private func tokens(_ text: String) -> Set<String> {
        Set(DiscoverNameMatch.normalize(text)
            .components(separatedBy: " ")
            .filter { $0.count >= 2 })
    }

    /// Keep only songs that are plausibly about `query`, dropping the same-name
    /// noise Deezer's broad full-text search mixes in (e.g. an unrelated artist
    /// whose album title happens to contain the query word). A song qualifies when
    /// its artist name closely matches the query, OR its title/artist together
    /// cover every meaningful query token.
    ///
    /// `matched` is false when nothing genuinely matched and the raw list is being
    /// returned as a last resort — the caller uses that to avoid anchoring the whole
    /// page (albums, "fans also like") on an artist the query never really named.
    private func relevantSongs(_ songs: [OnlineTrack],
                               matching query: String) -> (songs: [OnlineTrack], matched: Bool) {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return (songs, !songs.isEmpty) }
        let filtered = songs.filter { song in
            if namesMatch(song.artistName, query) { return true }
            let haystack = tokens("\(song.title) \(song.artistName)")
            return queryTokens.isSubset(of: haystack)
        }
        // Never let the filter empty the list — fall back to the raw results so a
        // genuinely odd query still shows something.
        return filtered.isEmpty ? (songs, false) : (filtered, true)
    }

    /// Artists matching `query`, ranked by name match blended with Deezer popularity.
    ///
    /// Deezer's own ordering is NOT popularity-ranked: `search/artist?q=drake`
    /// returns two 40-fan namesakes *before* the real Drake (24M fans). Because
    /// `withSpotifyImages` resolves photos by name, those impostors rendered with
    /// the real artist's face and then opened an empty page with someone else's
    /// albums. So over-fetch, rank ourselves, and collapse same-name duplicates.
    public func searchArtists(query: String, limit: Int = 12) async -> [OnlineArtist] {
        let ranked = Self.rank(await fetchArtistCandidates(query: query, limit: max(limit, 25)), for: query)
        return await withSpotifyImages(ranked.prefix(limit).map(\.artist))
    }

    /// One `search/artist` hit with the signals ranking needs. `OnlineArtist` can't
    /// carry them (it's the view model), and the anchor decision in `discoverSearch`
    /// needs the fan count and the match tier, not just the winner.
    private struct ArtistCandidate: Sendable {
        let id: Int
        let name: String
        let fans: Int
        let picture: URL?
        var tier: Int = DiscoverNameMatch.none
        var score: Double = 0

        var artist: OnlineArtist { OnlineArtist(id: id, name: name, imageURL: picture) }
    }

    private func fetchArtistCandidates(query: String, limit: Int) async -> [ArtistCandidate] {
        // Always pull a deep slice: `limit: 1` callers (resolveArtist, radioTracks)
        // would otherwise get whichever namesake Deezer happened to list first.
        guard let url = Self.deezerURL("search/artist", query: query, limit: max(limit, 25)),
              let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        return resp.data.map {
            ArtistCandidate(id: $0.id, name: $0.name, fans: $0.nb_fan ?? 0,
                            picture: Self.artistPicture($0.picture_xl, $0.picture_big))
        }
    }

    /// Score, sort and de-duplicate artist candidates.
    ///
    /// `corroboratingArtists` are the artist names behind the *songs* the same query
    /// matched, best first. An artist who actually owns those songs is far more
    /// likely to be the one meant — that's what separates THIZZY52 (7k fans, owns
    /// every matching track) from the 87-fan "Thizzy" whose name matches exactly.
    private static func rank(_ candidates: [ArtistCandidate], for query: String,
                             corroboratingArtists: [String] = []) -> [ArtistCandidate] {
        let scored = candidates.map { candidate -> ArtistCandidate in
            var scored = candidate
            scored.tier = DiscoverNameMatch.tier(name: candidate.name, query: query)
            let bonus = scored.tier > DiscoverNameMatch.none
                ? corroboration(for: candidate.name, among: corroboratingArtists)
                : 0
            scored.score = DiscoverNameMatch.score(name: candidate.name, fans: candidate.fans,
                                                   query: query, corroboration: bonus)
            return scored
        }
        // One row per name — a second "Drake" is a junk upload, not a choice the
        // user wants to make. Ranking guarantees the survivor is the real one.
        var seenNames = Set<String>()
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fans > $1.fans }
            .filter { seenNames.insert(DiscoverNameMatch.normalize($0.name)).inserted }
    }

    /// Bonus for owning one of the songs the query matched, tapering with position
    /// so a hit at the top of the song list counts for much more than one at the end.
    private static func corroboration(for name: String, among artists: [String]) -> Double {
        guard let index = artists.prefix(10).firstIndex(where: { DiscoverNameMatch.sameName($0, name) })
        else { return 0 }
        return 300 * (1 - Double(index) / 12)
    }

    /// Albums matching `query`.
    ///
    /// Over-fetched and collapsed the same way `artistAlbums` is: the album
    /// search returns the explicit pressing, the clean pressing and every
    /// edition as separate rows, and three tiles of one record is not a result
    /// set. `record_type` and `nb_tracks` come back here even though
    /// `release_date` does not, so the card can still say what it is.
    public func searchAlbums(query: String, limit: Int = 12) async -> [OnlineAlbum] {
        guard let url = Self.deezerURL("search/album", query: query, limit: max(limit, 30)) else { return [] }
        guard let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }
        let rows = resp.data.map {
            OnlineAlbum(id: $0.id, title: $0.title, artistName: $0.artist?.name ?? "",
                        coverURL: ($0.cover_xl ?? $0.cover_big).flatMap(URL.init(string:)),
                        releaseDate: Self.deezerDate($0.release_date),
                        recordType: $0.record_type,
                        trackCount: $0.nb_tracks)
        }
        // Relevance order is kept — this is a search, not a catalogue, so the
        // best title match must stay first.
        return Array(Self.oneTilePerRecord(rows).prefix(limit))
    }

    /// An artist's most popular tracks (the "Popular" list in the artist view).
    /// An artist's most-played songs. Fifty rather than Deezer's default ten:
    /// the page shows five and offers "Show more", and a "more" that added five
    /// was barely worth the click.
    public func artistTopTracks(artistId: Int, limit: Int = 10) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/top?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        // Prefer the explicit version when a song appears as both explicit + clean.
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                        contributors: t.contributors?.map(\.name) ?? [])
        }
    }

    /// A "radio" of tracks similar to `artist` — Deezer's artist-radio flow,
    /// which stays within the artist's genre/scene (won't jump rap → classical).
    /// Resolves the artist name to a Deezer id first, then fetches the radio.
    /// Used to seed auto-suggestions in the play queue.
    public func radioTracks(forArtist artist: String, limit: Int = 20) async -> [OnlineTrack] {
        guard let artistID = await searchArtists(query: artist, limit: 1).first?.id else { return [] }
        return await radioTracks(artistId: artistID, limit: limit)
    }

    /// The same radio, for callers that already hold the Deezer artist id — the
    /// recommendation build resolves each seed artist once and then fans out, so
    /// it would otherwise pay for the same name search three times over.
    public func radioTracks(artistId: Int, limit: Int = 20) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/radio?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                        contributors: t.contributors?.map(\.name) ?? [])
        }
    }

    /// The seed artist's radio, widened with the radios of artists Deezer says
    /// fans also like.
    ///
    /// One artist's radio comes back short — and shorter still once the songs
    /// already queued are filtered out — which is why a "recommended" run could
    /// end after three songs. Fanning out over related artists is what makes a
    /// 20-40 song run possible without leaving the seed's corner of the map.
    public func deepRadioTracks(forArtist artist: String, limit: Int) async -> [OnlineTrack] {
        guard let artistID = await searchArtists(query: artist, limit: 1).first?.id else { return [] }
        var out  = await radioTracks(artistId: artistID, limit: limit)
        guard out.count < limit else { return out }
        var seen = Set(out.map { "\($0.title.lowercased())|\($0.artistName.lowercased())" })
        for related in await relatedArtists(artistId: artistID, limit: 6) {
            guard out.count < limit else { break }
            for track in await radioTracks(artistId: related.id, limit: 25)
            where seen.insert("\(track.title.lowercased())|\(track.artistName.lowercased())").inserted {
                out.append(track)
            }
        }
        return out
    }

    /// Artists similar to `artistId` (Deezer "related" — fans also like).
    public func relatedArtists(artistId: Int, limit: Int = 12) async -> [OnlineArtist] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/related?limit=\(limit)"),
              let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map {
            OnlineArtist(id: $0.id, name: $0.name,
                         imageURL: Self.artistPicture($0.picture_xl, $0.picture_big))
        }
        return await withSpotifyImages(artists)
    }

    /// An artist's albums, newest first (the artist view's album grid).
    ///
    /// Unlike the chart and search listings, this endpoint does carry
    /// `release_date` and `record_type` per item, so the results are datable and
    /// labellable without a second round trip — which is what lets "New release
    /// from" prove something actually came out recently instead of guessing.
    /// `artistName` fills in the credit: this endpoint omits the artist object,
    /// since every row is theirs, and an album with no name reads "Album • ".
    public func artistAlbums(artistId: Int, artistName: String, limit: Int = 40) async -> [OnlineAlbum] {
        // Always fetch a deep slice, whatever the caller wants to show.
        //
        // Deezer returns this endpoint newest-first, so asking for twelve rows
        // asked for "the last twelve things released" — which for a working
        // artist is twelve singles, and the albums the section is named for
        // never arrive at all. Over-fetch, group, then cut.
        let depth = max(limit, 60)
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/albums?limit=\(depth)"),
              let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }

        let rows = resp.data.map { a in
            OnlineAlbum(id: a.id, title: a.title, artistName: a.artist?.name ?? artistName,
                        coverURL: (a.cover_xl ?? a.cover_big).flatMap(URL.init(string:)),
                        releaseDate: Self.deezerDate(a.release_date),
                        recordType: a.record_type,
                        trackCount: a.nb_tracks)
        }
        return Array(Self.oneTilePerRecord(rows).sorted(by: Self.catalogueOrder).prefix(limit))
    }

    /// Collapse a raw Deezer album listing down to one tile per actual record.
    ///
    /// The old test was `title.lowercased()` — exact string equality — which
    /// only ever caught a byte-identical repeat. Everything else Deezer lists
    /// the same record as survived it: the explicit and clean pressings, the
    /// regional duplicates, and above all the editions. Drake's page rendered
    /// "For All The Dogs Scary Hours Edition" twice and "For All The Dogs"
    /// beside it, two of the three truncating to the same label on the card.
    ///
    /// Two passes, because the duplicates come in two shapes:
    ///
    /// 1. Same work, spelled differently. `DiscoverNameMatch.normalize` folds
    ///    case, diacritics and punctuation, and the edition tail is trimmed off
    ///    the end, so "Nothing Was the Same (Deluxe)" and "Nothing Was The Same"
    ///    land on one key.
    /// 2. An edition listed under a *longer* title, where the base record is
    ///    also present. Collapsed only when the extra words actually name an
    ///    edition — so "For All The Dogs" absorbs its "Scary Hours Edition",
    ///    while "Care Package" and "Care Package 2" stay two records, which
    ///    they are.
    ///
    /// The survivor of a group is the one with the most tracks: if the app is
    /// going to show one tile for a record, it should be the complete one.
    private static func oneTilePerRecord(_ albums: [OnlineAlbum]) -> [OnlineAlbum] {
        var order: [String] = []
        var best: [String: OnlineAlbum] = [:]

        func keep(_ key: String, _ album: OnlineAlbum) {
            guard let held = best[key] else {
                best[key] = album
                order.append(key)
                return
            }
            if (album.trackCount ?? 0) > (held.trackCount ?? 0) { best[key] = album }
        }

        for album in albums { keep(recordKey(album.artistName, albumWorkKey(album.title)), album) }

        // Pass 2 — fold an edition into the base record it extends. Shortest
        // keys first, so a base title is already present when its editions are
        // considered. The test runs against the album's *untrimmed* name: pass
        // one has already taken "edition" off the end of the key, and it is
        // that very word which proves "For All The Dogs Scary Hours Edition"
        // is a pressing of "For All The Dogs" rather than a second record.
        for key in order.sorted(by: { $0.count < $1.count }) {
            guard let album = best[key] else { continue }
            let raw = recordKey(album.artistName, DiscoverNameMatch.normalize(album.title))
            guard let base = order.first(where: { candidate in
                candidate != key
                    && best[candidate] != nil
                    && (isEditionOf(key, base: candidate) || isEditionOf(raw, base: candidate))
            }) else { continue }
            best[key] = nil
            keep(base, album)
        }
        return order.compactMap { best[$0] }
    }

    /// Words that mark an *edition* of a record rather than part of its name.
    /// Deliberately short: every entry here is a word that, standing at the end
    /// of an album title, is packaging. "Soundtrack", "Mixtape" and "Sessions"
    /// are not on the list, because those name records.
    private static let albumEditionWords: Set<String> = [
        "deluxe", "edition", "editions", "version", "remaster", "remastered",
        "anniversary", "expanded", "extended", "explicit", "clean", "bonus",
        "reissue", "collectors", "collector", "platinum", "repack", "redux"
    ]

    /// A record is a title *and* the artist who made it. Grouping on the title
    /// alone folded two different records together: an album search for
    /// "Discovery Daft Punk" returns Daft Punk's Discovery *and* Data Punk's,
    /// and the one with more tracks won the tile.
    ///
    /// "|" cannot survive `DiscoverNameMatch.normalize`, so the two halves
    /// never bleed into one another and `isEditionOf`'s prefix test can only
    /// ever match editions by the same artist.
    private static func recordKey(_ artistName: String, _ titleKey: String) -> String {
        "\(DiscoverNameMatch.normalize(artistName))|\(titleKey)"
    }

    /// The record a title names, with its edition packaging trimmed off.
    private static func albumWorkKey(_ title: String) -> String {
        var tokens = DiscoverNameMatch.normalize(title).split(separator: " ").map(String.init)
        // Trim from the end while the tail is packaging: "… deluxe edition",
        // "… remastered 2011" (a bare year only counts behind an edition word,
        // so "1989" and "2014 Forest Hills Drive" keep their names).
        while let last = tokens.last {
            if albumEditionWords.contains(last) {
                tokens.removeLast()
            } else if last.count == 4, Int(last) != nil, tokens.count > 1,
                      albumEditionWords.contains(tokens[tokens.count - 2]) {
                tokens.removeLast()
            } else {
                break
            }
        }
        let trimmed = tokens.joined(separator: " ")
        // Never trim a title away entirely — a record actually called "Deluxe"
        // would otherwise key on the empty string and swallow the catalogue.
        return trimmed.isEmpty ? DiscoverNameMatch.normalize(title) : trimmed
    }

    /// Is `key` the same record as `base`, with edition words on the end?
    /// The extra must begin at a word boundary and must itself name an edition;
    /// a longer title that simply continues ("Care Package 2") is its own record.
    private static func isEditionOf(_ key: String, base: String) -> Bool {
        guard !base.isEmpty, key.count > base.count, key.hasPrefix(base) else { return false }
        let tail = key.dropFirst(base.count)
        guard tail.hasPrefix(" ") else { return false }
        return tail.split(separator: " ").contains { albumEditionWords.contains(String($0)) }
    }

    /// How a catalogue reads: albums, then EPs, then compilations, then
    /// singles — newest first inside each group.
    ///
    /// Sorting on date alone is what put HABIBTI, MAID OF HONOUR and ICEMAN at
    /// the head of Drake's "Albums" row: they are the most recent releases, and
    /// they are all singles. A row headed "Albums" is answering "what has this
    /// artist made", and last week's single is not that answer.
    private static func catalogueOrder(_ a: OnlineAlbum, _ b: OnlineAlbum) -> Bool {
        let ra = recordRank(a.recordType), rb = recordRank(b.recordType)
        if ra != rb { return ra < rb }
        switch (a.releaseDate, b.releaseDate) {
        case let (x?, y?): return x > y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return false
        }
    }

    private static func recordRank(_ recordType: String?) -> Int {
        switch recordType {
        case "album":   return 0
        case "ep":      return 1
        case "compile": return 2
        case "single":  return 3
        default:        return 1   // unlabelled sits with the EPs, not the singles
        }
    }

    /// Everything the artist page shows, fetched together — with a self-healing
    /// retry. Artist ids arrive here from several sources (search, track
    /// contributors, charts), and a wrong one yields a page with no songs AND no
    /// albums. When that happens, re-resolve the *name* through the ranked artist
    /// search once and retry, so the page recovers instead of rendering empty.
    public func artistCatalogue(for artist: OnlineArtist) async -> OnlineArtistCatalogue {
        let first = await fetchArtistCatalogue(artistId: artist.id, name: artist.name)
        guard first.top.isEmpty, first.albums.isEmpty else { return first }
        guard let better = await searchArtists(query: artist.name, limit: 1).first,
              better.id != artist.id else { return first }
        return await fetchArtistCatalogue(artistId: better.id, name: better.name)
    }

    private func fetchArtistCatalogue(artistId: Int, name: String) async -> OnlineArtistCatalogue {
        async let topCall   = artistTopTracks(artistId: artistId)
        async let albCall   = artistAlbums(artistId: artistId, artistName: name)
        async let relCall   = relatedArtists(artistId: artistId)
        async let fansCall  = artistFanCount(artistId: artistId)
        async let widerCall = artistCredits(name: name)
        async let radioCall = radioTracks(artistId: artistId, limit: 50)

        var catalogue = OnlineArtistCatalogue()
        catalogue.albums   = await albCall
        catalogue.related  = await relCall
        catalogue.fanCount = await fansCall
        catalogue.radio    = await radioCall

        // `/artist/{id}/top` is thin for anyone who isn't a household name —
        // it returned three songs for an artist with twenty-two on Deezer, so
        // "Popular" looked broken. The credit search fills the rest in by
        // Deezer's own popularity rank, and hands us "Appears On" for free:
        // the same results under someone else's artist id.
        let top   = await topCall
        let wider = await widerCall
        var seen  = Set(top.map { $0.title.lowercased() })
        catalogue.top = top + wider
            .filter { $0.artistID == artistId }
            .sorted { $0.rank > $1.rank }
            .compactMap { seen.insert($0.track.title.lowercased()).inserted ? $0.track : nil }

        var seenGuest = Set<String>()
        catalogue.appearsOn = wider
            .filter { $0.artistID != artistId }
            .sorted { $0.rank > $1.rank }
            .compactMap { seenGuest.insert($0.track.id).inserted ? $0.track : nil }

        return catalogue
    }

    /// Deezer's fan count for the artist header. Nil rather than 0 on failure —
    /// see `OnlineArtistCatalogue.fanCount`.
    private func artistFanCount(artistId: Int) async -> Int? {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)"),
              let artist: DeezerArtist = await Self.getJSON(url) else { return nil }
        return artist.nb_fan
    }

    /// Every track Deezer credits to a name, keeping whose release it is.
    ///
    /// `artist:"…"` is the exact-ish field search, so this doesn't drag in
    /// songs that merely mention the name in a title.
    private func artistCredits(name: String) async -> [(track: OnlineTrack, artistID: Int, rank: Int)] {
        let quoted = "artist:\"\(name)\""
        guard let escaped = quoted.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(escaped)&order=RANKING&limit=50"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data).compactMap { t in
            guard let artistID = t.artist?.id else { return nil }
            let track = OnlineTrack(
                title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                duration: TimeInterval(t.duration ?? 0),
                artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                contributors: t.contributors?.map(\.name) ?? [])
            return (track, artistID, t.rank ?? 0)
        }
    }

    /// The track listing for an album (used when an album is opened).
    /// Fill in the guest credits a listing didn't carry.
    ///
    /// `/album/{id}/tracks` returns no `contributors`, and Deezer doesn't put
    /// the guests in the title either — so an album row has nothing to print a
    /// full credit from until each track is asked about individually. One
    /// request per track, six at a time, and only for tracks that arrived
    /// without contributors; an album is a couple of dozen rows at most and this
    /// runs once, when it's opened. Best-effort: a track that fails to enrich
    /// keeps the single credited artist it already had.
    private func withContributors(_ tracks: [OnlineTrack], limit: Int = .max) async -> [OnlineTrack] {
        let needy = tracks.enumerated()
            .filter { $0.element.contributors.isEmpty && $0.element.sourceID != nil }
            .prefix(limit)
        guard !needy.isEmpty else { return tracks }

        var filled: [Int: [String]] = [:]
        let queue = Array(needy)
        for chunk in stride(from: 0, to: queue.count, by: 6).map({
            Array(queue[$0..<min($0 + 6, queue.count)])
        }) {
            await withTaskGroup(of: (Int, [String]).self) { group in
                for (index, track) in chunk {
                    group.addTask {
                        (index, await Self.contributorNames(trackID: track.sourceID!))
                    }
                }
                for await (index, names) in group where names.count > 1 { filled[index] = names }
            }
        }
        guard !filled.isEmpty else { return tracks }

        return tracks.enumerated().map { index, track in
            guard let names = filled[index] else { return track }
            return OnlineTrack(title: track.title, artistName: track.artistName,
                               albumTitle: track.albumTitle, duration: track.duration,
                               artworkURL: track.artworkURL, sourceID: track.sourceID,
                               isExplicit: track.isExplicit, contributors: names)
        }
    }

    private static func contributorNames(trackID: Int) async -> [String] {
        guard let url = URL(string: "https://api.deezer.com/track/\(trackID)"),
              let detail: DeezerTrackDetail = await getJSON(url) else { return [] }
        return detail.contributors?.map(\.name) ?? []
    }

    public func albumTracks(album: OnlineAlbum) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/album/\(album.id)/tracks?limit=100"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        // Usually one version per track, but if a title appears twice (explicit +
        // clean), prefer the explicit one.
        let rows = Self.preferringExplicit(resp.data).map { t in
            // Album-track records carry no per-track cover; reuse the album cover.
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? album.artistName, albumTitle: album.title,
                        duration: TimeInterval(t.duration ?? 0), artworkURL: album.coverURL,
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                        contributors: t.contributors?.map(\.name) ?? [])
        }
        return await withContributors(rows)
    }

    // MARK: - Deezer request helpers

    /// Dedup Deezer tracks by `title|artist`, ALWAYS preferring the explicit
    /// version over a clean (non-explicit) one. When the same song appears as
    /// both explicit and clean, the explicit version wins; the clean version is
    /// kept only when no explicit version exists.
    ///
    /// The incoming order is preserved as the tie-breaker within a group (callers
    /// pre-sort by rank desc), so we keep the highest-ranked explicit track, or —
    /// if none is explicit — the highest-ranked clean track. A clean version can
    /// never replace an explicit one already kept for that key.
    private static func preferringExplicit(_ tracks: [DeezerTrack]) -> [DeezerTrack] {
        var order: [String] = []                 // first-seen order of keys
        var best: [String: DeezerTrack] = [:]    // best track kept per key
        for t in tracks {
            let key = "\(t.title.lowercased())|\((t.artist?.name ?? "").lowercased())"
            guard let kept = best[key] else {
                best[key] = t
                order.append(key)
                continue
            }
            // Replace only when the incumbent is clean and this one is explicit.
            if kept.explicit_lyrics != true && t.explicit_lyrics == true {
                best[key] = t
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func deezerURL(_ path: String, query: String, limit: Int) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://api.deezer.com/\(path)?q=\(encoded)&limit=\(limit)")
    }

    /// How many times a throttled request is asked again before it gives up. The
    /// quota window is five seconds wide, and the backoff below covers it.
    private static let deezerMaxRetries = 3

    private static func getJSON<T: Decodable>(_ url: URL, attempt: Int = 0) async -> T? {
        // Cached and coalesced: an identical URL asked for twice inside a minute
        // — which is exactly what typing produces — costs neither a gate slot
        // nor a round trip the second time.
        guard let data = await DeezerResponseCache.shared.body(for: url, fetch: {
            await RequestGate.deezer.waitForSlot()
            do {
                let (body, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return body
            } catch {
                print("[Deezer] request failed \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }) else { return nil }

        if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }

        // Not the shape we asked for. Deezer reports its own failures at HTTP 200,
        // so read the body again as an error before calling this malformed JSON.
        guard let envelope = try? JSONDecoder().decode(DeezerErrorEnvelope.self, from: data) else {
            print("[Deezer] unreadable response from \(url.lastPathComponent)")
            return nil
        }

        guard envelope.isTransient, attempt < deezerMaxRetries else {
            print("[Deezer] \(url.lastPathComponent): \(envelope.describedError)")
            return nil
        }

        // A throttle notice is not an answer, so it must not be remembered as
        // one — otherwise the retry reads the refusal back out of the cache and
        // every attempt after the first is free and useless.
        await DeezerResponseCache.shared.forget(url)

        // Backoff with jitter: the whole burst is throttled at once, so retrying
        // it in lockstep would just rebuild the burst that caused this.
        let backoff = pow(2.0, Double(attempt)) * 0.7 + Double.random(in: 0...0.3)
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        return await getJSON(url, attempt: attempt + 1)
    }

    // MARK: - Artwork helper

    /// Transforms Apple's 100×100 artwork URL to a higher resolution.
    public func artworkURL(from url100: String, size: Int = 600) -> URL? {
        URL(string: url100.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb"))
    }

    // MARK: - Artist image

    /// Resolves the artist profile photo URL: Spotify first (fresher, and it now
    /// verifies the name before handing an image back), then Deezer's own photo for
    /// an artist genuinely called that. Returns nil when neither can confirm the
    /// name, so callers fall back to the built-in placeholder rather than showing
    /// a stranger's face.
    public func artistImageURL(for artistName: String) async -> URL? {
        if let spotify = await spotifyClient?.artistImageURL(for: artistName) { return spotify }
        let ranked = Self.rank(await fetchArtistCandidates(query: artistName, limit: 10), for: artistName)
        guard let best = ranked.first, DiscoverNameMatch.sameName(best.name, artistName) else { return nil }
        return best.picture
    }

    // MARK: - Private: title-only search

    /// Full-text song search across all storefronts, results merged.
    private func searchByTitle(_ title: String) async throws -> [ITunesTrackResult]? {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        var all: [ITunesTrackResult] = []
        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            for country in ["us", "gb", "au", "ca"] {
                guard let url = URL(string: "\(Self.searchURL)?term=\(encoded)&media=music&entity=song&limit=25&country=\(country)")
                else { continue }
                group.addTask {
                    guard let results = try? await self.fetchSearchResults(from: url)
                    else { return [] }
                    return results
                }
            }
            for try await results in group { all.append(contentsOf: results) }
        }

        let unique = deduplicated(all)
        print("[iTunes] title='\(title)' → \(unique.count) songs (text search)")
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private: artist-catalogue lookup

    /// Find artist ID then fetch their full song catalogue via Lookup API.
    /// This is the most reliable method — avoids the noise of general text search.
    private func searchByArtistCatalogue(_ artist: String) async throws -> [ITunesTrackResult]? {
        guard let artistId = try await findArtistId(artist) else {
            print("[iTunes] No artist ID found for '\(artist)'")
            return nil
        }
        print("[iTunes] Artist '\(artist)' → ID \(artistId)")
        return try await lookupSongs(artistId: artistId)
    }

    /// Search iTunes for an artist by name and return the best-matching artistId.
    /// GB is preferred (better catalogue for non-US artists), then US, AU, CA.
    ///
    /// All four are asked at once and the winner is picked by preference rank
    /// afterwards. Asking them in turn gave the same answer, but an artist the
    /// GB store doesn't carry cost up to four serial round-trips *before* the
    /// catalogue lookup could even begin — and this sits on the path to the
    /// import review sheet, where every one of those was visible as waiting.
    private func findArtistId(_ artist: String) async throws -> Int? {
        guard let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        let storefronts = ["gb", "us", "au", "ca"]
        var best: (rank: Int, id: Int, name: String, country: String)?

        await withTaskGroup(of: (Int, Int, String, String)?.self) { group in
            for (rank, country) in storefronts.enumerated() {
                guard let url = URL(string: "\(Self.searchURL)?term=\(encoded)&entity=musicArtist&limit=5&country=\(country)")
                else { continue }
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let decoded = try? JSONDecoder().decode(ArtistSearchResponse.self, from: data),
                          let first = decoded.results.first
                    else { return nil }
                    return (rank, first.artistId, first.artistName, country)
                }
            }
            for await hit in group {
                guard let hit else { continue }
                if best == nil || hit.0 < best!.rank {
                    best = (hit.0, hit.1, hit.2, hit.3)
                }
            }
        }

        guard let best else { return nil }
        print("[iTunes] Found artist '\(best.name)' id=\(best.id) in \(best.country) store")
        return best.id
    }

    /// Fetch all songs for a given artistId via the Lookup API.
    /// Returns up to 200 songs; tries GB first for regional availability.
    private func lookupSongs(artistId: Int) async throws -> [ITunesTrackResult]? {
        var all: [ITunesTrackResult] = []

        try await withThrowingTaskGroup(of: [ITunesTrackResult].self) { group in
            for country in ["gb", "us", "au", "ca"] {
                guard let url = URL(string: "\(Self.lookupURL)?id=\(artistId)&entity=song&limit=200&country=\(country)")
                else { continue }
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                    guard let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data)
                    else { return [] }
                    return decoded.results.compactMap { trackResult(from: $0) }
                }
            }
            for try await results in group { all.append(contentsOf: results) }
        }

        let unique = deduplicated(all)
        print("[iTunes] Lookup artistId=\(artistId) → \(unique.count) songs across storefronts")
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private helpers

    private func fetchSearchResults(from url: URL) async throws -> [ITunesTrackResult] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(SearchResponse.self, from: data))?.results ?? []
    }

    private func deduplicated(_ results: [ITunesTrackResult]) -> [ITunesTrackResult] {
        var seen = Set<String>()
        return results.filter { r in
            let key = "\(r.trackName.lowercased())|\(r.artistName.lowercased())"
            return seen.insert(key).inserted
        }
    }
}

// MARK: - Name matching

/// How well a catalogue name answers a typed query, as a score we can add real
/// popularity to.
///
/// Tiers are spaced so that a *hugely* popular partial match outranks a
/// microscopic exact one, while an exact match with any real audience still wins
/// outright. That balance is the whole point: ranking on match quality alone made
/// "dra" resolve to a 71-fan Deezer artist literally named "DRA" instead of Drake
/// (24M fans), and every album/song/related row on the page then belonged to DRA.
/// Ranking on popularity alone would do the opposite and bury genuinely small
/// artists (c4rl, THIZZY52) under whoever is famous.
///
/// The constants were tuned against live `search/artist` payloads for dra / drak /
/// drake / kanye / ye / the weeknd / wknd / tyler / travis / 21 / c4rl / thizzy,
/// so change them only with the same data in front of you.
/// Internal rather than file-private: `LibraryService` matches catalogue hits
/// against library tracks with the same rules, and a second, subtly different
/// copy of this logic living over there is how "the same song" starts meaning
/// two things in one app.
enum DiscoverNameMatch {

    // Match tiers, best first.
    static let exact             = 1000  // "drake" → Drake
    static let wordPrefix        = 800   // "kanye" → Kanye West, "21" → 21 Savage
    static let prefix            = 700   // "dra"   → Drake, "ye" → Yeat
    static let tokenSequence     = 650   // "tyler creat" → Tyler, The Creator
    static let consonantSkeleton = 620   // "wknd"  → The Weeknd
    static let tokenStart        = 560   // "dra"   → Imagine Dragons
    static let contains          = 300   // "drake" → Nick Drake
    static let fuzzy             = 150   // "utopia" → U-topia
    static let none              = 0

    /// A match at or above this tier is a plausible answer to the typed name;
    /// below it the hit is incidental (a word buried in a longer name).
    static let strong = consonantSkeleton

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Case/diacritic/punctuation-insensitive form used for every comparison, so
    /// "Beyoncé" == "beyonce" and "Tyler, The Creator" == "tyler the creator".
    /// Apostrophes and periods are *deleted* rather than spaced (so "D.R.A." and
    /// "god's plan" become "dra" and "gods plan"); every other separator becomes a
    /// single space.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        out.reserveCapacity(folded.count)
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" || ch == "." {
                continue
            } else if let last = out.last, last != " " {
                out.append(" ")
            }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// "The Weeknd" and "Weeknd" are the same artist to anyone typing a search box.
    static func withoutLeadingThe(_ normalized: String) -> String {
        normalized.hasPrefix("the ") ? String(normalized.dropFirst(4)) : normalized
    }

    /// Highest tier at which `name` answers `query`. Both raw and "the"-stripped
    /// forms are compared, so "the weeknd" ↔ "Weeknd" scores as an exact match.
    static func tier(name: String, query: String) -> Int {
        let n = normalize(name), q = normalize(query)
        guard !n.isEmpty, !q.isEmpty else { return none }
        let stripped = tier(normalizedName: withoutLeadingThe(n), normalizedQuery: withoutLeadingThe(q))
        return max(tier(normalizedName: n, normalizedQuery: q), stripped)
    }

    private static func tier(normalizedName n: String, normalizedQuery q: String) -> Int {
        guard !n.isEmpty, !q.isEmpty else { return none }
        if n == q { return exact }

        if n.hasPrefix(q) {
            // A prefix that lands on a word boundary ("Kanye| West") is a much
            // better answer than one that slices a word open ("Dra|keo").
            let next = n[n.index(n.startIndex, offsetBy: q.count)]
            return next == " " ? wordPrefix : prefix
        }

        let nameTokens  = n.split(separator: " ").map(String.init)
        let queryTokens = q.split(separator: " ").map(String.init)

        if queryTokens.count > 1, tokenSequenceMatches(queryTokens, nameTokens, from: 0) {
            return tokenSequence
        }
        // A vowel-less query is an abbreviation, not a name — only then is it safe
        // to compare consonant skeletons ("wknd" → "weeknd").
        if q.count >= 3, !q.contains(where: { vowels.contains($0) }),
           consonants(n) == consonants(q) {
            return consonantSkeleton
        }
        if nameTokens.dropFirst().contains(where: { $0.hasPrefix(q) }) { return tokenStart }
        if queryTokens.count > 1,
           (1..<max(nameTokens.count, 1)).contains(where: { tokenSequenceMatches(queryTokens, nameTokens, from: $0) }) {
            return tokenStart
        }
        if n.contains(q) { return contains }
        // Subsequence matching is only meaningful once the query is long enough to
        // be distinctive; on short queries it matches almost everything.
        if q.count >= 4, isSubsequence(q, of: n) { return fuzzy }
        return none
    }

    /// Every query token is a prefix of the corresponding name token, in order —
    /// "trav sco" → "Travis Scott".
    private static func tokenSequenceMatches(_ queryTokens: [String], _ nameTokens: [String], from start: Int) -> Bool {
        guard queryTokens.count <= nameTokens.count - start else { return false }
        for (offset, token) in queryTokens.enumerated()
        where !nameTokens[start + offset].hasPrefix(token) { return false }
        return true
    }

    private static func consonants(_ s: String) -> String {
        String(s.filter { $0 != " " && !vowels.contains($0) })
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let next = it.next() {
                if next == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Real-world popularity, compressed to the same scale as the tiers. Fans are
    /// log-scaled because the gap that matters is orders of magnitude (71 vs 24M),
    /// not raw difference, and capped so nothing outruns an exact match on fame alone.
    static func popularityBonus(fans: Int) -> Double {
        min(log10(Double(max(fans, 1))) * 110, 770)
    }

    /// Final ranking score: match quality + popularity, plus any corroboration the
    /// caller found (see `ITunesSearchClient.discoverSearch`). Names with no textual
    /// relation to the query keep only a fraction of their popularity, so Deezer's
    /// own loose matches (Carly Rae Jepsen for "c4rl") stay below every real match.
    static func score(name: String, fans: Int, query: String, corroboration: Double = 0) -> Double {
        let t = tier(name: name, query: query)
        guard t > none else { return popularityBonus(fans: fans) * 0.35 }
        return Double(t) + popularityBonus(fans: fans) + corroboration
    }

    /// Same artist, ignoring case/diacritics/punctuation. Deliberately strict —
    /// used to decide whether a search hit really *is* who was asked for, where a
    /// containment test would happily equate "Drake" with "Drake Bell".
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || withoutLeadingThe(x) == withoutLeadingThe(y)
    }
}
