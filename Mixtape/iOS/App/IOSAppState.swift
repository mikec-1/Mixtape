// IOSAppState.swift
// Mixtape — iOS/App
//
// Window-level state for the iOS app.
// Holds the metadata review queue shown after imports.
// Mirrors the review-queue slice of MacAppState.

#if os(iOS)
import SwiftUI
import Combine

final class IOSAppState: ObservableObject {

    // MARK: - Tab Selection

    /// The selected top-level tab. Held here (rather than as local @State in
    /// MainTabView) so navigation requests originating outside a tab — e.g.
    /// tapping an artist in the mini player or now-playing sheet — can switch
    /// tabs programmatically.
    @Published var selectedTab: AppTab = .home

    /// Bumped to ask the Home landing to raise its search field.
    ///
    /// The Search tab used to be a page of its own that searched the local
    /// library and nothing else — a box that couldn't reach a song you didn't
    /// already own. There's one search now, the landing's, and it looks at the
    /// catalogue with your own library folded in above it. So the tab is a
    /// doorway to that field rather than a second search: see MainTabView.
    @Published var searchFocusToken: Int = 0

    /// Open the one search field, wherever the user asked from.
    func focusSearch() {
        selectedTab = .home
        searchFocusToken &+= 1
    }

    /// Bumped when the Search tab is tapped while Search is already showing —
    /// the tab bar's own "press it again" gesture, which on Spotify raises the
    /// field and the keyboard. Same shape as `homeResetToken`: re-selecting a
    /// tab writes the value it already had, so nothing downstream can see the
    /// tap unless something else changes.
    @Published private(set) var searchTapToken = 0

    func goToSearch() {
        if selectedTab == .search { searchTapToken &+= 1 }
        selectedTab = .search
    }

    /// Bumped to ask the Home landing to drop back to its default state:
    /// no search, no results, nothing pushed.
    @Published private(set) var homeResetToken = 0

    /// What tapping the Home tab means when Home is already the tab you're on —
    /// Apple's "tap the current tab to go back to its root", plus the search.
    ///
    /// Assigning `selectedTab` can't carry this on its own: tapping Home while
    /// Home is selected writes the same value, so nothing downstream can tell
    /// the tap happened. That is exactly the state a search leaves you in, with
    /// the results drawn over the landing and no way back to it from the tab
    /// bar. Mirrors `MacAppState.goToSection(_:)` on the Mac side.
    ///
    /// Arriving from another tab deliberately doesn't reset: the landing is
    /// meant to come back the way it was left (see `DiscoverSessionStore`).
    func goHome() {
        if selectedTab == .home || selectedTab == .discover { homeResetToken &+= 1 }
        selectedTab = .home
    }

    // MARK: - Now Playing

    /// Whether the full player is up.
    ///
    /// This belongs to the app, not to the mini player that opens it. The sheet
    /// used to be presented *by* `MiniPlayerBar`, which `MainTabView` only mounts
    /// while `engine.state.isActive` — so skipping to a song that still has to be
    /// fetched dropped the engine out of `isActive` for a moment, unmounted the
    /// bar, and took the open full player down with it. Presenting from the tab
    /// view instead means the sheet outlives that gap, which is precisely the
    /// gap the user is waiting through.
    @Published var showNowPlaying = false

    // MARK: - Cross-tab Artist Navigation
    //
    // The mini player and now-playing sheet live ABOVE the per-tab
    // NavigationStacks, so they can't push directly. Instead they set one of
    // these pending requests; the owning tab consumes it and drives its own
    // NavigationStack (mirrors the macOS `showArtist` / `showOnlineArtist`
    // intent on MacAppState).

    /// A local library artist to push on the Library tab's stack. Only set by
    /// Library › Artists itself now — tapping a name anywhere goes to Discover,
    /// see `openOnlineArtist`.
    @Published var pendingLibraryArtist: Artist? = nil

    /// An artist name to resolve + push on the Discover tab's stack (used when no
    /// local library artist matches — e.g. a featured artist on a saved song).
    @Published var pendingDiscoverArtistName: String? = nil

    /// A library playlist to push on the Library tab's stack — set when a
    /// playlist is picked from somewhere that isn't the library, such as a saved
    /// mix on Mixtape's profile.
    @Published var pendingLibraryPlaylist: Playlist? = nil

    /// Mixtape's own profile, to push on the Discover tab's stack. A flag rather
    /// than a payload: the page builds itself from the session store, so there
    /// is nothing to carry across.
    @Published var pendingMixtapeProfile = false

    /// Open a library playlist from another tab.
    func openLibraryPlaylist(_ playlist: Playlist) {
        pendingLibraryPlaylist = playlist
        selectedTab = .library
    }

    /// Open Mixtape's profile from another tab.
    func openMixtapeProfile() {
        pendingMixtapeProfile = true
        selectedTab = .discover
    }

    /// Open a name straight on the Discover artist page, without asking whether
    /// the library happens to hold a row for it.
    ///
    /// This is what the now-playing surfaces use. Routing per name (below) meant
    /// one credit line could lead to two different kinds of page depending on
    /// what the user had saved — the features on a song opening Discover while
    /// its main artist opened the library. Mirrors macOS `showOnlineArtist`.
    func openOnlineArtist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pendingDiscoverArtistName = trimmed
        selectedTab = .discover
    }

    // MARK: - Metadata Review Queue

    /// Enrichment candidates waiting for user review, shown one at a time.
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
}
#endif
