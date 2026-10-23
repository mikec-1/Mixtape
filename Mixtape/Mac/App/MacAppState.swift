// Window-level state for the macOS app, injected from MacRootView.
// Right panel: another panel's button swaps to it, the active one's closes it.

#if os(macOS)
import SwiftUI
import Combine

extension Notification.Name {
    /// View > Toggle Sidebar (⌃⌘S). Posted from MixtapeApp, which can't reach `MacAppState`; MacRootView relays it.
    static let mixToggleSidebar  = Notification.Name("mix.toggleSidebar")
    /// View > Zoom In (⌘+). Same indirection as the sidebar toggle.
    static let mixZoomIn         = Notification.Name("mix.zoomIn")
    /// View > Zoom Out (⌘−). Same indirection as the sidebar toggle.
    static let mixZoomOut        = Notification.Name("mix.zoomOut")
    /// View > Actual Size (⌘0). Same indirection as the sidebar toggle.
    static let mixActualSize     = Notification.Name("mix.actualSize")
    /// View > Go Back (⌘[). Same indirection as the sidebar toggle.
    static let mixGoBack         = Notification.Name("mix.goBack")
    /// View > Go Forward (⌘]). Same indirection as the sidebar toggle.
    static let mixGoForward      = Notification.Name("mix.goForward")
    /// Controls > Get Info (⌘I) for the playing song, relayed the same way.
    static let mixShowInfo       = Notification.Name("mix.showInfo")
    /// File > New Playlist (⌘N). Creates a blank playlist and navigates to it.
    static let mixNewPlaylist    = Notification.Name("mix.newPlaylist")
}

// MARK: - Sidebar Item

enum MacSidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home      = "Home"
    case library   = "Library"
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    case playlists = "Playlists"
    case discover  = "Discover"
    case community = "Community"
    /// Watched folders shown as songs. Hidden until a folder has music in it.
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
        case .community: return "person.2"
        case .localFiles: return "folder"
        case .settings:  return "gear"
        }
    }

    /// Songs/Albums/Artists/Playlists are Library tabs and Discover is a Home tab; they still resolve via MacContentRouter.
    static var primaryItems: [MacSidebarItem] { [.home, .library, .community] }

    /// True when this destination is a face of the merged Home/Discover page.
    var isLandingPage: Bool { self == .home || self == .discover }

    /// The Library tab for the four destinations that are really tabs, nil otherwise.
    var libraryTab: LibraryTab? {
        switch self {
        case .songs:     return .songs
        case .albums:    return .albums
        case .artists:   return .artists
        case .playlists: return .playlists
        default:         return nil
        }
    }

    /// Any selection that shows the Library page, so the row stays lit when arriving via a tab.
    var isLibraryPage: Bool { self == .library || libraryTab != nil }
}

// MARK: - Library Tabs

/// Segments of the Library page.
enum LibraryTab: String, Hashable, CaseIterable, Identifiable {
    /// Spotify's unfiltered library: playlists, saved albums and smart playlists.
    case all       = "All"
    case playlists = "Playlists"
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    /// Rule-based playlists.
    case smart     = "Smart"

    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - Right Panel Mode

enum RightPanelMode: Equatable, CaseIterable {
    case nowPlaying   // shows MacTrackInspector for `inspectorTrack`
    case queue        // shows MacQueuePanelView
    case recent       // shows MacRecentPanelView

    /// Short: three tabs and a close button must fit a 220pt column.
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
@Observable
final class MacAppState {

    @ObservationIgnored public var currentUserID: String? = nil {
        didSet {
            loadSidebarLayout()
        }
    }

    private static let libraryTabKey       = "mixtape.libraryTab"
    private static let sidebarCollapsedKey = "mixtape.sidebarCollapsed"

    /// Library page segment. Global, not per-account: it's a browsing preference.
    var libraryTab: LibraryTab {
        didSet {
            guard libraryTab != oldValue else { return }
            UserDefaults.standard.set(libraryTab.rawValue, forKey: Self.libraryTabKey)
            // Leaving the tab closes the open artist.
            if libraryTab != .artists { libraryArtistID = nil }
            scheduleHistoryCapture()
        }
    }

    /// Sidebar folded to an icon rail.
    var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: MacAppState.sidebarCollapsedKey) {
        didSet {
            guard sidebarCollapsed != oldValue else { return }
            UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
        }
    }

    /// MacRootView animates the column width off this flag.
    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    /// Playlist order shared by the sidebar and the Playlists page. Mirrors
    /// `PlaylistSortSyncService.shared.sortOrder`, which owns and syncs it.
    var playlistSortOrder: LibrarySortOrder {
        get { PlaylistSortSyncService.shared.sortOrder }
        set { PlaylistSortSyncService.shared.sortOrder = newValue }
    }

