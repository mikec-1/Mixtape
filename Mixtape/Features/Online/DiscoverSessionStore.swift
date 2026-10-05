// Discover's session state, outliving the views. macOS swaps the content
// column on section change, which would drop results and the drill-down stack.
// Doesn't own the macOS search text (that's `MacAppState.searchText`); it only
// remembers which query the results belong to.

import Foundation
import Combine
import Supabase
#if os(iOS)
import UIKit
#endif

@MainActor
final class DiscoverSessionStore: ObservableObject {

    /// A singleton, like `ArtworkWashTint.shared`, so Discover keystrokes don't republish through `deps`.
    static let shared = DiscoverSessionStore()

    private init() {
        // The last stored shelves, so the first frame isn't blank. `loadPersonalIfNeeded` swaps in this week's.
        var stored = MixEditionStore.cached(.mixes, as: LandingWire.self)?.landing(keeping: .empty) ?? .empty
        stored.releaseRadar = MixEditionStore.cached(.radar)
        stored.stations     = MixEditionStore.cached(.stations) ?? []
        stored.genreMixes   = MixEditionStore.cached(.genres) ?? []
        raw      = stored
        personal = stored.filtered()

        // "Don't suggest" applies to what's already on screen.
        NotificationCenter.default.addObserver(
            forName: .suggestionFeedbackChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.personal = self.raw.filtered()
            }
        }

