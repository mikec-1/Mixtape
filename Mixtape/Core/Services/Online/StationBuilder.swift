// StationBuilder.swift
// Mixtape — Core/Services/Online
//
// The two shelves that aren't one-mix-per-favourite-artist.
//
// **Genre mixes** are still yours — "German Rap Mix", "UK Drill Mix" — but a
// layer above the artist mixes: your library clustered by the *scene* each
// artist belongs to, then drawn from the radios of your own artists in that
// cluster. They do not turn over weekly. An artist mix churning every Monday is
// what keeps Discover feeling alive; a genre mix churning is just noise,
// because your genres don't change on a Monday. They hold until the cluster
// itself moves.
//
// The scene labels come from MusicBrainz, not Deezer. Deezer files genre on the
// album and only from a dozen-odd top-level buckets, which is how a first cut
// of this shelf put German rappers in the same mix as Doja Cat: both are
// "Rap/Hip Hop" to Deezer, and a bucket that wide isn't a mix, it's a shrug.
// MusicBrainz tags artists with community genres — "german hip hop", "uk
// drill", "afroswing" — which is the granularity a mix needs.
//
// **Radios** are the opposite: nothing to do with your library at all. Chart,
// scene and artist radios, so a brand-new account with an empty history still
// opens on a full page, and an old one has somewhere to go that isn't its own
// taste reflected back.
//
// Both produce `PersonalMix`, so `MixDetailPage` renders them, `MixMosaicCard`
// draws them and saving/downloading works with no new UI.
//
// Everything here is pinned to disk (`MixEditionStore`) — clustering costs two
// requests per artist against a service that asks for one request a second, and
// a shelf that refetched on every landing rebuild would be unusable.

import Foundation

/// Artist → scene, on disk, forever.
///
/// The answer is close to immutable — nobody's back catalogue changes genre —
/// which makes it the ideal thing to cache and the worst thing to re-ask.
enum ArtistGenreStore {

    /// Normalised artist → display label, e.g. "German Hip Hop". An empty
    /// string means "asked, and there is no answer": cached on purpose, or an
    /// artist MusicBrainz can't place would be looked up again on every build
    /// for the rest of time.
    private(set) static var entries: [String: String] = load()

    static func genre(for artist: String) -> String? {
        // Relabelled on read: entries written under the old caps rule
        // ("HIP HOP") repair themselves without asking MusicBrainz again.
        entries[RecommendationEngine.normalize(artist)].map { $0.isEmpty ? $0 : MusicBrainzGenres.label($0) }
    }

    static func storeAll(_ pairs: [(artist: String, genre: String)]) {
        guard !pairs.isEmpty else { return }
        for pair in pairs { entries[RecommendationEngine.normalize(pair.artist)] = pair.genre }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: url)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        let dir = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Discover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artist-genres.json")
    }()
}

/// The scene an artist belongs to, from MusicBrainz's community genre tags.
///
/// Two requests — search for the artist, then read their genres — behind a
/// one-per-second gate, because that is what MusicBrainz asks of clients and
/// being rate-limited off it would cost the shelf entirely. Only ever called
/// for artists `ArtistGenreStore` hasn't already answered for.
enum MusicBrainzGenres {

    private struct SearchResponse: Decodable {
        struct Artist: Decodable { let id: String; let name: String }
        let artists: [Artist]
    }

    private struct ArtistResponse: Decodable {
        struct Genre: Decodable { let name: String; let count: Int? }
        let genres: [Genre]?
    }

    /// `none` is an answer — the artist has no usable tags — and gets cached.
    /// `unreachable` is not an answer and must never be, or one bad afternoon
    /// blanks half a library's genres permanently.
    enum Placement { case genre(String), none, unreachable }

    static func genre(for artist: String) async -> Placement {
        let found = await search(artist)
        guard case .id(let mbid) = found else {
            return found == .unreachable ? .unreachable : .none
        }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=genres&fmt=json")
        else { return .none }
        guard let response: ArtistResponse = await getJSON(url) else { return .unreachable }
        guard let genres = response.genres, !genres.isEmpty,
              let picked = pick(from: genres) else { return .none }
        return .genre(label(picked))
    }

    private enum Found: Equatable { case id(String), none, unreachable }

