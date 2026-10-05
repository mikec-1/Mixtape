// Two shelves beyond the per-artist mixes.
// Genre mixes: your library sorted into a fixed list of scenes (GenreBuckets)
// by MusicBrainz tags or Apple's genre, drawn from your own artists' radios.
// Radios: chart, scene and artist stations, independent of your library, so an
// empty account still gets a full page.
// Both are stored once a week per account (`MixEditionStore`).

import Foundation

/// Artist -> genre tags, on disk and pooled through the account's
/// placements row, so each artist is looked up once per account, not per device.
enum ArtistGenreStore {

    /// Normalised artist -> well-supported tags, most votes first. Empty means
    /// "asked, no answer", kept so it isn't looked up again.
    private(set) static var entries: [String: [String]] = load()

    static func tags(for artist: String) -> [String]? {
        entries[RecommendationEngine.normalize(artist)]
    }

    /// Takes in what other devices placed.
    static func pull() async {
        guard let remote = await MixEditionStore.placements() else { return }
        let merged = entries.merging(remote) { local, _ in local }
        guard merged.count != entries.count else { return }
        entries = merged
        save()
    }

    static func store(_ learned: [String: [String]]) async {
        guard !learned.isEmpty else { return }
        entries.merge(learned) { _, new in new }
        save()
        await MixEditionStore.addPlacements(learned)
    }

