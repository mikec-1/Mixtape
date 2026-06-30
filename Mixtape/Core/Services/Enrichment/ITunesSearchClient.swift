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
    let picture_xl:     String?
    let picture_medium: String?
}

// MARK: - Deezer track-search models (popularity-ranked discover search)

private struct DeezerTrackSearchResponse: Decodable {
    let data: [DeezerTrack]
}

private struct DeezerTrack: Decodable {
    struct Artist: Decodable { let id: Int?; let name: String; let picture_xl: String?; let picture_big: String? }
    struct Album:  Decodable { let title: String; let cover_xl: String?; let cover_big: String? }
    let id:       Int?       // Deezer track id (used to fetch contributors)
    let title:    String
    let duration: Int?       // seconds
    let rank:     Int?       // Deezer popularity score — higher = more popular
    let explicit_lyrics: Bool?  // true = explicit; optional because some endpoints omit it
    // Optional: /album/{id}/tracks responses omit `album`, and some omit `artist`.
    let artist:   Artist?
    let album:    Album?
}

// MARK: - Deezer track detail (contributors = main + featured artists)

private struct DeezerTrackDetail: Decodable {
    struct Contributor: Decodable {
        let id: Int
        let name: String
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
    }
    let data: [Item]
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

    /// Spotify client used to resolve artist profile images. Deezer artist photos
    /// are intentionally NOT used: every `OnlineArtist.imageURL` is resolved via
    /// Spotify, or left nil (so the built-in placeholder shows) when Spotify has
    /// no match. Optional so non-Discover callers can construct without it.
    private let spotifyClient: SpotifyClient?

    public init(spotifyClient: SpotifyClient? = nil) {
        self.spotifyClient = spotifyClient
    }

