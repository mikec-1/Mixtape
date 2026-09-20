// RecommendationEngine.swift
// Mixtape — Core/Services/Online
//
// Turns what you actually listen to into a Discover landing page.
//
// Before this, the landing page was `browseLanding()` — Deezer's *global*
// `/chart/0/*`. Everybody in the world saw the same four rows, and since a
// worldwide chart barely moves week to week, it looked frozen. It wasn't a
// recommendation system; it was a leaderboard.
//
// What we have to work with is Deezer's free API, so there is no "recommended
// for user X" endpoint to call. But there is something better than a chart:
// per-artist radio and per-artist related-artists. Seed those with the artists
// you personally play the most — which ListeningStatsService already knows,
// including plays that came from Discover itself — and you get the shape
// Spotify's home page has: a handful of mixes built around your regulars, a
// "recommended songs" list that leans on their neighbourhood rather than the
// global top 50, artists you haven't heard yet but probably should have, and
// what your regulars have released lately.
//
// Every fetch fails soft to empty. A seed that doesn't resolve, an endpoint
// that 403s, a network blip — each costs one row, not the page.

import Foundation

// MARK: - Models

/// One "Artist Mix" card: a radio built around a seed artist you play a lot.
public struct PersonalMix: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// The artist this was built from, as it appears in your listening history.
    public let seedArtist: String
    public let title: String
    /// "Travis Scott, Future, Metro Boomin and more" — who's actually in it.
    public let subtitle: String
    public let tracks: [OnlineTrack]
    /// Up to four distinct artworks, for the 2×2 mosaic the card draws.
    public let covers: [URL]

    /// The artists `subtitle` names, kept apart so the header can link each one
    /// to its own page. Derived rather than stored: a stored key wouldn't decode
    /// out of the mix snapshots already pinned to disk.
    var featured: [String] {
        var seen = Set<String>()
        return tracks.flatMap { ImportService.creditedArtists(from: $0.artistName) }
            .filter { RecommendationEngine.normalize($0) != RecommendationEngine.normalize(seedArtist) }
            .filter { seen.insert(RecommendationEngine.normalize($0)).inserted }
            .prefix(3)
            .map { $0 }
    }
}

/// "Because you listened to <artist>" — a row of artists Deezer's audience
/// overlaps with. This is the row that introduces someone genuinely new.
public struct RelatedArtistRow: Identifiable, Sendable {
    public let id: String
    public let seedArtist: String
    public let artists: [OnlineArtist]
}

