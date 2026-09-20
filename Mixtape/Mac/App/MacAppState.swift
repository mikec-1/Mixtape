// MacAppState.swift
// Mixtape — Mac/App
//
// Window-level state for the macOS app.
// Injected as @EnvironmentObject from MacRootView so all Mac views share one instance.
//
// Right-panel model
// -----------------
// A single optional value (stored as a 1-element array for API consistency).
// Pressing a button while another panel is open swaps to it immediately.
// Pressing the active button closes the panel entirely.

#if os(macOS)
import SwiftUI
import Combine

extension Notification.Name {
    /// View ▸ Toggle Sidebar (⌃⌘S). Posted by the menu command in MixtapeApp,
    /// which has no route to `MacAppState`; MacRootView turns it into a call.
    static let mixToggleSidebar  = Notification.Name("mix.toggleSidebar")
    /// View ▸ Zoom In (⌘+). Same indirection as the sidebar toggle.
    static let mixZoomIn         = Notification.Name("mix.zoomIn")
    /// View ▸ Zoom Out (⌘−). Same indirection as the sidebar toggle.
    static let mixZoomOut        = Notification.Name("mix.zoomOut")
    /// View ▸ Actual Size (⌘0). Same indirection as the sidebar toggle.
    static let mixActualSize     = Notification.Name("mix.actualSize")
    /// View ▸ Go Back (⌘[). Same indirection as the sidebar toggle.
    static let mixGoBack         = Notification.Name("mix.goBack")
    /// View ▸ Go Forward (⌘]). Same indirection as the sidebar toggle.
    static let mixGoForward      = Notification.Name("mix.goForward")
    /// File ▸ New Playlist (⌘N). Creates a blank playlist and navigates to it.
    static let mixNewPlaylist    = Notification.Name("mix.newPlaylist")
}

// MARK: - Sidebar Item

enum MacSidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home      = "Home"
    case library   = "Library"
    // The raw value used to be " Songs", leading space and all, which is what
    // put "Go to  Songs" in the command palette. Safe to fix now: the only thing
    // that ever persisted a raw value was the sidebar's stored item order, and
    // that went with the sections.
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    case playlists = "Playlists"
    case discover  = "Discover"
    /// The user's watched folders, shown as songs. Only appears when at least
    /// one folder actually has music in it — an empty row for a feature nobody
    /// has set up is just clutter.
    case localFiles = "Local Files"
    case settings  = "Settings"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .home:      return "house"
        case .library:   return "square.stack"
        case .songs:     return "music.note"
        case .albums:    return "square.stack"
        case .artists:   return "music.mic"
        case .playlists: return "music.note.list"
        case .discover:  return "sparkle.magnifyingglass"
        case .localFiles: return "folder"
        case .settings:  return "gear"
        }
    }

    /// The rows the sidebar actually draws, top to bottom.
    ///
    /// Songs / Albums / Artists / Playlists are deliberately absent: they are
    /// now *tabs within* the Library page rather than four sidebar rows. They
    /// stay in this enum because they are still perfectly good destinations —
    /// Home's quick links and the "go to album" menus select them by name — and
    /// `MacContentRouter` turns any of them into Library-with-that-tab-open. So
    /// nothing that could navigate before has stopped being able to; the four
    /// just no longer each cost a permanent line of sidebar.
    /// Discover is absent for the same reason, one level up: it and Home are
    /// tabs of a single landing page now, so two rows would have pointed at the
    /// same view. `.discover` still resolves — it opens that page on For You.
    static var primaryItems: [MacSidebarItem] { [.home, .library] }

    /// True when this destination is a face of the merged Home/Discover page.
    var isLandingPage: Bool { self == .home || self == .discover }

    /// The Library tab this destination corresponds to, for the four that are
    /// really tabs. Nil for a genuine page of its own.
    var libraryTab: LibraryTab? {
        switch self {
        case .songs:     return .songs
        case .albums:    return .albums
        case .artists:   return .artists
        case .playlists: return .playlists
        default:         return nil
        }
    }

    /// True for every selection that puts the Library page on screen — the row
    /// itself and the four tab identities alike. The sidebar highlights on this
    /// rather than on `== .library`, so arriving via a Home quick link or a
    /// "go to album" menu still lights up the row you're standing in.
    var isLibraryPage: Bool { self == .library || libraryTab != nil }
}

// MARK: - Library Tabs

/// The four views that used to be sidebar rows, now segments of one page.
///
/// Mixtape started as a place to keep files you owned, and a sidebar listing
/// Songs / Albums / Artists made sense when that was the whole app. It reads
/// differently now that most of what people play arrives from Discover: those
/// are three ways of slicing *the same library*, and giving each one a
/// permanent row pushed the playlists — the thing actually navigated to — below
/// the fold behind a button.
enum LibraryTab: String, Hashable, CaseIterable, Identifiable {
    /// Spotify's unfiltered library: playlists, saved albums and smart playlists.
    case all       = "All"
    case playlists = "Playlists"
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    /// Rule-based playlists. A Mac had no way to see one at all — the + menu
    /// created them and they went nowhere.
    case smart     = "Smart"

    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - Right Panel Mode

enum RightPanelMode: Equatable, CaseIterable {
    case nowPlaying   // shows MacTrackInspector for `inspectorTrack`
    case queue        // shows MacQueuePanelView
    case recent       // shows MacRecentPanelView

    /// Label for the panel's own tab bar. Short on purpose: three of these plus
    /// a close button have to fit a column the user can drag down to 220pt.
    var tabTitle: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .queue:      return "Queue"
        case .recent:     return "Recent"
        }
    }
}

// MARK: - MacAppState

@MainActor
final class MacAppState: ObservableObject {

    public var currentUserID: String? = nil {
        didSet {
            loadSidebarLayout()
        }
    }

    private static let libraryTabKey       = "mixtape.libraryTab"
    private static let sidebarCollapsedKey = "mixtape.sidebarCollapsed"

    /// Which slice of the library the Library page is showing.
    ///
    /// Persisted globally rather than per-account: it's a view preference about
    /// how someone likes to browse, not anything to do with whose music it is.
    @Published var libraryTab: LibraryTab = .all {
        didSet {
            guard libraryTab != oldValue else { return }
            UserDefaults.standard.set(libraryTab.rawValue, forKey: Self.libraryTabKey)
        }
    }

