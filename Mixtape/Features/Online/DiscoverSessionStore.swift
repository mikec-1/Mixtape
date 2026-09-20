// DiscoverSessionStore.swift
// Mixtape — Features/Online
//
// Discover's session state, lifted out of the two Discover views.
//
// All of it used to live in @State. On macOS MacContentRouter swaps the whole
// content column when the section changes, so leaving Discover tore the view
// down and took the results, the browse landing and the drill-down stack with
// it: search something, open an artist, go Home, come back — and you were on
// the default landing page with everything gone. A singleton that outlives
// every view is what makes that round trip land you exactly where you left,
// the way Spotify does. iOS gets the same store; a TabView usually keeps its
// tabs alive, but "usually" isn't a guarantee worth relying on.
//
// This deliberately does NOT own the macOS search text. That lives in
// MacAppState.searchText (per section, so a library search doesn't leak into
// Discover) and the view keeps reading it from there. All we remember is which
// query the results we're holding belong to, so a restored field can be matched
// against them instead of refiring an identical network call.

import Foundation
import Combine

@MainActor
final class DiscoverSessionStore: ObservableObject {

    /// One store for the whole process. Matches how the app already shares
    /// view-adjacent state that has to outlive a view (ArtworkWashTint.shared,
    /// ThemeManager.shared) — and unlike hanging it off AppDependencies, it
    /// doesn't push a Discover keystroke through every view in the app that
    /// observes the dependency container.
    static let shared = DiscoverSessionStore()

