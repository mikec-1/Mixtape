// Builds the Discover landing page from what you listen to. Deezer has no
// per-user recommendations, so this seeds per-artist radio and related artists
// with your most played artists (from ListeningStatsService): mixes around your
// regulars, recommended songs from their neighbourhood, new artists, and their
// recent releases.
// Every fetch fails soft to empty, so a failure costs one row, not the page.

import Foundation

// MARK: - Models

/// One "Artist Mix" card: a radio built around a seed artist you play a lot.
public struct PersonalMix: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// The artist this was built from, as it appears in your listening history.
    public let seedArtist: String
    public let title: String
    /// "Travis Scott, Future, Metro Boomin and more".
    public let subtitle: String
    public let tracks: [OnlineTrack]
    /// Up to four distinct artworks, for the 2x2 mosaic the card draws.
    public let covers: [URL]

    /// The artists `subtitle` names, so the header can link each one. Derived so
    /// old pinned snapshots still decode.
    var featured: [String] {
        var seen = Set<String>()
        return tracks.flatMap { ImportService.creditedArtists(from: $0.artistName) }
            .filter { RecommendationEngine.normalize($0) != RecommendationEngine.normalize(seedArtist) }
            .filter { seen.insert(RecommendationEngine.normalize($0)).inserted }
            .prefix(3)
            .map { $0 }
    }
}

/// "Because you listened to <artist>": artists with an overlapping audience.
public struct RelatedArtistRow: Identifiable, Sendable {
    public let id: String
    public let seedArtist: String
    public let artists: [OnlineArtist]
}

/// The "New release from <artist>" hero: one recent record plus the artist.
public struct FreshRelease: Identifiable, Sendable {
    public let album: OnlineAlbum
    public let artist: OnlineArtist
    public var id: Int { album.id }

    public init(album: OnlineAlbum, artist: OnlineArtist) {
        self.album = album
        self.artist = artist
    }
}

/// Everything the personalized part of the landing page needs.
public struct PersonalLanding: Sendable {

    public var seeds: [String]
    public var mixes: [PersonalMix]
    /// The hero beside "Your mixes". Nil when none of your artists released
    /// anything lately.
    public var newRelease: FreshRelease?
    /// Oversized on purpose. "Recommended songs" shows a window onto it, so
    /// refreshing needs no new request.
    public var recommendedPool: [OnlineTrack]
    public var related: [RelatedArtistRow]
    public var freshReleases: [OnlineAlbum]
    /// "Release Radar": songs off your artists' recent records, newest first.
    /// Nil when nothing was released in the window.
    public var releaseRadar: PersonalMix?
    /// Your library clustered by genre ("Rap/Hip Hop Mix"). Not weekly; holds
    /// until the cluster moves.
    public var genreMixes: [PersonalMix]
    /// Charts, scenes and artist radios. Independent of the library, so a new
    /// account still gets a full page.
    public var stations: [PersonalMix]
    /// Identifies the taste this was built from. Changing top artists rebuilds
    /// the page even within its TTL.
    public var fingerprint: String

    public static let empty = PersonalLanding(seeds: [], mixes: [], newRelease: nil,
                                              recommendedPool: [], related: [],
                                              freshReleases: [], releaseRadar: nil,
                                              genreMixes: [], stations: [],
                                              fingerprint: "")

    public var isEmpty: Bool {
        mixes.isEmpty && recommendedPool.isEmpty && related.isEmpty
            && freshReleases.isEmpty && newRelease == nil && releaseRadar == nil
            && genreMixes.isEmpty && stations.isEmpty
    }

    /// The line under "Made for you" naming the seeds, or nil when there are none.
    public func builtFromSubtitle(limit: Int) -> String? {
        let named = seeds.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty else { return nil }
        return "Built from \(named.prefix(limit).joined(separator: ", ")) and the rest of your listening history."
    }

