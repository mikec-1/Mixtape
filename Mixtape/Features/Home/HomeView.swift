// The library half of the landing page: greeting, a resume shelf, recent
// artists and the library carousels.
// HomeSections  - content only, no scroll view or margins, drawn in bands
// (see `HomeBands`) so the landing can place them around its
// own "Made for you".
// HomeStatsCard - the listening-stats card, drawn last on the landing.
// HomeView      - both inside a ScrollView, for hosts that want Home as a page.
// Playback goes through the injected `onPlay` so the host can route online
// tracks via OnlinePlaybackCoordinator. Artist taps go through `onArtist`.

import SwiftUI
import SwiftData
import Combine

// MARK: - Quick-link destinations
// Quick-link chip targets. The host maps them onto its own navigation.

public enum HomeQuickLink: Hashable {
    case songs, albums, artists, playlists
}

// MARK: - Bands
// Which parts of Home to draw. The landing renders Home twice, top bands above
// its "Made for you" and library bands below.

public struct HomeBands: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Greeting and the jump-back-in shelf. The page opener.
    public static let top     = HomeBands(rawValue: 1 << 0)
    /// Recent artists, "Made for you", recently added, favourites.
    public static let library = HomeBands(rawValue: 1 << 1)
    /// Smart-playlist shelves, placed near "Because you listened to...".
    public static let smart   = HomeBands(rawValue: 1 << 2)

    public static let all: HomeBands = [.top, .smart, .library]
}

// MARK: - Sections

/// Home's derived shelves, recomputed only when the library revision, play
/// history or artist artwork changes, not on every body evaluation.
@MainActor
private final class HomeShelvesMemo: ObservableObject {

    private struct Key: Equatable {
        var revision: UInt64
        var history: [String]
        var remoteArtKeys: Int
    }

    private var key: Key?
    private var inFlight: Task<Void, Never>?

    @Published private(set) var recentlyPlayed: [Track] = []
    @Published private(set) var recentlyAdded:  [Track] = []
    @Published private(set) var favourites:     [Track] = []
    @Published private(set) var recommendations: [Track] = []
    @Published private(set) var artists: [HomeArtist] = []

    /// Stable key -> where to read a played song's cover from. See `update`.
    @Published private(set) var playedArtwork: [String: ArtworkRef] = [:]

    /// Artwork for a played song, falling back to its own id.
    func artworkRef(for track: Track) -> ArtworkRef {
        playedArtwork[Self.stableKey(track)] ?? .track(track.id)
    }

    // Online tracks get a new UUID each play, so they're keyed by file hash. Local
    // tracks use their `id`.
    nonisolated static func stableKey(_ track: Track) -> String {
        track.file.fileHash.isEmpty ? track.id.uuidString : track.file.fileHash
    }

    /// "Same song" for the recently-played strip: by what it prints, since a library
    /// row and an online row for one song have different stable keys.
    nonisolated private static func songKey(_ track: Track) -> String {
        let t = track.displayTitle.lowercased()
        let a = track.displayArtistName.lowercased()
        return t.isEmpty && a.isEmpty ? stableKey(track) : "\(t)|\(a)"
    }

    nonisolated private static func deduped(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for track in tracks where seen.insert(songKey(track)).inserted {
            result.append(track)
        }
        return result
    }

