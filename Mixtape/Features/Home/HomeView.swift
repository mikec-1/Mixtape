// HomeView.swift
// Mixtape — Features/Home
//
// The library half of the landing page: a personalised greeting, one shelf of
// things to resume, recent artists, and the library carousels.
//
// This file is split three ways on purpose.
//
//   HomeSections   — the content, with no scroll view and no page margins, so
//                    it can be dropped into the merged Home/Discover landing as
//                    its opening sections. Drawn in bands (see `HomeBands`), so
//                    the landing can put the greeting above its own "Made for
//                    you" and the library rows below it.
//   HomeStatsCard  — the listening-stats card, separate because it sits at the
//                    very bottom of that merged page, under the genres.
//   HomeView       — the two above inside a ScrollView, for any host that still
//                    wants Home as a page of its own (iOS without Discover).
//
// It used to be one view that owned its own ScrollView, which is why Home had
// to be a *tab* to appear at all. Now it's sections, and sections compose.
//
// No new injected dependencies: uses existing AppDependencies (deps),
// PlaybackEngine (engine) and LibraryService (library) environment objects.
// Playback is routed through the injected `onPlay` closure so online tracks
// can be handled by the host's OnlinePlaybackCoordinator — this file never
// calls engine.play directly. Artist taps go through `onArtist`.

import SwiftUI
import SwiftData
import Combine

// MARK: - Quick-link destinations
//
// Platform-agnostic enum the quick-link chips emit. The host (MainTabView on
// iOS, MacContentRouter on macOS) maps it onto its own navigation model.

public enum HomeQuickLink: Hashable {
    case songs, albums, artists, playlists
}

// MARK: - Bands
//
// Which stretches of Home to draw. The merged landing needs the greeting and
// the shelf *above* "Made for you" and the library rows *below* it — otherwise
// you scroll past five bands of your own library before reaching the thing the
// page is named after. Rather than forking the view, the host renders it twice
// and asks for a different band each time.

public struct HomeBands: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Greeting and the jump-back-in shelf. The page opener.
    public static let top     = HomeBands(rawValue: 1 << 0)
    /// Recent artists, "Made for you", recently added, favourites.
    public static let library = HomeBands(rawValue: 1 << 1)
    /// The smart-playlist shelves. Their own band because the landing wants
    /// them up with "Because you listened to…", above Trending now, and the
    /// rest of the library rows stay where they are.
    public static let smart   = HomeBands(rawValue: 1 << 2)

    public static let all: HomeBands = [.top, .smart, .library]
}

// MARK: - Sections