    private init() {
        // This week's mixes are already decided (see `MixEditionStore`), so the
        // page can show them on the first frame after a relaunch instead of
        // waiting on a build to tell it what it already knows.
        personal.mixes = MixEditionStore.load(edition: RecommendationEngine.edition()) ?? []

        // Wiping the library or the history takes away everything this page is
        // built from, so the page has to go with it — otherwise the mixes drawn
        // for the old taste survive in memory *and* on disk, and the landing
        // that comes back after a "delete everything" is the one from before.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            let reset = UserDataReset.from(note)
            MainActor.assumeIsolated { self?.forgetPersonalLanding(reset) }
        }
    }

    /// Drop the derived landing after a reset.
    ///
    /// Both halves matter: `known` (what the recommendations exclude) comes from
    /// the library, and the seeds come from the history, so either wipe makes the
    /// current page wrong. The stored week's mixes go too — they are pinned to
    /// the edition precisely so they *don't* redraw, which without this made them
    /// the one thing a wipe couldn't remove.
    private func forgetPersonalLanding(_ reset: UserDataReset) {
        guard reset.clearedLibrary || reset.clearedHistory else { return }
        MixEditionStore.clear()
        personal          = .empty
        personalLoadedAt  = nil
        recommendedRoll   = 0
        artistPages.removeAll()
    }

    // MARK: - Search results

    /// What the results list is showing. Mutated in place when the lyric leg lands.
    @Published var results = DiscoverResults()

    /// Drives the header spinner. True from the moment a query is accepted
    /// until the lyric leg finishes, so the debounce window reads "Searching…"
    /// rather than flashing "No results."
    @Published var isSearching = false

    /// The trimmed query `results` answer, "" when there are none. Compared
    /// against the restored search field on the way back into Discover.
    @Published private(set) var resultsQuery = ""

    /// iOS only. Discover there has its own `.searchable` field, where macOS
    /// shares the window toolbar's (MacAppState). Held here so the typed text
    /// survives a tab switch along with the results it produced.
    @Published var iosQuery = ""

    /// The query a running search is for. Without it, rebuilding the view while
    /// a search is still in the air fires a second identical request.
    private var inFlightQuery: String?
    private var searchTask: Task<Void, Never>?

    // MARK: - Drill-down

    /// Drill-down stack. Empty = search results / browse landing; the last
    /// element is the visible page.
    ///
    /// `DiscoverDestination` is declared once per platform — in
    /// OnlineDiscoverView on macOS and IOSDiscoverComponents on iOS — with the
    /// same name and the same three cases. Only one of the two exists in any
    /// given build, so this resolves to whichever one is being compiled.
    @Published var path: [DiscoverDestination] = []

    /// Bumped when the user commits a query with Return.
    ///
    /// Typing alone leaves the drill-down page you're on alone — the query goes
    /// to the suggestions panel, not the navigation. Return is the moment they
    /// ask for the results list itself, and the Discover view watches this to
    /// unwind the stack. A counter rather than a flag so two consecutive
    /// Returns on the same text both register.
    @Published private(set) var searchCommitToken = 0

    /// Call when Return is pressed in the window's search field.
    ///
    /// Unwinds the drill-down here rather than only in the view's
    /// `onChange(of:)`: committing from *outside* Discover (a playlist, or
    /// Settings) mounts the Discover column fresh, and a view created after the
    /// token moved never sees the change — so Return landed you back on the
    /// artist page you had drilled into before, not on the new results.
    func commitSearch() {
        searchCommitToken &+= 1
        path.removeAll()
    }

    // MARK: - Scroll anchors

    /// Top-most visible section of the results and landing scroll views.
    /// Section granularity rather than pixels — that is all `.scrollPosition(id:)`
    /// gives for free, and it's enough that you don't lose your place.
    @Published var resultsAnchor: String?
    @Published var browseAnchor: String?

    // MARK: - Browse landing

    @Published private(set) var browse = BrowseLanding()
    @Published private(set) var browseLoading = false
    private var browseLoadedAt: Date?

    /// Deezer's charts and new-release rows turn over on the order of hours, so
    /// refetching on every appear is four requests for a page that is already
    /// correct — but caching for the life of the process means a window left
    /// open overnight still shows yesterday's chart. Half an hour splits it.
    private static let browseTTL: TimeInterval = 30 * 60

    // MARK: - Personalized landing

    @Published private(set) var personal = PersonalLanding.empty
    @Published private(set) var personalLoading = false

    /// Release Radar and the genre and radio shelves are still filling in
    /// behind the page.
    /// Drives their placeholder cards — those two are the slow legs, and
    /// leaving them out entirely made the page look finished when it wasn't.
    @Published private(set) var shelvesLoading = false
    private var shelvesTask: Task<Void, Never>?
    private var personalLoadedAt: Date?

    /// Which slice of `personal.recommendedPool` the Recommended row is showing.
    /// Bumped by the refresh button — a new twelve songs with no network call,
    /// which is what makes that button feel instant.
    @Published private(set) var recommendedRoll = 0

    /// Longer than the browse TTL on purpose. An artist's radio and related
    /// artists barely move day to day, and the two things that *should* change
    /// the page — what you've been playing, and the week turning over —
    /// invalidate it by fingerprint instead of by clock.
    ///
    /// So this is only about the rows that age on their own: new releases, and a
    /// radio that quietly gained a song. The mixes themselves are pinned to the
    /// week (`RecommendationEngine.edition(for:)`), so a rebuild inside one
    /// redraws the same six cards rather than reshuffling the page under
    /// someone who just came back to it.
    private static let personalTTL: TimeInterval = 6 * 60 * 60

    // MARK: - Drill-down page memo

    typealias ArtistCatalogue = OnlineArtistCatalogue

    /// Same half-hour rule as the landing, for the same reason.
    private static let pageTTL: TimeInterval = 30 * 60

    private var artistPages = TimedCache<Int, ArtistCatalogue>(ttl: pageTTL, limit: 24)
    private var albumPages  = TimedCache<Int, [OnlineTrack]>(ttl: pageTTL, limit: 24)
    private var genrePages  = TimedCache<Int, [OnlineArtist]>(ttl: pageTTL, limit: 24)

    // MARK: - Search

    /// Runs a debounced Discover search for `text` and files the results.
    ///
    /// No-ops when we already hold — or are already fetching — results for the
    /// same query. That is exactly the case when the view is rebuilt with the
    /// search field still filled, and refiring would blank the list and flash a
    /// spinner over results that were already right.
    func search(_ text: String, using catalog: ITunesSearchClient, immediate: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Cleared field: back to the landing page. Cancel first, or a response
        // still in the air repopulates a list the user just emptied.
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            searchTask = nil
            inFlightQuery = nil
            results = DiscoverResults()
            resultsQuery = ""
            resultsAnchor = nil
            isSearching = false
            return
        }

        // Already fetching this exact query — a rebuilt view must not fire a
        // second identical request alongside the first.
        guard trimmed != inFlightQuery else { return }
        // Already answered it, and the answer had something in it. A query that
        // came back empty is deliberately NOT treated as answered: that is as
        // likely to have been a dropped connection as a real absence of
        // results, and "No results." that never retries is a dead end.
        guard !(trimmed == resultsQuery && !results.isEmpty) else { return }

        // Only a genuinely different query supersedes the one running. That is
        // what keeps already-loaded results on screen instead of blanking them
        // every time the view comes back.
        searchTask?.cancel()
        inFlightQuery = trimmed
        isSearching = true
        resultsAnchor = nil          // a new query starts at the top

        searchTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            defer {
                // Only the search that is still the current one may clear these;
                // a superseded task must not switch off the new one's spinner.
                if self.inFlightQuery == trimmed {
                    self.inFlightQuery = nil
                    self.isSearching = false
                }
            }
            let grouped = await catalog.discoverSearch(query: trimmed)
            if Task.isCancelled { return }
            self.results = grouped
            self.resultsQuery = trimmed

            // Lyric search runs after so the main results show instantly.
            let lyricHits = await catalog.searchByLyrics(trimmed)
            if Task.isCancelled || self.resultsQuery != trimmed { return }
            self.results.lyricMatches = lyricHits
        }
    }

    // MARK: - Browse landing

    /// Fetches the pre-search landing content, at most once every `browseTTL`.
    /// Cheap to call on every appear — that's the point.
    /// The same fetch with the cache ignored, for a deliberate pull-to-refresh.
    ///
    /// Awaitable, unlike `loadBrowseIfNeeded`: the gesture's spinner has to stay
    /// up until the page it promised to refresh has actually changed.
    func reloadBrowse(using catalog: ITunesSearchClient) async {
        browseLoading = true
        defer { browseLoading = false }
        let landing = await catalog.browseLanding()
        guard !landing.isEmpty else { return }
        browse       = landing
        browseLoadedAt = Date()
    }

    func loadBrowseIfNeeded(using catalog: ITunesSearchClient) {
        guard !browseLoading else { return }
        if !browse.isEmpty,
           let loadedAt = browseLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.browseTTL { return }

        browseLoading = true
        Task { @MainActor in
            defer { self.browseLoading = false }
            let landing = await catalog.browseLanding()
            // A failed fetch comes back empty on every leg. Keeping the stale
            // landing beats replacing a working page with a blank one.
            guard !landing.isEmpty else { return }
            self.browse = landing
            self.browseLoadedAt = Date()
        }
    }

    // MARK: - Personalized landing

    /// Builds the "made for you" rows, at most once every `personalTTL` — and
    /// again whenever the fingerprint changes, whatever the clock says. That
    /// covers both reasons the page should stop being the page it was: play a
    /// new artist to death this afternoon and it reflects it this afternoon, and
    /// when the week turns over the mixes are drawn again from scratch.
    ///
    /// Seeds are computed by the caller because they need the main-actor stats
    /// and library services, and this store deliberately owns no dependencies.
    func loadPersonalIfNeeded(seeds: [String],
                              radarSeeds: [String] = [],
                              genreSeeds: [String] = [],
                              known: Set<String>,
                              using catalog: ITunesSearchClient) {
        guard !personalLoading else { return }
        // No seeds means no listening history to build from — a fresh account, or
        // one that was just wiped. Bailing out here left whatever had been built
        // before standing, which is how a cleared library kept a full page of
        // "Made for you" mixes and a "Built from " line with nothing in it.
        guard !seeds.isEmpty else {
            if !personal.isEmpty { forgetPersonalLanding(.everything) }
            return
        }

        // An empty library says the same thing, and it's the case seeds alone
        // miss: a wipe that arrives from another device takes the songs but
        // leaves this machine's play history standing, so there are still seeds
        // to build from and the fingerprint never changes. The page then comes
        // back after a relaunch exactly as it was, recommending around a library
        // that no longer exists. `known` is the library's own key set, so its
        // being empty *is* the library being empty.
        guard !known.isEmpty else {
            if !personal.isEmpty { forgetPersonalLanding(.everything) }
            return
        }

        let fingerprint = RecommendationEngine.fingerprint(seeds: seeds)
        if !personal.isEmpty,
           personal.fingerprint == fingerprint,
           let loadedAt = personalLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.personalTTL { return }

        personalLoading = true
        Task { @MainActor in
            defer { self.personalLoading = false }
            var landing = await RecommendationEngine.build(seeds: seeds,
                                                           radarSeeds: radarSeeds,
                                                           excluding: known,
                                                           using: catalog)
            // Same rule as the browse landing: an outage returns empty on every
            // leg, and stale rows beat a page that just emptied itself.
            guard !landing.isEmpty else { return }

            // The rest of the page is allowed to move whenever it's rebuilt —
            // new releases and recommendations are supposed to. The mixes are
            // not: they belong to the week, and every rebuild redraws them from
            // a radio that answers differently each time it's asked. A set
            // already drawn for this edition therefore wins over the one that
            // just came back. See `MixEditionStore`.
            let edition = RecommendationEngine.edition()
            landing.mixes = MixEditionStore.reconcile(landing.mixes,
                                                      edition: edition,
                                                      limit: RecommendationEngine.maxSeeds)

            self.personal = landing
            self.personalLoadedAt = Date()
            self.recommendedRoll = 0

            // Second pass, after the page is on screen. Everything above is
            // one round of Deezer calls; these two shelves are a rate-limited
            // lookup per artist and a fetch per radio, so they arrive when they
            // arrive rather than holding the whole landing behind them.
            self.loadShelves(radarSeeds: radarSeeds.isEmpty ? seeds : radarSeeds,
                             genreSeeds: genreSeeds.isEmpty ? seeds : genreSeeds,
                             using: catalog)
        }
    }

    private func loadShelves(radarSeeds: [String],
                             genreSeeds: [String],
                             using catalog: ITunesSearchClient) {
        shelvesTask?.cancel()
        shelvesLoading = true
        shelvesTask = Task { @MainActor in
            defer { self.shelvesLoading = false }

            // All three in flight at once, but published one at a time as they
            // land — awaited fastest-first, so the two Deezer shelves aren't
            // held behind genre clustering, which talks to a service that
            // allows one request a second. Awaiting all three together is what
            // made every shelf take as long as the slowest one.
            // Radios first, and not only in the awaiting: they cost about a
            // dozen requests to the radar's two dozen, and the Deezer gate is
            // first-come — started second, the radios shelf waited out every
            // one of the radar's reservations before it got a slot.
            async let radiosLeg = StationBuilder.stations(edition: RecommendationEngine.edition(),
                                                          using: catalog)
            async let radarLeg  = RecommendationEngine.releaseRadarIfNeeded(seeds: radarSeeds,
                                                                           using: catalog)
            async let genresLeg = StationBuilder.genreMixes(artists: genreSeeds, using: catalog)

            // Nothing back means a failed leg, and a shelf that was correct a
            // second ago beats one that just emptied itself.
            let radios = await radiosLeg
            if !radios.isEmpty, !Task.isCancelled { self.personal.stations = radios }

            if let radar = await radarLeg, !Task.isCancelled {
                self.personal.releaseRadar = radar
            }

            let genres = await genresLeg
            if !genres.isEmpty, !Task.isCancelled { self.personal.genreMixes = genres }
        }
    }

    /// Next twelve from the pool. No fetch — the pool is already five times the
    /// size of the row for exactly this.
    func rollRecommended() {
        guard !personal.recommendedPool.isEmpty else { return }
        recommendedRoll += 1
    }

    // MARK: - Drill-down pages

    /// A fresh cached catalogue, if there is one. Synchronous so a page walked
    /// back to can render populated instead of showing its spinner again.
    func cachedArtistCatalogue(for artist: OnlineArtist) -> ArtistCatalogue? {
        artistPages.value(for: artist.id)
    }

    func artistCatalogue(for artist: OnlineArtist, using catalog: ITunesSearchClient) async -> ArtistCatalogue {
        if let hit = artistPages.value(for: artist.id) { return hit }
        let fetched = await catalog.artistCatalogue(for: artist)
        // An empty catalogue is a failed lookup, not a fact about the artist —
        // caching it would make the failure stick for the next half hour.
        if !fetched.top.isEmpty || !fetched.albums.isEmpty {
            artistPages.insert(fetched, for: artist.id)
        }
        return fetched
    }

    func cachedAlbumTracks(for album: OnlineAlbum) -> [OnlineTrack]? {
        albumPages.value(for: album.id)
    }

    func albumTracks(for album: OnlineAlbum, using catalog: ITunesSearchClient) async -> [OnlineTrack] {
        if let hit = albumPages.value(for: album.id) { return hit }
        let fetched = await catalog.albumTracks(album: album)
        if !fetched.isEmpty { albumPages.insert(fetched, for: album.id) }
        return fetched
    }

    func cachedGenreArtists(for genre: BrowseGenre) -> [OnlineArtist]? {
        genrePages.value(for: genre.id)
    }

    func genreArtists(for genre: BrowseGenre, using catalog: ITunesSearchClient) async -> [OnlineArtist] {
        if let hit = genrePages.value(for: genre.id) { return hit }
        let fetched = await catalog.genreArtists(genreId: genre.id)
        if !fetched.isEmpty { genrePages.insert(fetched, for: genre.id) }
        return fetched
    }
}

// MARK: - Timed cache

/// A small time-boxed, size-capped memo. Enough to make walking back up the
/// drill-down stack instant, without letting a long browsing session grow the
/// process unbounded.
private struct TimedCache<Key: Hashable, Value> {
    let ttl: TimeInterval
    let limit: Int

    private var entries: [Key: (value: Value, at: Date)] = [:]
    /// Insertion order, used to evict the oldest key once `limit` is passed.
    private var order: [Key] = []

    init(ttl: TimeInterval, limit: Int) {
        self.ttl = ttl
        self.limit = limit
    }

    func value(for key: Key) -> Value? {
        guard let hit = entries[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if entries[key] == nil { order.append(key) }
        entries[key] = (value, Date())
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}