    func update(revision: UInt64,
                history: [Track],
                remoteArtwork: [String: Data],
                library: LibraryService,
                stats: @escaping @MainActor () -> ListeningStats) {
        let historyKeys = history.map(Self.stableKey)
        let next = Key(revision: revision,
                       history: historyKeys,
                       remoteArtKeys: remoteArtwork.count)
        guard key != next else { return }

        // Wait while the library is mid-sync: a sync publishes many times, and every
        // rebuild but the last would be thrown away. `activity` is `@Published`, so going
        // idle re-runs this with the stale key. The first build never waits.
        if key != nil, library.activity != .idle { return }

        key = next

        // Outputs are `@Published` and this is called from `body`, so work happens in a
        // task to avoid publishing during a view update.
        // History shelves are small and need main-actor state, so they stay here. The
        // whole-library passes run off the main actor. A newer key cancels an in-flight pass.
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            mixMainActivity("home-shelves/history") {
                let recents = Array(Self.deduped(history).prefix(12))
                self.recentlyPlayed = recents

                // Borrow the library's cover for a played song. Online history rows get a new id
                // each play, so `.track(track.id)` would point at nothing.
                var refs: [String: ArtworkRef] = [:]
                for track in recents {
                    let key = Self.stableKey(track)
                    if track.artworkData != nil
                        || ArtworkProvider.shared.data(for: .track(track.id)) != nil {
                        refs[key] = .track(track.id)
                        continue
                    }
                    if let owned = library.track(matching: track.title,
                                                 artistName: track.artistName,
                                                 duration: track.duration) {
                        refs[key] = .track(owned.id)
                    } else {
                        refs[key] = .track(track.id)
                    }
                }
                self.playedArtwork = refs

                // Distinct artists from the play history, in order.
                var seenNames = Set<String>()
                var rows: [HomeArtist] = []
                // Split the credit so "Dave, Stormzy" becomes two artists. The stored
                // `artistName` stays as is (it's part of the identity).
                outer: for track in history {
                    for name in ImportService.creditedArtists(from: track.artistName) {
                        let lowered = name.lowercased()
                        guard seenNames.insert(lowered).inserted else { continue }
                        let row = library.artist(named: name)
                        rows.append(HomeArtist(name: name,
                                               artworkData: row?.artworkData ?? remoteArtwork[lowered],
                                               artworkRef: row.map { .artist($0.id) }))
                        if rows.count >= 12 { break outer }
                    }
                }
                self.artists = rows
            }

            let tracks       = library.tracks
            let favouriteIDs = library.favouriteIDs()
            let topNames     = stats().topArtists.map(\.name)
            let recentKeys   = Set(historyKeys.prefix(12))

            // `Task.detached`, not `nonisolated async`, which runs on the caller's actor
            // under SE-0461. See `LibrarySnapshotReader`.
            let shelves = await Task.detached(priority: .userInitiated) {
                Self.libraryShelves(tracks: tracks,
                                    favouriteIDs: favouriteIDs,
                                    topNames: topNames,
                                    recentKeys: recentKeys)
            }.value
            guard !Task.isCancelled else { return }
            self.recentlyAdded   = shelves.recentlyAdded
            self.favourites      = shelves.favourites
            self.recommendations = shelves.recommendations
        }
    }

    private struct LibraryShelves: Sendable {
        var recentlyAdded:   [Track]
        var favourites:      [Track]
        var recommendations: [Track]
    }

    /// The whole-library passes. Pure; keep main-actor state out of here.
    nonisolated private static func libraryShelves(tracks: [Track],
                                                   favouriteIDs: Set<UUID>,
                                                   topNames: [String],
                                                   recentKeys: Set<String>) -> LibraryShelves {
        // Sorted once, reused by the shelf and the recommendation fallback.
        let newestFirst = tracks.sorted { $0.dateImported > $1.dateImported }
        let recentlyAdded = Array(deduped(newestFirst).prefix(12))

        let favouriteTracks = tracks.filter { favouriteIDs.contains($0.id) }
        let favourites = Array(deduped(favouriteTracks).prefix(12))

        // "Made for you": top artists' library tracks minus recent plays, topped up from
        // favourites and new arrivals.
        var picks: [Track] = []
        if !topNames.isEmpty {
            // One pass bucketed by artist instead of a scan per top artist.
            var byArtist: [String: [Track]] = [:]
            for track in tracks {
                byArtist[track.artistName.lowercased(), default: []].append(track)
            }
            for name in topNames {
                let matches = (byArtist[name.lowercased()] ?? [])
                    .filter { !recentKeys.contains(stableKey($0)) }
                picks.append(contentsOf: matches)
            }
        }
        if picks.count < 6 { picks.append(contentsOf: favouriteTracks) }
        if picks.count < 6 { picks.append(contentsOf: newestFirst) }

        return LibraryShelves(recentlyAdded: recentlyAdded,
                              favourites: favourites,
                              recommendations: Array(deduped(picks).prefix(12)))
    }
}

public struct HomeSections: View {

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    /// For "Recently played" playlists.
    @ObservedObject private var meta = PlaylistMetadataService.shared

    /// Observed so deleting a smart playlist updates the shelf.
    @EnvironmentObject private var smartService: SmartPlaylistService

    /// Invoked when a quick-link chip is tapped. Host translates navigation.
    private let onQuickLink: (HomeQuickLink) -> Void

    /// Plays a track in a context. The host routes online vs. local playback. No-op by default.
    private let onPlay: (_ track: Track, _ context: [Track], _ origin: String) -> Void