/// Home's derived shelves, computed once per real change.
///
/// Every shelf on this page was a computed property, and several are read twice
/// per body evaluation — once to ask whether they're empty, once to draw them.
/// "Made for you" was the worst of them: it ran a full all-time listening-stats
/// pass and several filters over the whole library, from a view body, on every
/// re-render including ones caused by a hover or the player bar ticking.
///
/// The inputs are the library (via its `revision`), the play history, and the
/// artist artwork that arrives from the network later. When none of those moved,
/// the shelves can't have moved either.
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

    /// Stable key → where to read that played song's cover from. See the
    /// assignment in `update` for why it is not simply `.track(track.id)`.
    @Published private(set) var playedArtwork: [String: ArtworkRef] = [:]

    /// The artwork pointer for a played song, falling back to its own id so a
    /// row that has never been through `update` still draws.
    func artworkRef(for track: Track) -> ArtworkRef {
        playedArtwork[Self.stableKey(track)] ?? .track(track.id)
    }

    // Online tracks are minted with a fresh UUID `id` every play, so two plays
    // of the same song are *different* Track values. The stable identity for an
    // online track is its file hash; local tracks already have a stable `id`.
    nonisolated static func stableKey(_ track: Track) -> String {
        track.file.fileHash.isEmpty ? track.id.uuidString : track.file.fileHash
    }

    /// What counts as "the same song" on the recently-played strip.
    ///
    /// `stableKey` is an identity: a library row and the online row minted for
    /// the same song have different ones, which is why one song could appear
    /// twice in the strip. The shelf is a list of songs, so it dedupes by what
    /// it prints.
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

        // Hold still while the library is mid-flight.
        //
        // The key is doing its job: `revision` really has changed. The problem
        // is that a sync publishes the library over and over — pull, artwork,
        // refresh — and each publish is a real change, so this rebuilt 14-20
        // times per sync, measured. Every rebuild but the last was of a library
        // that was about to change again.
        //
        // Nothing is lost by waiting: `activity` is `@Published`, so returning
        // to `.idle` re-evaluates the body that calls this, and the key is left
        // stale on purpose so that pass rebuilds. The one case that must not
        // wait is the first build, which has nothing to show yet.
        if key != nil, library.activity != .idle { return }

        key = next

        // Everything below happens in a task, never inline.
        //
        // `update` is called from `body` (see `lists`), and these outputs are
        // `@Published` — assigning one during a view update is the
        // "Publishing changes from within view updates is not allowed"
        // warning, and the undefined behaviour it names shows up as dropped
        // frames. Hopping to a task lets the current update finish first.
        //
        // Split deliberately in two.
        //
        // The history-derived shelves are bounded by the size of the play
        // history (tens of rows) and need `artistRow`, which is main-actor
        // state, so they stay here. The library-derived ones are a sort, a
        // filter and a bucketing pass over the *whole* library — 2154 tracks,
        // ~80 ms each and 18 rebuilds a session, with sampled main-thread hangs
        // of 303-482 ms landing squarely inside them. Those go off the actor.
        // A newer key supersedes an in-flight pass; its results would only be
        // overwritten, and the library it was computed from is already stale.
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            mixMainActivity("home-shelves/history") {
                let recents = Array(Self.deduped(history).prefix(12))
                self.recentlyPlayed = recents

                // Where a played song's cover lives.
                //
                // A history row is a snapshot of the song as it was played, and
                // an online one is minted with a fresh `id` every time — so
                // `.track(track.id)` names a cover the store has never heard
                // of, and the tile drew a placeholder for a song whose artwork
                // was sitting in the library the whole time. The recording is
                // matched the way the rest of the app matches recordings, and
                // only the artwork is borrowed: the row itself stays exactly
                // the song that was played.
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
                // Split, not raw: a song stored as "Dave, Stormzy" is two
                // artists, and one shelf tile reading "Dave, Stormzy" opens on
                // nothing. The stored `artistName` stays as it is — it's part
                // of the track's identity — so the credit is drawn apart here,
                // at the point it's displayed.
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

            // `Task.detached` around a `nonisolated` *synchronous* body. Not
            // `nonisolated async` — under Swift 6.2 (SE-0461) that runs on the
            // caller's actor, which here is the main one. See the notes in
            // `LibrarySnapshotReader`.
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

    /// The whole-library passes. Pure: everything it needs is passed in, so it
    /// can be run anywhere. Keep it that way — reaching for main-actor state
    /// from in here puts the sort back on the thread that draws.
    nonisolated private static func libraryShelves(tracks: [Track],
                                                   favouriteIDs: Set<UUID>,
                                                   topNames: [String],
                                                   recentKeys: Set<String>) -> LibraryShelves {
        // Sorted once and reused by both the shelf and the recommendation
        // fallback below, rather than sorting the whole library twice.
        let newestFirst = tracks.sorted { $0.dateImported > $1.dateImported }
        let recentlyAdded = Array(deduped(newestFirst).prefix(12))

        let favouriteTracks = tracks.filter { favouriteIDs.contains($0.id) }
        let favourites = Array(deduped(favouriteTracks).prefix(12))

        // "Made for you": the user's most-played artists' library tracks, minus
        // anything they just heard, topped up from favourites and new arrivals.
        var picks: [Track] = []
        if !topNames.isEmpty {
            // One pass over the library, bucketed by artist, instead of a full
            // scan per top artist.
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

    /// Drives "Recently played" — `markPlayed` has been recording playlist plays
    /// all along; this is the first surface that reads them back.
    @ObservedObject private var meta = PlaylistMetadataService.shared

    /// Observed, not just read: deleting a smart playlist doesn't touch the
    /// library, so without this the shelf kept drawing rows that no longer
    /// existed until something unrelated moved.
    @EnvironmentObject private var smartService: SmartPlaylistService

    /// Invoked when a quick-link chip is tapped. Host translates navigation.
    private let onQuickLink: (HomeQuickLink) -> Void

    /// Invoked to play a track in a given context. The host decides whether to
    /// route through the online coordinator (Discover tracks) or the offline
    /// engine — this view stays playback-agnostic. Defaults to a no-op so
    /// previews / compilation stay safe.
    private let onPlay: (_ track: Track, _ context: [Track], _ origin: String) -> Void

    /// Invoked when a recent-artist avatar is tapped. Defaults to a no-op; the
    /// host wires it to its artist destination.
    private let onArtist: (_ name: String) -> Void

    /// Invoked when a "Recently played" playlist card is tapped. macOS swaps the
    /// content column through this; iOS ignores it and pushes `navPlaylist`
    /// onto the enclosing NavigationStack instead.
    private let onPlaylist: (Playlist) -> Void

    /// Invoked when a "Made by Mixtape" card is tapped. macOS swaps the content
    /// column; iOS pushes onto its own stack and ignores this.
    private let onSmartPlaylist: (SmartPlaylist) -> Void

    /// The merged landing has an online "Made for you" of its own, built from
    /// the same listening history but with a whole catalogue behind it. Two
    /// sections under one name is worse than either, so the host that shows the
    /// online one turns this off.
    private let showsRecommendations: Bool

    /// Which stretches of the page this instance draws. See `HomeBands`.
    private let bands: HomeBands

    #if os(iOS)
    @State private var navPlaylist: Playlist? = nil
    @State private var navSmart: SmartPlaylist? = nil
    #endif

    /// "Recent artists" is the one band here that grows without bound — twelve
    /// circles is three rows on a narrow window, all of it above the things
    /// people actually came for. Collapsed to one row's worth until asked.
    @State private var showsAllArtists = false

    /// Smart playlists, already resolved to their tracks.
    ///
    /// Resolving is a scan of the whole library per playlist, so it happens in
    /// `.task` keyed on the library revision rather than in `body` — the same
    /// bargain `HomeShelvesMemo` makes for the other shelves.
    /// A smart playlist with the rows its rule currently matches.
    typealias SmartEntry = (playlist: SmartPlaylist, tracks: [Track])
    @State private var allSmartLists: [SmartEntry] = []
    @State private var showsSmartEditor = false

    /// Spotify-sourced artist profile images for "Recent artists", keyed by
    /// lowercased name. Discover-only artists have no library `Artist` row, so we
    /// fetch their photo from `deps.spotifyClient` and cache the bytes here.
    @State private var remoteArtistArtwork: [String: Data] = [:]

    /// Home's shelves, rebuilt only when the library or the play history moves.
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

    /// "Good evening, Mike" — the name folds into the greeting rather than
    /// sitting under it as a second grey line, which read like a subtitle for
    /// the page instead of an address to the person.
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

    /// One quiet line of context under the greeting. Prefers what the user was
    /// doing over what the library contains — resuming is the common intent.
    private var greetingSubline: String {
        if let last = recentlyPlayed.first {
            return "Pick up where you left off: \(last.title)"
        }
        if isLibraryEmpty { return "Your library is waiting to be filled" }
        // Deliberately nothing. A song-and-artist tally is a statistic about
        // the database, not a reason to open the app — and it was the one line
        // of the greeting that never changed.
        return ""
    }

    /// Artwork the page tints itself from — whatever the user last played, so
    /// the landing carries the colour of the thing they'll most likely resume.
    public static func washSource(engine: PlaybackEngine, library: LibraryService) -> Data? {
        // `max(by:)` rather than `sorted().first`: this is read from a view
        // body, so it ran on every redraw of Home — a full sort of the whole
        // library to answer a question with one winner.
        engine.recentlyPlayed.first?.displayArtwork
            ?? library.tracks.max { $0.dateImported < $1.dateImported }?.displayArtwork
    }

    /// Whether the `.library` band would draw anything.
    ///
    /// The merged landing puts a section rule above that band, and a rule above
    /// nothing is a line drawn across the page for no reason. Tracks in the
    /// library fill "Recently added"; plays with no library behind them (a
    /// Discover-only user) still fill "Recent artists" — so either one is enough.
    public static func hasLibraryContent(engine: PlaybackEngine, library: LibraryService) -> Bool {
        !library.tracks.isEmpty || !engine.recentlyPlayed.isEmpty
    }

    /// Brings `shelves` up to date, cheaply, and hands it back.
    ///
    /// Read by every shelf below, so a body evaluation caused by something
    /// unrelated costs one key comparison instead of a stats pass and several
    /// scans of the whole library.
    private var lists: HomeShelvesMemo {
        shelves.update(revision:      library.revision,
                       history:       engine.recentlyPlayed,
                       remoteArtwork: remoteArtistArtwork,
                       library:       library,
                       stats:         { deps.statsService.compute(period: .allTime) })
        return shelves
    }

    /// Recently played, de-duplicated by stable key (see `deduped`). Online
    /// tracks get a fresh UUID per play, so without this the same song appears
    /// multiple times in the carousel.
    private var recentlyPlayed: [Track] { lists.recentlyPlayed }

    private var recentlyAdded: [Track] { lists.recentlyAdded }

    private var favourites: [Track] { lists.favourites }

    /// "Made for you" — recommendations derived purely from local data (no
    /// network). The user's top artists from listening history, their library
    /// tracks the user *hasn't* played recently, falling back to favourites /
    /// most-imported so the row is never empty.
    private var recommendations: [Track] { lists.recommendations }

    /// Circular artist row — distinct artists from recently-played tracks,
    /// matched to a library `Artist` (for artwork) where one exists.
    private var recentArtists: [HomeArtist] { lists.artists }

    /// Playlists the user actually opened and played, most recent first. Only
    /// playlists that still exist are listed — a deleted one leaves its date
    /// behind in the store.
    private var recentPlaylists: [Playlist] {
        meta.playlistLastPlayedDates
            .sorted { $0.value > $1.value }
            .compactMap { entry in library.playlists.first { $0.id == entry.key } }
            .prefix(12)
            .map { $0 }
    }

    private var isLibraryEmpty: Bool { library.tracks.isEmpty }

    /// True when there is genuinely nothing to show — no local library *and* no
    /// played history. A Discover-only user has an empty library but plenty to
    /// resume, so the empty state must not key off the library alone.
    private var hasNothingToShow: Bool { isLibraryEmpty && recentlyPlayed.isEmpty }

    // MARK: The shelf

    /// One shelf of one-click resumes, songs and playlists together.
    ///
    /// These used to be two bands — a grid of recent songs, then a whole
    /// separate carousel of recent playlists under its own heading — which cost
    /// most of a screen to say "here are things you were just listening to"
    /// twice. They're the same thought, so they're one shelf, the way Spotify's
    /// shortcut grid mixes albums, playlists and songs without labelling any of
    /// them.
    ///
    /// Playlists take the last two slots rather than queueing behind the songs:
    /// a session spent on one playlist fills the recent-songs list with tracks
    /// from it, and the playlist itself — the thing you'd actually click to
    /// carry on — would never make the cut.
    private var shortcuts: [HomeShortcut] {
        let playlists = recentPlaylists.prefix(2).map { HomeShortcut.playlist($0) }
        let songs = recentlyPlayed
            .prefix(Self.shelfCapacity - playlists.count)
            .map { HomeShortcut.track($0) }
        return songs + playlists
    }

    /// Eight is two rows of four on a wide window and four rows of two on a
    /// phone — enough to hold a session's worth of context, few enough that the
    /// page below it is still on screen.
    private static let shelfCapacity = 8

    /// Two fixed columns on a phone — the adaptive 220pt minimum fits only one
    /// on a 390pt screen, which turned the shelf into a list.
    #if os(iOS)
    private static let shortcutColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    #else
    private static let shortcutColumns = [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 8)]
    #endif

    /// One row's worth of artists before "Show all". Six wraps to a single row
    /// at any window width the app is usable at.
    private static let collapsedArtistCount = 6

    // MARK: Stable de-dup
    //
    // Online tracks are minted with a fresh UUID `id` every play, so two plays
    // of the same song are *different* Track values that ForEach(id: \.id) would
    // render twice. The stable identity for an online track is its file hash
    // ("title|artist"); local tracks already have a stable `id`.

    private func stableKey(_ track: Track) -> String {
        HomeShelvesMemo.stableKey(track)
    }

    /// Identity for the warm-up task: which songs are at the top of the page,
    /// not how many times they've been played. Keyed on the stable keys so a
    /// re-render that produces equal-but-fresh online Tracks doesn't restart the
    /// prefetch it already ran.
    /// Re-resolves on a library change *or* a smart-playlist change.
    private var smartKey: String {
        "\(library.revision)#" + smartService.playlists.map(\.id.uuidString).joined(separator: ",")
    }

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
                // A phone's Home has its own header row (avatar + filters); the
                // greeting would be a second title above the first shelf.
                #if os(macOS)
                header
                #endif

                if hasNothingToShow {
                    emptyState
                } else {
                    // One shelf of recent songs and playlists — see `shortcuts`.
                    if !shortcuts.isEmpty { shortcutShelf }
                }
            }

            // The library half. Each band still guards its own visibility, so an
            // empty library removes a band rather than leaving a bare heading.
            if bands.contains(.smart), !hasNothingToShow {
                if !smartLists.isEmpty { smartShelf }
                mySmartShelf
            }

            if bands.contains(.library), !hasNothingToShow {
                if !recentArtists.isEmpty {
                    artistRow(title: "Recent artists", artists: recentArtists)
                }
                if showsRecommendations, !recommendations.isEmpty {
                    carousel(title: "Made for you", tracks: recommendations)
                }
                libraryColumns
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Warm the songs at the top of the page while the user is still looking
        // at it. Every other surface already does this — album, artist and
        // playlist pages all warm their rows on open, and Discover warms on
        // hover — which left Home, the one page whose entire purpose is resuming
        // something, doing the whole search-resolve-download with the user
        // watching. Songs that can play from their own file are skipped, so this
        // costs nothing for a local library.
        //
        // Re-fires as the recent list changes: the song just played is already
        // cached, so what this actually warms is whatever moved up behind it.
        //
        // Guarded to the band that draws the shelf. The merged landing renders
        // this view twice, and two instances warming the same six songs is one
        // wasted round of resolves.
        .task(id: smartKey) {
            guard bands.contains(.smart) else { return }
            let history = PlayHistoryRepository()
            let service = smartService
            allSmartLists = service.playlists.compactMap { playlist in
                let tracks = service.resolve(playlist, using: library, history: history)
                // A rule that can't fill a card isn't a playlist yet. A "Most
                // Played" of one song was the complaint; the floor applies to
                // the shipped rules only — see `isWorthShowing`.
                guard SmartPlaylistService.isWorthShowing(playlist, count: tracks.count) else { return nil }
                return (playlist, tracks)
            }
        }
        .sheet(isPresented: $showsSmartEditor) {
            SmartPlaylistEditorView(service: smartService)
                .environmentObject(deps)
        }
        .task(id: prefetchKey) {
            guard bands.contains(.top) else { return }
            deps.onlineCoordinator.prefetchResolvable(Array(recentlyPlayed.prefix(6)))
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

                // A gentle top-to-bottom fade on the type itself, so the title
                // sits in the wash instead of on top of it.
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
    //
    // Spotify's top-of-home shortcut grid: short, wide tiles in an adaptive
    // grid, each one artwork + title with the artwork flush to the leading edge.
    // Eight of them cost roughly the vertical space the single hero banner used
    // to, and every one is a one-click resume.

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
                        // Hovering a tile is the same signal as hovering a
                        // Discover row: the pointer arrives a moment before the
                        // click, and that moment is most of the wait.
                        onHover: { deps.onlineCoordinator.prefetchResolvable([track], limit: 1) },
                        action: {
                            Haptics.play(.light)
                            onPlay(track, recentlyPlayed, "Recently played")
                        }
                    )
                    .contextMenu { trackMenu(track, context: recentlyPlayed, origin: "Recently played") }

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
                    // Same gesture as in the Playlists list: drag a card onto
                    // the sidebar to keep the playlist there.
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
    //
    // These have lived in a Library tab that nothing pointed at. They are
    // generated from the same listening history as everything else on this
    // page, so they belong on it: one shelf, tap to play, same grammar as the
    // song cards beside them.

    private var smartShelf: some View { smartShelf(title: "Made by Mixtape", entries: smartLists) }

    /// The user's own rules, kept off the shelf above: a card named "lol" sitting
    /// between Hidden Gems and On Repeat reads as something the app generated.
    /// Always drawn, even with no rules in it: the `+` at the end of the row is
    /// the only place on this page you can make one, and a heading over a lone
    /// plus reads as an invitation rather than an empty shelf.
    private var mySmartShelf: some View {
        smartShelf(title: "Your smart playlists", entries: mySmartLists, showsCreate: true)
    }

    /// The five the app ships, in seed order.
    private var smartLists: [SmartEntry] { allSmartLists.filter { SmartPlaylistService.isBuiltIn($0.playlist) } }
    private var mySmartLists: [SmartEntry] { allSmartLists.filter { !SmartPlaylistService.isBuiltIn($0.playlist) } }

    private func smartShelf(title: String, entries: [SmartEntry], showsCreate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
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

    private func openSmart(_ playlist: SmartPlaylist) {
        #if os(iOS)
        navSmart = playlist
        #else
        onSmartPlaylist(playlist)
        #endif
    }

    // MARK: Carousel

    /// `clipped: true` keeps a carousel's content inside its own column. The
    /// full-width shelves let their cards bleed past the page padding, but two
    /// of these sit side by side on a Mac — unclipped, each one paints and
    /// scrolls across the other, which is what made the scrollbar look like it
    /// belonged to the whole window.
    private func carousel(title: String, tracks: [Track], clipped: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // Keyed by id, not by the whole value. `Track.id` is a
                    // content hash, so two genuine duplicates collapse under
                    // either key — `\.self` bought nothing and cost a full
                    // struct hash per row, and made any field change tear the
                    // card down and rebuild it.
                    ForEach(tracks, id: \.id) { track in
                        HomeTrackCard(track: track) {
                            Haptics.play(.light)
                            onPlay(track, tracks, title)
                        }
                        .contextMenu { trackMenu(track, context: tracks, origin: title) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled(!clipped)
        }
    }

    // MARK: Library columns
    //
    // "Recently added" and "Your Liked Songs" are the same shape — a row of
    // 140pt cards — and each one used a full page width to show four of them.
    // Side by side on a Mac window they cost one band instead of two and still
    // show three each; a phone gets them stacked, because half of 390pt is not
    // a carousel. If only one of the two has anything in it, it takes the whole
    // width on its own.

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
    //
    // A wrapping grid, not a horizontal scroller. Artists are the one thing on
    // this page you scan for a *specific* name rather than browse — and a name
    // you have to drag a row sideways to find is a name you can't scan for.

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
            // A phone fits three circles a row, so the wrapping grid became a
            // wall; a shelf costs one row however many artists there are.
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
        // Keyed on the full set, not the visible one: expanding must not kick
        // off a second fetch for artists whose photos already arrived.
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

    /// Fetch Spotify profile images for any recent artist that doesn't already
    /// have artwork (i.e. Discover-only artists with no library `Artist` row),
    /// download the bytes, and cache them so the avatars fill in.
    private func loadRemoteArtistImages(for artists: [HomeArtist]) async {
        // `artworkData` alone is not the question any more — a library artist's
        // cover lives in the store and is fetched on demand. Only an artist with
        // neither wants a remote image. The list is a handful of names.
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
    //
    // The same items the library rows offer, because a card on this page is the
    // same song as the row on that one — right-clicking one and getting nothing
    // is what made Home feel like a poster rather than part of the app.

    @ViewBuilder
    private func trackMenu(_ track: Track, context: [Track], origin: String) -> some View {
        Button("Play Now", systemImage: MixtapeIcons.play) { onPlay(track, context, origin) }
        Button("Play Next") { engine.queue.insertNext(track) }
        Button("Add to Queue") { engine.queue.append(track) }

        Divider()

        // History and "jump back in" carry Discover songs that were played but
        // never saved. Favouriting one does nothing (a favourite is a flag on a
        // library row), so the offer for those is to save it.
        if library.track(id: track.id) == nil {
            Button("Add to Library", systemImage: "plus") {
                Task {
                    await deps.onlineCoordinator.addToLibrary(unsaved: track)
                    deps.showSavedToast(.library)
                }
            }
        } else {
            let favoured = library.isFavourited(trackID: track.id)
            Button(favoured ? "Remove from Liked Songs" : "Add to Liked Songs",
                   systemImage: favoured ? "heart.slash" : "heart") {
                deps.toggleFavourite(trackID: track.id)
            }
        }

        let targets = library.playlists.filter {
            !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id)
        }
        if !targets.isEmpty {
            Menu("Add to Playlist") {
                ForEach(targets) { playlist in
                    Button(playlist.name) {
                        deps.addTrack(id: track.id, toPlaylist: playlist.id)
                    }
                }
            }
        }

        Divider()

        Button("Go to Artist", systemImage: MixtapeIcons.artist) { onArtist(track.artistName) }

        Divider()

        ShareMenuItems(.track(track))
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
    private func artistMenu(_ artist: HomeArtist) -> some View {
        Button("Open Artist", systemImage: MixtapeIcons.artist) { onArtist(artist.name) }
        let tracks = library.tracks.filter {
            $0.artistName.localizedCaseInsensitiveCompare(artist.name) == .orderedSame
        }
        if let first = tracks.first {
            Button("Play", systemImage: MixtapeIcons.play) { onPlay(first, tracks, artist.name) }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "music.note.house.fill",
            title: "Import music to get started",
            message: "Tracks you add or play will appear here."
        )
        .padding(.vertical, 40)
    }
}

// MARK: - Listening stats card
//
// Split out of the sections above because on the merged landing it is the last
// thing on the page, under the genres — a summary belongs after the thing it
// summarises, not in the middle of it.

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
//
// Kept for hosts that still want Home on its own (iOS builds without the merged
// Discover landing). It is now only a scroll view and margins around the two
// pieces above.

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
        // Pinned to the container rather than the scroll content: the window
        // titlebar is tinted from this colour, so a wash that scrolled away
        // would leave the chrome coloured and the page underneath bare.
        // Softer than a detail page — Home is a page of cards, not one subject,
        // so the colour only sets the mood behind the greeting.
        .artworkWash(source: HomeSections.washSource(engine: engine, library: library),
                     intensity: 0.6)
        .background(Color.mixBackground.ignoresSafeArea())
        .miniPlayerSafeArea()
        #if os(iOS)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Recent artist model
//
// Lightweight value type for the circular artist row. Decoupled from the
// library `Artist` so artists that exist only in recently-played online tracks
// (no library record) can still appear, just without artwork.

private struct HomeArtist: Identifiable {
    var id: String { name.lowercased() }
    let name: String
    let artworkData: Data?
    /// The library row behind this name, when there is one. Artists reached
    /// only through a track credit have none, and fall back to `artworkData`
    /// (a remote image) or the placeholder.
    let artworkRef: ArtworkRef?
}

// MARK: - Shelf item
//
// One tile on the jump-back-in shelf. Songs and playlists sit in the same grid
// and look the same on purpose — what they have in common is that clicking one
// puts you back where you were.

private enum HomeShortcut: Identifiable {
    case track(Track)
    case playlist(Playlist)

    /// Online tracks are minted with a fresh UUID per play, so their stable
    /// identity is the file hash — the same rule `HomeSections.stableKey` uses.
    /// Prefixed by kind, because a playlist and a song can't collide but the
    /// compiler doesn't know that.
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
//
// Short, wide "jump back in" row. The artwork sits flush against the leading
// edge and the whole tile is one click target; on macOS a play badge fades in
// under the pointer so the row reads as actionable without a permanent button.

private struct RecentTile: View {
    let title: String
    var artworkData: Data? = nil
    /// The library row behind the tile, for covers the bulk fetch skipped.
    var artworkRef: ArtworkRef? = nil
    /// Drawn by `PlaylistArtwork`, so Favourites and All Songs wear the brand
    /// tile they wear in the sidebar instead of a grey placeholder.
    var playlist: Playlist? = nil
    /// The icon behind missing artwork — the one thing that distinguishes a
    /// playlist tile from a song tile on a shelf that deliberately mixes them.
    var placeholder: String = MixtapeIcons.track
    /// Fired once each time the pointer enters. Used to start warming the audio
    /// before the click lands; inert on iOS, which has no hover to give.
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

/// A smart playlist has no artwork of its own, so the tile is its icon over a
/// tint derived from its name — stable per playlist, and distinct from the
/// album covers on the shelves around it.
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
                // The description, the way any other playlist card carries one.
                // No fixed height: a clipped blurb ending in "…" tells the
                // reader less than the sentence it hid, and these are short.
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

/// The `+` at the end of "Your smart playlists" — the mixes row's tile, sized
/// to the smart cards beside it.
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