    /// Without anything "Don't suggest" covers. The stored shelves come from
    /// whichever device built them first, so each device filters on display.
    public func filtered() -> PersonalLanding {
        let songs = SuggestionFeedback.filteredSongs, artists = SuggestionFeedback.blockedArtists
        guard !songs.isEmpty || !artists.isEmpty else { return self }
        let blocked = { (name: String) in artists.contains(ArtistAliases.fold(name)) }
        let allowed = { (track: OnlineTrack) in
            SuggestionFeedback.allows(title: track.title, artist: track.artistName, songs: songs, artists: artists)
        }
        func clean(_ mix: PersonalMix) -> PersonalMix {
            PersonalMix(id: mix.id, seedArtist: mix.seedArtist, title: mix.title, subtitle: mix.subtitle,
                        tracks: mix.tracks.filter(allowed), covers: mix.covers)
        }

        var out = self
        out.mixes = mixes.filter { !blocked($0.seedArtist) }.map(clean)
        out.recommendedPool = recommendedPool.filter(allowed)
        out.related = related.filter { !blocked($0.seedArtist) }.map { row in
            RelatedArtistRow(id: row.id, seedArtist: row.seedArtist, artists: row.artists.filter { !blocked($0.name) })
        }
        out.freshReleases = freshReleases.filter { !blocked($0.artistName) }
        if let hero = newRelease, blocked(hero.artist.name) { out.newRelease = nil }
        out.releaseRadar = releaseRadar.map(clean)
        // A genre mix is the scene, not its first artist, so only its songs are filtered.
        out.genreMixes = genreMixes.map(clean)
        out.stations = stations.filter { $0.seedArtist.isEmpty || !blocked($0.seedArtist) }.map(clean)
        return out
    }

    /// The visible slice of recommendedPool for a refresh roll. Deterministic, so
    /// scrolling away and back doesn't reshuffle.
    public func recommended(roll: Int, count: Int = 12) -> [OnlineTrack] {
        guard !recommendedPool.isEmpty else { return [] }
        guard recommendedPool.count > count else { return recommendedPool }
        guard roll > 0 else { return Array(recommendedPool.prefix(count)) }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(roll)) &+ 0x9E37_79B9_7F4A_7C15)
        return Array(recommendedPool.shuffled(using: &rng).prefix(count))
    }
}

// MARK: - Engine

public enum RecommendationEngine {

    /// Past six the extra requests aren't worth it; seeds become artists you
    /// played twice.
    nonisolated public static let maxSeeds = 6

    /// Under three cards "Your mixes" looks broken. The build tops up from
    /// related artists instead (see toppedUp).
    static let minimumMixes = 3

    /// A mix shorter than this is dropped.
    nonisolated private static let mixMinimumTracks = 8

    /// Songs per mix. The radio is fetched deeper so each weekly edition can be a
    /// different selection.
    private static let mixTrackCount = 24

    // MARK: Editions

    /// The weekly edition a date falls in. Taste changes rebuild immediately via
    /// the seeds. Plain arithmetic, not Calendar, so it ignores locale. 1970-01-01
    /// was a Thursday; the four-day shift puts the rollover at Monday 00:00 UTC.
    public static func edition(for date: Date = Date()) -> UInt64 {
        let week: TimeInterval = 7 * 24 * 60 * 60
        let shifted = date.timeIntervalSince1970 + 4 * 24 * 60 * 60
        return UInt64(max(0, (shifted / week).rounded(.down)))
    }

    /// What the page was built from: the seed set and the week. Shared by the
    /// store's staleness check and the build. Sorted, so reordering your top
    /// artists doesn't rebuild the page.
    public static func fingerprint(seeds: [String], at date: Date = Date()) -> String {
        seeds.prefix(maxSeeds).map(normalize).sorted().joined(separator: "|")
            + "#\(edition(for: date))"
    }

    // MARK: Seeding

    /// Seed artists, best first: the last month, topped up from all time, then
    /// from the library. The library goes last since imports are a weaker signal
    /// than plays, but it keeps a one-artist history from producing one mix.
    @MainActor
    public static func seeds(stats: ListeningStatsService,
                             library: LibraryService,
                             limit: Int = maxSeeds) -> [String] {
        // Home asks every time it appears and each ask scans the play log twice.
        // Seeds only steer the week's mixes, so a few minutes old is fine.
        let blocked = SuggestionFeedback.blockedArtists
        if let c = seedCache, c.limit == limit, c.blocked == blocked,
           Date().timeIntervalSince(c.at) < 300 { return c.seeds }

        var ordered: [String] = []
        var seen = Set<String>()

        func add(_ name: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.lowercased() != "unknown artist" else { return }
            guard !SuggestionFeedback.isBlocked(artist: clean) else { return }
            guard seen.insert(clean.lowercased()).inserted else { return }
            ordered.append(clean)
        }

        for artist in stats.compute(period: .last30Days).topArtists.prefix(3) { add(artist.name) }
        for artist in stats.compute(period: .allTime).topArtists.prefix(limit)  { add(artist.name) }

        if ordered.count < limit {
            // Library artists ranked by track count, filling the remaining slots.
            let counts = Dictionary(grouping: library.tracks, by: { $0.artistName })
                .mapValues(\.count)
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            for (name, _) in counts {
                add(name)
                if ordered.count >= limit { break }
            }
        }

        let result = Array(ordered.prefix(limit))
        seedCache = (limit, blocked, Date(), result)
        return result
    }

