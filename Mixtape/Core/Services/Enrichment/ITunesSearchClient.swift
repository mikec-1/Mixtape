// Wrapper for the public iTunes Search and Lookup APIs, plus the Deezer
// catalogue used by Discover. With a known artist, finds the artist id, pulls
// their songs and scores them against the title, alongside a title-only search.

import Foundation
import OSLog
internal import Auth
import Supabase
// MARK: - Public result model

public struct ITunesTrackResult: Decodable, Sendable {
    public let trackName:        String
    public let artistName:       String
    public let collectionName:   String?
    public let artworkUrl100:    String?
    public let releaseDate:      String?    // "2014-07-01T07:00:00Z"
    public let trackNumber:      Int?
    public let primaryGenreName: String?
    public let trackTimeMillis:  Int?  // used to reject mismatched videos
    public var sourceID:         Int? = nil  // Deezer id, nil for iTunes
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

/// Deezer's error body. It returns HTTP 200 with {"error": {...}}, so a decode
/// failure is usually this rather than bad JSON.
private struct DeezerErrorEnvelope: Decodable {

    struct Payload: Decodable {
        let type:    String?
        let message: String?
        let code:    Int?
    }

    let error: Payload

    /// Code 4 is the quota (~50 requests per 5 s per IP), 700 is "busy".
    /// Everything else fails the same on retry.
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

/// Spaces Deezer requests to stay under the quota. Slots are claimed in order
/// before sleeping, so a sleeper never blocks the next caller.
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

/// Short-lived Deezer body cache that also coalesces identical in-flight
/// requests. The type-ahead and the full search ask for the same URL moments
/// apart. Caches bodies, not decoded values.
private actor DeezerResponseCache {

    static let shared = DeezerResponseCache()

    private struct Entry { let body: Data; let at: Date }

    private static let ttl: TimeInterval = 60
    private static let capacity = 240

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func body(for url: URL, fetch: @Sendable @escaping () async -> Data?) async -> Data? {
        let key = url.absoluteString

        if let hit = entries[key], Date().timeIntervalSince(hit.at) < Self.ttl { return hit.body }

        // Already in flight, wait for it.
        if let running = inFlight[key] { return await running.value }

        let task = Task { await fetch() }
        inFlight[key] = task
        let body = await task.value
        inFlight[key] = nil

        if let body {
            // Clears at capacity rather than LRU. A miss only costs a request.
            if entries.count >= Self.capacity { entries.removeAll() }
            entries[key] = Entry(body: body, at: Date())
        }
        return body
    }

    /// Drops a throttle notice so the retry asks again.
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
    let rank:     Int?  // popularity, higher is more popular
    let explicit_lyrics: Bool?  // optional, some endpoints omit it
    // Optional: /album/{id}/tracks responses omit `album`, and some omit `artist`.
    let artist:   Artist?
    let album:    Album?
    /// Main artist first. Only /artist/{id}/top has these; see withContributors.
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
        let nb_fan: Int?  // follower count
        // Fallback when Spotify can't confirm the artist.
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
        /// Only on /artist/{id}/albums.
        let release_date: String?
        let record_type: String?
        let nb_tracks: Int?
    }
    let data: [Item]
}

/// A single album from /album/{id}. Listings don't carry release_date or
/// record_type, which New releases needs.
nonisolated private struct DeezerAlbumDetail: Decodable {
    nonisolated struct Artist: Decodable { let id: Int?; let name: String }
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

nonisolated private struct ArtistItem: Decodable {
    let artistId:   Int
    let artistName: String
}

nonisolated private struct ArtistSearchResponse: Decodable {
    let resultCount: Int
    let results:     [ArtistItem]
}

/// Flexible item used for Lookup API responses which mix artist + track records.
nonisolated private struct LookupItem: Decodable, Sendable {
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

nonisolated private struct LookupResponse: Decodable, Sendable {
    let resultCount: Int
    let results:     [LookupItem]
}

/// nonisolated since lookups decode off the main actor.
nonisolated private func trackResult(from item: LookupItem) -> ITunesTrackResult? {
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

    /// Spotify images win when Spotify can confirm the name. Optional.
    private let spotifyClient: SpotifyClient?

    public init(spotifyClient: SpotifyClient? = nil) {
        self.spotifyClient = spotifyClient
    }

    /// Swaps in Spotify photos, keeping Deezer's when Spotify has no verified match.
    /// Cosmetic, so it races a deadline; whatever misses keeps its Deezer photo.
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

    /// Runs `work` with a timeout, returning `fallback` and cancelling if it loses.
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

    /// First usable Deezer photo. Deezer's grey silhouette counts as none.
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

    /// Songs matching `title`, optionally by `artist`. With an artist, also pulls
    /// their catalogue (GB, US, AU, CA) and merges it with a title search.
    public func search(title: String, artist: String?) async throws -> [ITunesTrackResult] {
        var all: [ITunesTrackResult] = []

        // A bare query might be an artist name, so treat it as both.
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

        // Exact artist matches first, then partial, then title matches.
        let q = (artist ?? title).lowercased().trimmingCharacters(in: .whitespaces)
        return unique
            .map { ($0, Self.relevance(of: $0, query: q)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.trackName < $1.0.trackName }
            .map { $0.0 }
    }

    /// Higher is more relevant. `query` is lowercased.
    private static func relevance(of r: ITunesTrackResult, query q: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let artist = r.artistName.lowercased()
        let track  = r.trackName.lowercased()
        var score = 0
        if artist == q                              { score += 100 }   // "drake" -> Drake
        else if artist.hasPrefix(q)                 { score += 70 }    // "drak" -> Drake
        else if artist.contains(q)                  { score += 40 }    // "ovo drake"
        if track == q                               { score += 60 }    // exact song title
        else if track.hasPrefix(q)                  { score += 30 }
        else if track.contains(q)                   { score += 15 }
        return score
    }

    // MARK: - Popularity-ranked discover search (Deezer)

    /// Free-text search by popularity (Deezer rank). [] on failure so the caller
    /// can fall back to iTunes. Uses fetchTracks for the gate, retries and cache.
    public func searchPopular(query: String, limit: Int = 40) async -> [ITunesTrackResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let rows = await fetchTracks(query: trimmed, limit: limit)
        guard !rows.isEmpty else { return [] }

        // Deduped inside fetchTracks, explicit kept.
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

    /// Grouped search for Discover: songs, artists and albums. Everything hangs off
    /// one anchor artist, so picking it right matters most.
    public func discoverSearch(query: String) async -> DiscoverResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return DiscoverResults() }

        // Stage timings, logged under the "search" category.
        let began = Date()
        // Row counts tell a fast empty result from a fast real one.
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
        // Drop Deezer's same-name noise, keeping the top real match first.
        // Credits are fetched at the end, only for the songs that survive.
        elapsed("songs", rawSongs.count)
        let (relevant, songsAreRelevant) = relevantSongs(rawSongs, matching: trimmed)
        var songs = relevant

        // Rank artists by name match and by who owns the matching songs.
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
            // Artist query: use their own top tracks, not full-text hits.
            let top = await artistTopTracks(artistId: topArtist.id, limit: 25)
            if !top.isEmpty { songs = top }
        }

        // Song query: that song as the hero, its artists, then more by the main artist.
        // Skipped when nothing matched.
        if !isArtistQuery, songsAreRelevant, let hero = songs.first {
            topSong = hero
            // Contributors give real ids for main and featured artists.
            if let trackID = hero.sourceID {
                songArtists = await trackContributors(trackID: trackID)
            }
            if songArtists.isEmpty, !hero.artistName.isEmpty {
                songArtists = await searchArtists(query: hero.artistName, limit: 1)
            }
            anchor = songArtists.first

            // More by the main artist, minus the hero.
            if let mainArtistID = anchor?.id {
                let more = await artistTopTracks(artistId: mainArtistID, limit: 12)
                    .filter { $0.id != hero.id }
                songs = more.isEmpty
                    ? songs.filter { namesMatch($0.artistName, hero.artistName) }
                    : more
            }
        }

        elapsed("anchor", songs.count)

        // The anchor's albums and related artists, fetched together.
        var albums: [OnlineAlbum] = []
        var artists: [OnlineArtist] = []
        if let resolved = anchor {
            async let albumsCall  = artistAlbums(artistId: resolved.id, artistName: resolved.name, limit: 12)
            async let relatedCall = relatedArtists(artistId: resolved.id, limit: 11)
            albums = await albumsCall
            let related = await relatedCall

            // Some ids are dead duplicate profiles. Retry with the best song's artist.
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

        // Credits last, only for the rows kept. Usually free since top tracks have them.
        songs = await withContributors(songs, limit: 10)
        if let hero = topSong {
            topSong = await withContributors([hero], limit: 1).first ?? hero
        }
        elapsed("done", songs.count)

        // Only the unanchored fallback is a guess.
        return DiscoverResults(songs: songs, artists: artists, albums: albums,
                               topSong: topSong, songArtists: songArtists,
                               anchorIsArtist: isArtistQuery && anchor != nil,
                               songsMatched: songsAreRelevant || anchor != nil)
    }

    /// Whether the query names this artist rather than a song. A name match also
    /// needs evidence: owning several matching songs, or being popular. An exact
    /// match needs much less, so small artists still resolve.
    private static func namesAnArtist(_ candidate: ArtistCandidate, songs: [OnlineTrack]) -> Bool {
        guard candidate.tier >= DiscoverNameMatch.strong else { return false }
        let owned = songs.prefix(5).filter { DiscoverNameMatch.sameName($0.artistName, candidate.name) }.count
        if owned >= 2 { return true }
        return candidate.fans >= (candidate.tier == DiscoverNameMatch.exact ? 10_000 : 250_000)
    }

    // MARK: - Search-as-you-type

    /// Type-ahead rows, debounced by the caller. Best artist first, then up to two
    /// completions, then songs. Deezer images only.
    public func searchSuggestions(query: String, limit: Int = 16) async -> [SearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        // Same URLs as discoverSearch so the cache answers one of them.
        async let candidatesRaw = fetchArtistCandidates(query: trimmed, limit: 25)
        async let tracksRaw     = fetchTracks(query: trimmed, limit: 25)
        let (candidates, tracks) = await (candidatesRaw, tracksRaw)
        guard !Task.isCancelled else { return [] }

        let ranked = Self.rank(candidates, for: trimmed,
                               corroboratingArtists: tracks.compactMap { $0.artist?.name })
        let typed = DiscoverNameMatch.normalize(trimmed)
        var out: [SearchSuggestion] = []

        // 1. The artist, only on a strong name match.
        let topArtist = ranked.first.flatMap { $0.tier >= DiscoverNameMatch.strong ? $0 : nil }
        if let topArtist {
            out.append(SearchSuggestion(id: "artist-\(topArtist.id)", kind: .artist(id: topArtist.id),
                                        title: topArtist.name, subtitle: "Artist",
                                        imageURL: topArtist.picture, isExplicit: false))
        }

        // 2. Completions that extend the query. Tapping one re-runs the search.
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

        // 3. An album, only when the query names it.
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

    /// Raw track search, explicit preferred. Keeps the ids searchPopular drops.
    private func fetchTracks(query: String, limit: Int) async -> [DeezerTrack] {
        guard let url = Self.deezerURL("search", query: query, limit: limit),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data)
    }

    // MARK: - Discover landing (charts / genres, shown before searching)

    /// The Discover landing: chart, artists, new releases and genres.
    public func browseLanding() async -> BrowseLanding {
        async let trending = chartTracks(limit: 20)
        async let artists  = chartArtists(limit: 15)
        async let releases = newReleases(limit: 18)
        async let genreTiles = genres()
        return await BrowseLanding(trending: trending, artists: artists,
                                   newReleases: releases, genres: genreTiles)
    }

    /// Deezer chart. genreId 0 is all genres.
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

    /// Trending artists, taken from the track chart since Deezer's artist chart
    /// is stale. Falls back to the artist chart.
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

    /// Recent albums behind today's charting songs. Deezer's album chart is
    /// editorial and undated, so this resolves each album for its date and type,
    /// drops old ones, and puts albums and EPs before singles. Ties keep chart order.
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
        // Empty means the chart failed. A short list is a real answer.
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

    /// Fetches each album concurrently, keeping chart order.
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

    /// Parsed in UTC so it's the same day everywhere.
    static func deezerDate(_ raw: String?) -> Date? {
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

    /// Editorial album chart. Only used when the track chart fails.
    public func chartAlbums(limit: Int = 15) async -> [OnlineAlbum] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/albums?limit=\(limit)"),
              let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }
        return resp.data.map {
            OnlineAlbum(id: $0.id, title: $0.title, artistName: $0.artist?.name ?? "",
                        coverURL: ($0.cover_xl ?? $0.cover_big).flatMap(URL.init(string:)))
        }
    }

    /// Deezer genres, minus the "All" pseudo-genre.
    public func genres() async -> [BrowseGenre] {
        guard let url = URL(string: "https://api.deezer.com/genre"),
              let resp: DeezerGenreResponse = await Self.getJSON(url) else { return [] }
        return resp.data
            .filter { $0.id != 0 }
            .map { BrowseGenre(id: $0.id, name: $0.name,
                               pictureURL: ($0.picture_xl ?? $0.picture_medium).flatMap(URL.init(string:))) }
    }

    /// Popular artists in a genre. Deezer's genre artist endpoints ignore the
    /// genre, so this uses the genre's track chart instead. Falls back to genre
    /// albums, then the global chart.
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

    // MARK: - Lyric search (Genius + NetEase -> Deezer resolve)

    /// Lyric search: Genius (through mixtaped.tech, which holds the token) then NetEase
    /// find songs containing the words, each resolved to a Deezer track. Empty for very short queries.
    public func searchByLyrics(_ query: String, limit: Int = 8) async -> [OnlineTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 else { return [] }

        async let genius = geniusLyricHits(trimmed, limit: limit)
        guard var comps = URLComponents(string: "https://music.163.com/api/search/get") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "type",  value: "1006"),     // 1006 = lyric search
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "s",     value: trimmed)
        ]
        var netease: [LyricHit] = []
        if let url = comps.url,
           let decoded: NetEaseLyricSearchResponse = await Self.getNetEaseJSON(url) {
            netease = (decoded.result?.songs ?? []).map {
                LyricHit(title: $0.name ?? "", artist: $0.artists?.first?.name ?? "")
            }
        }