/// The single "New release from <artist>" hero: one recent record by someone you
/// actually play, plus the artist itself so the card can show their face.
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
    /// The hero beside "Your mixes". Nil when none of your artists has put
    /// anything out lately — the card is a claim about the world, so it either
    /// has something genuinely new to say or it isn't drawn at all.
    public var newRelease: FreshRelease?
    /// A deliberately over-sized candidate list. The visible "Recommended songs"
    /// row is a window onto it, so the refresh button costs nothing — no second
    /// round trip just to see twelve different songs.
    public var recommendedPool: [OnlineTrack]
    public var related: [RelatedArtistRow]
    public var freshReleases: [OnlineAlbum]
    /// "Release Radar": songs off records your artists have put out lately,
    /// newest first. Nil when nobody you play has released anything inside the
    /// window — an empty radar is a lie, so there simply isn't one.
    public var releaseRadar: PersonalMix?
    /// Your library clustered by genre — "Rap/Hip Hop Mix". Unlike the artist
    /// mixes these don't turn over weekly; they hold until the cluster moves.
    public var genreMixes: [PersonalMix]
    /// Charts, scenes and artist radios. Nothing to do with your library, so a
    /// brand-new account still opens on a full page.
    public var stations: [PersonalMix]
    /// Identifies the taste this was built from. When your top artists change,
    /// the fingerprint changes and the page rebuilds even inside its TTL.
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

    /// The line under "Made for you", naming what the page was built from — or
    /// nil when it can't name anything.
    ///
    /// It used to interpolate the seeds unconditionally, which reads fine right
    /// up until there are none: a wiped history left the sentence as "Built from
    /// and the rest of your listening history", a page introducing itself with a
    /// blank where the reason should be. The names are the whole point of the
    /// line, so with no names there is no line.
    public func builtFromSubtitle(limit: Int) -> String? {
        let named = seeds.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty else { return nil }
        return "Built from \(named.prefix(limit).joined(separator: ", ")) and the rest of your listening history."
    }

    /// The visible slice of `recommendedPool` for a given roll of the refresh
    /// button. Deterministic, so the same roll always shows the same songs —
    /// scrolling away and back doesn't reshuffle the list under you.
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

    /// Six is where the request cost stops paying for itself: past that the
    /// mixes start being built from artists you played twice.
    public static let maxSeeds = 6

    /// Under three cards "Your mixes" reads as broken rather than sparse — one
    /// mosaic beside a hero looks like the row failed to load. When the seeds
    /// can't produce three, the build borrows from the neighbourhood instead of
    /// shipping a stub; see `toppedUp(_:from:using:)`.
    private static let minimumMixes = 3

    /// Under this a mix isn't a mix, it's a shortfall — better to drop the card
    /// than to ship a "Mix" that ends after two songs.
    private static let mixMinimumTracks = 8

    /// How many songs a mix ships with. The radio is fetched deeper than this on
    /// purpose: the surplus is what lets a new edition be a genuinely different
    /// list rather than last week's songs in a new order. A thin radio degrades
    /// to "all of it", which is what the old build did every week.
    private static let mixTrackCount = 24

    // MARK: Editions

    /// Which weekly edition of the mixes a date falls in.
    ///
    /// Mixes are rebuilt on a weekly cadence: often enough that the home page
    /// isn't the same six cards all month, rarely enough that a mix you liked on
    /// Tuesday is still there on Thursday. Taste changes don't wait for it —
    /// they move the seeds, and the seeds invalidate the page immediately.
    ///
    /// Plain arithmetic rather than `Calendar`, so the edition doesn't depend on
    /// the device's locale or first-weekday setting. 1970-01-01 was a Thursday;
    /// the four-day shift puts the rollover on Monday 00:00 UTC.
    public static func edition(for date: Date = Date()) -> UInt64 {
        let week: TimeInterval = 7 * 24 * 60 * 60
        let shifted = date.timeIntervalSince1970 + 4 * 24 * 60 * 60
        return UInt64(max(0, (shifted / week).rounded(.down)))
    }

    /// What the page was built from: the taste *and* the week. Both legs matter
    /// — the seeds rebuild it when you change what you play, the edition rebuilds
    /// it when the week turns over. Computed here so the store's staleness check
    /// and the build itself can't drift apart.
    ///
    /// Sorted, so it's the *set* of seed artists that counts and not their
    /// ranking. Playing one song is enough to swap your first and second
    /// favourites of the last thirty days, and rebuilding the entire landing for
    /// that meant the page churned constantly while showing near-identical
    /// artists — an expensive way to look broken.
    public static func fingerprint(seeds: [String], at date: Date = Date()) -> String {
        seeds.prefix(maxSeeds).map(normalize).sorted().joined(separator: "|")
            + "#\(edition(for: date))"
    }

    // MARK: Seeding

    /// The artists to build the page around, best first.
    ///
    /// Weighted toward the last month so the page moves as your taste does, then
    /// topped up from all time so someone who took a week off doesn't get a page
    /// built from the three songs they played on Tuesday, then topped up again
    /// from the local library — a freshly imported library is still a statement
    /// of taste.
    ///
    /// That last pass used to be a *fallback*, running only when the history was
    /// completely empty, and it's why this could return a single name: play one
    /// artist a lot and they were the only seed there was, so the page built one
    /// mix and stopped. A history with one artist in it is still a history; it
    /// just isn't `limit` artists, and the page needs `limit` to fill. What you
    /// chose to import is a weaker signal than what you played, so it goes
    /// underneath the history — never instead of it.
    @MainActor
    public static func seeds(stats: ListeningStatsService,
                             library: LibraryService,
                             limit: Int = maxSeeds) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func add(_ name: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.lowercased() != "unknown artist" else { return }
            guard seen.insert(clean.lowercased()).inserted else { return }
            ordered.append(clean)
        }

        for artist in stats.compute(period: .last30Days).topArtists.prefix(3) { add(artist.name) }
        for artist in stats.compute(period: .allTime).topArtists.prefix(limit)  { add(artist.name) }

        if ordered.count < limit {
            // Rank the library's artists by how much of them you have, and take
            // as many as the history left room for.
            let counts = Dictionary(grouping: library.tracks, by: { $0.artistName })
                .mapValues(\.count)
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            for (name, _) in counts {
                add(name)
                if ordered.count >= limit { break }
            }
        }

        return Array(ordered.prefix(limit))
    }

    /// How many library artists the radar asks about.
    ///
    /// Two requests each against a gate that allows nine a second, and the
    /// gate is shared with every other Deezer call, so this number is a queue
    /// everything else waits behind: at thirty seeds the radios shelf sat
    /// behind sixty reservations and took half a minute to draw. Twelve of
    /// your most-played artists is what a radar is about anyway — the
    /// thirteenth was never going to be the reason you opened it.
    public static let maxRadarSeeds = 12

    /// Wider than the radar's list on purpose. Scenes are narrow — "uk drill",
    /// "german hip hop" — so a 2000-song library only shows its shape once
    /// enough of its artists have been placed; capping at the radar's thirty
    /// produced one broad mix where there were half a dozen.
    public static let maxGenreSeeds = 90

    /// Every artist in the library, most-owned first — the radar's claim is
    /// about your whole library, not the six artists the mixes are drawn from.
    ///
    /// Credits are split here: a song filed as "Dave, Stormzy" is two artists to
    /// ask about, and the composite string resolves to nobody.
    @MainActor
    public static func radarSeeds(library: LibraryService,
                                  limit: Int = maxRadarSeeds) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for track in library.tracks {
            for name in ImportService.creditedArtists(from: track.artistName) {
                let key = name.lowercased()
                guard !key.isEmpty, key != "unknown artist" else { continue }
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

    /// "title|artist" keys for everything already in the library, so the
    /// recommendation row doesn't spend its twelve slots recommending songs you
    /// own. Cheap to build and it makes the row feel like it knows you.
    @MainActor
    public static func knownKeys(library: LibraryService) -> Set<String> {
        Set(library.tracks.map { normalize($0.title) + "|" + normalize($0.artistName) })
    }

    // MARK: Building

    /// Fetch and assemble the personalized landing. Roughly 5 + 5 + 2 + 3
    /// requests for five seeds, all in flight together; the caller caches the
    /// result behind a TTL so this runs a couple of times a day, not per view.
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
        // Read, not built — all three of them.
        //
        // This is the whole reason the page paints in a couple of seconds
        // rather than twenty. Deezer is gated to nine requests a second, so
        // what costs time here is the *count* of requests on the critical path,
        // not any one of them being slow. The radar reads every artist in the
        // library (two requests each) and the scene clustering is worse; put
        // together they were sixty-odd gated requests standing between the user
        // and a page whose personalised half was already in hand.
        //
        // So the critical path is now the seeds and their mixes, full stop.
        // Whatever these three held last time goes up on the first frame, and
        // `DiscoverSessionStore` refills them behind it. All three are pinned, so on
        // most launches the refill finds its answer on disk and does nothing.
        let radar    = MixEditionStore.loadRadar(edition: radarEdition() &+ radarSchema)
        let genres   = MixEditionStore.loadList("genres") ?? []
        let stations = MixEditionStore.loadList("stations") ?? []
        let mixes = await toppedUp(mixes(from: bundles, edition: edition),
                                   from: bundles, edition: edition, using: catalog)

        return PersonalLanding(
            seeds: bundles.map(\.name),
            mixes: mixes,
            newRelease: hero,
            recommendedPool: recommendedPool(from: bundles, seedNames: seedNames, known: known),
            related: relatedRows(from: bundles),
            freshReleases: freshReleases(from: bundles, excluding: hero),
            releaseRadar: radar,
            genreMixes: genres,
            stations: stations,
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

    /// Name → Deezer artist, once per seed. Everything downstream works from the
    /// id, which is why this is a separate pass rather than each endpoint
    /// re-searching the same name (`radioTracks(forArtist:)` used to do exactly
    /// that, three times over).
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
    /// The lower-ranked seeds still earn their place in the recommendation pool,
    /// but a "because you listened to" row for your fifth-favourite artist is a
    /// row nobody scrolls to.
    private static func fill(_ base: SeedBundle, using catalog: ITunesSearchClient) async -> SeedBundle {
        // Deeper than a mix ships (`mixTrackCount`) so the weekly draw has
        // something to choose between, and deeper than the recommendation pool
        // needs. Deezer returns what it has; a short radio just means a smaller
        // pool to draw from, not a broken card.
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

    /// Every seed, not just the top few: the "New release from" hero only needed
    /// the first three, but Release Radar is a claim about *your artists* and
    /// stopping at three would quietly drop half of them.
    private static func albumsIfWanted(_ base: SeedBundle,
                                       using catalog: ITunesSearchClient) async -> [OnlineAlbum] {
        await catalog.artistAlbums(artistId: base.artist.id, artistName: base.artist.name, limit: 6)
    }

    // MARK: Release Radar

    /// How far back "new" reaches. Wide enough that a quiet fortnight still
    /// fills a list, narrow enough that nothing in it is last season's record.
    private static let radarWindow: TimeInterval = 45 * 24 * 60 * 60
    private static let radarTrackCount = 30
    /// One record can't be the whole radar — a deluxe reissue is twenty tracks
    /// and would leave no room for anyone else's release.
    private static let radarPerAlbum = 2
    private static let radarAlbums = 20
    private static let radarMinimumTracks = 5
    private static let radarSchema: UInt64 = 1

    /// Records come out on Fridays, so the radar's week turns over on a Friday.
    /// Same length as the mix edition, two days along.
    public static func radarEdition(for date: Date = Date()) -> UInt64 {
        edition(for: date.addingTimeInterval(-2 * 24 * 60 * 60))
    }

    /// New songs by artists you actually play, newest record first.
    ///
    /// Unlike a mix this isn't drawn — there is no randomness to pin, because
    /// the answer is just "what came out, in date order". Two builds an hour
    /// apart agree unless something was released in between, which is the one
    /// case where the list *should* move.
    /// This week's radar, pinned. Building it reads the whole library, so it
    /// runs once an edition and is read back from disk for the rest of the week.
    static func releaseRadarIfNeeded(seeds: [String],
                                             using catalog: ITunesSearchClient) async -> PersonalMix? {
        guard !seeds.isEmpty else { return nil }
        // Bumped when the rules that build the list change: a radar pinned by
        // the old rules would otherwise stand for the rest of the week.
        let edition = radarEdition() &+ radarSchema
        if let pinned = MixEditionStore.loadRadar(edition: edition) { return pinned }
        guard let mix = await releaseRadar(seeds: seeds, edition: edition, using: catalog)
        else { return nil }
        MixEditionStore.saveRadar(mix, edition: edition)
        return mix
    }

    /// New songs by artists you actually play, newest record first.
    ///
    /// Unlike a mix this isn't drawn — there is no randomness, the answer is
    /// just "what came out, in date order".
    private static func releaseRadar(seeds: [String],
                                     edition: UInt64,
                                     using catalog: ITunesSearchClient) async -> PersonalMix? {
        let now    = Date()
        let cutoff = now.addingTimeInterval(-radarWindow)
        // Both ends. Deezer lists announced records the day they're announced —
        // a radar with a song that's still on a pre-save countdown is a radar
        // full of silence, so anything dated in the future is not out yet.
        func fresh(_ albums: [OnlineAlbum]) -> [OnlineAlbum] {
            albums.filter {
                guard let date = $0.releaseDate else { return false }
                return date >= cutoff && date <= now
            }
        }

        // Every artist in the library costs a lookup. This used to reuse the
        // albums the landing's seeds had already fetched, which saved five of
        // them and cost the page the other fifty-five in its critical path;
        // off that path the reuse isn't worth the coupling.
        var albums = fresh(await albumsForArtists(names: seeds, using: catalog))

        // Still thin — a quiet month for the artists you own. Widen to who they
        // sound like rather than showing a four-song "radar".
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

        // Rebuilt in album order rather than in completion order: the whole
        // promise of the list is that it's newest first.
        // A track with no cover and no length is a placeholder row on a record
        // that hasn't shipped its audio yet — it plays as 0:00 and draws as a
        // grey note.
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

    /// One mix per seed, drawn for `edition`.
    ///
    /// The draw is deterministic in the artist and the week together: the same
    /// mix rebuilt an hour later is identical — reopening Discover must not
    /// reshuffle a page you were reading, and a saved snapshot must not go
    /// looking like a different mix — while next Monday's is a different slice of
    /// the radio, in a different order, with a different mosaic.
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

    /// Fills "Your mixes" out to `minimumMixes` when the seeds couldn't.
    ///
    /// Your top artists make the best seeds, but they are not the only ones, and
    /// a history two artists deep should still fill a row. The related artists
    /// have already been fetched for the "Because you listened to" rows, so the
    /// candidates are free and — by construction — people this listener is
    /// likely to want; only their radios cost anything, and only when the row is
    /// actually short. Seeds and mixes already built are excluded, so nothing
    /// appears twice.
    ///
    /// Twice as many radios are requested as cards are needed: a radio that
    /// comes back thin is dropped by `mixes(from:)`, and asking for exactly
    /// three is how you end up with two.
    private static func toppedUp(_ mixes: [PersonalMix],
                                 from bundles: [SeedBundle],
                                 edition: UInt64,
                                 using catalog: ITunesSearchClient) async -> [PersonalMix] {
        let wanted = minimumMixes - mixes.count
        guard wanted > 0 else { return mixes }

        var taken = Set(mixes.map(\.id))
        for bundle in bundles { taken.insert(normalize(bundle.name)) }

        // Round-robin across the seeds so a top-up isn't one artist's entire
        // neighbourhood — the same interleave the release row uses.
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

    /// The candidate list behind "Recommended songs".
    ///
    /// Round-robin across seeds rather than seed-by-seed, so the top of the list
    /// reflects your whole taste instead of just your single most-played artist.
    /// Songs *by* a seed artist are dropped: this row's job is the thing you
    /// haven't heard, and your regulars already have their own mix card above it.
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

    /// Newest-first per artist (Deezer already orders `/artist/{id}/albums` that
    /// way), interleaved so the row isn't one artist's back catalogue followed by
    /// another's. Whatever the hero card took is skipped — the two sit on the same
    /// screen, and a record shown twice reads as a bug.
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

    /// The one record to headline with: the most recent thing any of your top
    /// artists has actually put out.
    ///
    /// Date decides it, not rank — "new release" is a claim about when, and your
    /// second-favourite artist releasing something last week beats your
    /// favourite's from eight months ago. Rank only breaks ties on the same day,
    /// which is common: Friday is release day for the whole industry.
    ///
    /// Anything older than the window is no release at all and the card is
    /// dropped. The window is wider than the chart's twelve months because the
    /// candidate pool is three artists rather than a hundred — but it still has
    /// to be recent enough that calling it "new" is true.
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

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so a mix drawn
    /// from it would come out differently after every relaunch — the one thing
    /// a weekly edition must not do.
    static func hash(_ value: String) -> UInt64 {
        var result: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result &*= 0x0000_0100_0000_01B3
        }
        return result
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