    private static func search(_ artist: String) async -> Found {
        let query = artist.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !query.isEmpty,
              let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&fmt=json&limit=1")
        else { return .none }
        guard let response: SearchResponse = await getJSON(url) else { return .unreachable }
        // Only an exact name match. A near miss here doesn't degrade the mix,
        // it mislabels it — the wrong artist's scene becomes the mix's title.
        guard let first = response.artists.first,
              RecommendationEngine.normalize(first.name) == RecommendationEngine.normalize(artist)
        else { return .none }
        return .id(first.id)
    }

    /// The most specific tag people actually agreed on.
    ///
    /// Straight "most votes" always returns the widest label — everyone tags a
    /// Berlin rapper "hip hop" and only some add "german hip hop" — which is
    /// the bucket problem again. So: take the well-supported tags, then prefer
    /// the most specific of those, which for genre names means the longest.
    private static func pick(from genres: [ArtistResponse.Genre]) -> String? {
        let ranked = genres.sorted { ($0.count ?? 0) > ($1.count ?? 0) }
        guard let top = ranked.first else { return nil }
        let floor = max(1, (top.count ?? 1) / 2)
        let supported = ranked.filter { ($0.count ?? 0) >= floor }
        return supported
            .max { lhs, rhs in lhs.name.count < rhs.name.count }?
            .name ?? top.name
    }