    static func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: url)
    }

    private static func save() {
        try? FileManager.default.createDirectory(at: MixEditionStore.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static var url: URL { MixEditionStore.directory.appendingPathComponent("artist-tags.3.json") }
}

/// The fixed scenes genre mixes are built from. The web has the same table in
/// src/lib/genreBuckets.ts; change both together.
enum GenreBuckets {

    /// Languages a Hip Hop or Pop artist's lyrics are checked for. Each has common words that aren't
    /// English or another listed language's, and the countries used when a song has no lyrics.
    static let languages: [(name: String, countries: [String], words: Set<String>)] = [
        ("German", "DE AT", "ich du und nicht der das mit auf bin ist mein dein wir sie wie auch noch nur kein keine ein eine für von zu dem mir dich mich hab habe wenn weil aber jetzt immer"),
        ("French", "FR", "je nous vous est pas les des une avec dans moi toi suis ça sur comme tout fait ai mes ce elle sont quand rien trop j qu vais veux faut"),
        ("Spanish", "ES MX AR CO CL PE", "el los las es pero estoy eres soy muy quiero quieres cuando tengo ella ahora siempre también hay hasta así mucho noche contigo tú eso esto estás tiene puedo nadie dime pa sé"),
        ("Italian", "IT", "io che non sono della gli ho questo perché sei anche tutto cosa ancora adesso voglio nella lei lui mio mia sto fare tutti più così dove niente qua"),
        ("Portuguese", "BR PT", "eu não você uma com muito ela isso tudo meu minha sou estou agora nós também pra tô vai então é"),
        ("Dutch", "NL", "ik niet het een zijn maar mijn jij wij ook nog voor naar heb weet hij mij jou niks gaat waarom"),
        ("Turkish", "TR", "bir bu ben sen ile için çok gibi var yok daha ama beni seni benim senin değil şey kadar olan oldu mı bana sana hep yine artık hiç kim neden"),
        ("Polish", "PL", "nie się jest że jak ty mnie ale tak już tylko był jestem mam moje gdy więc tego mój wiesz chcę nigdy zawsze kiedy nic czy"),
        ("Russian", "RU", "я ты не и в на что это как мне меня тебя он она мы вы все так но да нет мой моя"),
    ].map { (name: String, countries: String, words: String) in
        (name, countries.components(separatedBy: " "), Set(words.components(separatedBy: " ")))
    }

    /// Buckets split by language, with the tag and name each split uses: German Hip Hop is "german hip hop", "German Rap".
    static let languageScenes: [(parent: String, tag: String, name: String)] = [
        ("Hip Hop", "hip hop", "Rap"),
        ("Pop", "pop", "Pop"),
    ]

    private static let languageRules: [(keyword: String, bucket: String)] = languages.flatMap { language in
        languageScenes.map { ("\(language.name.lowercased()) \($0.tag)", "\(language.name) \($0.name)") }
    }

    /// Tag keyword -> bucket. First match wins, so narrow keywords come before the
    /// ones they contain ("reggaeton" before "reggae", "dancehall" before "dance").
    static let rules: [(keyword: String, bucket: String)] = narrowRules + languageRules + broadRules

    private static let narrowRules: [(keyword: String, bucket: String)] = [
        ("drill", "Drill"),
        ("grime", "Grime"),
        ("uk garage", "UK Garage"), ("2-step", "UK Garage"), ("speed garage", "UK Garage"), ("bassline", "UK Garage"),
        ("uk hip hop", "UK Rap"), ("british hip hop", "UK Rap"), ("uk rap", "UK Rap"), ("road rap", "UK Rap"),
    ]

    private static let broadRules: [(keyword: String, bucket: String)] = [
        ("deutschrap", "German Rap"),
        ("afrobeat", "Afrobeats"), ("afropop", "Afrobeats"), ("afroswing", "Afrobeats"), ("afro-fusion", "Afrobeats"),
        ("amapiano", "Afrobeats"),
        ("k-pop", "K-Pop"),
        ("drum and bass", "Drum & Bass"), ("jungle", "Drum & Bass"), ("liquid funk", "Drum & Bass"),
        ("neurofunk", "Drum & Bass"),
        ("reggaeton", "Latin"), ("latin", "Latin"), ("bachata", "Latin"), ("salsa", "Latin"), ("cumbia", "Latin"),
        ("corrido", "Latin"), ("dembow", "Latin"),
        ("dancehall", "Reggae/Dancehall"), ("reggae", "Reggae/Dancehall"), ("ragga", "Reggae/Dancehall"),
        ("r&b", "R&B"), ("rhythm and blues", "R&B"), ("soul", "Soul"),
        ("trap", "Hip Hop"), ("hip hop", "Hip Hop"), ("hip-hop", "Hip Hop"), ("rap", "Hip Hop"), ("boom bap", "Hip Hop"),
        ("dance-pop", "Pop"), ("electropop", "Pop"),
        ("house", "Dance/House"), ("disco", "Dance/House"), ("dance", "Dance/House"), ("edm", "Dance/House"),
        ("techno", "Electronic"), ("dubstep", "Electronic"), ("trance", "Electronic"), ("ambient", "Electronic"),
        ("electro", "Electronic"), ("idm", "Electronic"), ("synthwave", "Electronic"),
        ("metal", "Metal"),
        ("indie", "Indie"), ("shoegaze", "Indie"), ("dream pop", "Indie"), ("bedroom pop", "Indie"),
        ("alternative", "Indie"),
        ("punk", "Rock"), ("rock", "Rock"), ("grunge", "Rock"),
        ("jazz", "Jazz"), ("bebop", "Jazz"),
        ("country", "Country"), ("americana", "Country"), ("bluegrass", "Country"),
        ("pop", "Pop"),
    ]

    /// A narrow bucket beats its parent when both are among an artist's tags.
    static let parents: [String: String] = [
        "Drill": "Hip Hop", "Grime": "Hip Hop", "UK Rap": "Hip Hop",
        "UK Garage": "Dance/House", "Drum & Bass": "Electronic", "K-Pop": "Pop",
    ].merging(languages.flatMap { language in
        languageScenes.map { ("\(language.name) \($0.name)", $0.parent) }
    }) { own, _ in own }

    static func bucket(forTag tag: String) -> String? {
        rules.first { tag.contains($0.keyword) }?.bucket
    }

    /// The top tag's bucket, or a narrower one under it that's also well supported.
    static func bucket(for tags: [String]) -> String? {
        let buckets = tags.compactMap(bucket(forTag:))
        guard let primary = buckets.first else { return nil }
        return buckets.first { parents[$0] == primary } ?? primary
    }

    /// The listed language most of the lyrics' words belong to, or nil for English and anything unlisted.
    static func lyricsLanguage(_ lyrics: String) -> String? {
        let words = lyrics.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return nil }
        var best: (name: String, share: Double)?
        for language in languages {
            let share = Double(words.filter(language.words.contains).count) / Double(words.count)
            // A listed language's words are 10 to 35% of its lyrics and 1% at most of English ones.
            if share >= 0.05, share > best?.share ?? 0 { best = (language.name, share) }
        }
        return best?.name
    }

    static func countryLanguage(_ country: String?) -> String? {
        languages.first { $0.countries.contains(country ?? "") }?.name
    }
}