    /// Recent-artist tap. No-op by default.
    private let onArtist: (_ name: String) -> Void

    /// "Recently played" playlist tap. macOS swaps the content column; iOS pushes
    /// `navPlaylist` instead.
    private let onPlaylist: (Playlist) -> Void

    /// "Made by Mixtape" tap. macOS swaps the content column; iOS pushes.
    private let onSmartPlaylist: (SmartPlaylist) -> Void

    /// Off when the host shows its own online "Made for you".
    private let showsRecommendations: Bool

    /// Which stretches of the page this instance draws. See `HomeBands`.
    private let bands: HomeBands

    #if os(iOS)
    @State private var navPlaylist: Playlist? = nil
    @State private var navSmart: SmartPlaylist? = nil
    #endif

    /// Recent artists collapse to one row until expanded.
    @State private var showsAllArtists = false

    /// A smart playlist with the rows its rule currently matches.
    typealias SmartEntry = (playlist: SmartPlaylist, tracks: [Track])
    /// Smart playlists resolved to their tracks, in `.task` rather than `body` since it scans the library.
    @State private var allSmartLists: [SmartEntry] = []
    @State private var showsSmartEditor = false
    @State private var showsTapes = false
    /// The tape picked in the archive, opened once its sheet has gone.
    @State private var pendingTape: SmartPlaylist? = nil

    /// "This week, one year ago", most played first.
    @State private var yearAgo: [Track] = []

    /// Spotify profile images for Discover-only recent artists (no library
    /// `Artist` row), keyed by lowercased name.
    @State private var remoteArtistArtwork: [String: Data] = [:]

    /// See `HomeShelvesMemo`.
    @StateObject private var shelves = HomeShelvesMemo()

    public init(
        onQuickLink: @escaping (HomeQuickLink) -> Void = { _ in },
        onPlay: @escaping (_ track: Track, _ context: [Track], _ origin: String) -> Void = { _, _, _ in },
        onArtist: @escaping (_ name: String) -> Void = { _ in },
        onPlaylist: @escaping (Playlist) -> Void = { _ in },
        onSmartPlaylist: @escaping (SmartPlaylist) -> Void = { _ in },
        showsRecommendations: Bool = true,
        bands: HomeBands = .all
    ) {
        self.onQuickLink = onQuickLink
        self.onPlay = onPlay
        self.onArtist = onArtist
        self.onPlaylist = onPlaylist
        self.onSmartPlaylist = onSmartPlaylist
        self.showsRecommendations = showsRecommendations
        self.bands = bands
    }