    /// Resolve Spotify images for a batch of artists, returning new `OnlineArtist`
    /// values whose `imageURL` is the Spotify image (or nil — never a Deezer photo).
    private func withSpotifyImages(_ artists: [OnlineArtist]) async -> [OnlineArtist] {
        guard let spotifyClient, !artists.isEmpty else {
            // No Spotify client wired: drop Deezer photos so no stale image shows.
            return artists.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: nil) }
        }
        let images = await spotifyClient.artistImages(for: artists.map(\.name))
        return artists.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: images[$0.name]) }
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
    public func searchPopular(query: String, limit: Int = 40) async -> [ITunesTrackResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=\(limit)")
        else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data)

            // Sort most-popular-first, then map into the shared result model.
            // Dedup by title|artist so the same song from many albums collapses —
            // but ALWAYS prefer the explicit version over a clean one when both
            // exist (see Self.preferringExplicit). Sort order (rank desc) is kept.
            let results = Self.preferringExplicit(decoded.data)
                .map { t -> ITunesTrackResult in
                    let artistName = t.artist?.name ?? ""
                    return ITunesTrackResult(
                        trackName:        t.title,
                        artistName:       artistName,
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
            print("[Deezer] query='\(trimmed)' → \(results.count) popularity-ranked songs")
            return results
        } catch {
            print("[Deezer] search failed for '\(trimmed)': \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Discover browse (Deezer artists / albums / catalogue)

    /// One round-trip-ish grouped search for the sectioned Discover UI: popular
    /// songs, matching artists, and matching albums. Each leg fails soft to [].
    public func discoverSearch(query: String) async -> DiscoverResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return DiscoverResults() }

        async let songsRaw  = searchPopular(query: trimmed, limit: 25)
        async let topArtist = searchArtists(query: trimmed, limit: 1)

        var songs = await songsRaw.map { r in
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
        songs = relevantSongs(songs, matching: trimmed)

        // Determine the primary anchor artist. Everything downstream (albums +
        // "fans also like") hangs off this so a song-title query surfaces that
        // song's ARTIST — not random albums/artists that merely share the title.
        //
        // Prefer the artist-search hit when its name closely matches the query
        // (a bare artist search like "drake"); otherwise fall back to the artist
        // of the most-popular matching song (a song-title query like a Drake track).
        let artistHit = await topArtist.first
        let isArtistQuery = artistHit.map { namesMatch($0.name, trimmed) } ?? false

        var anchor: OnlineArtist?
        if isArtistQuery {
            anchor = artistHit
        } else if let name = songs.first?.artistName, !name.isEmpty {
            // Look the song's artist up to get a real Deezer id for albums/related.
            anchor = await searchArtists(query: name, limit: 1).first ?? artistHit
        } else {
            anchor = artistHit
        }

        // Bare-artist query (e.g. "drake"): the songs list should be the anchor
        // artist's OWN top tracks — not Deezer's full-text popularity search, which
        // mixes in same-name songs/albums by other artists. This is the main cause
        // of "the first song is right but the rest are different artists". Fall
        // back to the relevance-filtered popularity list if the lookup whiffs.
        if isArtistQuery, let anchor {
            let top = await artistTopTracks(artistId: anchor.id, limit: 25)
            if !top.isEmpty { songs = top }
        }

        // Song-centric query (a specific song, not an artist name): promote that
        // song to a wide hero and surface the artists ON it — the main artist plus
        // any featured artists — followed by more songs by the main artist.
        var topSong: OnlineTrack?
        var songArtists: [OnlineArtist] = []
        if !isArtistQuery, let hero = songs.first {
            topSong = hero
            // Contributors give the real main + featured artists (with ids/images).
            if let trackID = hero.sourceID {
                songArtists = await trackContributors(trackID: trackID)
            }
            if songArtists.isEmpty, let anchor { songArtists = [anchor] }

            // "More songs by that artist" — the main artist's top tracks, minus the
            // hero itself. Falls back to the popularity list (filtered to the hero's
            // artist so we don't reintroduce same-name noise) if the lookup whiffs.
            let mainArtistID = songArtists.first?.id ?? anchor?.id
            if let mainArtistID {
                let more = await artistTopTracks(artistId: mainArtistID, limit: 12)
                    .filter { $0.id != hero.id }
                if !more.isEmpty {
                    songs = more
                } else {
                    songs = songs.filter { namesMatch($0.artistName, hero.artistName) }
                }
            }
        }

        // Albums section = the anchor artist's OWN catalogue (not a title match),
        // and the "fans also like" row = the anchor + its related artists.
        var albums: [OnlineAlbum] = []
        var artists: [OnlineArtist] = []
        if let anchor {
            albums = await artistAlbums(artistId: anchor.id, limit: 12)
            let related = await relatedArtists(artistId: anchor.id, limit: 11)
            var seen = Set([anchor.id])
            artists = [anchor] + related.filter { seen.insert($0.id).inserted }
        }
        return DiscoverResults(songs: songs, artists: artists, albums: albums,
                               topSong: topSong, songArtists: songArtists)
    }

    // MARK: - Discover landing (charts / genres, shown before searching)

    /// One grouped fetch for the pre-search Discover landing: trending tracks,
    /// popular artists, new releases, and genre tiles. Each leg fails soft to []
    /// so a partial outage still yields a populated page.
    public func browseLanding() async -> BrowseLanding {
        async let trending = chartTracks(limit: 20)
        async let artists  = chartArtists(limit: 15)
        async let releases = chartAlbums(limit: 15)
        async let genreTiles = genres()
        return await BrowseLanding(trending: trending, artists: artists,
                                   newReleases: releases, genres: genreTiles)
    }

    /// Globally trending tracks (Deezer chart). Explicit version preferred.
    public func chartTracks(limit: Int = 20) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/tracks?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false)
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
                artists.append(OnlineArtist(id: id, name: a.name, imageURL: nil))
                if artists.count >= limit { break }
            }
            if !artists.isEmpty { return await withSpotifyImages(artists) }
        }
        // Fallback: Deezer's artist chart.
        guard let url = URL(string: "https://api.deezer.com/chart/0/artists?limit=\(limit)"),
              let resp: DeezerChartArtistsResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: nil) }
        return await withSpotifyImages(artists)
    }

    /// New / popular album releases (Deezer chart).
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
                artists.append(OnlineArtist(id: id, name: a.name, imageURL: nil))
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
        let artists = resp.data.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: nil) }
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
            return OnlineArtist(id: c.id, name: c.name, imageURL: nil)
        }
        return await withSpotifyImages(artists)
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
        return await searchArtists(query: name, limit: 1).first
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
        return hits.first { namesMatch($0.title, track.albumTitle) } ?? hits.first
    }

    /// True when an artist's name is a close match for the search query, so we
    /// can trust the artist-search hit as the anchor (a bare-artist query). Uses
    /// a case/whitespace-insensitive equality-or-containment test — loose enough
    /// to absorb punctuation/diacritic noise without matching unrelated names.
    private func namesMatch(_ name: String, _ query: String) -> Bool {
        let a = name.lowercased().trimmingCharacters(in: .whitespaces)
        let b = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Meaningful lowercased word tokens of `text` (drops 1-char filler so "the",
    /// punctuation, and stray letters don't create spurious matches).
    private func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 })
    }

    /// Keep only songs that are plausibly about `query`, dropping the same-name
    /// noise Deezer's broad full-text search mixes in (e.g. an unrelated artist
    /// whose album title happens to contain the query word). A song qualifies when
    /// its artist name closely matches the query, OR its title/artist together
    /// cover every meaningful query token. Conservative by design: if the query
    /// has no usable tokens we return the input untouched rather than over-filter.
    private func relevantSongs(_ songs: [OnlineTrack], matching query: String) -> [OnlineTrack] {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return songs }
        let filtered = songs.filter { song in
            if namesMatch(song.artistName, query) { return true }
            let haystack = tokens("\(song.title) \(song.artistName)")
            return queryTokens.isSubset(of: haystack)
        }
        // Never let the filter empty the list — fall back to the raw results so a
        // genuinely odd query still shows something.
        return filtered.isEmpty ? songs : filtered
    }

    /// Artists matching `query`, ranked by Deezer popularity (nb_fan).
    public func searchArtists(query: String, limit: Int = 12) async -> [OnlineArtist] {
        guard let url = Self.deezerURL("search/artist", query: query, limit: limit) else { return [] }
        guard let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: nil) }
        return await withSpotifyImages(artists)
    }

    /// Albums matching `query`.
    public func searchAlbums(query: String, limit: Int = 12) async -> [OnlineAlbum] {
        guard let url = Self.deezerURL("search/album", query: query, limit: limit) else { return [] }
        guard let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }
        return resp.data.map {
            OnlineAlbum(id: $0.id, title: $0.title, artistName: $0.artist?.name ?? "",
                        coverURL: ($0.cover_xl ?? $0.cover_big).flatMap(URL.init(string:)))
        }
    }

    /// An artist's most popular tracks (the "Popular" list in the artist view).
    public func artistTopTracks(artistId: Int, limit: Int = 10) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/top?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        // Prefer the explicit version when a song appears as both explicit + clean.
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false)
        }
    }

    /// A "radio" of tracks similar to `artist` — Deezer's artist-radio flow,
    /// which stays within the artist's genre/scene (won't jump rap → classical).
    /// Resolves the artist name to a Deezer id first, then fetches the radio.
    /// Used to seed auto-suggestions in the play queue.
    public func radioTracks(forArtist artist: String, limit: Int = 20) async -> [OnlineTrack] {
        guard let artistID = await searchArtists(query: artist, limit: 1).first?.id,
              let url = URL(string: "https://api.deezer.com/artist/\(artistID)/radio?limit=\(limit)"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        return Self.preferringExplicit(resp.data).map { t in
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? "", albumTitle: t.album?.title ?? "",
                        duration: TimeInterval(t.duration ?? 0),
                        artworkURL: (t.album?.cover_xl ?? t.album?.cover_big).flatMap(URL.init(string:)),
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false)
        }
    }

    /// Artists similar to `artistId` (Deezer "related" — fans also like).
    public func relatedArtists(artistId: Int, limit: Int = 12) async -> [OnlineArtist] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/related?limit=\(limit)"),
              let resp: DeezerArtistSearchResponse = await Self.getJSON(url) else { return [] }
        let artists = resp.data.map { OnlineArtist(id: $0.id, name: $0.name, imageURL: nil) }
        return await withSpotifyImages(artists)
    }

    /// An artist's albums, newest first (the artist view's album grid).
    public func artistAlbums(artistId: Int, limit: Int = 40) async -> [OnlineAlbum] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/albums?limit=\(limit)"),
              let resp: DeezerAlbumSearchResponse = await Self.getJSON(url) else { return [] }
        // Dedup by title (Deezer lists explicit + clean + regional dupes).
        var seen = Set<String>()
        return resp.data.compactMap { a in
            guard seen.insert(a.title.lowercased()).inserted else { return nil }
            return OnlineAlbum(id: a.id, title: a.title, artistName: a.artist?.name ?? "",
                               coverURL: (a.cover_xl ?? a.cover_big).flatMap(URL.init(string:)))
        }
    }

    /// The track listing for an album (used when an album is opened).
    public func albumTracks(album: OnlineAlbum) async -> [OnlineTrack] {
        guard let url = URL(string: "https://api.deezer.com/album/\(album.id)/tracks?limit=100"),
              let resp: DeezerTrackSearchResponse = await Self.getJSON(url) else { return [] }
        // Usually one version per track, but if a title appears twice (explicit +
        // clean), prefer the explicit one.
        return Self.preferringExplicit(resp.data).map { t in
            // Album-track records carry no per-track cover; reuse the album cover.
            OnlineTrack(title: t.title, artistName: t.artist?.name ?? album.artistName, albumTitle: album.title,
                        duration: TimeInterval(t.duration ?? 0), artworkURL: album.coverURL,
                        sourceID: t.id, isExplicit: t.explicit_lyrics ?? false)
        }
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

    private static func getJSON<T: Decodable>(_ url: URL) async -> T? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[Deezer] request failed \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Artwork helper

    /// Transforms Apple's 100×100 artwork URL to a higher resolution.
    public func artworkURL(from url100: String, size: Int = 600) -> URL? {
        URL(string: url100.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb"))
    }

    // MARK: - Artist image

    /// Resolves the artist profile photo URL via Spotify only. Deezer artist
    /// photos are intentionally NOT used (often stale, and not the artist's real
    /// profile picture). Returns nil when no Spotify client is wired or Spotify
    /// has no match, so callers fall back to the built-in placeholder.
    public func artistImageURL(for artistName: String) async -> URL? {
        await spotifyClient?.artistImageURL(for: artistName)
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
    /// Tries GB first (better for non-US artists), then US, AU, CA.
    private func findArtistId(_ artist: String) async throws -> Int? {
        guard let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        for country in ["gb", "us", "au", "ca"] {
            guard let url = URL(string: "\(Self.searchURL)?term=\(encoded)&entity=musicArtist&limit=5&country=\(country)")
            else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            guard let decoded = try? JSONDecoder().decode(ArtistSearchResponse.self, from: data),
                  let first = decoded.results.first else { continue }
            print("[iTunes] Found artist '\(first.artistName)' id=\(first.artistId) in \(country) store")
            return first.artistId
        }
        return nil
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