/// An artist's genre tags: MusicBrainz, or Apple's genre when it has none. Hip Hop and Pop
/// artists also get a language scene. Only called for artists not already placed.
enum ArtistGenres {

    private struct SearchResponse: Decodable {
        struct Artist: Decodable { let id: String; let name: String }
        let artists: [Artist]
    }

    private struct RecordingResponse: Decodable {
        struct Credit: Decodable { let name: String; let artist: SearchResponse.Artist }
        struct Recording: Decodable {
            let credits: [Credit]?
            private enum CodingKeys: String, CodingKey { case credits = "artist-credit" }
        }
        let recordings: [Recording]
    }

    private struct ArtistResponse: Decodable {
        struct Genre: Decodable { let name: String; let count: Int? }
        let genres: [Genre]?
        let country: String?
    }

    private struct AppleResponse: Decodable {
        struct Result: Decodable { let artistId: Int?; let artistName: String?; let primaryGenreName: String? }
        let results: [Result]
    }

    private struct LyricsResult: Decodable { let artistName: String?; let plainLyrics: String? }

    /// `tags`, even empty, is an answer and gets stored. `unreachable` never is.
    enum Lookup { case tags([String]), unreachable }

    /// `title` is one of the artist's songs from the library. Many artists share a name
    /// (Luciano, Dave), and the song picks the right one.
    static func tags(for artist: String, title: String?) async -> Lookup {
        guard let found = await musicBrainz(artist, title: title) else { return .unreachable }
        var tags = found.tags
        if tags.isEmpty {
            guard let genre = await appleGenre(artist, title: title) else { return .unreachable }
            if !genre.isEmpty { tags = [genre] }
        }

        // Hip hop and pop split by the language of that song ("german hip hop"), or the country without lyrics.
        // ponytail: one song decides, so a multilingual artist lands by the song in your library.
        let bucket = GenreBuckets.bucket(for: tags)
        guard let scene = GenreBuckets.languageScenes.first(where: { $0.parent == bucket }) else { return .tags(tags) }
        var lyrics = ""
        if let title {
            guard let found = await lyricsFor(artist, title: title) else { return .unreachable }
            lyrics = found
        }
        let language = lyrics.isEmpty ? GenreBuckets.countryLanguage(found.country) : GenreBuckets.lyricsLanguage(lyrics)
        return .tags(language.map { tags + ["\($0.lowercased()) \(scene.tag)"] } ?? tags)
    }

    /// Well-supported tags and the artist's country. No tags when MusicBrainz doesn't know them, nil when unreachable.
    private static func musicBrainz(_ artist: String, title: String?) async -> (tags: [String], country: String?)? {
        var found = Found.none
        if let title { found = await searchRecording(title, by: artist) }
        if found == .none { found = await search(artist) }
        switch found {
        case .unreachable: return nil
        case .none: return ([], nil)
        case .id(let mbid):
            guard let url = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=genres&fmt=json")
            else { return ([], nil) }
            guard let response: ArtistResponse = await getJSON(url) else { return nil }
            return (supported(response.genres ?? []), response.country)
        }
    }