    /// "german hip hop" → "German Hip Hop". MusicBrainz tags are lowercase.
    /// Idempotent, so it also repairs labels cached under the old rule, which
    /// uppercased every short word ("HIP HOP", "Alternative POP").
    static func label(_ tag: String) -> String {
        tag.lowercased().split(separator: " ").enumerated().map { index, sub -> String in
            let word = String(sub)
            // Scene names carry initialisms plain title case would ruin: "uk
            // drill" is not "Uk Drill". Only these, by name — a length rule
            // can't tell "uk" from "hip".
            if word == "lo-fi" { return "Lo-Fi" }
            if initialisms.contains(word) { return word.uppercased() }
            if index > 0 && lowercaseWords.contains(word) { return word }
            return word.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    private static let lowercaseWords: Set<String> = ["and", "the", "of"]
    private static let initialisms: Set<String> = [
        "uk", "us", "usa", "nz", "nyc", "atl", "dmv", "edm", "idm", "ebm", "r&b", "rnb", "dnb"
    ]

    // MARK: Transport

    /// MusicBrainz asks for one request a second and a real User-Agent, and
    /// enforces the first. One shared gate, so concurrent lookups queue rather
    /// than all getting a 503.
    private static let gate = RequestGate(spacing: 1.05)

    private static func getJSON<T: Decodable>(_ url: URL) async -> T? {
        await gate.waitForSlot()
        var request = URLRequest(url: url)
        request.setValue("Mixtape/1.0 ( https://mixtaped.tech )", forHTTPHeaderField: "User-Agent")
        // Short on purpose. MusicBrainz being unreachable is a shelf that
        // doesn't draw; MusicBrainz being unreachable for twelve seconds a
        // time is a minute of the app waiting to find that out.
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

}

enum StationBuilder {

    /// Under this a mix isn't a mix — the same floor the artist mixes use.
    private static let minimumTracks = 8
    private static let trackCount = 24

    // MARK: - Genre mixes

    /// Artists placed per build.
    ///
    /// Two MusicBrainz requests each behind a one-per-second gate, so this
    /// number *is* the shelf's cold-start delay in seconds times two. Kept
    /// small deliberately: placements are cached forever, so a library fills
    /// in over a handful of launches instead of holding the first one for a
    /// minute. The shelf grows; it never blocks.
    /// 6 was one artist's worth of shelf per launch: a library of hundreds of
    /// artists needed dozens of launches before two of them ever landed in the
    /// same scene, so the shelf was permanently empty and the "looking through
    /// your genres" pass had nothing to show for itself. Still gated and still
    /// off the critical path — it just fills in over a couple of launches now
    /// instead of a couple of months.
    private static let genreLookupsPerBuild = 40
    /// Two of your artists sharing a scene is a scene you're in; one is a
    /// coincidence. Deliberately lower than it would be for Deezer's buckets —
    /// the labels are narrow now, so the clusters are small by nature.
    private static let minimumArtistsPerGenre = 2
    private static let maxGenreMixes = 8
    /// Bumped when the clustering rules change, so a shelf pinned by the old
    /// ones doesn't stand. 2: MusicBrainz scenes replaced Deezer's buckets.
    private static let genreSchema: UInt64 = 4

    static func genreMixes(artists: [String],
                           using catalog: ITunesSearchClient) async -> [PersonalMix] {
        guard artists.count >= minimumArtistsPerGenre else { return [] }

        let placed = await placeGenres(for: artists, using: catalog)
        guard !placed.isEmpty else { return [] }

        // Grouped in the incoming order, so a scene's mix is seeded by the
        // artists this listener plays most within it.
        var byGenre: [String: [String]] = [:]
        for artist in artists {
            guard let genre = placed[RecommendationEngine.normalize(artist)],
                  !genre.isEmpty else { continue }
            byGenre[genre, default: []].append(artist)
        }

        // Fold the loners into their parent scene. MusicBrainz labels are
        // narrow on purpose — "german hip hop", "melodic drill" — which is what
        // makes a mix worth playing, but it also means one artist per label and
        // no cluster ever reaching two. An unplaced artist is dropped entirely,
        // so a coarse "Hip Hop" mix beats no shelf at all.
        for (genre, artists) in byGenre where artists.count < minimumArtistsPerGenre {
            let root = coarse(genre)
            guard root != genre else { continue }
            byGenre[genre] = nil
            byGenre[root, default: []].append(contentsOf: artists)
        }

        let clusters = byGenre
            .filter { $0.value.count >= minimumArtistsPerGenre }
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(maxGenreMixes)
        guard !clusters.isEmpty else { return [] }

        // The pin key is the clustering itself: same scenes, same artists in
        // them, same shelf — which is the whole point of these not being weekly.
        let key = hashKey(clusters.map { "\($0.key):\($0.value.prefix(4).joined(separator: ","))" })
            &+ genreSchema
        if let pinned = MixEditionStore.loadList("genres", key: key) { return pinned }

        let built = await ordered(Array(clusters)) { cluster in
            await genreMix(name: cluster.key,
                           seeds: Array(cluster.value.prefix(3)),
                           using: catalog)
        }

        if !built.isEmpty { MixEditionStore.saveList(built, name: "genres", key: key) }
        return built
    }

    /// The parent scene of a narrow label: the last two words of a three-word
    /// tag ("German Hip Hop" → "Hip Hop"), the last word otherwise ("Melodic
    /// Drill" → "Drill"). Crude, and right for how these tags are written.
    private static func coarse(_ genre: String) -> String {
        let words = genre.split(separator: " ")
        guard words.count > 1 else { return genre }
        let tail = words.count > 2 ? words.suffix(2) : words.suffix(1)
        return tail.joined(separator: " ")
    }

    /// One scene's mix, pooled from the radios of your own artists in it.
    private static func genreMix(name: String,
                                 seeds: [String],
                                 using catalog: ITunesSearchClient) async -> PersonalMix? {
        var pool: [OnlineTrack] = []
        for artist in seeds {
            guard let resolved = await catalog.resolveArtist(name: artist, trackID: nil) else { continue }
            pool += await catalog.radioTracks(artistId: resolved.id, limit: 40)
        }

        var seen = Set<String>()
        let deduped = pool.filter { seen.insert($0.id).inserted }
        guard deduped.count >= minimumTracks else { return nil }

        // Deterministic in the scene and its seeds — not in the week. A genre
        // mix is supposed to be the same list until your taste moves.
        var rng = SplitMix64(seed: hashKey([name] + seeds))
        let tracks = Array(deduped.shuffled(using: &rng).prefix(trackCount))

        return PersonalMix(id: "genre:" + RecommendationEngine.normalize(name),
                           seedArtist: seeds.first ?? name,
                           title: "\(name) Mix",
                           subtitle: "Your \(name.lowercased()) corner — "
                                   + credits(of: tracks, excluding: "", limit: 2),
                           tracks: tracks,
                           covers: covers(of: tracks))
    }

    /// Resolve any artist the cache can't already place, up to the per-build
    /// budget, and return the placements for `artists`.
    private static func placeGenres(for artists: [String],
                                    using catalog: ITunesSearchClient) async -> [String: String] {
        let missing = artists
            .filter { ArtistGenreStore.genre(for: $0) == nil }
            .prefix(genreLookupsPerBuild)

        if !missing.isEmpty {
            var looked: [(artist: String, genre: String)] = []
            // Serial, not a task group: the gate would serialise them anyway,
            // and a group here just parks ten tasks on a one-per-second queue.
            var failures = 0
            lookups: for name in missing {
                switch await MusicBrainzGenres.genre(for: name) {
                case .genre(let genre): looked.append((name, genre)); failures = 0
                case .none:             looked.append((name, ""));    failures = 0
                case .unreachable:
                    // The service is down or blocked, not slow for this one
                    // artist. Two in a row is enough to stop paying a timeout
                    // per remaining name; next launch tries again.
                    failures += 1
                    if failures >= 2 { break lookups }
                }
            }
            ArtistGenreStore.storeAll(looked)
        }

        var placed: [String: String] = [:]
        for name in artists {
            guard let genre = ArtistGenreStore.genre(for: name) else { continue }
            placed[RecommendationEngine.normalize(name)] = genre
        }
        return placed
    }

    // MARK: - Radios

    /// A list called "Top 50" with 24 songs in it is a list that lied in its
    /// own title, so the chart radio keeps the whole chart.
    ///
    /// Fetched ten over the cap, because the dedupe runs *after* the fetch:
    /// Deezer ships the odd repeat in its chart, and a "Top 50" that came back
    /// with 49 songs is a title that doesn't match its own list.
    private static let chartRadioTracks = 50
    private static let sceneRadios = 4
    private static let artistRadios = 4
    private static let stationSchema: UInt64 = 2

    /// The non-personal shelf. Pinned weekly: the charts behind it move weekly
    /// too, and a radio that reshuffled on every visit would be a different
    /// radio every time you came back to it.
    static func stations(edition: UInt64, using catalog: ITunesSearchClient) async -> [PersonalMix] {
        // Bumped when the shelf's own rules change, so a week's pin built by
        // the old ones doesn't stand. 1: everything is a Radio, chart keeps 50.
        let key = edition &+ stationSchema
        if let pinned = MixEditionStore.loadList("stations", key: key) { return pinned }

        async let global = catalog.chartTracks(limit: chartRadioTracks + 10)
        async let genres = catalog.genres()
        async let chartArtists = catalog.chartArtists(limit: artistRadios)

        var out: [PersonalMix] = []
        if let top = mix(id: "station:global", title: "Top 50 Global",
                         subtitleText: "The 50 most-played songs in the world this week",
                         tracks: await global, cap: chartRadioTracks) {
            out.append(top)
        }

        // Scene radios, from the genres Deezer actually charts. Taken in the
        // order the API returns them so the shelf is the same shelf tomorrow.
        let scenes = Array(await genres.prefix(sceneRadios))
        out += await ordered(scenes) { genre in
            let tracks = await catalog.chartTracks(genreId: genre.id, limit: 50)
            return mix(id: "station:genre:\(genre.id)",
                       title: "\(genre.name) Radio",
                       subtitleText: "This week's biggest \(genre.name.lowercased()) — "
                                   + credits(of: tracks, excluding: "", limit: 2),
                       tracks: tracks)
        }

        // Artist radios off today's chart — the "Central Cee Radio" shape.
        let artists = await chartArtists
        out += await ordered(artists) { artist in
            let tracks = await catalog.radioTracks(artistId: artist.id, limit: 40)
            return mix(id: "station:artist:\(artist.id)",
                       title: "\(artist.name) Radio",
                       subtitleText: "\(artist.name) and the artists around them — "
                                   + credits(of: tracks, excluding: artist.name, limit: 2),
                       seedArtist: artist.name,
                       tracks: tracks)
        }

        if !out.isEmpty { MixEditionStore.saveList(out, name: "stations", key: key) }
        return out
    }

    // MARK: - Artist page stations

    /// The two stations an artist page carries.
    ///
    /// This is our answer to Spotify's "Appears On"/"Discovered on" shelves,
    /// which are made of playlists *other people* made. Nobody has made any
    /// here yet, so instead of an empty shelf the page offers the two lists
    /// that are worth making from what the page already fetched: the artist's
    /// own best songs, and Deezer's radio around them.
    ///
    /// Synchronous and free — both lists come out of the catalogue the page
    /// loaded, so the cards are there when the page is.
    static func artistStations(_ artist: OnlineArtist,
                               catalogue: OnlineArtistCatalogue) -> [PersonalMix] {
        var out: [PersonalMix] = []
        // A lower floor than a shelf mix: a small artist with six songs still
        // has a "This Is", and it is the most useful thing on their page.
        if let thisIs = mix(id: "artist:this-is:\(artist.id)",
                            title: "This Is \(artist.name)",
                            subtitleText: "\(artist.name)'s biggest songs, most played first",
                            seedArtist: artist.name,
                            tracks: catalogue.top,
                            cap: 50,
                            floor: 4) {
            out.append(thisIs)
        }
        if let radio = mix(id: "artist:radio:\(artist.id)",
                           title: "\(artist.name) Radio",
                           subtitleText: "\(artist.name) and the artists around them — "
                                       + credits(of: catalogue.radio, excluding: artist.name, limit: 2),
                           seedArtist: artist.name,
                           tracks: catalogue.radio,
                           cap: 50) {
            out.append(radio)
        }
        // "Appears on" as a record rather than a list: it is a playlist by
        // definition — other people's songs that credit this artist — and as a
        // card it plays, saves and downloads like any other mix.
        if let appears = mix(id: "artist:appears-on:\(artist.id)",
                             title: "Featuring \(artist.name)",
                             subtitleText: "Songs by other artists that credit \(artist.name)",
                             seedArtist: artist.name,
                             tracks: catalogue.appearsOn,
                             cap: 60,
                             floor: 3) {
            out.append(appears)
        }
        return out
    }

    // MARK: - Helpers

    /// Build each item concurrently, keep the input's order, drop the nils.
    /// A shelf whose cards reshuffle by whichever request answered first isn't
    /// the shelf that was pinned.
    private static func ordered<T: Sendable>(_ items: [T],
                                             _ make: @escaping @Sendable (T) async -> PersonalMix?)
                                             async -> [PersonalMix] {
        await withTaskGroup(of: (Int, PersonalMix?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await make(item)) }
            }
            var slots: [Int: PersonalMix] = [:]
            for await (index, mix) in group { slots[index] = mix }
            return (0..<items.count).compactMap { slots[$0] }
        }
    }

    private static func mix(id: String,
                            title: String,
                            subtitleText: String?,
                            seedArtist: String = "",
                            tracks: [OnlineTrack],
                            cap: Int = trackCount,
                            floor: Int = minimumTracks) -> PersonalMix? {
        var seen = Set<String>()
        let deduped = tracks.filter { seen.insert($0.id).inserted }
        guard deduped.count >= floor else { return nil }
        let picks = Array(deduped.prefix(cap))
        return PersonalMix(id: id,
                           seedArtist: seedArtist,
                           title: title,
                           subtitle: subtitleText ?? credits(of: picks, excluding: seedArtist, limit: 3),
                           tracks: picks,
                           covers: covers(of: picks))
    }

    /// "A, B and more" — the same shape the artist mixes' line has.
    private static func credits(of tracks: [OnlineTrack], excluding seed: String, limit: Int) -> String {
        var seen = Set<String>()
        let names = tracks
            .flatMap { ImportService.creditedArtists(from: $0.artistName) }
            .filter { RecommendationEngine.normalize($0) != RecommendationEngine.normalize(seed) }
            .filter { seen.insert(RecommendationEngine.normalize($0)).inserted }
            .prefix(limit)
        return names.isEmpty ? "\(tracks.count) songs" : names.joined(separator: ", ") + " and more"
    }

    /// Stable across launches — Swift's own hashing is per-process seeded and
    /// would repin on every relaunch.
    private static func hashKey(_ parts: [String]) -> UInt64 {
        RecommendationEngine.hash(parts.joined(separator: "|"))
    }

    private static func covers(of tracks: [OnlineTrack]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for track in tracks {
            guard let url = track.artworkURL, seen.insert(url.absoluteString).inserted else { continue }
            out.append(url)
            if out.count == 4 { break }
        }
        return out
    }

}