        // Genius ranks lyric matches better, so it goes first. Resolve concurrently, keeping order.
        let hits = Array((await genius + netease).prefix(limit * 2))
        guard !hits.isEmpty else { return [] }
        let resolved: [OnlineTrack?] = await withTaskGroup(of: (Int, OnlineTrack?).self) { group in
            for (i, hit) in hits.enumerated() {
                group.addTask { (i, await self.resolveOnlineTrack(title: hit.title, artist: hit.artist)) }
            }
            var slots = [OnlineTrack?](repeating: nil, count: hits.count)
            for await (i, t) in group { slots[i] = t }
            return slots
        }
        // Drop misses and dedup by title|artist.
        var seen = Set<String>()
        return Array(resolved.compactMap { $0 }.filter {
            seen.insert("\($0.title.lowercased())|\($0.artistName.lowercased())").inserted
        }.prefix(limit))
    }

    private struct LyricHit: Decodable, Sendable {
        let title: String
        let artist: String
    }

    /// Genius hits from the web's catalogue route. Signed-in only; empty on any failure.
    private func geniusLyricHits(_ query: String, limit: Int) async -> [LyricHit] {
        guard let token = try? await SupabaseConfig.client.auth.session.accessToken,
              var comps = URLComponents(string: "https://www.mixtaped.tech/api/catalog/lyrics") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "source", value: "genius"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Response: Decodable { let hits: [LyricHit] }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.hits
    }

    /// Resolve a (title, artist) pair to a playable Deezer OnlineTrack via search.
    func resolveOnlineTrack(title: String, artist: String) async -> OnlineTrack? {
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
            MixLog.lyrics.error("netease lyric search failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A track's main and featured artists, in Deezer's order.
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

    /// Credits and cover from the track record, fetched once at play time.
    public static func trackDetail(trackID: Int) async -> (contributors: [String], coverURL: URL?) {
        guard let url = URL(string: "https://api.deezer.com/track/\(trackID)"),
              let detail: DeezerTrackDetail = await getJSON(url) else { return ([], nil) }
        return (detail.contributors?.map(\.name) ?? [],
                (detail.album?.cover_xl ?? detail.album?.cover_big).flatMap(URL.init(string:)))
    }

    /// The artist to open for a tapped name: an exact contributor match, then the
    /// main artist, then a name search.
    public func resolveArtist(name: String, trackID: Int?) async -> OnlineArtist? {
        if let trackID {
            let contributors = await trackContributors(trackID: trackID)
            if let match = contributors.first(where: { namesMatch($0.name, name) }) { return match }
            if let main = contributors.first { return main }
        }
        guard let hit = await searchArtists(query: name, limit: 1).first else { return nil }
        // Record the spelling for ArtistAliases. Not done for the main-artist
        // fallback above, which would credit the guest's songs to someone else.
        ArtistAliases.record(local: name, canonical: hit.name)
        return hit
    }

    /// A track's album: from the track detail, else an album search.
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
        let query = "\(track.albumTitle) \(track.artistName)".trimmingCharacters(in: .whitespaces)
        guard !track.albumTitle.isEmpty else { return nil }
        let hits = await searchAlbums(query: query, limit: 5)
        // Match artist too. Two different albums can share a title.
        return hits.first { namesMatch($0.title, track.albumTitle) && namesMatch($0.artistName, track.artistName) }
            ?? hits.first { namesMatch($0.title, track.albumTitle) }
            ?? hits.first
    }

    /// Loose name match (equal or contained, after folding). For UI wiring only;
    /// anchoring uses DiscoverNameMatch.sameName.
    private func namesMatch(_ name: String, _ query: String) -> Bool {
        let a = DiscoverNameMatch.normalize(name)
        let b = DiscoverNameMatch.normalize(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Lowercased tokens, minus single characters.
    private func tokens(_ text: String) -> Set<String> {
        Set(DiscoverNameMatch.normalize(text)
            .components(separatedBy: " ")
            .filter { $0.count >= 2 })
    }

    /// Drops same-name noise: keeps songs whose artist matches the query or whose
    /// title and artist cover every query token. `matched` is false when the raw
    /// list was returned, so the page isn't anchored on it.
    private func relevantSongs(_ songs: [OnlineTrack],
                               matching query: String) -> (songs: [OnlineTrack], matched: Bool) {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return (songs, !songs.isEmpty) }
        let filtered = songs.filter { song in
            if namesMatch(song.artistName, query) { return true }
            let haystack = tokens("\(song.title) \(song.artistName)")
            return queryTokens.isSubset(of: haystack)
        }
        // Never empty the list.
        return filtered.isEmpty ? (songs, false) : (filtered, true)
    }

    /// Artists for `query`, ranked by name match and popularity. Deezer's order
    /// isn't popularity (namesakes come before Drake), so over-fetch and rank.
    public func searchArtists(query: String, limit: Int = 12) async -> [OnlineArtist] {
        let ranked = Self.rank(await fetchArtistCandidates(query: query, limit: max(limit, 25)), for: query)
        return await withSpotifyImages(ranked.prefix(limit).map(\.artist))
    }

    /// An artist hit with the fan count and tier ranking needs.
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
        // Always fetch deep so limit-1 callers don't get a namesake.
        guard let url = Self.deezerURL("search/artist", query: query, limit: max(limit, 25)),
              let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        return resp.data.map {
            ArtistCandidate(id: $0.id, name: $0.name, fans: $0.nb_fan ?? 0,
                            picture: Self.artistPicture($0.picture_xl, $0.picture_big))
        }
    }

    /// Scores, sorts and dedupes. Artists owning the matched songs get a bonus.
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
        // One row per name.
        var seenNames = Set<String>()
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fans > $1.fans }
            .filter { seenNames.insert(DiscoverNameMatch.normalize($0.name)).inserted }
    }

    /// Bonus for owning a matched song, bigger near the top.
    private static func corroboration(for name: String, among artists: [String]) -> Double {
        guard let index = artists.prefix(10).firstIndex(where: { DiscoverNameMatch.sameName($0, name) })
        else { return 0 }
        return 300 * (1 - Double(index) / 12)
    }

    /// Albums for `query`, collapsed one tile per record like artistAlbums.
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
        // Keep relevance order.
        return Array(Self.oneTilePerRecord(rows).prefix(limit))
    }

    /// An artist's most-played songs, for the artist page.
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

    /// Deezer artist radio for a name. Stays within the artist's scene.
    /// Seeds queue suggestions.
    public func radioTracks(forArtist artist: String, limit: Int = 20) async -> [OnlineTrack] {
        guard let artistID = await searchArtists(query: artist, limit: 1).first?.id else { return [] }
        return await radioTracks(artistId: artistID, limit: limit)
    }

    /// Same, for callers that already have the id.
    public func radioTracks(artistId: Int, limit: Int = 20) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/radio?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        // Every recommendation comes from radio, so "don't suggest" is applied here.
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false,
                        contributors: t.contributors?.map(\.name) ?? [])
        }
        .filter(SuggestionFeedback.allows)
    }

    /// The artist's radio plus related artists' radios, so a run can reach 20-40 songs.
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

    /// Deezer related artists.
    public func relatedArtists(artistId: Int, limit: Int = 12) async -> [OnlineArtist] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/related?limit=\(limit)"),
              let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map {
            OnlineArtist(id: $0.id, name: $0.name,
                         imageURL: Self.artistPicture($0.picture_xl, $0.picture_big))
        }
        .filter { !SuggestionFeedback.isBlocked(artist: $0.name) }
        return await withSpotifyImages(artists)
    }

    /// An artist's albums, newest first. This endpoint has release_date and
    /// record_type. `artistName` fills the credit it leaves out.
    public func artistAlbums(artistId: Int, artistName: String, limit: Int = 40) async -> [OnlineAlbum] {
        // Over-fetch, since newest-first would otherwise be all singles.
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

    /// One tile per record. Two passes:
    /// 1. Fold case/diacritics/punctuation and trim edition words, so
    /// "Nothing Was the Same (Deluxe)" matches "Nothing Was The Same".
    /// 2. Fold a longer title into its base when the extra words are an edition
    /// ("Scary Hours Edition"), but keep "Care Package 2" separate.
    /// The one with the most tracks survives.
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

        // Pass 2. Shortest first so the base is seen before its editions. Uses the
        // untrimmed name, since pass 1 already cut the edition word.
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

    /// Words that mark an edition, not a name. Kept short.
    private static let albumEditionWords: Set<String> = [
        "deluxe", "edition", "editions", "version", "remaster", "remastered",
        "anniversary", "expanded", "extended", "explicit", "clean", "bonus",
        "reissue", "collectors", "collector", "platinum", "repack", "redux"
    ]

    /// Title and artist, so two artists' albums with one title stay apart.
    /// "|" can't survive normalize.
    private static func recordKey(_ artistName: String, _ titleKey: String) -> String {
        "\(DiscoverNameMatch.normalize(artistName))|\(titleKey)"
    }

    /// The record a title names, with its edition packaging trimmed off.
    private static func albumWorkKey(_ title: String) -> String {
        var tokens = DiscoverNameMatch.normalize(title).split(separator: " ").map(String.init)
        // Trim edition words from the end. A year only counts after one.
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
        // Never trim to empty.
        return trimmed.isEmpty ? DiscoverNameMatch.normalize(title) : trimmed
    }

    /// `key` is `base` plus edition words, starting at a word boundary.
    private static func isEditionOf(_ key: String, base: String) -> Bool {
        guard !base.isEmpty, key.count > base.count, key.hasPrefix(base) else { return false }
        let tail = key.dropFirst(base.count)
        guard tail.hasPrefix(" ") else { return false }
        return tail.split(separator: " ").contains { albumEditionWords.contains(String($0)) }
    }

    /// Albums, EPs, compilations, singles, newest first within each.
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

    /// Everything the artist page shows. If an id yields nothing, re-resolve the
    /// name once and retry.
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

        // /top is thin for smaller artists, so the credit search fills in and
        // provides Appears On.
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

    /// Nil on failure, see fanCount.
    private func artistFanCount(artistId: Int) async -> Int? {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)"),
              let artist: DeezerArtist = await Self.getJSON(url) else { return nil }
        return artist.nb_fan
    }

    /// Every track credited to a name via the artist:"..." field search.
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

    /// Fills in guest credits album listings don't carry. One request per track,
    /// six at a time, only for tracks without them. Failures keep what they had.
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
        // Prefer explicit when a title appears twice.
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

    /// Dedupes by title|artist, preferring explicit. Input order (rank) breaks ties.
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

    /// Retries for a throttled request. Covers the 5 s quota window.
    private static let deezerMaxRetries = 3

    private static func getJSON<T: Decodable>(_ url: URL, attempt: Int = 0) async -> T? {
        // Cached and coalesced.
        guard let data = await DeezerResponseCache.shared.body(for: url, fetch: {
            await RequestGate.deezer.waitForSlot()
            do {
                let (body, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return body
            } catch {
                MixLog.catalog.error("[Deezer] request failed \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }) else { return nil }

        if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }

        // Deezer reports errors at HTTP 200, so check for an error body.
        guard let envelope = try? JSONDecoder().decode(DeezerErrorEnvelope.self, from: data) else {
            MixLog.catalog.debug("[Deezer] unreadable response from \(url.lastPathComponent)")
            return nil
        }

        guard envelope.isTransient, attempt < deezerMaxRetries else {
            MixLog.catalog.error("[Deezer] \(url.lastPathComponent): \(envelope.describedError)")
            return nil
        }

        // Don't cache a throttle notice.
        await DeezerResponseCache.shared.forget(url)

        // Exponential backoff with jitter so retries don't re-burst.
        let backoff = pow(2.0, Double(attempt)) * 0.7 + Double.random(in: 0...0.3)
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        return await getJSON(url, attempt: attempt + 1)
    }

    // MARK: - Artwork helper

    /// Transforms Apple's 100x100 artwork URL to a higher resolution.
    public func artworkURL(from url100: String, size: Int = 600) -> URL? {
        URL(string: url100.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb"))
    }

    // MARK: - Artist image

    /// Artist photo: Spotify first, then Deezer. Nil when neither confirms the name.
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
        MixLog.catalog.debug("[iTunes] title='\(title)' → \(unique.count) songs (text search)")
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private: artist-catalogue lookup

    /// Artist id, then their full catalogue. Less noisy than text search.
    private func searchByArtistCatalogue(_ artist: String) async throws -> [ITunesTrackResult]? {
        guard let artistId = try await findArtistId(artist) else {
            MixLog.catalog.debug("[iTunes] No artist ID found for '\(artist)'")
            return nil
        }
        MixLog.catalog.debug("[iTunes] Artist '\(artist)' → ID \(artistId)")
        return try await lookupSongs(artistId: artistId)
    }

    /// Best artist id, preferring GB, then US, AU, CA. All four asked at once.
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
        MixLog.catalog.debug("[iTunes] Found artist '\(best.name)' id=\(best.id) in \(best.country) store")
        return best.id
    }

    /// All songs for an artist, up to 200, GB first.
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
        MixLog.catalog.debug("[iTunes] Lookup artistId=\(artistId) → \(unique.count) songs across storefronts")
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

/// Scores how well a catalogue name answers a typed query. Tiers are spaced so
/// a very popular partial match beats a tiny exact one, but an exact match with
/// a real audience wins. Tuned against live search/artist results, so change
/// the constants with that data in hand. Shared with LibraryService.
enum DiscoverNameMatch {

    // Match tiers, best first.
    static let exact             = 1000  // "drake" -> Drake
    static let wordPrefix        = 800   // "kanye" -> Kanye West, "21" -> 21 Savage
    static let prefix            = 700   // "dra"   -> Drake, "ye" -> Yeat
    static let tokenSequence     = 650   // "tyler creat" -> Tyler, The Creator
    static let consonantSkeleton = 620   // "wknd"  -> The Weeknd
    static let tokenStart        = 560   // "dra"   -> Imagine Dragons
    static let contains          = 300   // "drake" -> Nick Drake
    static let fuzzy             = 150   // "utopia" -> U-topia
    static let none              = 0

    /// At or above this, the hit plausibly answers the name.
    static let strong = consonantSkeleton

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Folds case, diacritics and punctuation. Apostrophes and periods are deleted
    /// ("D.R.A." -> "dra"), other separators become a space.
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

    /// Best tier, comparing with and without a leading "the".
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
            // A prefix ending at a word boundary scores higher.
            let next = n[n.index(n.startIndex, offsetBy: q.count)]
            return next == " " ? wordPrefix : prefix
        }

        let nameTokens  = n.split(separator: " ").map(String.init)
        let queryTokens = q.split(separator: " ").map(String.init)

        if queryTokens.count > 1, tokenSequenceMatches(queryTokens, nameTokens, from: 0) {
            return tokenSequence
        }
        // Vowel-less queries are abbreviations ("wknd" -> "weeknd").
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
        // Subsequence only for longer queries.
        if q.count >= 4, isSubsequence(q, of: n) { return fuzzy }
        return none
    }

    /// Each query token prefixes the matching name token ("trav sco").
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

    /// Log-scaled fan count, capped below an exact match.
    static func popularityBonus(fans: Int) -> Double {
        min(log10(Double(max(fans, 1))) * 110, 770)
    }

    /// Match plus popularity plus corroboration. Unrelated names keep only part
    /// of their popularity.
    static func score(name: String, fans: Int, query: String, corroboration: Double = 0) -> Double {
        let t = tier(name: name, query: query)
        guard t > none else { return popularityBonus(fans: fans) * 0.35 }
        return Double(t) + popularityBonus(fans: fans) + corroboration
    }

    /// Strict same-name test, so "Drake" isn't "Drake Bell".
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || withoutLeadingThe(x) == withoutLeadingThe(y)
    }
}