    /// Apple's genre for the artist, lowercased like a tag. Empty when it has none, nil when unreachable.
    /// The artist's genre, not a song's: a label can file one release under Rock.
    private static func appleGenre(_ artist: String, title: String?) async -> String? {
        let key = RecommendationEngine.normalize(artist)
        func apple(_ path: String, _ query: [String: String]) async -> [AppleResponse.Result]? {
            guard let url = url("https://itunes.apple.com/\(path)", query) else { return [] }
            guard let response: AppleResponse = await getJSON(url, gated: false) else { return nil }
            return response.results.filter { RecommendationEngine.normalize($0.artistName ?? "") == key }
        }
        // Found by one of their songs, for the same reason as MusicBrainz (capré and Capre fold the same).
        var songs: [AppleResponse.Result] = []
        if let title {
            guard let found = await apple("search", ["term": "\(artist) \(title)", "entity": "song", "limit": "10"])
            else { return nil }
            songs = found
        }
        let artists = if let id = songs.first?.artistId {
            await apple("lookup", ["id": String(id)])
        } else {
            await apple("search", ["term": artist, "entity": "musicArtist", "limit": "10"])
        }
        guard let artists else { return nil }
        return artists.first?.primaryGenreName?.lowercased() ?? ""
    }

    /// The song's plain lyrics. Empty when LRCLIB has none, nil when it couldn't be reached.
    private static func lyricsFor(_ artist: String, title: String) async -> String? {
        guard let url = url("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist])
        else { return "" }
        guard let results: [LyricsResult] = await getJSON(url, gated: false) else { return nil }
        let key = RecommendationEngine.normalize(artist)
        let match = results.first {
            !($0.plainLyrics ?? "").isEmpty && RecommendationEngine.normalize($0.artistName ?? "").contains(key)
        }
        return match?.plainLyrics ?? ""
    }

    private enum Found: Equatable { case id(String), none, unreachable }

    private static func search(_ artist: String) async -> Found {
        let query = artist.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !query.isEmpty,
              let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&fmt=json&limit=1")
        else { return .none }
        guard let response: SearchResponse = await getJSON(url) else { return .unreachable }
        // Exact name match only, or the wrong artist's scene becomes theirs.
        guard let first = response.artists.first,
              RecommendationEngine.normalize(first.name) == RecommendationEngine.normalize(artist)
        else { return .none }
        return .id(first.id)
    }

    /// The artist credited on one of their songs. Matches the credited name too,
    /// since MusicBrainz lists some artists under a newer one (Kanye West is "Ye").
    private static func searchRecording(_ title: String, by artist: String) async -> Found {
        let quoted = { (text: String) in
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let query = ("recording:" + quoted(title) + " AND artist:" + quoted(artist))
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording?query=\(query)&fmt=json&limit=5")
        else { return .none }
        guard let response: RecordingResponse = await getJSON(url) else { return .unreachable }
        let key = RecommendationEngine.normalize(artist)
        let credit = response.recordings.lazy.flatMap { $0.credits ?? [] }.first {
            RecommendationEngine.normalize($0.name) == key || RecommendationEngine.normalize($0.artist.name) == key
        }
        return credit.map { .id($0.artist.id) } ?? .none
    }

    /// Tags with at least half the top tag's votes, most votes first. Same rule as the web.
    private static func supported(_ genres: [ArtistResponse.Genre]) -> [String] {
        let ranked = genres.sorted {
            ($0.count ?? 0) == ($1.count ?? 0) ? $0.name < $1.name : ($0.count ?? 0) > ($1.count ?? 0)
        }
        guard let top = ranked.first else { return [] }
        let floor = max(1, (top.count ?? 1) / 2)
        return ranked.filter { ($0.count ?? 0) >= floor }.map { $0.name.lowercased() }
    }

    // MARK: Transport

    /// MusicBrainz enforces one request a second; one shared gate queues lookups.
    /// Apple and LRCLIB don't need it.
    private static let gate = RequestGate(spacing: 1.05)

    private static func url(_ base: String, _ query: [String: String]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    private static func getJSON<T: Decodable>(_ url: URL, gated: Bool = true) async -> T? {
        if gated { await gate.waitForSlot() }
        var request = URLRequest(url: url)
        request.setValue("Mixtape/1.0 ( https://mixtaped.tech )", forHTTPHeaderField: "User-Agent")
        // Short, so an unreachable service fails fast instead of stalling the shelf.
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

}

enum StationBuilder {

    /// Under this a mix isn't a mix. Same floor the artist mixes use.
    private static let minimumTracks = 8
    private static let trackCount = 24

    // MARK: - Genre mixes

    /// Artists placed per build. Two gated MusicBrainz requests each; placements
    /// are shared through the account, so the shelf fills in over a few launches.
    private static let genreLookupsPerBuild = 40
    /// Two artists sharing a scene is a cluster; one is a coincidence.
    private static let minimumArtistsPerGenre = 2
    private static let maxGenreMixes = 8

    /// Nil when there's nothing to show. `complete` is false while artists are
    /// still unplaced or a scene failed to build, so the week isn't locked in early.
    /// `titles` maps a normalised artist to one of their songs, for the lookup.
    static func genreMixes(artists: [String],
                           titles: [String: String],
                           using catalog: ITunesSearchClient) async -> (value: [PersonalMix], complete: Bool)? {
        guard artists.count >= minimumArtistsPerGenre else { return nil }
        let allPlaced = await placeGenres(for: artists, titles: titles)

        let placed = artists.compactMap { artist in
            ArtistGenreStore.tags(for: artist).flatMap(GenreBuckets.bucket(for:)).map { (artist, $0) }
        }
        let sizes = Dictionary(placed.map { ($0.1, 1) }, uniquingKeysWith: +)
        // Keeps incoming order, so each scene is seeded by its most-played artists.
        var byGenre: [String: [String]] = [:]
        for (artist, bucket) in placed {
            // A scene with one of your artists joins its parent, so a lone French rapper still plays in Hip Hop.
            var scene = bucket
            if let parent = GenreBuckets.parents[bucket], sizes[bucket, default: 0] < minimumArtistsPerGenre { scene = parent }
            byGenre[scene, default: []].append(artist)
        }

        let clusters = byGenre
            .filter { $0.value.count >= minimumArtistsPerGenre }
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(maxGenreMixes)
        guard !clusters.isEmpty else { return nil }

        let built = await ordered(Array(clusters)) { cluster in
            await genreMix(name: cluster.key,
                           seeds: Array(cluster.value.prefix(3)),
                           using: catalog)
        }
        guard !built.isEmpty else { return nil }
        return (built, allPlaced && built.count == clusters.count)
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

        // Seeded by scene and artists, not the week.
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

    /// Looks up unplaced artists up to the per-build budget. True when every
    /// artist in `artists` has an answer.
    private static func placeGenres(for artists: [String], titles: [String: String]) async -> Bool {
        await ArtistGenreStore.pull()
        let missing = artists.filter { ArtistGenreStore.tags(for: $0) == nil }
        guard !missing.isEmpty else { return true }

        var learned: [String: [String]] = [:]
        // Serial: the gate serialises them anyway.
        var failures = 0
        lookups: for name in missing.prefix(genreLookupsPerBuild) {
            switch await ArtistGenres.tags(for: name, title: titles[RecommendationEngine.normalize(name)]) {
            case .tags(let tags):
                learned[RecommendationEngine.normalize(name)] = tags
                failures = 0
            case .unreachable:
                // Two failures in a row means the service is down; stop and retry next launch.
                failures += 1
                if failures >= 2 { break lookups }
            }
        }
        await ArtistGenreStore.store(learned)
        return learned.count == Set(missing.map(RecommendationEngine.normalize)).count
    }

    // MARK: - Radios

    /// The chart radio keeps the whole chart. Fetched with headroom since dedupe
    /// runs after the fetch.
    private static let chartRadioTracks = 50
    private static let sceneRadios = 4
    private static let artistRadios = 4

    /// The non-personal shelf. Stored weekly, like the charts behind it.
    static func stations(using catalog: ITunesSearchClient) async -> [PersonalMix] {
        async let global = catalog.chartTracks(limit: chartRadioTracks + 10)
        async let genres = catalog.genres()
        async let chartArtists = catalog.chartArtists(limit: artistRadios)

        var out: [PersonalMix] = []
        if let top = mix(id: "station:global", title: "Top 50 Global",
                         subtitleText: "The 50 most-played songs in the world this week",
                         tracks: await global, cap: chartRadioTracks) {
            out.append(top)
        }

        // Scene radios in API order, so the shelf is stable day to day.
        let scenes = Array(await genres.prefix(sceneRadios))
        out += await ordered(scenes) { genre in
            let tracks = await catalog.chartTracks(genreId: genre.id, limit: 50)
            return mix(id: "station:genre:\(genre.id)",
                       title: "\(genre.name) Radio",
                       subtitleText: "This week's biggest \(genre.name.lowercased()) — "
                                   + credits(of: tracks, excluding: "", limit: 2),
                       tracks: tracks)
        }

        // Artist radios off today's chart.
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

        return out
    }

    // MARK: - Song radio

    /// "Go to Song Radio". Deezer has no track radio, so each credited artist gets
    /// a radio and the lists are interleaved.
    /// ponytail: artist-level seeding; a real track-radio endpoint would replace the body.
    static func songRadio(title: String,
                          artistName: String,
                          using catalog: ITunesSearchClient) async -> PersonalMix? {
        // `names` because a local `credits` would shadow the helper below.
        let names = Array(ImportService.creditedArtists(from: artistName).prefix(3))
        guard let seed = names.first, !title.isEmpty else { return nil }

        let lists: [[OnlineTrack]] = await withTaskGroup(of: (Int, [OnlineTrack]).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask { (index, await catalog.deepRadioTracks(forArtist: name, limit: 40)) }
            }
            var slots: [Int: [OnlineTrack]] = [:]
            for await (index, list) in group { slots[index] = list }
            return (0..<names.count).map { slots[$0] ?? [] }
        }

        var pooled: [OnlineTrack] = []
        var depth  = 0
        while lists.contains(where: { $0.count > depth }) {
            for list in lists where list.count > depth { pooled.append(list[depth]) }
            depth += 1
        }

        return mix(id: "station:song:\(hashKey([title, seed]))",
                   title: "\(title) Radio",
                   subtitleText: "Songs like \u{201C}\(title)\u{201D} — "
                               + credits(of: pooled, excluding: seed, limit: 2),
                   seedArtist: seed,
                   tracks: pooled,
                   cap: 50)
    }

    /// "radio <artist>" from ⌘K, for any name the catalogue knows.
    static func artistRadio(name: String, using catalog: ITunesSearchClient) async -> PersonalMix? {
        let tracks = await catalog.deepRadioTracks(forArtist: name, limit: 50)
        return mix(id: "station:artist-name:\(hashKey([name.lowercased()]))",
                   title: "\(name) Radio",
                   subtitleText: "\(name) and the artists around them \u{2014} "
                               + credits(of: tracks, excluding: name, limit: 2),
                   seedArtist: name,
                   tracks: tracks,
                   cap: 50)
    }

    // MARK: - Artist page stations

    /// The two stations on an artist page ("This Is" and "Appears On"). Built
    /// synchronously from the catalogue the page already loaded.
    static func artistStations(_ artist: OnlineArtist,
                               catalogue: OnlineArtistCatalogue) -> [PersonalMix] {
        var out: [PersonalMix] = []
        // Lower floor than shelf mixes, so small artists still get a "This Is".
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
        // "Appears On" as a mix so it plays, saves and downloads like any other.
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

    /// Builds items concurrently but keeps input order and drops nils, so a pinned
    /// shelf doesn't reshuffle.
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

    /// "A, B and more", same shape as the artist mixes.
    private static func credits(of tracks: [OnlineTrack], excluding seed: String, limit: Int) -> String {
        var seen = Set<String>()
        let names = tracks
            .flatMap { ImportService.creditedArtists(from: $0.artistName) }
            .filter { RecommendationEngine.normalize($0) != RecommendationEngine.normalize(seed) }
            .filter { seen.insert(RecommendationEngine.normalize($0)).inserted }
            .prefix(limit)
        return names.isEmpty ? "\(tracks.count) songs" : names.joined(separator: ", ") + " and more"
    }

    /// Stable across launches, unlike Swift's per-process seeded hashing.
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