    /// Sidebar folded down to an icon rail.
    ///
    /// A fold, not a hide: `NavigationSplitView` only offered "there" or "gone
    /// entirely", which is part of why it isn't here. Collapsing to icons keeps
    /// every destination one click away while giving the content the width —
    /// which is the trade people actually want on a laptop screen.
    @Published var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: MacAppState.sidebarCollapsedKey) {
        didSet {
            guard sidebarCollapsed != oldValue else { return }
            UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
        }
    }

    /// Fold the sidebar down to the icon rail, or back out again.
    ///
    /// One flag, and MacRootView animates the column's width off it. It used to
    /// set `NavigationSplitView`'s `columnVisibility` in the same breath — the
    /// rail was drawn beside a column that had to be hidden to make room — and
    /// the two moved on separate animations that visibly disagreed. The column
    /// is hand-rolled now, so there is only this.
    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    /// The order playlists are shown in — the sidebar's own control now, and
    /// the single source both the sidebar and the Playlists page draw from, so
    /// the two can never show a different order for the same choice. A mirror
    /// of `PlaylistSortSyncService.shared.sortOrder`, which owns the value,
    /// persists it and carries it to the phone — this stays a `@Published` on
    /// `MacAppState` only so the sidebar's existing bindings keep working.
    @Published var playlistSortOrder: LibrarySortOrder = .manual {
        didSet {
            guard playlistSortOrder != oldValue else { return }
            PlaylistSortSyncService.shared.sortOrder = playlistSortOrder
        }
    }

    private var sortOrderObserver: AnyCancellable?

    /// Whether the sidebar's playlist list is in drag-to-reorder mode. Not
    /// persisted — it describes this visit to the sidebar, not a preference.
    @Published var isArrangingPlaylists = false

    // MARK: - Init (loads persisted UI scale)

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.scaleKey)
        _uiScale = Published(initialValue: saved > 0
            ? max(Self.scaleSteps.first!, min(Self.scaleSteps.last!, CGFloat(saved)))
            : 1.0)

        loadSidebarLayout()
        observeDiscoverPath()
        // Follows the account: a change made on the phone lands here the
        // moment the session refreshes. The `didSet` above pushes the other
        // way, and both sides stop on the equality guard.
        playlistSortOrder = PlaylistSortSyncService.shared.sortOrder
        sortOrderObserver = PlaylistSortSyncService.shared.$sortOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] order in self?.playlistSortOrder = order }
    }

    func loadSidebarLayout() {
        if let raw = UserDefaults.standard.string(forKey: Self.libraryTabKey),
           let tab = LibraryTab(rawValue: raw) {
            libraryTab = tab
        }
        // The sort order is not restored here — `PlaylistSortSyncService` owns
        // both the stored value and the account's copy of it. See `init`.
    }

    // MARK: - UI Scale  (Cmd+= / Cmd+-)

    private static let scaleKey   = "mixtape.uiScale"
    /// Allowed zoom steps — 70 % … 150 % in 10 % increments.
    static  let scaleSteps: [CGFloat] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5]

    @Published var uiScale: CGFloat = 1.0 {
        didSet { UserDefaults.standard.set(Double(uiScale), forKey: Self.scaleKey) }
    }

    func zoomIn() {
        if let next = Self.scaleSteps.first(where: { $0 > uiScale + 0.01 }) { uiScale = next }
    }
    func zoomOut() {
        if let prev = Self.scaleSteps.last(where:  { $0 < uiScale - 0.01 }) { uiScale = prev }
    }
    func resetZoom() { uiScale = 1.0 }

    // MARK: Navigation
    @Published var selection:        MacSidebarItem?               = .home {
        // Changing sidebar section swaps the main content column; dismiss
        // fullscreen lyrics so the new section isn't hidden behind them.
        didSet {
            if oldValue != selection, lyricsPresented && lyricsFullscreen {
                lyricsPresented = false
            }
            if oldValue != selection { leaveSearchOnSectionChange() }
            scheduleHistoryCapture()
        }
    }
    // MARK: Search
    //
    // One field, one query, one corpus — the catalogue, with your own library
    // folded in above it (see `LocalMatchesSection`).
    //
    // It used to be one query *per corpus*: Discover searched online, every
    // other section searched the local library. Which meant the same box did
    // two different jobs depending on where you happened to be standing, and
    // the job it did most of the time was the one that couldn't reach a song
    // you didn't already own. Typing a song you'd heard about got you "no
    // results" from a box that had never looked anywhere but your own disk.
    //
    // The per-corpus storage existed to stop a Discover query following you
    // into the library and silently filtering it. Committing (see
    // `searchCommitted`) solves that directly: an uncommitted query is invisible
    // to everything that draws, so leaving a section leaves its search behind
    // whether or not the text is still sitting in the field.

    /// Backing store. Written through `searchText` so every edit can also reset
    /// the library narrowing and the parked flag below. Nothing that *draws*
    /// reads this — see `activeSearchText`.
    @Published private var searchStorage: String = "" {
        // Only ever a *refresh* of the search entry while one is on screen —
        // `resolvedDestination` ignores an uncommitted query.
        didSet { scheduleHistoryCapture() }
    }

    /// The live query. Still a plain settable String, so the field's binding,
    /// the Library page's filters and OnlineDiscoverView all keep working
    /// untouched — only what it searches changed.
    var searchText: String {
        get { searchStorage }
        set {
            guard searchStorage != newValue else { return }
            searchStorage = newValue
            // A new query is a new search: back to searching everything rather
            // than staying narrowed to whatever the last one narrowed to.
            searchInLibrary = false
            // Typing is not asking for results — a new query gets the panel
            // under the field and nothing else until Return. An already
            // committed one stays committed, because there the typing is
            // refining a page the user is looking at; emptying the field ends
            // the search outright.
            if newValue.isEmpty { searchCommitted = false }
        }
    }

    /// Set only by Discover's "Show all in Library". The one case where a live
    /// query should survive a section change, because there the section change
    /// *is* the result the user asked for. Cleared by the next edit or the next
    /// move to any other section.
    @Published var searchInLibrary: Bool = false

    /// Whether the query has been *asked for* — Return, or a row picked out of
    /// the suggestions panel — rather than merely typed.
    ///
    /// Typing used to hand the entire content column to the results on the first
    /// character, which made the search field a trapdoor: three letters and the
    /// page you were reading was gone, before you had finished deciding what you
    /// were even looking for. And because the router checks the query *before*
    /// the drill-downs, a playlist opened while text sat in the field was
    /// genuinely selected and simply never drawn.
    ///
    /// So typing now only feeds the panel hanging off the field, which is what
    /// iOS has always done — UIKit draws `.searchSuggestions` over the content
    /// and only reveals the results on submit. Return commits, and committing is
    /// what puts the results on screen (`showSearchResults`). Editing a query
    /// that is already committed keeps it committed — there the typing is
    /// refining a search you are looking at, not starting one. Navigating
    /// anywhere else un-commits (`leaveSearch`), leaving the text in the field
    /// with nothing behind it: click back into the field and the panel returns,
    /// press Return and the results do.
    @Published private(set) var searchCommitted: Bool = false {
        didSet { scheduleHistoryCapture() }
    }

    /// The query as far as anything that *draws* is concerned — empty until the
    /// search is committed. Only the field itself binds to `searchText`; every
    /// reader that would put the query on screen — the router, Discover, the
    /// Library page's filters — reads this one, so a query that hasn't been
    /// asked for is invisible to all of them at once.
    var activeSearchText: String { searchCommitted ? searchStorage : "" }

    /// Leaving the search behind: keep the text, give back the screen.
    ///
    /// Called from every navigation that opens a specific page — the sidebar
    /// sections, and the album and playlist drill-downs, which set their targets
    /// directly and so never went through `goToSection`.
    func leaveSearch() {
        if searchInLibrary { searchInLibrary = false }
        if searchCommitted { searchCommitted = false }
    }

    /// "Show all in Library" — hand the current query to the Library page's own
    /// Songs list, which searches the whole library rather than the six rows
    /// Discover has room to preview.
    func showAllInLibrary() {
        // Reached from the results, so it is already committed — but the Library
        // page reads `activeSearchText` like everything else, and a query that
        // stopped counting on the way over would arrive as no query at all.
        searchCommitted = true
        searchInLibrary = true
        libraryTab      = .songs
        selection       = .library
    }

    /// Return in the search field: show me the results.
    ///
    /// The router hands the content column to Discover as soon as a query
    /// exists — but four things are drawn in front of it, and fullscreen lyrics
    /// are the worst of them, because they replace the column outright. Reading
    /// along to a song and searching for something else got you the suggestions
    /// panel hanging off the field and nothing behind it: the results were
    /// there, under the lyrics, with no way to tell. The account page, a profile
    /// and a public playlist all outrank the search in the same way.
    ///
    /// Deliberately not run on every keystroke: typing is not a decision to
    /// leave the page you're on, and Return is. Until this runs, the query
    /// exists only in the field and in the suggestions panel — see
    /// `searchCommitted`.
    func showSearchResults() {
        if lyricsPresented { lyricsPresented = false }
        dismissContentOverlays()
        // The commit itself. Everything above clears what is drawn *over* the
        // content column; this is what puts the results in it. The drill-down
        // the query was sitting behind goes too — the search is the page you're
        // on now, so clearing the query later lands on the section rather than
        // reopening the playlist that was hiding behind the results.
        guard !searchCommitted else { return }
        searchCommitted  = true
        selectedAlbum    = nil
        selectedPlaylist = nil
        selectedSmartPlaylist = nil
    }

    /// Called from `selection`'s `didSet`. Clicking a sidebar row means "show me
    /// that", not "show me that, filtered by whatever I was last looking for" —
    /// except on the Show-all handoff, which is the one section change a query
    /// is supposed to survive.
    private func leaveSearchOnSectionChange() {
        if searchInLibrary, selection == .library { return }
        leaveSearch()
    }

    /// Bumped to ask the toolbar search field to take focus. The field owns its
    /// own `@FocusState`, so ⌘F can't just set a boolean here — it has to send
    /// an edge the field can observe.
    @Published var searchFocusToken: Int                           = 0
    func focusSearch() { searchFocusToken &+= 1 }

    /// ⌘K — the command palette overlay in MacRootView.
    @Published var commandPaletteOpen: Bool = false

    /// Incremented when the user presses ↓ in the search field, handing keyboard
    /// control to the results list so typing and then arrowing works without
    /// reaching for the mouse.
    @Published var resultsFocusToken: Int = 0
    func focusResults() { resultsFocusToken &+= 1 }

    /// True → MacContentRouter shows the inline account page (full content
    /// area). Navigated to from Settings → Manage Account; its Back button
    /// sets this false. (Ported presentation from main's 1.1 Account window.)
    @Published var showingAccount:   Bool                          = false {
        didSet { scheduleHistoryCapture() }
    }

    /// Person whose profile the user opened — from search, or from Find People.
    /// Non-nil → MacContentRouter shows ProfilePageView across the whole content
    /// area, the same way albums and playlists drill in. A profile is a
    /// destination, not a popover.
    @Published var profileTarget: UserProfile? = nil {
        didSet { scheduleHistoryCapture() }
    }

    /// A public playlist opened from someone's profile. Checked *before*
    /// `profileTarget` in MacContentRouter, so closing it returns to the profile
    /// it was opened from rather than unwinding the whole way out.
    @Published var publicPlaylistTarget: PublicPlaylistTarget? = nil {
        didSet { scheduleHistoryCapture() }
    }

    /// Drops the pages that take over the entire content area.
    ///
    /// Called from the drill-down setters below and not only from the router's
    /// `onChange(of: selection)`: a sidebar playlist row sets `selectedPlaylist`
    /// and `selection = nil`, so selection never becomes non-nil and that handler
    /// never runs — which is why an open profile used to stay on top of every
    /// playlist clicked afterwards.
    /// Fullscreen lyrics belong in this list for the same reason: they replace
    /// the content column outright, so a playlist opened underneath them
    /// switched invisibly.
    private func dismissContentOverlays() {
        showingAccount       = false
        profileTarget        = nil
        publicPlaylistTarget = nil
        discoverLinkActive   = false
        leaveFullscreenLyricsForNavigation()
    }

    // MARK: - Sidebar navigation

    /// What clicking a sidebar row means: show me that page, from the top —
    /// including when it is already the selected page.
    ///
    /// `selection`'s `didSet` can't do this, because clicking Home while Home is
    /// selected assigns the same value: `oldValue != selection` is false and
    /// nothing resets. That is precisely the state a search leaves you in. Type
    /// anything while on Home and the router hands the whole content column to
    /// the results (`isSearching`), so the page you're looking at is no longer
    /// the page the sidebar says you're on — and Home, the one control that
    /// should undo that, was the one click guaranteed to do nothing.
    ///
    /// So the reset lives here rather than in the `didSet`, and it runs on every
    /// click: the query goes, the drill-downs go, and the landing page's own
    /// stack unwinds so Home means the greeting rather than whichever artist
    /// page was open behind the search.
    func goToSection(_ item: MacSidebarItem) {
        leaveFullscreenLyricsForNavigation()
        dismissContentOverlays()
        leaveSearch()
        selectedAlbum    = nil
        selectedPlaylist = nil
        selectedSmartPlaylist = nil
        if item.isLandingPage { DiscoverSessionStore.shared.path.removeAll() }
        selection = item
    }

    /// Album the user drilled into from any content view.
    /// Non-nil → MacContentRouter shows MacAlbumDetailView.
    /// Setting this to nil returns to whichever section was active.
    @Published var selectedAlbum: Album? = nil {
        didSet {
            if selectedAlbum != nil {
                dismissContentOverlays()
                leaveSearch()
            }
            scheduleHistoryCapture()
        }
    }

    /// Artist the user asked to view (e.g. by clicking the artist name in the
    /// inspector). MacArtistsView consumes this on appear / change, selects the
    /// matching row, then clears it back to nil.
    @Published var pendingArtistID: Artist.ID? = nil

    /// Playlist the user drilled into from the Playlists view.
    /// Non-nil → MacContentRouter shows PlaylistDetailView.
    /// Setting this to nil returns to the playlists list.
    /// Smart playlist the user opened from Home's "Made by Mixtape" shelf.
    /// Non-nil → MacContentRouter shows its page. Not captured in the
    /// back/forward history; navigating anywhere clears it.
    @Published var selectedSmartPlaylist: SmartPlaylist? = nil

    /// Open a smart playlist's page, clearing whatever the column was showing.
    func showSmartPlaylist(_ playlist: SmartPlaylist) {
        selectedAlbum         = nil
        selectedPlaylist      = nil
        selectedSmartPlaylist = playlist
        dismissContentOverlays()
        leaveSearch()
    }

    @Published var selectedPlaylist: Playlist? = nil {
        didSet {
            selectedPlaylistID = (selectedPlaylist?.isSystem == false) ? selectedPlaylist?.id : nil
            if selectedPlaylist != nil {
                dismissContentOverlays()
                leaveSearch()
            }
            scheduleHistoryCapture()
        }
    }

    // MARK: - Navigation history (⌘[ / ⌘])
    //
    // The content area is addressed by six independent properties, which is fine
    // for showing a page and useless for going back to one: "where was I" isn't
    // written down anywhere. So every settled arrangement of those properties is
    // collapsed into a single `MacDestination` and pushed onto a stack, the same
    // model a browser uses.
    //
    // Capture is deferred to the next main-actor turn rather than run inside the
    // `didSet`s that trigger it. A single navigation writes several of these
    // properties in one synchronous burst — `dismissContentOverlays()` alone
    // clears three — and recording each write would fill the stack with
    // half-built states nobody ever saw. Waiting for the burst to finish means
    // the history only ever holds arrangements that actually reached the screen.

    /// Everywhere the content column can be, as one value.
    enum MacDestination {
        case section(MacSidebarItem)
        case album(Album)
        case playlist(Playlist)
        case profile(UserProfile)
        case publicPlaylist(PublicPlaylistTarget)
        case account
        /// A committed search. The results fill the content column exactly the
        /// way a playlist does, so they are a page, and Back has to come back
        /// to them — it used to land on whatever section the search was drawn
        /// over, which for most people is Home.
        case search(String)

        /// Identity, not equality — deliberately not `Equatable`.
        ///
        /// The payloads are snapshots taken when the page opened, so a playlist
        /// renamed since then no longer equals the one in the stack. Comparing
        /// whole values would make "am I already here?" answer no, and every
        /// rename would push a duplicate entry for the page already on screen.
        func matches(_ other: MacDestination) -> Bool {
            switch (self, other) {
            case let (.section(a),        .section(b)):        return a == b
            case let (.album(a),          .album(b)):          return a.id == b.id
            case let (.playlist(a),       .playlist(b)):       return a.id == b.id
            case let (.profile(a),        .profile(b)):        return a.id == b.id
            case let (.publicPlaylist(a), .publicPlaylist(b)): return a.id == b.id
            case (.account,               .account):           return true
            // Refining a query is the same page asking a different question,
            // not a new one — see `captureHistory`, which refreshes the entry
            // rather than pushing one.
            case (.search,                .search):            return true
            default:                                           return false
            }
        }
    }

    /// Past and future. `@Published` so the toolbar's arrows enable and disable
    /// themselves — `canGoBack` is computed, and a computed property only
    /// refreshes a view when something it reads publishes.
    @Published private(set) var backStack:    [MacDestination] = []
    @Published private(set) var forwardStack: [MacDestination] = []

    var canGoBack: Bool {
        lyricsCoverContent || (discoverOnScreen && discoverDepth > 0) || !backStack.isEmpty
    }
    var canGoForward: Bool {
        !forwardStack.isEmpty || (discoverOnScreen && !discoverForward.isEmpty)
    }

    // MARK: Discover's own stack
    //
    // Discover drills into artists, albums, genres and mixes through a
    // NavigationStack path that lives in DiscoverSessionStore — none of it
    // touches the six destination properties, so as far as the history above is
    // concerned opening an artist page never happened. That is why the arrows
    // looked broken: inside Discover, which is where most browsing actually
    // takes place, there was nothing in `backStack` to go back to, and the
    // arrows greyed out mid-journey.
    //
    // So the path is mirrored here and treated as a second layer of history,
    // the same way the fullscreen lyrics are: Back unwinds it before it touches
    // the destination stack, and only once it is empty does the window-level
    // history take over.

    /// Mirror of `DiscoverSessionStore.shared.path.count`. Published because
    /// `canGoBack` has to refresh the toolbar when a drill-down opens, and the
    /// store's own changes don't reach a view observing this object.
    @Published private(set) var discoverDepth = 0

    /// Pages popped off the Discover path by the Back arrow, newest last.
    private var discoverForward: [DiscoverDestination] = []

    /// True while *we* are the ones mutating the path, so the observer doesn't
    /// mistake our own unwinding for the user taking a new turn.
    private var isRestoringDiscover = false
    private var discoverObserver: AnyCancellable?

    /// Whether the Discover view is the thing filling the content column. The
    /// store is a singleton whose path outlives the view, so without this check
    /// Back would silently pop a drill-down nobody can see while the user is
    /// somewhere else entirely.
    private var discoverOnScreen: Bool {
        guard !showingAccount,
              publicPlaylistTarget == nil,
              profileTarget        == nil else { return false }
        // A linked page is Discover's column too, drawn over whatever section
        // the sidebar is still pointing at — so Back has to unwind it first.
        if discoverLinkActive { return true }
        guard selectedAlbum    == nil,
              selectedPlaylist == nil else { return false }
        // The router hands the whole column to Discover while a query is live,
        // unless the query was explicitly handed off to the Library page.
        if isSearching { return !searchInLibrary }
        let section = selection ?? .home
        return section == .home || section == .discover
    }

    private func observeDiscoverPath() {
        // `$path` publishes in `willSet`, so the value handed over is the one
        // about to be installed and `discoverDepth` still holds the old one —
        // which is exactly the comparison needed to tell a push from a pop.
        discoverObserver = DiscoverSessionStore.shared.$path.sink { [weak self] newPath in
            guard let self else { return }
            let newDepth = newPath.count
            defer { self.discoverDepth = newDepth }
            // A linked page lives exactly as long as its stack. Emptying it —
            // Back, the page's own back button, a committed search — is what
            // hands the column back to the page the link was clicked on. Above
            // the guard below because the commonest way to empty it is Back,
            // which sets `isRestoringDiscover`.
            if newDepth == 0, self.discoverDepth != 0 { self.discoverLinkActive = false }
            guard !self.isRestoringDiscover, newDepth != self.discoverDepth else { return }
            // Same rule as the destination history: a turn the user takes
            // themselves discards the future they were no longer walking to.
            self.discoverForward.removeAll()
        }
    }

    /// True while fullscreen lyrics are the thing filling the content column.
    ///
    /// They are drawn by MacRootView *instead of* MacContentRouter, so for as
    /// long as they're up they are the page on screen — but they set no
    /// destination property, so `resolvedDestination` can't see them and the
    /// history has no idea they ever opened.
    private var lyricsCoverContent: Bool { lyricsPresented && lyricsFullscreen }

    /// Where the history believes we are. Distinct from `resolvedDestination`,
    /// which is where we actually are — they differ for exactly as long as it
    /// takes a capture to run.
    private var currentDestination: MacDestination = .section(.home)

    /// True while `apply` is writing the properties. Restoring a destination
    /// looks identical to navigating to it from the outside, so without this the
    /// act of going back would record going back, and forward could never win.
    private var isRestoringHistory = false
    private var historyCaptureScheduled = false

    /// Deep enough that nobody reaches the end of it in a session, bounded so a
    /// week-long run doesn't accumulate every page ever opened.
    private static let historyLimit = 60

    /// Reads the six properties in the router's own precedence order. Any other
    /// order would record a destination different from the one on screen.
    private var resolvedDestination: MacDestination {
        if showingAccount                     { return .account }
        if let target = publicPlaylistTarget  { return .publicPlaylist(target) }
        if let profile = profileTarget        { return .profile(profile) }
        // Exactly where the router puts it: above the drill-downs, which in
        // practice can never both be set (opening one calls `leaveSearch`, and
        // committing a query clears them). `searchInLibrary` is the handoff to
        // the Library page, which is that section's own page.
        if isSearching, !searchInLibrary      { return .search(activeSearchText) }
        if let album = selectedAlbum          { return .album(album) }
        if let playlist = selectedPlaylist    { return .playlist(playlist) }
        return .section(selection ?? .home)
    }

    fileprivate func scheduleHistoryCapture() {
        guard !isRestoringHistory, !historyCaptureScheduled else { return }
        historyCaptureScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.historyCaptureScheduled = false
            self.captureHistory()
        }
    }

    private func captureHistory() {
        let destination = resolvedDestination
        guard !destination.matches(currentDestination) else {
            // Same page, newer payload: a refined query, or a playlist renamed
            // since it opened. No entry to push, but the one Back restores has
            // to be what is actually on screen.
            currentDestination = destination
            return
        }

        // Leaving a page drops its song selection. The selection is shared
        // across every track list, so without this the row you clicked stays
        // highlighted — and stays the target of Delete and the toolbar — on
        // every page you visit afterwards.
        clearTrackSelection()

        backStack.append(currentDestination)
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        // Same rule as a browser: taking a new turn discards the future you were
        // no longer walking towards.
        if !forwardStack.isEmpty { forwardStack.removeAll() }
        if !discoverForward.isEmpty { discoverForward.removeAll() }
        currentDestination = destination
    }

    func goBack() {
        // Lyrics first, because they're the top layer and the history can't see
        // them. Without this, Back read straight past the fullscreen lyrics to
        // the section you'd arrived from: open lyrics over a page of Discover
        // results, press Back, and instead of the results you got whatever
        // preceded Discover — the search you were reading gone, because
        // leaving the section swaps its query out from under it.
        //
        // Closing them is what "one step back" means from here, and it's the
        // same thing Escape already does (MacRootView's `.onExitCommand`).
        // Deliberately not pushed onto `forwardStack`: dismissing an overlay
        // isn't travel, and Forward re-opening the lyrics you just closed would
        // be a strange thing for a history arrow to do.
        if lyricsCoverContent {
            lyricsPresented = false
            return
        }

        // Discover's drill-downs sit above the destination history in exactly
        // the way the lyrics do: they're steps the user took after arriving,
        // so they have to unwind first.
        if discoverOnScreen, let top = DiscoverSessionStore.shared.path.last {
            isRestoringDiscover = true
            DiscoverSessionStore.shared.path.removeLast()
            isRestoringDiscover = false
            discoverForward.append(top)
            return
        }

        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDestination)
        currentDestination = previous
        apply(previous)
    }

    func goForward() {
        // Mirror image of Back, and deliberately in the opposite order: the
        // destination history is unwound last on the way back, so it is
        // rewound first on the way forward.
        guard let next = forwardStack.popLast() else {
            if discoverOnScreen, let page = discoverForward.popLast() {
                isRestoringDiscover = true
                DiscoverSessionStore.shared.path.append(page)
                isRestoringDiscover = false
            }
            return
        }
        backStack.append(currentDestination)
        currentDestination = next
        apply(next)
    }

    /// Every property is cleared before one is set, so a destination is restored
    /// exactly, not merged into whatever happened to be showing.
    private func apply(_ destination: MacDestination) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }

        // Same rule as ordinary navigation — which routes through
        // `captureHistory`, and this path deliberately doesn't.
        clearTrackSelection()

        // `selection` is one of the properties `resolvedDestination` reads, so
        // skipping it here didn't restore a destination, it merged one into the
        // section that happened to be showing: Back out of Settings drew the
        // playlist with Settings still lit in the sidebar, and ⌘, then assigned
        // `.settings` over `.settings` — a write that changes nothing, so the
        // router's `onChange` never fired and the playlist never cleared.
        //
        // Nil rather than the section the page was opened from, which the
        // history doesn't record: a drill-down highlighting nothing is never
        // wrong, and it's the same shape the sidebar's own `openPlaylist` makes.
        selection            = nil
        showingAccount       = false
        publicPlaylistTarget = nil
        profileTarget        = nil
        selectedAlbum        = nil
        selectedPlaylist     = nil
        selectedSmartPlaylist = nil
        discoverLinkActive   = false
        // Restoring any other page ends the search, for the same reason the
        // drill-downs call `leaveSearch`: the results are no longer what the
        // column is showing. The `.search` case below puts it back.
        searchCommitted      = false

        switch destination {
        case .section(let item):       selection            = item
        case .album(let album):        selectedAlbum        = album
        case .playlist(let playlist):  selectedPlaylist     = playlist
        case .profile(let profile):    profileTarget        = profile
        case .publicPlaylist(let t):   publicPlaylistTarget = t
        case .account:                 showingAccount       = true
        case .search(let query):
            searchStorage    = query
            searchInLibrary  = false
            searchCommitted  = true
        }
    }

    // MARK: Toolbar Delete Selection
    /// Track IDs selected in MacSongsView — drives the toolbar trash button.
    @Published var selectedTrackIDs:   Set<Track.ID> = []
    /// The row a shift-click measures its range from — the last row picked
    /// without shift, exactly as Finder anchors a range.
    ///
    /// Only the SwiftUI track lists need it; the AppKit tables anchor their own
    /// ranges. It lives here rather than in a view so it survives the view being
    /// rebuilt and is cleared by the same call that clears the selection.
    @Published var selectionAnchorTrackID: Track.ID? = nil
    /// Playlist ID selected in MacPlaylistsView (system playlists excluded).
    @Published var selectedPlaylistID: UUID? = nil

    /// True when the toolbar delete button should be enabled.
    var canDelete: Bool { !selectedTrackIDs.isEmpty || selectedPlaylistID != nil }

    /// Wipes both selection buckets — call on view disappear or after deletion.
    func clearDeleteSelection() {
        clearTrackSelection()
        selectedPlaylistID = nil
        clearPlaylistSelection()
    }

    /// Drops the song selection and its anchor, leaving the selected playlist
    /// alone — Escape inside a playlist means "never mind these rows", not
    /// "forget which playlist I'm in".
    func clearTrackSelection() {
        selectedTrackIDs       = []
        selectionAnchorTrackID = nil
    }

    // MARK: Track selection (SwiftUI lists)

    /// Applies a click to the track selection the way Finder does: plain click
    /// replaces it, ⌘-click toggles one row, ⇧-click extends from the anchor.
    ///
    /// `ordered` is the list as it appears on screen, because a shift-range means
    /// "everything between these two rows" — which depends on the sort the user
    /// is looking at, not on any order the library keeps.
    func selectTrack(_ id: Track.ID, in ordered: [Track.ID], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedTrackIDs.contains(id) {
                selectedTrackIDs.remove(id)
                // Deselecting the anchor hands the role to whatever is left, so
                // a following shift-click still has somewhere to measure from.
                if selectionAnchorTrackID == id {
                    selectionAnchorTrackID = ordered.last { selectedTrackIDs.contains($0) }
                }
            } else {
                selectedTrackIDs.insert(id)
                selectionAnchorTrackID = id
            }
            return
        }

        if modifiers.contains(.shift),
           let anchor = selectionAnchorTrackID,
           let from   = ordered.firstIndex(of: anchor),
           let to     = ordered.firstIndex(of: id) {
            // The anchor deliberately stays put: dragging a shift-click up and
            // down the list should grow and shrink one range, not ratchet.
            selectedTrackIDs = Set(ordered[min(from, to) ... max(from, to)])
            return
        }

        selectedTrackIDs       = [id]
        selectionAnchorTrackID = id
    }

    // MARK: Playlist selection

    /// Playlists picked on the Playlists page, for the actions that can be done
    /// to several at once. Ordinary rows only — a right-click outside the
    /// selection still acts on the one row it landed on.
    @Published var selectedPlaylistIDs: Set<UUID> = []

    /// Where a shift-click measures its range from, same as the track list.
    @Published var playlistSelectionAnchor: UUID? = nil

    /// Finder's rules again: plain click replaces, ⌘-click toggles, ⇧-click
    /// extends from the anchor. Shared with the track list in behaviour but not
    /// in code — the two selections are independent, and one list's Escape
    /// should not clear the other's rows.
    func selectPlaylist(_ id: UUID, in ordered: [UUID], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedPlaylistIDs.contains(id) {
                selectedPlaylistIDs.remove(id)
                if playlistSelectionAnchor == id {
                    playlistSelectionAnchor = ordered.last { selectedPlaylistIDs.contains($0) }
                }
            } else {
                selectedPlaylistIDs.insert(id)
                playlistSelectionAnchor = id
            }
            return
        }

        // With nothing picked yet, the playlist that is actually open is what
        // the user sees as "where they are" — extend from there so it ends up
        // highlighted too, instead of starting a fresh one-row selection.
        if modifiers.contains(.shift),
           let anchor = playlistSelectionAnchor ?? selectedPlaylist?.id,
           let from   = ordered.firstIndex(of: anchor),
           let to     = ordered.firstIndex(of: id) {
            selectedPlaylistIDs = Set(ordered[min(from, to) ... max(from, to)])
            return
        }

        selectedPlaylistIDs     = [id]
        playlistSelectionAnchor = id
    }

    /// Finder's right-click rule: a right-click inside the selection leaves it
    /// alone, so the menu can act on all of it; one outside replaces it with
    /// the row that was hit, so the menu is always about something the click
    /// visibly pointed at.
    func contextClickPlaylist(_ id: UUID) {
        guard !selectedPlaylistIDs.contains(id) else { return }
        selectedPlaylistIDs     = [id]
        playlistSelectionAnchor = id
    }

    func clearPlaylistSelection() {
        selectedPlaylistIDs     = []
        playlistSelectionAnchor = nil
    }

    /// The selected tracks in the order they appear on screen. Order matters for
    /// everything a multi-row menu item does — queueing, adding to a playlist —
    /// and a `Set` has none.
    func orderedSelection(from ordered: [Track.ID]) -> [Track.ID] {
        ordered.filter { selectedTrackIDs.contains($0) }
    }

    // MARK: Right Panel stack
    @Published private(set) var panelStack: [RightPanelMode] = []

    /// Which track is shown when the panel is in .nowPlaying mode.
    @Published private(set) var inspectorTrack: Track? = nil

    // MARK: Lyrics
    private static let lyricsFullscreenKey = "lyricsFullscreen"

    /// Whether the lyrics UI is currently open (popover or fullscreen overlay).
    @Published var lyricsPresented = false {
        didSet { if !lyricsPresented { karaokeActive = false } }
    }

    /// Preferred lyrics presentation. Persisted so reopening lyrics restores the
    /// last-used mode (windowed popover vs. Spotify-style fullscreen).
    @Published var lyricsFullscreen: Bool = UserDefaults.standard.bool(forKey: MacAppState.lyricsFullscreenKey) {
        didSet { UserDefaults.standard.set(lyricsFullscreen, forKey: Self.lyricsFullscreenKey) }
    }

    /// The song whose lyrics the user is editing, or nil.
    ///
    /// Lives here rather than in `MacLyricsView` because in windowed mode that
    /// view is the content of a `.popover`, and a popover hosts its own window.
    /// A sheet presented from inside one belongs to that window, so it dismisses
    /// into a context that's being torn down — the save landed on disk but the
    /// popover never re-evaluated, and the lyrics only appeared after closing
    /// and reopening them. `MacRootView` presents the editor instead, from the
    /// main window, and the popover observes this state like any other, so
    /// clearing it on dismiss is what brings the popover back up to date.
    @Published var lyricsEditorTrack: Track? = nil

    /// Karaoke: fullscreen lyrics with the rest of the app out of the way —
    /// no sidebar, no right panel, and chrome that fades until the mouse moves.
    ///
    /// Deliberately not persisted, and not the same thing as `lyricsFullscreen`:
    /// that one is a size, this one is a mode you are in for a song.
    @Published var karaokeActive = false

    /// Open/close the lyrics UI (mode is whatever `lyricsFullscreen` remembers).
    func toggleLyrics() { lyricsPresented.toggle() }

    /// Switch between windowed and fullscreen lyrics while keeping them open.
    func toggleLyricsFullscreen() { lyricsFullscreen.toggle() }

    /// Karaoke in one gesture: open the lyrics *and* put them fullscreen, or
    /// close them outright. Distinct from `toggleLyrics`, which reopens in
    /// whichever mode was last used.
    func toggleKaraoke() {
        karaokeActive.toggle()
        if karaokeActive {
            lyricsFullscreen = true
            lyricsPresented  = true
        }
    }

    // MARK: Metadata Review Queue
    /// Enrichment candidates waiting for user review, shown one at a time via sheet.
    @Published private(set) var reviewQueue: [MetadataReviewItem] = []

    /// The item currently shown in the review sheet (front of queue).
    var pendingReview: MetadataReviewItem? { reviewQueue.first }

    /// Total items in the current review batch (resets when queue drains to zero).
    private(set) var batchTotal = 0

    /// 1-based index of the item currently being reviewed.
    var currentItemNumber: Int {
        guard batchTotal > 0 else { return 1 }
        return batchTotal - reviewQueue.count + 1
    }

    func enqueueReview(_ item: MetadataReviewItem) {
        if reviewQueue.isEmpty { batchTotal = 0 }   // fresh batch
        reviewQueue.append(item)
        batchTotal += 1
    }

    func dequeueReview() {
        if !reviewQueue.isEmpty { reviewQueue.removeFirst() }
        if reviewQueue.isEmpty  { batchTotal = 0 }
    }

    // MARK: Derived

    var isSearching:      Bool            { !activeSearchText.isEmpty }
    var rightPanel:       RightPanelMode? { panelStack.last }
    var isRightPanelOpen: Bool            { !panelStack.isEmpty }

    // MARK: - Panel API

    /// Open the panel in Now Playing mode for `track` (always switches, never stacks).
    func showNowPlaying(for track: Track) {
        inspectorTrack = track
        panelStack = [.nowPlaying]
    }

    /// Toggle Now Playing — closes if already open, otherwise switches to it.
    func toggleNowPlaying(for track: Track) {
        inspectorTrack = track
        panelStack = (rightPanel == .nowPlaying) ? [] : [.nowPlaying]
    }

    /// Switch the panel to `mode` without touching whether it was open — used by
    /// the panel's own tab bar, where every tab is a lateral move.
    func showPanel(_ mode: RightPanelMode) {
        panelStack = [mode]
    }

    /// Toggle Queue — closes if already open, otherwise switches to it.
    func toggleQueue() {
        panelStack = (rightPanel == .queue) ? [] : [.queue]
    }

    /// Close the entire panel (X button on the inspector column).
    func closePanel() {
        panelStack.removeAll()
        inspectorTrack = nil
    }

    // MARK: - Drill-down navigation (from the inspector's clickable title rows)

    /// Fullscreen lyrics take over the main content column, so any navigation
    /// that swaps that column must first dismiss them — otherwise the destination
    /// page opens hidden behind the lyrics.
    private func leaveFullscreenLyricsForNavigation() {
        if lyricsPresented && lyricsFullscreen { lyricsPresented = false }
    }

    /// Open someone's profile as a full page. Clears the search that usually led
    /// here, so coming back lands on the section rather than on stale results.
    func showProfile(_ profile: UserProfile) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        showingAccount  = false
        selectedAlbum   = nil
        selectedPlaylist = nil
        profileTarget   = profile
    }

    /// Open one of someone's public playlists as a full page. Leaves
    /// `profileTarget` alone on purpose — the profile is where Back goes.
    func showPublicPlaylist(_ summary: PublicPlaylistSummary, ownerName: String) {
        leaveFullscreenLyricsForNavigation()
        publicPlaylistTarget = PublicPlaylistTarget(summary: summary, ownerName: ownerName)
    }

    /// Drill into an album, leaving the current sidebar section intact.
    func showAlbum(_ album: Album) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        selectedAlbum  = album
    }

    /// Switch to the Playlists section and open the given playlist.
    ///
    /// For jumps that arrive from outside the library — a saved mix picked off
    /// Mixtape's profile, say. Sets the section as well as the selection so the
    /// sidebar agrees with the page; `selectedPlaylist` alone would leave
    /// Discover highlighted behind a playlist.
    func showPlaylist(_ playlist: Playlist) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        selectedAlbum        = nil
        // Both of these outrank `selectedPlaylist` in the router's precedence
        // order, so leaving one set would open the playlist behind the page it
        // was picked from.
        profileTarget        = nil
        publicPlaylistTarget = nil
        selection            = .playlists
        selectedPlaylist     = playlist
    }

    /// Open Mixtape's own profile.
    ///
    /// It's a page inside Discover rather than a `profileTarget`: mixes live
    /// there, the page is already wired into that stack's playback, and giving
    /// the app a second profile route would mean two copies of the same screen.
    func showMixtapeProfile() {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        showingAccount       = false
        selectedAlbum        = nil
        selectedPlaylist     = nil
        profileTarget        = nil
        publicPlaylistTarget = nil
        // Replaces the stack rather than pushing onto it: this is arrived at
        // from outside Discover, so whatever was last drilled into there isn't
        // where Back should go.
        DiscoverSessionStore.shared.path = [.mixtapeProfile]
        selection            = .discover
    }

    /// Switch to the Artists section and select the given artist.
    func showArtist(_ artist: Artist) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        selectedAlbum   = nil
        pendingArtistID = artist.id
        selection       = .artists
    }

    /// A pending deep-link into the Discover section, consumed by
    /// OnlineDiscoverView. Used when the now-playing track is an online song that
    /// hasn't been saved locally, so its artist/album live online, not in the
    /// local library.
    enum DiscoverDeepLink: Equatable {
        case artist(name: String, trackID: Int?)
        case album(title: String, artistName: String, trackID: Int?)
    }
    @Published var pendingDiscover: DiscoverDeepLink? = nil

    /// A Discover page opened from a link somewhere else in the window — the
    /// artist under the player bar, a song's album in the queue, a name in the
    /// lyrics header. It is its own page *over* the page you were reading, not a
    /// trip to the Discover section.
    ///
    /// It used to be exactly that trip: a link set `selection = .discover`, which
    /// rendered Discover's landing — Home — for as long as the name took to
    /// resolve into a page, and left Home selected in the sidebar afterwards.
    /// Every click on a name went to Home first and then jumped. Now the section
    /// never moves: the sidebar keeps your place, and closing the page (Back, its
    /// own back button) puts you straight back on the page you clicked from.
    @Published var discoverLinkActive = false

    /// The name a link is currently turning into a page. Set at the click and
    /// cleared when the page lands, so Discover has something to draw for the
    /// length of the round trip — resolving "Travis Scott" to a catalogue id is
    /// a network call, and the landing page is what used to fill that gap.
    @Published var resolvingDiscoverLink: String? = nil

    /// Put Discover's stack on screen without moving the window to Discover.
    ///
    /// Already looking at Discover — the landing, a drill-down, a search — then
    /// there is nothing to open: the pending link lands on the stack that is
    /// already there, which is what a drill-down has always done.
    private func openLinkedDiscover() {
        guard !discoverOnScreen, !discoverLinkActive else { return }
        // A link starts its own stack rather than inheriting wherever Discover
        // was left; the store outlives the view, so without this the old page
        // would be on screen for the instant before the new one resolves.
        DiscoverSessionStore.shared.path.removeAll()
        discoverLinkActive = true
    }

    /// Open the online artist page for `name`, as a page of its own.
    func showOnlineArtist(name: String, trackID: Int?) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        // Explicit, because the router's `onChange(of: selection)` only clears
        // overlays when the value actually changes — and these are now reachable
        // from a profile opened while Discover was already the selected section,
        // where the assignment below is a no-op and the profile would stay on top.
        dismissContentOverlays()
        pendingDiscover       = .artist(name: name, trackID: trackID)
        resolvingDiscoverLink = name
        openLinkedDiscover()
    }

    /// Open the online album page for `title`/`artistName`, as a page of its own.
    func showOnlineAlbum(title: String, artistName: String, trackID: Int?) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        dismissContentOverlays()
        pendingDiscover       = .album(title: title, artistName: artistName, trackID: trackID)
        resolvingDiscoverLink = title
        openLinkedDiscover()
    }

    // MARK: - Track drag & drop

    /// Prefix that marks a dragged pasteboard string as a *track* rather than a
    /// sidebar playlist being reordered. Both payloads are UUIDs, so without it
    /// the sidebar can't tell "add these songs" from "move this playlist".
    static let trackDragPrefix = "mixtape.track:"

    static func trackDragPayload(_ id: Track.ID) -> String { trackDragPayload([id]) }

    /// One payload for a whole selection. SwiftUI's `.onDrag` hands over a single
    /// item provider no matter how many rows are selected, so dragging several
    /// songs has to travel as one string rather than one string per song.
    static func trackDragPayload(_ ids: [Track.ID]) -> String {
        trackDragPrefix + ids.map(\.uuidString).joined(separator: ",")
    }

    /// Decode a batch of dropped strings into track IDs. Empty when the drop was
    /// a playlist reorder rather than a track drag.
    static func trackIDs(fromDrop items: [String]) -> [Track.ID] {
        items.flatMap { item -> [Track.ID] in
            guard item.hasPrefix(trackDragPrefix) else { return [] }
            return item.dropFirst(trackDragPrefix.count)
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        }
    }

    // MARK: - Playlist drag & drop

    /// Prefix that marks a dragged pasteboard string as a playlist on its way
    /// *into* the sidebar. Sidebar rows drag a bare UUID to reorder themselves, so
    /// the prefix is what tells "keep this playlist in the sidebar" apart from
    /// "move this one within it" — all three payloads are otherwise just UUIDs.
    static let playlistDragPrefix = "mixtape.playlist:"

    static func playlistDragPayload(_ id: Playlist.ID) -> String {
        playlistDragPrefix + id.uuidString
    }

    /// Decode a batch of dropped strings into playlist IDs. Empty when the drop
    /// was a track drag or a sidebar reorder.
    static func playlistIDs(fromDrop items: [String]) -> [Playlist.ID] {
        items.compactMap {
            guard $0.hasPrefix(playlistDragPrefix) else { return nil }
            return UUID(uuidString: String($0.dropFirst(playlistDragPrefix.count)))
        }
    }

    /// True while the user is dragging track rows. The sidebar uses this to show
    /// a "drop into this playlist" highlight instead of the reorder insertion
    /// line — the two gestures land on the same rows and need to look different.
    @Published var isDraggingTracks = false

    // MARK: - "Go to Artist" / "Go to Album" (track context menus)
    //
    // Both used to prefer a local library row and only fall back to Discover.
    // That made one menu item mean two different pages: "Go to Artist" on a song
    // by someone you own three records by opened a list of those three records,
    // and on anyone else opened the artist. A menu item whose destination
    // depends on what happens to be saved isn't a destination. They are the
    // Discover routes now — the local pages keep their own front doors,
    // Library › Albums and Library › Artists.

    // MARK: - Song-row artist / album links

    /// Clicking an artist name in a song row, or "Go to Artist" in its menu.
    /// The Discover page carries the whole catalogue (and says how much of it is
    /// already in the library) rather than only the songs owned.
    func openDiscoverArtist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        showOnlineArtist(name: trimmed, trackID: nil)
    }

    /// Clicking the album name in a song row, or "Go to Album" in its menu.
    func openDiscoverAlbum(for track: Track) {
        guard !track.albumTitle.isEmpty else { return }
        // A multi-artist credit would be searched verbatim otherwise, and no
        // catalogue files "Album X" under "c4rl, Yungpalo".
        let artist = ImportService.creditedArtists(from: track.artistName).first
                  ?? track.artistName
        showOnlineAlbum(title: track.albumTitle, artistName: artist, trackID: nil)
    }

    // MARK: - Backward-compat shims (used by "Get Info" context menus)

    func showInspector(for track: Track) { showNowPlaying(for: track) }
    func hideInspector()                 { closePanel() }
    func toggleInspector(for track: Track) { toggleNowPlaying(for: track) }

    // MARK: - Misc

    /// Drops the query. Every navigation that opens a specific page calls this
    /// first: the router hands the whole content column to Discover whenever a
    /// query exists, so a live query would swallow the very page being opened.
    ///
    /// There used to be a second, section-aware version of this. With one query
    /// instead of one per corpus there is nothing left for it to disambiguate.
    func clearSearch() {
        searchText      = ""
        searchCommitted = false
    }
}

#endif