        // A library or history wipe invalidates everything here, including stored mixes.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            let reset = UserDataReset.from(note)
            MainActor.assumeIsolated { self?.forgetPersonalLanding(reset) }
        }

        #if os(iOS)
        // Leaving the app ends the search. macOS quits too fast to send it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushUnpickedSearch(replacing: nil) }
        }
        #endif
    }

    /// Drops the derived landing and the stored shelves after a reset. An account
    /// switch leaves the old account's rows alone.
    private func forgetPersonalLanding(_ reset: UserDataReset) {
        guard reset.clearedLibrary || reset.clearedHistory else { return }
        MixEditionStore.clear(remote: !reset.isAccountSwitch)
        clearPersonal()
        artistPages.removeAll()
    }

    /// Display only. The stored shelves stay, since they belong to the account.
    private func clearPersonal() {
        shelvesTask?.cancel()
        raw               = .empty
        personalPrint     = nil
        personalLoadedAt  = nil
        recommendedRoll   = 0
    }

    // MARK: - Search results

    /// What the results list is showing. Mutated in place when the lyric leg lands.
    @Published var results = DiscoverResults()

    /// Drives the spinner from query accepted until the lyric leg finishes.
    @Published var isSearching = false

    /// The trimmed query `results` answer, "" when none. Matched against the restored search field.
    @Published private(set) var resultsQuery = ""

    /// iOS only: its own `.searchable` text, kept across tab switches.
    @Published var iosQuery = ""

    /// The query a running search is for, so a rebuilt view doesn't fire a duplicate.
    private var inFlightQuery: String?
    private var searchTask: Task<Void, Never>?

    // MARK: - Drill-down

    /// Drill-down stack; empty is results/landing. `DiscoverDestination` is declared
    /// once per platform (OnlineDiscoverView / IOSDiscoverComponents) with the same cases.
    @Published var path: [DiscoverDestination] = [] {
        didSet { if path.count > oldValue.count { noteSearchPick() } }
    }

    /// Bumped when a query is committed with Return, which unwinds the stack.
    /// A counter so two Returns on the same text both register.
    @Published private(set) var searchCommitToken = 0

    /// Call on Return. Unwinds here too, since committing from outside Discover
    /// mounts a fresh view that never sees the token change.
    func commitSearch() {
        searchCommitToken &+= 1
        path.removeAll()
    }

    // MARK: - Scroll anchors

    /// Top visible section, for restoring scroll position.
    @Published var resultsAnchor: String?
    @Published var browseAnchor: String?

    // MARK: - Browse landing

    @Published private(set) var browse = BrowseLanding()
    @Published private(set) var browseLoading = false
    private var browseLoadedAt: Date?

    /// Charts and new releases change over hours, so refetch every half hour.
    private static let browseTTL: TimeInterval = 30 * 60

    // MARK: - Personalized landing

    /// What Discover shows: the stored shelves minus "Don't suggest" songs and artists.
    @Published private(set) var personal = PersonalLanding.empty
    /// The stored shelves as built. Kept unfiltered so un-hiding brings rows back.
    private var raw = PersonalLanding.empty { didSet { personal = raw.filtered() } }
    @Published private(set) var personalLoading = false

    /// Release Radar, genre and radio shelves still loading. Drives their placeholder cards.
    @Published private(set) var shelvesLoading = false
    private var shelvesTask: Task<Void, Never>?
    private var personalLoadedAt: Date?
    /// This device's seeds at the last load. The stored landing carries the building device's.
    private var personalPrint: String?

    /// Which slice of `personal.recommendedPool` is showing. Refresh bumps it, no network.
    @Published private(set) var recommendedRoll = 0

    /// Longer than the browse TTL: listening changes and the week turning over
    /// invalidate by fingerprint. Mixes are pinned to the week, so a rebuild redraws the same ones.
    private static let personalTTL: TimeInterval = 6 * 60 * 60

    // MARK: - Drill-down page memo

    typealias ArtistCatalogue = OnlineArtistCatalogue

    /// Same half-hour rule as the landing, for the same reason.
    private static let pageTTL: TimeInterval = 30 * 60

    private var artistPages = TimedCache<Int, ArtistCatalogue>(ttl: pageTTL, limit: 24)
    private var albumPages  = TimedCache<Int, [OnlineTrack]>(ttl: pageTTL, limit: 24)
    private var genrePages  = TimedCache<Int, [OnlineArtist]>(ttl: pageTTL, limit: 24)

    // MARK: - Search

    /// Debounced search. No-ops when the same query is already held or in flight.
    func search(_ text: String, using catalog: ITunesSearchClient, immediate: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Cleared field: back to the landing. Cancel first so a late response can't refill it.
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            searchTask = nil
            inFlightQuery = nil
            results = DiscoverResults()
            resultsQuery = ""
            resultsAnchor = nil
            isSearching = false
            flushUnpickedSearch(replacing: nil)
            return
        }

        guard trimmed != inFlightQuery else { return }
        // Answered with results already. Empty results aren't treated as answered, since they may be a dropped connection.
        guard !(trimmed == resultsQuery && !results.isEmpty) else { return }

        // Only a different query supersedes the running one.
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
                // Only the current search may clear these.
                if self.inFlightQuery == trimmed {
                    self.inFlightQuery = nil
                    self.isSearching = false
                }
            }
            let grouped = await catalog.discoverSearch(query: trimmed)
            if Task.isCancelled { return }
            self.results = grouped
            self.resultsQuery = trimmed
            self.flushUnpickedSearch(replacing: trimmed)
            self.pendingSearch = trimmed

            // Lyric search runs after so the main results show instantly.
            let lyricHits = await catalog.searchByLyrics(trimmed)
            if Task.isCancelled || self.resultsQuery != trimmed { return }
            // Songs already listed above don't repeat in the lyric section.
            let shown = Set(([self.results.topSong].compactMap { $0 } + self.results.songs).map(\.id))
            self.results.lyricMatches = lyricHits.filter { !shown.contains($0.id) }
        }
    }

    // MARK: - Search analytics

    /// The last query that got results and nothing has been played or opened from yet.
    private var pendingSearch: String?

    /// A result was played or opened, so the pending search worked.
    func noteSearchPick() {
        guard let query = pendingSearch else { return }
        pendingSearch = nil
        Analytics.track("search", ["query": .string(query), "clicked": .bool(true)])
    }

    /// Logs the pending search as a miss when the user moves on without picking anything.
    /// ponytail: backspacing ("radiohead" -> "radio") also counts as a miss; fine for a rough signal.
    private func flushUnpickedSearch(replacing next: String?) {
        guard let query = pendingSearch else { return }
        // Typing on ("radio" -> "radiohead") refines the same search.
        if let next, next.lowercased().hasPrefix(query.lowercased()) { return }
        pendingSearch = nil
        Analytics.track("search", ["query": .string(query), "clicked": .bool(false)])
    }

    // MARK: - Browse landing

    /// The same fetch ignoring the cache, for pull-to-refresh. Awaitable so the spinner stays up.
    func reloadBrowse(using catalog: ITunesSearchClient) async {
        browseLoading = true
        defer { browseLoading = false }
        let landing = await catalog.browseLanding()
        guard !landing.isEmpty else { return }
        browse       = landing
        browseLoadedAt = Date()
    }

    /// Fetches the landing content at most once per `browseTTL`. Cheap to call on every appear.
    func loadBrowseIfNeeded(using catalog: ITunesSearchClient) {
        guard !browseLoading else { return }
        if !browse.isEmpty,
           let loadedAt = browseLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.browseTTL { return }

        browseLoading = true
        Task { @MainActor in
            defer { self.browseLoading = false }
            let landing = await catalog.browseLanding()
            // A failed fetch is empty; keep the stale landing.
            guard !landing.isEmpty else { return }
            self.browse = landing
            self.browseLoadedAt = Date()
        }
    }

    // MARK: - Personalized landing

    /// Builds "made for you" at most once per `personalTTL`, or whenever the
    /// fingerprint changes. Callers compute seeds since this store owns no dependencies.
    /// The shelf inputs walk the library, so they're only worked out when something is built.
    func loadPersonalIfNeeded(seeds: [String],
                              radarSeeds: @autoclosure () -> [String] = [],
                              genreSeeds: @autoclosure () -> [String] = [],
                              genreTitles: @autoclosure () -> [String: String] = [:],
                              known: Set<String>,
                              using catalog: ITunesSearchClient) {
        guard !personalLoading else { return }
        // No seeds means no history, so clear the page rather than leave old mixes.
        guard !seeds.isEmpty else {
            if !personal.isEmpty { clearPersonal() }
            return
        }

        // An empty library means the same, even when a remote wipe left this device's play history.
        guard !known.isEmpty else {
            if !personal.isEmpty { clearPersonal() }
            return
        }

        let fingerprint = RecommendationEngine.fingerprint(seeds: seeds)
        if !personal.isEmpty,
           personalPrint == fingerprint,
           let loadedAt = personalLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.personalTTL { return }

        personalLoading = true
        let radar = radarSeeds(), genres = genreSeeds(), titles = genreTitles()
        Task { @MainActor in
            defer { self.personalLoading = false }
            // The account's copy of this week wins; this device builds only when there's none.
            let wire: LandingWire? = await MixEditionStore.shelf(.mixes, edition: RecommendationEngine.edition()) {
                let built = await RecommendationEngine.build(seeds: seeds,
                                                             radarSeeds: radar,
                                                             excluding: known,
                                                             using: catalog)
                // An outage returns empty; keep the stale rows.
                guard !built.isEmpty else { return nil }
                return (LandingWire(built), built.mixes.count >= RecommendationEngine.minimumMixes)
            }
            guard let wire else { return }

            self.raw = wire.landing(keeping: self.raw)
            self.personalPrint = fingerprint
            self.personalLoadedAt = Date()
            self.recommendedRoll = 0

            // The slow shelves load after the page is on screen.
            self.loadShelves(radarSeeds: radar.isEmpty ? seeds : radar,
                             genreSeeds: genres.isEmpty ? seeds : genres,
                             genreTitles: titles,
                             using: catalog)
        }
    }

    private func loadShelves(radarSeeds: [String],
                             genreSeeds: [String],
                             genreTitles: [String: String],
                             using catalog: ITunesSearchClient) {
        shelvesTask?.cancel()
        shelvesLoading = true
        shelvesTask = Task { @MainActor in
            defer { self.shelvesLoading = false }

            // All three in flight, published as each lands, fastest first. Radios start
            // first since the Deezer gate is first-come and they need fewer requests.
            // Each is the account's copy when there is one, see `MixEditionStore`.
            async let radiosLeg: [PersonalMix]? = MixEditionStore.shelf(.stations, edition: RecommendationEngine.edition()) {
                let radios = await StationBuilder.stations(using: catalog)
                return radios.isEmpty ? nil : (radios, true)
            }
            async let radarLeg: PersonalMix? = MixEditionStore.shelf(.radar, edition: RecommendationEngine.radarEdition()) {
                await RecommendationEngine.releaseRadar(seeds: radarSeeds, using: catalog).map { ($0, true) }
            }
            async let genresLeg: [PersonalMix]? = MixEditionStore.shelf(.genres, edition: RecommendationEngine.edition()) {
                await StationBuilder.genreMixes(artists: genreSeeds, titles: genreTitles, using: catalog)
            }

            // Nothing back means a failed leg; keep the old shelf.
            if let radios = await radiosLeg, !Task.isCancelled { self.raw.stations = radios }
            if let radar = await radarLeg, !Task.isCancelled { self.raw.releaseRadar = radar }
            if let genres = await genresLeg, !Task.isCancelled { self.raw.genreMixes = genres }
        }
    }

    /// Next twelve from the pool, no fetch.
    func rollRecommended() {
        guard !personal.recommendedPool.isEmpty else { return }
        recommendedRoll += 1
    }

    // MARK: - Drill-down pages

    /// A fresh cached catalogue, if any, so a revisited page renders immediately.
    func cachedArtistCatalogue(for artist: OnlineArtist) -> ArtistCatalogue? {
        artistPages.value(for: artist.id)
    }

    func artistCatalogue(for artist: OnlineArtist, using catalog: ITunesSearchClient) async -> ArtistCatalogue {
        if let hit = artistPages.value(for: artist.id) { return hit }
        let fetched = await catalog.artistCatalogue(for: artist)
        // Don't cache an empty catalogue; it's a failed lookup.
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

/// Small time-boxed, size-capped memo for walking back up the drill-down stack.
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