    @MainActor private static var seedCache: (limit: Int, blocked: Set<String>, at: Date, seeds: [String])?

    /// How many library artists the radar checks. Two requests each through the
    /// shared Deezer gate, so more would delay everything else.
    nonisolated public static let maxRadarSeeds = 12

    /// Wider than the radar. Scenes are narrow ("uk drill"), so a big library
    /// only shows its shape once enough artists are placed.
    public static let maxGenreSeeds = 90

    /// Every library artist, most-owned first. Credits are split, so "Dave,
    /// Stormzy" asks about two artists.
    @MainActor
    public static func radarSeeds(library: LibraryService,
                                  limit: Int = maxRadarSeeds) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for track in library.tracks {
            for name in ImportService.creditedArtists(from: track.artistName) {
                let key = name.lowercased()
                guard !key.isEmpty, key != "unknown artist" else { continue }
                guard !SuggestionFeedback.isBlocked(artist: name) else { continue }
                var entry = counts[key] ?? (name, 0)
                entry.count += 1
                counts[key] = entry
            }
        }
        return counts.values
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(limit)
            .map(\.name)
    }

    /// Normalised artist -> one of their songs, so the genre lookup can tell
    /// artists who share a name apart.
    @MainActor
    public static func seedTitles(library: LibraryService) -> [String: String] {
        var titles: [String: String] = [:]
        for track in library.tracks {
            for name in ImportService.creditedArtists(from: track.artistName) where titles[normalize(name)] == nil {
                titles[normalize(name)] = ImportService.bareTitle(track.title)
            }
        }
        return titles
    }

    /// title|artist keys for the library, so recommendations skip songs you own.
    @MainActor
    public static func knownKeys(library: LibraryService) -> Set<String> {
        Set(library.tracks.map { normalize($0.title) + "|" + normalize($0.artistName) })
    }

    // MARK: Building

    /// Fetches and assembles the landing. About 15 requests for five seeds, run
    /// concurrently. The caller caches it behind a TTL.
    public static func build(seeds: [String],
                             radarSeeds: [String] = [],
                             excluding known: Set<String> = [],
                             using catalog: ITunesSearchClient) async -> PersonalLanding {
        let seeds = Array(seeds.prefix(maxSeeds))
        guard !seeds.isEmpty else { return .empty }
        let edition    = edition()
        let fingerprint = fingerprint(seeds: seeds)

        let resolved = await resolve(seeds: seeds, using: catalog)
        guard !resolved.isEmpty else { return .empty }

        let bundles = await withTaskGroup(of: SeedBundle.self) { group in
            for base in resolved {
                group.addTask { await fill(base, using: catalog) }
            }
            var out: [SeedBundle] = []
            for await bundle in group { out.append(bundle) }
            return out.sorted { $0.rank < $1.rank }
        }

        let seedNames = Set(bundles.map { normalize($0.name) })
        let hero = newRelease(from: bundles)
        // Radar, genre mixes and stations aren't built here: they'd add ~60 gated
        // requests to the first paint. DiscoverSessionStore loads them afterwards.
        let mixes = await toppedUp(mixes(from: bundles, edition: edition),
                                   from: bundles, edition: edition, using: catalog)

        return PersonalLanding(
            seeds: bundles.map(\.name),
            mixes: mixes,
            newRelease: hero,
            recommendedPool: recommendedPool(from: bundles, seedNames: seedNames, known: known),
            related: relatedRows(from: bundles),
            freshReleases: freshReleases(from: bundles, excluding: hero),
            releaseRadar: nil,
            genreMixes: [],
            stations: [],
            fingerprint: fingerprint
        )
    }

    // MARK: Fetch

    private struct SeedBundle: Sendable {
        let rank: Int
        let name: String
        let artist: OnlineArtist
        var radio:   [OnlineTrack]  = []
        var related: [OnlineArtist] = []
        var albums:  [OnlineAlbum]  = []
    }

    /// Name to Deezer artist, once per seed. Everything downstream uses the id.
    private static func resolve(seeds: [String],
                                using catalog: ITunesSearchClient) async -> [SeedBundle] {
        await withTaskGroup(of: SeedBundle?.self) { group in
            for (rank, name) in seeds.enumerated() {
                group.addTask {
                    guard let artist = await catalog.searchArtists(query: name, limit: 1).first
                    else { return nil }
                    return SeedBundle(rank: rank, name: name, artist: artist)
                }
            }
            var out: [SeedBundle] = []
            for await bundle in group { if let bundle { out.append(bundle) } }
            return out.sorted { $0.rank < $1.rank }
        }
    }

    /// Radio for every seed; related artists and albums only for the top few.
    private static func fill(_ base: SeedBundle, using catalog: ITunesSearchClient) async -> SeedBundle {
        // Fetched deeper than mixTrackCount so the weekly draw has choices. A short
        // radio just means a smaller pool.
        async let radio   = catalog.radioTracks(artistId: base.artist.id, limit: 50)
        async let related = relatedIfWanted(base, using: catalog)
        async let albums  = albumsIfWanted(base, using: catalog)
        var filled = base
        filled.radio   = await radio
        filled.related = await related
        filled.albums  = await albums
        return filled
    }

    private static func relatedIfWanted(_ base: SeedBundle,
                                        using catalog: ITunesSearchClient) async -> [OnlineArtist] {
        guard base.rank < 2 else { return [] }
        return await catalog.relatedArtists(artistId: base.artist.id, limit: 12)
    }

    /// Every seed, since Release Radar covers all your artists.
    private static func albumsIfWanted(_ base: SeedBundle,
                                       using catalog: ITunesSearchClient) async -> [OnlineAlbum] {
        await catalog.artistAlbums(artistId: base.artist.id, artistName: base.artist.name, limit: 6)
    }

    // MARK: Release Radar

    /// How far back "new" goes.
    private static let radarWindow: TimeInterval = 45 * 24 * 60 * 60
    private static let radarTrackCount = 30
    /// Cap per record, so one deluxe reissue can't fill the radar.
    private static let radarPerAlbum = 2
    private static let radarAlbums = 20
    private static let radarMinimumTracks = 5
    private static let radarSchema: UInt64 = 1

    /// Releases come out on Fridays, so the radar's week turns over on Friday.
    public static func radarEdition(for date: Date = Date()) -> UInt64 {
        edition(for: date.addingTimeInterval(-2 * 24 * 60 * 60))
    }

    /// This week's radar. It reads the whole library, so the caller stores it once
    /// an edition (`MixEditionStore`).
    static func releaseRadar(seeds: [String], using catalog: ITunesSearchClient) async -> PersonalMix? {
        guard !seeds.isEmpty else { return nil }
        return await releaseRadar(seeds: seeds, edition: radarEdition() &+ radarSchema, using: catalog)
    }

    /// New songs by artists you play, newest record first. Not random: just what
    /// came out, in date order.
    private static func releaseRadar(seeds: [String],
                                     edition: UInt64,
                                     using catalog: ITunesSearchClient) async -> PersonalMix? {
        let now    = Date()
        let cutoff = now.addingTimeInterval(-radarWindow)
        // Drops future-dated records too; Deezer lists announced albums early.
        func fresh(_ albums: [OnlineAlbum]) -> [OnlineAlbum] {
            albums.filter {
                guard let date = $0.releaseDate else { return false }
                return date >= cutoff && date <= now
            }
        }

        // One lookup per library artist.
        var albums = fresh(await albumsForArtists(names: seeds, using: catalog))

        // A quiet month: widen to related artists instead of a four-song radar.
        if albums.count < radarAlbums / 2 {
            let top = await resolve(seeds: Array(seeds.prefix(3)), using: catalog)
            let related = await withTaskGroup(of: [OnlineArtist].self) { group in
                for bundle in top {
                    group.addTask { await catalog.relatedArtists(artistId: bundle.artist.id, limit: 8) }
                }
                var out: [OnlineArtist] = []
                for await batch in group { out.append(contentsOf: batch) }
                return out
            }
            var seen = Set(seeds.map(normalize))
            let names = related.map(\.name).filter { seen.insert(normalize($0)).inserted }
            albums += fresh(await albumsForArtists(names: Array(names.prefix(12)), using: catalog))
        }

        let recent = Array(
            dedupeAlbums(albums)
                .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
                .prefix(radarAlbums)
        )
        guard !recent.isEmpty else { return nil }

        let fetched = await withTaskGroup(of: (Int, [OnlineTrack]).self) { group in
            for (index, album) in recent.enumerated() {
                group.addTask {
                    (index, Array(await catalog.albumTracks(album: album).prefix(radarPerAlbum)))
                }
            }
            var out: [Int: [OnlineTrack]] = [:]
            for await (index, tracks) in group { out[index] = tracks }
            return out
        }

        // Album order, not completion order: the list is newest first. A track with
        // no cover and no length is an unreleased placeholder.
        let ordered = recent.indices.flatMap { fetched[$0] ?? [] }
            .filter { $0.duration > 0 && $0.artworkURL != nil }
        let picks = Array(dedupe(ordered).prefix(radarTrackCount))
        guard picks.count >= radarMinimumTracks else { return nil }

        var covers: [URL] = []
        var seenCovers = Set<String>()
        for album in recent {
            guard let url = album.coverURL, seenCovers.insert(url.absoluteString).inserted else { continue }
            covers.append(url)
            if covers.count == 4 { break }
        }

        return PersonalMix(id: "radar:\(edition)",
                           seedArtist: "",
                           title: "Release Radar",
                           subtitle: "New music from the artists you play",
                           tracks: picks,
                           covers: covers)
    }

    /// Records by these artists out in the last week, newest first. For release banners.
    public static func recentReleases(artists: [String],
                                      using catalog: ITunesSearchClient) async -> [OnlineAlbum] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return dedupeAlbums(await albumsForArtists(names: artists, using: catalog))
            .filter { $0.releaseDate.map { $0 >= cutoff && $0 <= now } ?? false }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    /// Resolve each name and take its recent records, all in flight together.
    private static func albumsForArtists(names: [String],
                                         using catalog: ITunesSearchClient) async -> [OnlineAlbum] {
        guard !names.isEmpty else { return [] }
        return await withTaskGroup(of: [OnlineAlbum].self) { group in
            for name in names {
                group.addTask {
                    guard let artist = await catalog.resolveArtist(name: name, trackID: nil)
                    else { return [] }
                    return await catalog.artistAlbums(artistId: artist.id, artistName: artist.name, limit: 4)
                }
            }
            var out: [OnlineAlbum] = []
            for await batch in group { out.append(contentsOf: batch) }
            return out
        }
    }

    private static func dedupeAlbums(_ albums: [OnlineAlbum]) -> [OnlineAlbum] {
        var seen = Set<String>()
        return albums.filter { seen.insert(normalize($0.title) + "|" + normalize($0.artistName)).inserted }
    }

    // MARK: Assembly

    /// One mix per seed, drawn for `edition`. Deterministic in artist and week,
    /// so reopening Discover doesn't reshuffle but next Monday is different.
    private static func mixes(from bundles: [SeedBundle], edition: UInt64) -> [PersonalMix] {
        bundles.compactMap { bundle in
            let pool = dedupe(bundle.radio)
            guard pool.count >= mixMinimumTracks else { return nil }

            var rng = SplitMix64(seed: hash(normalize(bundle.name)) ^ (edition &* 0x9E37_79B9_7F4A_7C15))
            let tracks = Array(pool.shuffled(using: &rng).prefix(mixTrackCount))

            let others = tracks
                .map(\.artistName)
                .filter { normalize($0) != normalize(bundle.name) }
            var seen = Set<String>()
            let featured = others.filter { seen.insert(normalize($0)).inserted }.prefix(3)

            let subtitle = featured.isEmpty
                ? "\(tracks.count) songs"
                : featured.joined(separator: ", ") + " and more"

            var covers: [URL] = []
            var coverKeys = Set<String>()
            for track in tracks {
                guard let url = track.artworkURL, coverKeys.insert(url.absoluteString).inserted
                else { continue }
                covers.append(url)
                if covers.count == 4 { break }
            }

            return PersonalMix(id: normalize(bundle.name),
                               seedArtist: bundle.name,
                               title: "\(bundle.name) Mix",
                               subtitle: subtitle,
                               tracks: tracks,
                               covers: covers)
        }
    }

    /// Fills "Your mixes" up to minimumMixes using related artists, which were
    /// already fetched. Only their radios cost anything. Seeds and existing mixes
    /// are excluded. Asks for twice as many radios since thin ones get dropped.
    private static func toppedUp(_ mixes: [PersonalMix],
                                 from bundles: [SeedBundle],
                                 edition: UInt64,
                                 using catalog: ITunesSearchClient) async -> [PersonalMix] {
        let wanted = minimumMixes - mixes.count
        guard wanted > 0 else { return mixes }

        var taken = Set(mixes.map(\.id))
        for bundle in bundles { taken.insert(normalize(bundle.name)) }

        // Round-robin across seeds so one artist's neighbourhood doesn't dominate.
        var candidates: [OnlineArtist] = []
        let lists = bundles.map(\.related)
        if let deepest = lists.map(\.count).max() {
            for index in 0..<deepest {
                for list in lists where index < list.count {
                    let artist = list[index]
                    guard taken.insert(normalize(artist.name)).inserted else { continue }
                    candidates.append(artist)
                }
            }
        }
        guard !candidates.isEmpty else { return mixes }

        let extra = await withTaskGroup(of: SeedBundle?.self) { group in
            for (offset, artist) in candidates.prefix(wanted * 2).enumerated() {
                group.addTask {
                    let radio = await catalog.radioTracks(artistId: artist.id, limit: 50)
                    guard radio.count >= mixMinimumTracks else { return nil }
                    return SeedBundle(rank: bundles.count + offset, name: artist.name,
                                      artist: artist, radio: radio)
                }
            }
            var out: [SeedBundle] = []
            for await bundle in group { if let bundle { out.append(bundle) } }
            return out.sorted { $0.rank < $1.rank }
        }
        return mixes + self.mixes(from: extra, edition: edition).prefix(wanted)
    }

    /// Candidates for "Recommended songs". Round-robin across seeds so the top
    /// reflects your whole taste. Songs by seed artists are dropped; they have
    /// their own mixes.
    private static func recommendedPool(from bundles: [SeedBundle],
                                        seedNames: Set<String>,
                                        known: Set<String>) -> [OnlineTrack] {
        let radios = bundles.map { dedupe($0.radio) }
        guard let deepest = radios.map(\.count).max() else { return [] }

        var pool: [OnlineTrack] = []
        var seen = Set<String>()
        for index in 0..<deepest {
            for radio in radios where index < radio.count {
                let track = radio[index]
                guard !seedNames.contains(normalize(track.artistName)) else { continue }
                let key = normalize(track.title) + "|" + normalize(track.artistName)
                guard !known.contains(key), seen.insert(key).inserted else { continue }
                pool.append(track)
                if pool.count == 60 { return pool }
            }
        }
        return pool
    }

    private static func relatedRows(from bundles: [SeedBundle]) -> [RelatedArtistRow] {
        bundles.compactMap { bundle in
            guard bundle.related.count >= 4 else { return nil }
            return RelatedArtistRow(id: normalize(bundle.name),
                                    seedArtist: bundle.name,
                                    artists: bundle.related)
        }
    }

    /// Newest first per artist, interleaved. Skips whatever the hero card shows.
    private static func freshReleases(from bundles: [SeedBundle],
                                      excluding hero: FreshRelease?) -> [OnlineAlbum] {
        let lists = bundles.map { Array($0.albums.prefix(4)) }
        guard let deepest = lists.map(\.count).max() else { return [] }

        var out: [OnlineAlbum] = []
        var seen = Set<String>()
        if let hero { seen.insert(releaseKey(hero.album)) }
        for index in 0..<deepest {
            for list in lists where index < list.count {
                let album = list[index]
                guard seen.insert(releaseKey(album)).inserted else { continue }
                out.append(album)
                if out.count == 15 { return out }
            }
        }
        return out
    }

    /// The newest record from any top artist. Date decides, rank breaks same-day
    /// ties. Nothing older than the window.
    private static func newRelease(from bundles: [SeedBundle]) -> FreshRelease? {
        let cutoff = Calendar.current.date(byAdding: .month, value: -18, to: Date())

        var best: (release: FreshRelease, date: Date, rank: Int)?
        for bundle in bundles {
            for album in bundle.albums {
                guard let released = album.releaseDate else { continue }
                if let cutoff, released < cutoff { continue }
                if let current = best,
                   released < current.date || (released == current.date && bundle.rank >= current.rank) {
                    continue
                }
                best = (FreshRelease(album: album, artist: bundle.artist), released, bundle.rank)
            }
        }
        return best?.release
    }

    private static func releaseKey(_ album: OnlineAlbum) -> String {
        normalize(album.title) + "|" + normalize(album.artistName)
    }

    // MARK: Helpers

    private static func dedupe(_ tracks: [OnlineTrack]) -> [OnlineTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// FNV-1a. Swift's hashValue is seeded per process, so it would redraw mixes
    /// after every relaunch.
    static func hash(_ value: String) -> UInt64 {
        var result: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result &*= 0x0000_0100_0000_01B3
        }
        return result
    }

    nonisolated static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