    // MARK: Derived data

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Good night"
        }
    }

    private var displayName: String? {
        let name = deps.authService.currentUser?.displayName
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return nil
    }

    /// "Good evening, Mike".
    private var greetingLine: String {
        guard let displayName else { return greeting }
        // Only the first name: "Good evening, Mike Schmidt" is a form letter.
        let first = displayName.split(separator: " ").first.map(String.init) ?? displayName
        return "\(greeting), \(first)"
    }

    private var greetingIcon: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<22: return "sunset.fill"
        default:      return "moon.stars.fill"
        }
    }

    /// One line under the greeting, preferring what the user was doing.
    private var greetingSubline: String {
        if let last = recentlyPlayed.first {
            return "Pick up where you left off: \(last.title)"
        }
        if isLibraryEmpty { return "Your library is waiting to be filled" }
        // Intentionally empty for now.
        return ""
    }

    /// Artwork the page is tinted from: the last played song.
    public static func washSource(engine: PlaybackEngine, library: LibraryService) -> Data? {
        engine.recentlyPlayed.first?.displayArtwork
            ?? library.tracks.max { $0.dateImported < $1.dateImported }?.displayArtwork
    }

    /// Whether the `.library` band draws anything, so the landing doesn't draw a rule
    /// above nothing. Library tracks or recent plays are enough.
    public static func hasLibraryContent(engine: PlaybackEngine, library: LibraryService) -> Bool {
        !library.tracks.isEmpty || !engine.recentlyPlayed.isEmpty
    }

    /// Updates `shelves` if its inputs moved and returns it.
    private var lists: HomeShelvesMemo {
        shelves.update(revision:      library.revision,
                       history:       engine.recentlyPlayed,
                       remoteArtwork: remoteArtistArtwork,
                       library:       library,
                       stats:         { deps.statsService.compute(period: .allTime) })
        return shelves
    }

    /// Recently played, deduped by stable key.
    private var recentlyPlayed: [Track] { lists.recentlyPlayed }

    private var recentlyAdded: [Track] { lists.recentlyAdded }

    private var favourites: [Track] { lists.favourites }

    /// "Made for you" from local data only: top artists' tracks not played recently,
    /// falling back to favourites and recent imports.
    private var recommendations: [Track] { lists.recommendations }

    /// Distinct artists from recent plays, matched to library `Artist`s for artwork.
    private var recentArtists: [HomeArtist] { lists.artists }

    /// Playlists the user played, newest first. Deleted ones are skipped.
    private var recentPlaylists: [Playlist] {
        meta.playlistLastPlayedDates
            .sorted { $0.value > $1.value }
            .compactMap { entry in library.playlists.first { $0.id == entry.key } }
            .prefix(12)
            .map { $0 }
    }

    private var isLibraryEmpty: Bool { library.tracks.isEmpty }

    /// Nothing to show: no library and no play history. Discover-only users still have history.
    private var hasNothingToShow: Bool { isLibraryEmpty && recentlyPlayed.isEmpty }

    // MARK: The shelf

    /// One resume shelf mixing songs and playlists. Playlists take the last two slots
    /// so a playlist session doesn't push the playlist itself off the shelf.
    private var shortcuts: [HomeShortcut] {
        let playlists = recentPlaylists.prefix(2).map { HomeShortcut.playlist($0) }
        let songs = recentlyPlayed
            .prefix(Self.shelfCapacity - playlists.count)
            .map { HomeShortcut.track($0) }
        return songs + playlists
    }

    /// Two rows of four on a wide window, four of two on a phone.
    private static let shelfCapacity = 8

    /// Two fixed columns on a phone; the adaptive minimum only fits one.
    #if os(iOS)
    private static let shortcutColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    #else
    private static let shortcutColumns = [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 8)]
    #endif

    /// Artists shown before "Show all". One row at any usable width.
    private static let collapsedArtistCount = 6

    // MARK: Stable de-dup
    // Online tracks get a new UUID each play, so dedupe by stable key instead of `id`.

    private func stableKey(_ track: Track) -> String {
        HomeShelvesMemo.stableKey(track)
    }

    /// Re-resolves on a library change or a smart-playlist change.
    private var smartKey: String {
        "\(library.revision)#" + smartService.playlists.map(\.id.uuidString).joined(separator: ",")
    }

    /// Warm-up task identity: stable keys of the top songs, so fresh online `Track` values don't restart it.
    private var prefetchKey: String {
        recentlyPlayed.prefix(6).map(stableKey).joined(separator: "\u{1F}")
    }

    /// Keep the first occurrence per stable key, preserving order.
    private func deduped(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for track in tracks where seen.insert(stableKey(track)).inserted {
            result.append(track)
        }
        return result
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if bands.contains(.top) {
                // A phone's Home has its own header row, so no greeting.
                #if os(macOS)
                header
                #endif

                RecapHomeSlot(recap: deps.recap, onTape: openSmart)

                if hasNothingToShow {
                    emptyState
                } else {
                    if !shortcuts.isEmpty { shortcutShelf }
                }
            }

            // Each band hides itself when empty.
            if bands.contains(.smart), !hasNothingToShow {
                if !smartLists.isEmpty { smartShelf }
                mySmartShelf
            }

            if bands.contains(.library), !hasNothingToShow {
                if !recentArtists.isEmpty {
                    artistRow(title: "Recent artists", artists: recentArtists)
                }
                if yearAgo.count >= Self.minimumYearAgo {
                    carousel(title: "This week, one year ago", tracks: yearAgo)
                }
                if showsRecommendations, !recommendations.isEmpty {
                    carousel(title: "Made for you", tracks: recommendations)
                }
                libraryColumns
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Prewarm the top songs while the page is visible, like album, artist and
        // playlist pages do. Songs with a local file are skipped. Only the band that
        // draws the shelf does it, since the landing renders this view twice.
        .task(id: smartKey) {
            guard bands.contains(.smart) else { return }
            let history = PlayHistoryRepository()
            let service = smartService
            // A new month, or history synced in from before, needs its tape first.
            service.ensureMonthTapes(history: history)
            allSmartLists = service.playlists.compactMap { playlist in
                guard !SmartPlaylistService.isArchivedTape(playlist) else { return nil }
                let tracks = deps.smartTracks(playlist)
                // Shipped rules need enough songs to fill a card. See `isWorthShowing`.
                guard SmartPlaylistService.isWorthShowing(playlist, count: tracks.count) else { return nil }
                return (playlist, tracks)
            }
        }
        .sheet(isPresented: $showsSmartEditor) {
            SmartPlaylistEditorView(service: smartService)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showsTapes, onDismiss: {
            if let tape = pendingTape { pendingTape = nil; openSmart(tape) }
        }) {
            TapeArchiveView(service: smartService) { pendingTape = $0 }
                .environmentObject(engine)
                .environmentObject(library)
        }
        .task(id: prefetchKey) {
            guard bands.contains(.top) else { return }
            deps.onlineCoordinator.prefetchResolvable(Array(recentlyPlayed.prefix(6)))
        }
        .task(id: library.revision) {
            guard bands.contains(.library) else { return }
            yearAgo = Self.yearAgo(in: library)
        }
        #if os(iOS)
        .navigationDestination(item: $navSmart) { playlist in
            SmartPlaylistDetailView(playlist: playlist, service: smartService)
                .environmentObject(deps)
                .environmentObject(engine)
        }
        .navigationDestination(item: $navPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
                .environmentObject(deps)
                .environmentObject(engine)
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: greetingIcon)
                    .font(.system(size: greetingSize * 0.62, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolRenderingMode(.hierarchical)

                // Top-to-bottom fade on the title so it sits in the wash.
                Text(greetingLine)
                    .font(.system(size: greetingSize, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.mixTextPrimary, Color.mixTextPrimary.opacity(0.74)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if !greetingSubline.isEmpty {
                Text(greetingSubline)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var greetingSize: CGFloat {
        #if os(macOS)
        32
        #else
        26
        #endif
    }

    // MARK: The shelf
    // Shortcut grid: short, wide tiles with the artwork on the leading edge.

    private var shortcutShelf: some View {
        LazyVGrid(columns: Self.shortcutColumns, spacing: 8) {
            ForEach(shortcuts) { shortcut in
                switch shortcut {
                case .track(let track):
                    RecentTile(
                        title: track.title,
                        artworkData: track.artworkData,
                        artworkRef: lists.artworkRef(for: track),
                        placeholder: MixtapeIcons.track,
                        // Hover means a click is likely; start resolving.
                        onHover: { deps.onlineCoordinator.prefetchResolvable([track], limit: 1) },
                        action: {
                            Haptics.play(.light)
                            onPlay(track, [track], "Recently played")
                        }
                    )
                    .contextMenu { trackMenu(track, origin: "Recently played") }

                case .playlist(let playlist):
                    RecentTile(
                        title: playlist.name,
                        playlist: playlist,
                        action: {
                            Haptics.play(.light)
                            openPlaylist(playlist)
                        }
                    )
                    .contextMenu { playlistMenu(playlist) }
                    #if os(macOS)
                    // Drag a card onto the sidebar to pin it.
                    .onDrag {
                        NSItemProvider(
                            object: MacAppState.playlistDragPayload(playlist.id) as NSString
                        )
                    }
                    #endif
                }
            }
        }
    }

    // MARK: Smart playlists
    // Smart playlists, generated from the same history as the rest of this page.

    private var smartShelf: some View {
        smartShelf(title: "Made by Mixtape", entries: smartLists,
                   allTapes: smartService.playlists.contains { $0.rule.tapeStart != nil } ? { showsTapes = true } : nil)
    }

    /// The user's own rules, separate from the built-in shelf. Always drawn since the
    /// trailing `+` is the only place here to make one.
    private var mySmartShelf: some View {
        smartShelf(title: "Your smart playlists", entries: mySmartLists, showsCreate: true)
    }

    /// The app's own: the monthly tapes, newest first, then the five it ships in seed order.
    private var smartLists: [SmartEntry] {
        let builtIn = allSmartLists.filter { SmartPlaylistService.isBuiltIn($0.playlist) }
        return builtIn.filter { $0.playlist.rule.tapeStart != nil }.reversed()
            + builtIn.filter { $0.playlist.rule.tapeStart == nil }
    }
    private var mySmartLists: [SmartEntry] { allSmartLists.filter { !SmartPlaylistService.isBuiltIn($0.playlist) } }

    private func smartShelf(title: String, entries: [SmartEntry], showsCreate: Bool = false,
                            allTapes: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                if let allTapes {
                    Button {
                        Haptics.play(.light)
                        allTapes()
                    } label: {
                        Text("All tapes")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixPrimary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(entries, id: \.playlist.id) { entry in
                        HomeSmartCard(playlist: entry.playlist, count: entry.tracks.count) {
                            Haptics.play(.light)
                            openSmart(entry.playlist)
                        }
                    }
                    if showsCreate {
                        NewSmartPlaylistCard {
                            Haptics.play(.light)
                            showsSmartEditor = true
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }

    /// Fewer than this and last year's week isn't worth a row.
    private static let minimumYearAgo = 5

    /// Songs played in this week last year, most played first. History is synced, so
    /// every device shows the same row.
    private static func yearAgo(in library: LibraryService, now: Date = Date()) -> [Track] {
        let calendar = Calendar.current
        guard let then = calendar.date(byAdding: .year, value: -1, to: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: then),
              let ids = try? PlayHistoryRepository().fetchTrackIDs(in: week) else { return [] }
        return Array(ListeningTrends.tapeOrder(ids).lazy
            .compactMap { library.track(id: $0) }
            .prefix(20))
    }

    private func openSmart(_ playlist: SmartPlaylist) {
        #if os(iOS)
        navSmart = playlist
        #else
        onSmartPlaylist(playlist)
        #endif
    }

    // MARK: Carousel

    /// `clipped: true` for side-by-side carousels on Mac, so neither paints or scrolls
    /// over the other.
    private func carousel(title: String, tracks: [Track], clipped: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // By id: `Track.id` is a content hash, and `\.self` would rebuild the card on any field change.
                    ForEach(tracks, id: \.id) { track in
                        HomeTrackCard(track: track) {
                            Haptics.play(.light)
                            onPlay(track, [track], title)
                        }
                        .contextMenu { trackMenu(track, origin: title) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled(!clipped)
        }
    }

    // MARK: Library columns
    // "Recently added" and "Your Liked Songs" side by side on Mac, stacked on a
    // phone. If only one has content it takes the full width.

    @ViewBuilder
    private var libraryColumns: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 28) {
            if !recentlyAdded.isEmpty {
                carousel(title: "Recently added", tracks: recentlyAdded, clipped: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !favourites.isEmpty {
                carousel(title: "Your Liked Songs", tracks: favourites, clipped: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #else
        if !recentlyAdded.isEmpty { carousel(title: "Recently added", tracks: recentlyAdded) }
        if !favourites.isEmpty    { carousel(title: "Your Liked Songs", tracks: favourites) }
        #endif
    }

    private func openPlaylist(_ playlist: Playlist) {
        #if os(iOS)
        navPlaylist = playlist
        #else
        onPlaylist(playlist)
        #endif
    }

    // MARK: Recent artists
    // A wrapping grid so names can be scanned.

    private func artistRow(title: String, artists: [HomeArtist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title)
                #if os(macOS)
                if artists.count > Self.collapsedArtistCount {
                    MixPillButton(title: showsAllArtists ? "Show less" : "Show all") {
                        withMixAnimation(.easeInOut(duration: 0.18)) { showsAllArtists.toggle() }
                    }
                }
                #endif
            }
            #if os(iOS)
            // A horizontal shelf on the phone, where the grid gets too tall.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) { artistAvatars(artists) }
            }
            .scrollClipDisabled()
            #else
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 16)],
                alignment: .leading,
                spacing: 18
            ) {
                artistAvatars(showsAllArtists ? artists : Array(artists.prefix(Self.collapsedArtistCount)))
            }
            #endif
        }
        // Keyed on all artists, so expanding doesn't refetch.
        .task(id: artists.map(\.name).joined(separator: "|")) {
            await loadRemoteArtistImages(for: artists)
        }
    }

    private func artistAvatars(_ artists: [HomeArtist]) -> some View {
        ForEach(artists) { artist in
            HomeArtistAvatar(artist: artist) {
                Haptics.play(.light)
                onArtist(artist.name)
            }
            .contextMenu { artistMenu(artist) }
        }
    }

    /// Fetches Spotify images for recent artists without artwork (Discover-only ones).
    private func loadRemoteArtistImages(for artists: [HomeArtist]) async {
        // Library artists load their cover on demand; only artists with neither need a remote image.
        let missing = artists.filter {
            $0.artworkData == nil
                && $0.artworkRef.flatMap { ref in ArtworkProvider.shared.data(for: ref) } == nil
        }.map(\.name)
        guard !missing.isEmpty else { return }
        let urls = await deps.spotifyClient.artistImages(for: missing)
        for (name, url) in urls {
            let key = name.lowercased()
            if remoteArtistArtwork[key] != nil { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                remoteArtistArtwork[key] = data
            }
        }
    }

    // MARK: Context menus
    // Same menu items as the library rows.

    /// A song plays alone, so autoplay's recommendations follow it rather than the rest of the row.
    private func trackMenu(_ track: Track, origin: String) -> some View {
        LibrarySongMenu(targets: [track], onPlay: { onPlay(track, [track], origin) })
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        Button("Open", systemImage: MixtapeIcons.playlist) { openPlaylist(playlist) }
        let tracks = playlist.trackIDs.compactMap { library.track(id: $0) }
        if let first = tracks.first {
            Button("Play", systemImage: MixtapeIcons.play) { onPlay(first, tracks, playlist.name) }
        }
        if !playlist.isSystem {
            Divider()
            PlaylistShareMenuItems(playlist: playlist)
        }
    }

    @ViewBuilder
    /// No "Open Artist": tapping the tile does that. Credit-only artists pass the
    /// remote image the tile used.
    private func artistMenu(_ artist: HomeArtist) -> some View {
        ArtistActionsMenu(name: artist.name,
                          artwork: .stored(artist.artworkData, artist.artworkRef))
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        // A first sign-in on a new device is busy pulling the library, not empty.
        if library.activity != .idle {
            EmptyStateView(
                icon: "arrow.triangle.2.circlepath",
                title: "Loading your library",
                message: "Your songs and playlists are on their way."
            )
            .padding(.vertical, 40)
        } else {
            EmptyStateView(
                icon: "music.note.house.fill",
                title: "Import music to get started",
                message: "Tracks you add or play will appear here."
            )
            .padding(.vertical, 40)
        }
    }
}

// MARK: - Listening stats card
// Separate because the landing draws it last, under the genres.

public struct HomeStatsCard: View {

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    @State private var showStats = false

    public init() {}

    public var body: some View {
        let totalSecs = Int(library.tracks.map(\.duration).reduce(0, +))
        let totalDuration: String = {
            if totalSecs >= 3600 { return "\(totalSecs / 3600) hr \((totalSecs % 3600) / 60) min" }
            return "\(totalSecs / 60) min"
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Listening stats")
                Spacer()
                Button {
                    Haptics.play(.light)
                    showStats = true
                } label: {
                    Text("See all")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixPrimary)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
            HStack(spacing: 12) {
                StatTile(value: "\(library.tracks.count)", label: "Tracks", icon: MixtapeIcons.track)
                StatTile(value: "\(engine.recentlyPlayed.count)", label: "Played", icon: MixtapeIcons.clock)
                StatTile(value: totalDuration, label: "Library", icon: "hourglass")
            }
        }
        .sheet(isPresented: $showStats) {
            ListeningStatsView()
                .environmentObject(deps)
                .environmentObject(engine)
        }
    }
}

// MARK: - Home as a standalone page
// Home as a standalone page (iOS without the merged landing).

public struct HomeView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    private let onQuickLink: (HomeQuickLink) -> Void
    private let onPlay: (_ track: Track, _ context: [Track], _ origin: String) -> Void
    private let onArtist: (_ name: String) -> Void
    private let onPlaylist: (Playlist) -> Void

    public init(
        onQuickLink: @escaping (HomeQuickLink) -> Void = { _ in },
        onPlay: @escaping (_ track: Track, _ context: [Track], _ origin: String) -> Void = { _, _, _ in },
        onArtist: @escaping (_ name: String) -> Void = { _ in },
        onPlaylist: @escaping (Playlist) -> Void = { _ in }
    ) {
        self.onQuickLink = onQuickLink
        self.onPlay = onPlay
        self.onArtist = onArtist
        self.onPlaylist = onPlaylist
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HomeSections(onQuickLink: onQuickLink,
                             onPlay: onPlay,
                             onArtist: onArtist,
                             onPlaylist: onPlaylist)
                HomeStatsCard()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        // On the container so it stays put while content scrolls, and tints the titlebar.
        // Softer than on detail pages.
        .artworkWash(source: HomeSections.washSource(engine: engine, library: library),
                     intensity: 0.6)
        .background(MixPageBackground())
        .miniPlayerSafeArea()
        #if os(iOS)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Recent artist model
// Artist for the circular row. Not a library `Artist`, so online-only artists
// can appear too.

private struct HomeArtist: Identifiable {
    var id: String { name.lowercased() }
    let name: String
    let artworkData: Data?
    /// The library row, if any. Credit-only artists use `artworkData` or a placeholder.
    let artworkRef: ArtworkRef?
}

// MARK: - Shelf item
// A tile on the resume shelf. Songs and playlists look the same.

private enum HomeShortcut: Identifiable {
    case track(Track)
    case playlist(Playlist)

    /// Online tracks are keyed by file hash (see `HomeSections.stableKey`). Prefixed
    /// by kind for the compiler.
    var id: String {
        switch self {
        case .track(let track):
            let key = track.file.fileHash.isEmpty ? track.id.uuidString : track.file.fileHash
            return "track:\(key)"
        case .playlist(let playlist):
            return "playlist:\(playlist.id.uuidString)"
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            #if os(iOS)
            .font(.mixTitle.bold())
            #else
            .font(.mixTitle2)
            #endif
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recent Tile
// Short, wide resume tile. On macOS a play badge fades in on hover.

private struct RecentTile: View {
    let title: String
    var artworkData: Data? = nil
    /// The library row behind the tile, for covers the bulk fetch skipped.
    var artworkRef: ArtworkRef? = nil
    /// Drawn with `PlaylistArtwork`, so system playlists get their brand tile.
    var playlist: Playlist? = nil
    /// Placeholder icon; what tells a playlist tile from a song tile.
    var placeholder: String = MixtapeIcons.track
    /// Fires on pointer enter to start warming audio. Unused on iOS.
    var onHover: () -> Void = {}
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let playlist {
                    PlaylistArtwork(playlist: playlist, size: 52, cornerRadius: 0)
                } else {
                    ArtworkThumbnail(
                        data: artworkData,
                        artworkRef: artworkRef,
                        size: 52,
                        cornerRadius: 0,
                        placeholder: placeholder
                    )
                }

                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                #if os(macOS)
                Image(systemName: MixtapeIcons.play)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.mixAccentFill, in: Circle())
                    .mixShadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.8)
                    .padding(.trailing, 10)
                #endif
            }
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.mixSurface2 : Color.mixSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .mixAnimation(.easeOut(duration: 0.12), value: isHovering)
        #if os(macOS)
        .onHover { entered in
            isHovering = entered
            if entered { onHover() }
        }
        #endif
    }
}

// MARK: - Smart Playlist Card

/// No artwork: the icon over a tint derived from the name.
private struct HomeSmartCard: View {
    let playlist: SmartPlaylist
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                SmartPlaylistCover(playlist: playlist, size: 170)
                    .mixShadow(color: .black.opacity(0.3), radius: 8, y: 4)

                Text(playlist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                // No fixed height; these are short and shouldn't truncate.
                Text(playlist.rule.blurb)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text("\(count) song\(count == 1 ? "" : "s")")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

/// The `+` at the end of "Your smart playlists".
private struct NewSmartPlaylistCard: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.mixSurface2)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(isHovered ? Color.mixPrimary : Color.mixTextSecondary)
                            .scaleEffect(isHovered ? 1.18 : 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isHovered ? Color.mixPrimary : Color.mixSeparator, lineWidth: 1)
                    }
                    .frame(width: 170, height: 170)

                Text("New smart playlist")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text("Pick a rule and let it fill itself.")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: 170, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovered)
        .accessibilityLabel("New smart playlist")
    }
}

// MARK: - Track Card

private struct HomeTrackCard: View {
    let track: Track
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkThumbnail(
                    data: track.artworkData, artworkRef: .track(track.id),
                    size: 140,
                    cornerRadius: 8,
                    placeholder: MixtapeIcons.track
                )
                .mixShadow(color: .black.opacity(0.3), radius: 8, y: 4)

                Text(track.displayTitle)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.displayArtistName)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - Artist Avatar

private struct HomeArtistAvatar: View {
    let artist: HomeArtist
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ArtworkThumbnail(
                    data: artist.artworkData,
                    artworkRef: artist.artworkRef,
                    size: 96,
                    cornerRadius: 48,            // fully circular
                    placeholder: MixtapeIcons.artist
                )
                .mixShadow(color: .black.opacity(0.3), radius: 6, y: 3)

                Text(artist.name)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - Stat Tile

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
            Text(value)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.mixSeparator, lineWidth: 0.5)
        )
    }
}