    /// Sidebar drag-to-reorder mode. Not persisted.
    var isArrangingPlaylists = false

    // MARK: - Init (loads persisted UI scale)

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.scaleKey)
        uiScale = saved > 0
            ? max(Self.scaleSteps.first!, min(Self.scaleSteps.last!, CGFloat(saved)))
            : 1.0
        // Set directly so `didSet` skips its UserDefaults write. @State builds this on every
        // MacRootView init, and that write re-runs the @AppStorage views above it, forever.
        libraryTab = Self.savedLibraryTab ?? .all

        observeDiscoverPath()
        settingsObserver = SettingsRoute.shared.categoryChanges.sink { [weak self] _ in
            self?.scheduleHistoryCapture()
        }
    }

    private static var savedLibraryTab: LibraryTab? {
        UserDefaults.standard.string(forKey: libraryTabKey).flatMap(LibraryTab.init(rawValue:))
    }

    func loadSidebarLayout() {
        if let tab = Self.savedLibraryTab { libraryTab = tab }
        // Sort order is restored by `PlaylistSortSyncService`, not here.
    }

    // MARK: - UI Scale  (Cmd+= / Cmd+-)

    private static let scaleKey   = "mixtape.uiScale"
    static  let scaleSteps: [CGFloat] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5]

    var uiScale: CGFloat {
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
    var selection:        MacSidebarItem?               = .home {
        // A new section swaps the content column, so dismiss fullscreen lyrics.
        didSet {
            if oldValue != selection, lyricsPresented && lyricsFullscreen {
                lyricsPresented = false
            }
            if oldValue != selection {
                leaveSearchOnSectionChange(); libraryArtistID = nil
                if let selection { Analytics.screen(selection.rawValue.lowercased()) }
            }
            // Switching sections clears any drill-down. Here rather than in the view, so a caller
            // that sets a section and then a page (showPlaylist) keeps the page.
            if oldValue != selection, selection != nil {
                selectedAlbum = nil
                selectedPlaylist = nil
                showingAccount = false
                profileTarget = nil
                publicPlaylistTarget = nil
                messagesPage = nil
            }
            // Old section items open Library on that tab. Set here so the history sees the tab in the same turn.
            if let tab = selection?.libraryTab { libraryTab = tab }
            selectedCrateID = nil
            scheduleHistoryCapture()
        }
    }
    // MARK: Search
    // One query over the catalogue, with library matches folded in above (`LocalMatchesSection`).

    /// Backing store, written via `searchText`. Drawing code reads `activeSearchText`.
    private var searchStorage: String = "" {
        // Only refreshes a search entry already on screen; an uncommitted query is ignored.
        didSet { scheduleHistoryCapture() }
    }

    /// The live query, bound to the search field.
    var searchText: String {
        get { searchStorage }
        set {
            guard searchStorage != newValue else { return }
            searchStorage = newValue
            // Typing only feeds the suggestions panel until Return. A committed query stays
            // committed while edited; emptying the field ends it.
            if newValue.isEmpty { searchCommitted = false }
        }
    }

    /// Whether the query was asked for (Return or a suggestion pick) rather than just typed.
    /// Typing only feeds the suggestions panel, like iOS. Committing shows the results;
    /// navigating away un-commits (`leaveSearch`) but keeps the text.
    private(set) var searchCommitted: Bool = false {
        didSet { scheduleHistoryCapture() }
    }

    /// The query as drawing code sees it: empty until committed. Only the field binds to `searchText`.
    var activeSearchText: String { searchCommitted ? searchStorage : "" }

    /// Keep the text, give back the screen. Called by every navigation that opens a specific page.
    func leaveSearch() {
        if searchCommitted { searchCommitted = false }
    }

    /// Return in the search field. Clears everything drawn over the content column (fullscreen
    /// lyrics, account, profile, public playlist) so the results are visible.
    func showSearchResults() {
        if lyricsPresented { lyricsPresented = false }
        dismissContentOverlays()
        // Commit. Also drop the drill-down behind the query, so clearing it later lands on the section.
        guard !searchCommitted else { return }
        searchCommitted  = true
        selectedAlbum    = nil
        selectedPlaylist = nil
        selectedSmartPlaylist = nil
    }

    private func leaveSearchOnSectionChange() { leaveSearch() }

    /// Bumped to focus the toolbar search field, which owns its own `@FocusState`.
    var searchFocusToken: Int                           = 0
    func focusSearch() { searchFocusToken &+= 1 }

    /// ⌘K palette, drawn by MacRootView.
    var commandPaletteOpen: Bool = false

    /// Bumped on ↓ in the search field to move keyboard focus into the results.
    var resultsFocusToken: Int = 0
    func focusResults() { resultsFocusToken &+= 1 }

    /// Shows the inline account page (Settings > Manage Account).
    var showingAccount:   Bool                          = false {
        didSet { scheduleHistoryCapture() }
    }

    /// Profile opened from search or Find People; fills the content area.
    var profileTarget: UserProfile? = nil {
        didSet { scheduleHistoryCapture() }
    }

    /// Public playlist opened from a profile. Checked before `profileTarget`, so closing it returns to the profile.
    var publicPlaylistTarget: PublicPlaylistTarget? = nil {
        didSet { scheduleHistoryCapture() }
    }

    enum MessagesPage: Equatable { case list, thread(UserProfile) }

    /// Messages, from the paper plane in the top bar or a profile's Message button.
    var messagesPage: MessagesPage? = nil {
        didSet { scheduleHistoryCapture() }
    }

    /// Drops pages that take over the whole content area, including fullscreen lyrics.
    /// Called from the drill-down setters too: a sidebar playlist sets `selection = nil`,
    /// so the `selection` setter never clears them.
    private func dismissContentOverlays() {
        showingAccount       = false
        profileTarget        = nil
        publicPlaylistTarget = nil
        messagesPage         = nil
        discoverLinkActive   = false
        leaveFullscreenLyricsForNavigation()
    }

    // MARK: - Sidebar navigation

    /// Sidebar click: show that page from the top, even if already selected (`selection`'s
    /// `didSet` can't, reselecting assigns the same value). Clears the query and drill-downs
    /// and unwinds the landing page's stack.
    func goToSection(_ item: MacSidebarItem) {
        leaveFullscreenLyricsForNavigation()
        dismissContentOverlays()
        leaveSearch()
        selectedAlbum    = nil
        selectedPlaylist = nil
        selectedSmartPlaylist = nil
        libraryArtistID  = nil
        if item == .settings { SettingsRoute.shared.category = .general }
        if item.isLandingPage { DiscoverSessionStore.shared.path.removeAll() }
        selection = item
    }

    /// Album drill-down; nil returns to the active section.
    var selectedAlbum: Album? = nil {
        didSet {
            if selectedAlbum != nil {
                dismissContentOverlays()
                leaveSearch()
            }
            scheduleHistoryCapture()
        }
    }

    /// Artist open on the Artists tab, nil shows the grid. Lives here so history can restore it.
    var libraryArtistID: Artist.ID? = nil {
        didSet { scheduleHistoryCapture() }
    }
    @ObservationIgnored private var settingsObserver: AnyCancellable?

    /// Smart playlist opened from Home's "Made by Mixtape" shelf. Navigating anywhere clears it.
    var selectedSmartPlaylist: SmartPlaylist? = nil {
        didSet { scheduleHistoryCapture() }
    }

    /// Open a smart playlist's page, clearing whatever the column was showing.
    func showSmartPlaylist(_ playlist: SmartPlaylist) {
        selectedAlbum         = nil
        selectedPlaylist      = nil
        selectedSmartPlaylist = playlist
        dismissContentOverlays()
        leaveSearch()
    }

    /// Playlist drill-down; nil returns to the list.
    /// Crate page. A drill-down like a playlist; any sidebar section clears it.
    var selectedCrateID: UUID? = nil {
        didSet { scheduleHistoryCapture() }
    }

    func showCrate(_ id: UUID) {
        leaveFullscreenLyricsForNavigation()
        dismissContentOverlays()
        leaveSearch()
        selectedAlbum         = nil
        selectedPlaylist      = nil
        selectedSmartPlaylist = nil
        selection             = nil
        selectedCrateID       = id
    }

    var selectedPlaylist: Playlist? = nil {
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
    // Each settled arrangement of the destination properties is one `MacDestination` on a
    // browser-style stack. Capture waits a main-actor turn so one navigation's burst of
    // writes records only its final state.

    /// Everywhere the content column can be, as one value.
    enum MacDestination {
        case section(MacSidebarItem)
        case album(Album)
        case playlist(Playlist)
        case profile(UserProfile)
        case publicPlaylist(PublicPlaylistTarget)
        case messages(MessagesPage)
        case account
        /// A committed search is a page, so Back returns to it.
        case search(String)
        case smartPlaylist(SmartPlaylist)
        case crate(UUID)
        /// The Library page on a tab, and on Artists, the artist open on it.
        case library(LibraryTab, artist: Artist.ID?)
        case settings(SettingsCategory)

        /// Identity, not equality: payloads are snapshots, so a renamed playlist must still match its entry.
        func matches(_ other: MacDestination) -> Bool {
            switch (self, other) {
            case let (.section(a),        .section(b)):        return a == b
            case let (.album(a),          .album(b)):          return a.id == b.id
            case let (.playlist(a),       .playlist(b)):       return a.id == b.id
            case let (.profile(a),        .profile(b)):        return a.id == b.id
            case let (.publicPlaylist(a), .publicPlaylist(b)): return a.id == b.id
            case let (.messages(a),       .messages(b)):       return a == b
            case (.account,               .account):           return true
            case let (.smartPlaylist(a),  .smartPlaylist(b)):  return a.id == b.id
            case let (.crate(a),          .crate(b)):          return a == b
            case let (.library(a, x),     .library(b, y)):     return a == b && x == y
            case let (.settings(a),       .settings(b)):       return a == b
            // A refined query refreshes the entry rather than pushing one.
            case (.search,                .search):            return true
            default:                                           return false
            }
        }
    }

    /// Tracked so the toolbar arrows refresh; `canGoBack` is computed.
    private(set) var backStack:    [HistoryEntry] = []
    private(set) var forwardStack: [HistoryEntry] = []

    /// A page plus the Discover drill-downs open on it. Home and search share one path, so it's copied here.
    typealias HistoryEntry = (destination: MacDestination, discoverPath: [DiscoverDestination])

    var canGoBack: Bool {
        lyricsCoverContent || (discoverOnScreen && discoverDepth > 0) || !backStack.isEmpty
    }
    var canGoForward: Bool {
        !forwardStack.isEmpty || (discoverOnScreen && !discoverForward.isEmpty)
    }

    // MARK: Discover's own stack
    // Discover's NavigationStack path is a second history layer: Back unwinds it before
    // the destination stack, like fullscreen lyrics.

    /// Mirror of `DiscoverSessionStore.shared.path.count`, tracked so `canGoBack` refreshes the toolbar.
    private(set) var discoverDepth = 0

    /// Pages popped off the Discover path by the Back arrow, newest last.
    private var discoverForward: [DiscoverDestination] = []

    /// Set while we mutate the path, so the observer doesn't treat it as a new turn.
    @ObservationIgnored private var isRestoringDiscover = false
    @ObservationIgnored private var discoverObserver: AnyCancellable?

    /// Whether Discover fills the content column. The store's path outlives the view, so Back
    /// mustn't pop a drill-down nobody can see.
    private var discoverOnScreen: Bool {
        guard !showingAccount,
              publicPlaylistTarget == nil,
              messagesPage         == nil,
              profileTarget        == nil else { return false }
        // A linked page is Discover's column drawn over the current section.
        if discoverLinkActive { return true }
        guard selectedAlbum    == nil,
              selectedSmartPlaylist == nil,
              selectedPlaylist == nil,
              selectedCrateID == nil else { return false }
        // The router hands the whole column to Discover while a query is live.
        if isSearching { return true }
        let section = selection ?? .home
        return section == .home || section == .discover
    }

    private func observeDiscoverPath() {
        // `$path` publishes in `willSet`, so `discoverDepth` still holds the old count: that tells a push from a pop.
        discoverObserver = DiscoverSessionStore.shared.pathPublisher.sink { [weak self] newPath in
            guard let self else { return }
            let newDepth = newPath.count
            defer { self.discoverDepth = newDepth }
            // A linked page lives as long as its stack. Before the guard below, since Back sets `isRestoringDiscover`.
            if newDepth == 0, self.discoverDepth != 0 { self.discoverLinkActive = false }
            // Record only while the page the stack was opened on is on screen, so a navigation
            // clearing it on the way out can't wipe Back's copy.
            if !self.historyCaptureScheduled, self.resolvedDestination.matches(self.currentDestination) {
                self.currentDiscoverPath = self.discoverOnScreen ? newPath : []
            }
            guard !self.isRestoringDiscover, newDepth != self.discoverDepth else { return }
            // A new turn discards the forward history.
            self.discoverForward.removeAll()
        }
    }

    /// Fullscreen lyrics replace MacContentRouter but set no destination property, so the history tracks them separately.
    private var lyricsCoverContent: Bool { lyricsPresented && lyricsFullscreen }

    /// Where the history thinks we are; lags `resolvedDestination` until a capture runs.
    @ObservationIgnored private var currentDestination: MacDestination = .section(.home)
    @ObservationIgnored private var currentDiscoverPath: [DiscoverDestination] = []
    private var liveDiscoverPath: [DiscoverDestination] {
        discoverOnScreen ? DiscoverSessionStore.shared.path : []
    }

    /// Set while `apply` writes, so going back isn't recorded as a navigation.
    @ObservationIgnored private var isRestoringHistory = false
    @ObservationIgnored private var historyCaptureScheduled = false

    private static let historyLimit = 60

    /// Reads the properties in the router's precedence order, so it matches what's on screen.
    private var resolvedDestination: MacDestination {
        if showingAccount                     { return .account }
        if let target = publicPlaylistTarget  { return .publicPlaylist(target) }
        if let page = messagesPage            { return .messages(page) }
        if let profile = profileTarget        { return .profile(profile) }
        // Above the drill-downs, as in the router.
        if isSearching                        { return .search(activeSearchText) }
        if let album = selectedAlbum          { return .album(album) }
        if let smart = selectedSmartPlaylist  { return .smartPlaylist(smart) }
        if let playlist = selectedPlaylist    { return .playlist(playlist) }
        if let crate = selectedCrateID        { return .crate(crate) }
        let section = selection ?? .home
        if section == .library || section.libraryTab != nil {
            return .library(libraryTab, artist: libraryTab == .artists ? libraryArtistID : nil)
        }
        if section == .settings               { return .settings(SettingsRoute.shared.category) }
        return .section(section)
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
            // Same page, newer payload (refined query, renamed playlist): refresh the entry instead of pushing.
            currentDestination = destination
            currentDiscoverPath = liveDiscoverPath
            return
        }

        // Leaving a page drops its song selection, which is shared across every track list.
        clearTrackSelection()

        backStack.append((currentDestination, currentDiscoverPath))
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        // A new turn discards the forward history.
        if !forwardStack.isEmpty { forwardStack.removeAll() }
        if !discoverForward.isEmpty { discoverForward.removeAll() }
        currentDestination = destination
        currentDiscoverPath = liveDiscoverPath
    }

    func goBack() {
        // Fullscreen lyrics close first: they're the top layer and the history can't see them.
        // Same as Escape. Not pushed forward, since dismissing isn't travel.
        if lyricsCoverContent {
            lyricsPresented = false
            return
        }

        // Then Discover's drill-downs, which were opened after arriving.
        if discoverOnScreen, let top = DiscoverSessionStore.shared.path.last {
            isRestoringDiscover = true
            DiscoverSessionStore.shared.path.removeLast()
            isRestoringDiscover = false
            discoverForward.append(top)
            return
        }

        guard let previous = backStack.popLast() else { return }
        forwardStack.append((currentDestination, currentDiscoverPath))
        currentDestination = previous.destination
        apply(previous)
    }

    func goForward() {
        // Mirror of Back: the destination history is rewound first.
        guard let next = forwardStack.popLast() else {
            if discoverOnScreen, let page = discoverForward.popLast() {
                isRestoringDiscover = true
                DiscoverSessionStore.shared.path.append(page)
                isRestoringDiscover = false
            }
            return
        }
        backStack.append((currentDestination, currentDiscoverPath))
        currentDestination = next.destination
        apply(next)
    }

    /// Clears every property before setting one, so the destination is restored exactly, not merged.
    private func apply(_ entry: HistoryEntry) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }

        // Ordinary navigation does this in `captureHistory`, which this path skips.
        clearTrackSelection()

        // `selection` too, or Back merges the destination into the current section. Nil, since
        // the history doesn't record which section a drill-down came from.
        selection            = nil
        showingAccount       = false
        publicPlaylistTarget = nil
        messagesPage         = nil
        profileTarget        = nil
        selectedAlbum        = nil
        selectedPlaylist     = nil
        selectedSmartPlaylist = nil
        selectedCrateID      = nil
        discoverLinkActive   = false
        // Restoring any other page ends the search; `.search` below puts it back.
        searchCommitted      = false

        switch entry.destination {
        case .section(let item):       selection            = item
        case .album(let album):        selectedAlbum        = album
        case .playlist(let playlist):  selectedPlaylist     = playlist
        case .profile(let profile):    profileTarget        = profile
        case .publicPlaylist(let t):   publicPlaylistTarget = t
        case .messages(let page):      messagesPage         = page
        case .account:                 showingAccount       = true
        case .smartPlaylist(let p):    selectedSmartPlaylist = p
        case .crate(let id):           selectedCrateID      = id
        case .library(let tab, let artist):
            selection       = .library
            libraryTab      = tab
            libraryArtistID = artist
        case .settings(let category):
            selection = .settings
            SettingsRoute.shared.category = category
        case .search(let query):
            searchStorage    = query
            searchCommitted  = true
        }

        // Last, because `discoverOnScreen` reads everything above.
        isRestoringDiscover = true
        DiscoverSessionStore.shared.path = entry.discoverPath
        isRestoringDiscover = false
        if !entry.discoverPath.isEmpty, !discoverOnScreen { discoverLinkActive = true }
        currentDiscoverPath = entry.discoverPath
    }

    // MARK: Toolbar Delete Selection
    /// Selected track IDs; drives the toolbar trash button.
    var selectedTrackIDs:   Set<Track.ID> = []
    /// Where a shift-click range starts, like Finder. Only the SwiftUI lists use it; AppKit tables anchor their own.
    var selectionAnchorTrackID: Track.ID? = nil
    /// Playlist ID selected in MacPlaylistsView (system playlists excluded).
    var selectedPlaylistID: UUID? = nil

    /// True when the toolbar delete button should be enabled.
    var canDelete: Bool { !selectedTrackIDs.isEmpty || selectedPlaylistID != nil }

    /// Clears both selections. Call on disappear or after deletion.
    func clearDeleteSelection() {
        clearTrackSelection()
        selectedPlaylistID = nil
        clearPlaylistSelection()
    }

    /// Drops the song selection but keeps the playlist: Escape means "never mind these rows".
    func clearTrackSelection() {
        selectedTrackIDs       = []
        selectionAnchorTrackID = nil
    }

    // MARK: Track selection (SwiftUI lists)

    /// Finder rules: click replaces, ⌘-click toggles, ⇧-click extends from the anchor.
    /// `ordered` is the on-screen order.
    func selectTrack(_ id: Track.ID, in ordered: [Track.ID], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedTrackIDs.contains(id) {
                selectedTrackIDs.remove(id)
                // Hand the anchor to what's left so shift-click still has a start.
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
            // The anchor stays put, so shift-clicking up and down resizes one range.
            selectedTrackIDs = Set(ordered[min(from, to) ... max(from, to)])
            return
        }

        selectedTrackIDs       = [id]
        selectionAnchorTrackID = id
    }

    // MARK: Playlist selection

    /// Playlists selected on the Playlists page, for bulk actions.
    var selectedPlaylistIDs: Set<UUID> = []

    /// Where a shift-click measures its range from, same as the track list.
    var playlistSelectionAnchor: UUID? = nil

    /// Same Finder rules as `selectTrack`, but independent so one list's Escape doesn't clear the other.
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

        // With nothing selected, extend from the open playlist.
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

    /// Finder's right-click: inside the selection keeps it, outside replaces it with the clicked row.
    func contextClickPlaylist(_ id: UUID) {
        guard !selectedPlaylistIDs.contains(id) else { return }
        selectedPlaylistIDs     = [id]
        playlistSelectionAnchor = id
    }

    func clearPlaylistSelection() {
        selectedPlaylistIDs     = []
        playlistSelectionAnchor = nil
    }

    /// Selected tracks in on-screen order, for queueing and adding to playlists.
    func orderedSelection(from ordered: [Track.ID]) -> [Track.ID] {
        ordered.filter { selectedTrackIDs.contains($0) }
    }

    // MARK: Right Panel stack
    private(set) var panelStack: [RightPanelMode] = []

    /// Which track is shown when the panel is in .nowPlaying mode.
    private(set) var inspectorTrack: Track? = nil

    // MARK: Lyrics
    private static let lyricsFullscreenKey = "lyricsFullscreen"

    /// Whether the lyrics UI is currently open (popover or fullscreen overlay).
    var lyricsPresented = false {
        didSet { if !lyricsPresented { karaokeActive = false } }
    }

    /// Persisted lyrics mode: popover or fullscreen.
    var lyricsFullscreen: Bool = UserDefaults.standard.bool(forKey: MacAppState.lyricsFullscreenKey) {
        didSet { UserDefaults.standard.set(lyricsFullscreen, forKey: Self.lyricsFullscreenKey) }
    }

    /// Song whose lyrics are being edited. Lives here because a sheet inside the lyrics
    /// popover dismisses into a dead window; MacRootView presents the editor instead.
    var lyricsEditorTrack: Track? = nil

    /// The lyric card sheet, presented from the main window for the same reason.
    var lyricCard: LyricCardRequest? = nil

    /// Get Info's song. A sheet, since the Now Playing panel follows playback.
    var infoTrack: Track? = nil

    /// The song editor's song, presented from the main window like Get Info.
    var editTrack: Track? = nil

    /// An edit being posted to the community. Same reason as `editTrack`.
    var postTrack: Track? = nil

    /// Karaoke: fullscreen lyrics, no sidebar or right panel, fading chrome. Not persisted,
    /// and separate from `lyricsFullscreen` (a size, not a mode).
    var karaokeActive = false

    /// Open/close the lyrics UI (mode is whatever `lyricsFullscreen` remembers).
    func toggleLyrics() { lyricsPresented.toggle() }

    /// Switch between windowed and fullscreen lyrics while keeping them open.
    func toggleLyricsFullscreen() { lyricsFullscreen.toggle() }

    /// Open lyrics fullscreen, or close them. `toggleLyrics` reopens in the last-used mode instead.
    func toggleKaraoke() {
        karaokeActive.toggle()
        if karaokeActive {
            lyricsFullscreen = true
            lyricsPresented  = true
        }
    }

    // MARK: Metadata Review Queue
    /// Enrichment candidates waiting for user review, shown one at a time via sheet.
    private(set) var reviewQueue: [MetadataReviewItem] = []

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

    /// Close Now Playing if open, otherwise switch to it.
    func toggleNowPlaying(for track: Track) {
        inspectorTrack = track
        panelStack = (rightPanel == .nowPlaying) ? [] : [.nowPlaying]
    }

    /// Switch panel mode without changing whether it's open, for the panel's tab bar.
    func showPanel(_ mode: RightPanelMode) {
        panelStack = [mode]
    }

    /// Close Queue if open, otherwise switch to it.
    func toggleQueue() {
        panelStack = (rightPanel == .queue) ? [] : [.queue]
    }

    /// Close the entire panel (X button on the inspector column).
    func closePanel() {
        panelStack.removeAll()
        inspectorTrack = nil
    }

    // MARK: - Drill-down navigation (from the inspector's clickable title rows)

    /// Navigation that swaps the content column must dismiss fullscreen lyrics, or the page opens behind them.
    private func leaveFullscreenLyricsForNavigation() {
        if lyricsPresented && lyricsFullscreen { lyricsPresented = false }
    }

    /// Open a profile as a full page, clearing the search that led here.
    func showProfile(_ profile: UserProfile) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        showingAccount  = false
        selectedAlbum   = nil
        selectedPlaylist = nil
        messagesPage    = nil
        profileTarget   = profile
    }

    /// Messages as a full page, on one conversation when `person` is set.
    func openMessages(with person: UserProfile? = nil) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        showingAccount       = false
        selectedAlbum        = nil
        selectedPlaylist     = nil
        profileTarget        = nil
        publicPlaylistTarget = nil
        messagesPage         = person.map { .thread($0) } ?? .list
    }

    /// Open a public playlist as a full page. Keeps `profileTarget` so Back returns to the profile.
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

    /// Switch to Playlists and open `playlist`, for jumps from outside the library.
    func showPlaylist(_ playlist: Playlist) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        selectedAlbum        = nil
        // Both outrank `selectedPlaylist` in the router, so they must be cleared.
        profileTarget        = nil
        publicPlaylistTarget = nil
        messagesPage         = nil
        selection            = .playlists
        selectedPlaylist     = playlist
    }

    /// Mixtape's own profile: a page in Discover's stack, not a `profileTarget`.
    func showMixtapeProfile() {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        showingAccount       = false
        selectedAlbum        = nil
        selectedPlaylist     = nil
        profileTarget        = nil
        publicPlaylistTarget = nil
        messagesPage         = nil
        // Replace the stack: arriving from outside Discover, the old drill-down isn't where Back should go.
        DiscoverSessionStore.shared.path = [.mixtapeProfile]
        selection            = .discover
    }

    /// A community post, drawn over the current page like other links.
    /// From a profile page, the profile goes under it so Back lands there.
    func showPost(code: String, from profile: UserProfile? = nil) {
        clearSearch()
        dismissContentOverlays()
        openLinkedDiscover()
        if let profile { DiscoverSessionStore.shared.path.append(.profile(profile)) }
        DiscoverSessionStore.shared.path.append(.post(code))
    }

    /// Switch to the Artists section and select the given artist.
    func showArtist(_ artist: Artist) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        selectedAlbum   = nil
        selection       = .artists
        libraryArtistID = artist.id
    }

    /// Pending deep link into Discover, consumed by OnlineDiscoverView. Used for online songs
    /// whose artist/album aren't in the library.
    enum DiscoverDeepLink: Equatable {
        case artist(name: String, trackID: Int?)
        case album(title: String, artistName: String, trackID: Int?)
        /// Station seeded from one song (Go to Song Radio).
        case songRadio(title: String, artistName: String)
        /// Station seeded from an artist name (⌘K radio).
        case artistRadio(name: String)
    }
    var pendingDiscover: DiscoverDeepLink? = nil

    /// A Discover page opened from a link elsewhere (player bar, queue, lyrics header). Drawn
    /// over the current page without changing the sidebar section; closing it returns there.
    var discoverLinkActive = false

    /// Name a link is resolving, so Discover has something to draw during the network round trip.
    var resolvingDiscoverLink: String? = nil

    /// Show Discover's stack without switching section. Already on Discover: the link lands on the existing stack.
    private func openLinkedDiscover() {
        guard !discoverOnScreen, !discoverLinkActive else { return }
        // A link starts a fresh stack; the store outlives the view.
        DiscoverSessionStore.shared.path.removeAll()
        discoverLinkActive = true
    }

    /// Open the online artist page for `name`, as a page of its own.
    func showOnlineArtist(name: String, trackID: Int?) {
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        // Explicit: the `selection` setter doesn't clear anything when Discover was already selected.
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

    /// Open the station seeded by one song, as a page of its own.
    func showArtistRadio(name: String) {
        guard !name.isEmpty else { return }
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        dismissContentOverlays()
        pendingDiscover       = .artistRadio(name: name)
        resolvingDiscoverLink = "\(name) Radio"
        openLinkedDiscover()
    }

    /// ⌘K "dub <playlist> to <person>". MacRootView presents the sheet.
    struct DubRequest: Identifiable {
        let id = UUID()
        let playlist: Playlist
        let recipient: String
    }
    var dubRequest: DubRequest? = nil

    func showSongRadio(title: String, artistName: String) {
        guard !title.isEmpty, !artistName.isEmpty else { return }
        leaveFullscreenLyricsForNavigation()
        clearSearch()
        dismissContentOverlays()
        pendingDiscover       = .songRadio(title: title, artistName: artistName)
        resolvingDiscoverLink = "\(title) Radio"
        openLinkedDiscover()
    }

    // MARK: - Track drag & drop

    /// Marks a dragged string as tracks, not a sidebar playlist reorder (both are UUIDs).
    static let trackDragPrefix = "mixtape.track:"

    static func trackDragPayload(_ id: Track.ID) -> String { trackDragPayload([id]) }

    /// One payload for the whole selection: `.onDrag` gives a single item provider.
    static func trackDragPayload(_ ids: [Track.ID]) -> String {
        trackDragPrefix + ids.map(\.uuidString).joined(separator: ",")
    }

    /// Dropped strings -> track IDs. Empty for a playlist reorder.
    static func trackIDs(fromDrop items: [String]) -> [Track.ID] {
        items.flatMap { item -> [Track.ID] in
            guard item.hasPrefix(trackDragPrefix) else { return [] }
            return item.dropFirst(trackDragPrefix.count)
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        }
    }

    // MARK: - Playlist drag & drop

    /// Marks a playlist dragged into the sidebar, vs. a sidebar row reordering (bare UUID).
    static let playlistDragPrefix = "mixtape.playlist:"

    static func playlistDragPayload(_ id: Playlist.ID) -> String {
        playlistDragPrefix + id.uuidString
    }

    /// Dropped strings -> playlist IDs. Empty for a track drag or sidebar reorder.
    static func playlistIDs(fromDrop items: [String]) -> [Playlist.ID] {
        items.compactMap {
            guard $0.hasPrefix(playlistDragPrefix) else { return nil }
            return UUID(uuidString: String($0.dropFirst(playlistDragPrefix.count)))
        }
    }

    /// True while dragging track rows, so the sidebar shows a drop highlight instead of the reorder line.
    var isDraggingTracks = false

    // MARK: - Song-row artist / album links

    /// Artist name click or Go to Artist. Always the Discover page, never a local library row.
    func openDiscoverArtist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        showOnlineArtist(name: trimmed, trackID: nil)
    }

    /// Go to Song Radio, titled with the printed song rather than the stored one.
    func openSongRadio(for track: Track) {
        showSongRadio(title: track.displayTitle, artistName: track.displayArtistName)
    }

    /// Clicking the album name in a song row, or "Go to Album" in its menu.
    func openDiscoverAlbum(for track: Track) {
        guard !track.albumTitle.isEmpty else { return }
        // Search a multi-artist credit by its first artist.
        let artist = ImportService.creditedArtists(from: track.artistName).first
                  ?? track.artistName
        showOnlineAlbum(title: track.albumTitle, artistName: artist, trackID: nil)
    }

    // MARK: - Backward-compat shims (used by "Get Info" context menus)

    func showInspector(for track: Track) { infoTrack = track }
    func hideInspector()                 { closePanel() }
    func toggleInspector(for track: Track) { toggleNowPlaying(for: track) }

    // MARK: - Misc

    /// Drops the query. Pages call this before opening, since the router gives the whole column to Discover while a query exists.
    func clearSearch() {
        searchText      = ""
        searchCommitted = false
    }
}

#endif

struct LyricCardRequest: Identifiable {
    let track: Track
    let lyrics: TrackLyrics
    var id: Track.ID { track.id }
}
