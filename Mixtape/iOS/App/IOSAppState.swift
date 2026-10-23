// Window-level state for the iOS app. Mirrors parts of MacAppState.

#if os(iOS)
import SwiftUI
import Combine

@Observable
final class IOSAppState {

    // MARK: - Tab Selection

    /// Selected tab. Held here so things outside a tab (mini player, now playing) can switch tabs.
    /// Every switch closes the full player so the new page isn't hidden under it.
    var selectedTab: AppTab = .home {
        didSet {
            showNowPlaying = false; showMessages = false
            if oldValue != selectedTab { Analytics.screen("\(selectedTab)") }
        }
    }

    /// Open the Search tab with its field raised, wherever the user asked from.
    func focusSearch() {
        selectedTab = .search
        searchFocusRequested = true
    }

    /// Set when the Search tab is tapped while already showing, to raise the field and keyboard. SearchView
    /// clears it, so a second tap that lands before Search has appeared still counts.
    var searchFocusRequested = false

    func goToSearch() {
        // Writing the same tab changes nothing on screen, so raise the field instead.
        if selectedTab == .search { searchFocusRequested = true } else { selectedTab = .search }
    }

    /// Bumped to reset Home: no search, no results, nothing pushed.
    private(set) var homeResetToken = 0

    /// Tapping Home while on Home: pop to root and clear the search. Needs a method because writing the same
    /// `selectedTab` is invisible. Arriving from another tab doesn't reset (see `DiscoverSessionStore`).
    /// Mirrors `MacAppState.goToSection(_:)`.
    func goHome() {
        if selectedTab == .home || selectedTab == .discover { homeResetToken &+= 1 }
        if selectedTab != .home { selectedTab = .home }
    }

    // MARK: - Now Playing

    /// Whether the full player is up. Owned here, not by `MiniPlayerBar`, which unmounts while the engine
    /// is between songs and would take the sheet with it.
    var showNowPlaying = false

    // MARK: - Messages

    /// Messages, full screen over everything like Instagram's.
    var showMessages = false
    /// A conversation for the cover to open on, consumed by MessagesView.
    var messagesWith: UserProfile?

    func openMessages(with person: UserProfile? = nil) {
        messagesWith = person
        showMessages = true
    }

    // MARK: - Cross-tab Artist Navigation
    // The mini player and now-playing sheet sit above the tab NavigationStacks, so they set a pending
    // request and the owning tab pushes it.

    /// A library artist to push on the Library tab. Only set by Library > Artists; names elsewhere use
    /// `openOnlineArtist`.
    var pendingLibraryArtist: Artist? = nil

    /// Artist name to resolve and push on Discover, when no library artist matches.
    var pendingDiscoverArtistName: String? = nil

    /// Album to resolve and push on Discover, as a probe song carrying its title and artist.
    var pendingDiscoverAlbum: OnlineTrack? = nil

    /// Library playlist to push on the Library tab, when picked from outside the library.
    var pendingLibraryPlaylist: Playlist? = nil

    /// Song to build a station from on the Discover tab. Mirrors `MacAppState.showSongRadio`.
    struct SongRadioSeed: Equatable {
        let title: String
        let artistName: String
    }
    var pendingSongRadio: SongRadioSeed? = nil

    /// Push Mixtape's profile on Discover. A flag: the page builds from the session store.
    var pendingMixtapeProfile = false

    /// Song whose info sheet is open, presented once at the tab root. A sheet inside a `.contextMenu` is
    /// torn down when the menu closes. Mirrors `MacAppState.showInspector(for:)`.
    var infoTrack: Track? = nil

    /// The song editor's song, presented at the tab root like `infoTrack`.
    var editTrack: Track? = nil

    /// An edit being posted to the community, presented like `editTrack`.
    var postTrack: Track? = nil

    /// A community post's share code to push on Discover.
    var pendingPost: String? = nil

    func openPost(code: String) {
        pendingPost = code
        selectedTab = .discover
    }

    /// A profile to push on Discover, e.g. a new follower from the inbox.
    var pendingProfile: UserProfile? = nil

    func openProfile(_ profile: UserProfile) {
        pendingProfile = profile
        selectedTab = .discover
    }

    /// Show the metadata sheet for one song.
    func showInfo(for track: Track) { infoTrack = track }

    /// Open a library playlist from another tab.
    func openLibraryPlaylist(_ playlist: Playlist) {
        pendingLibraryPlaylist = playlist
        selectedTab = .library
    }

    var pendingLibraryCrate: Crate? = nil

    func openLibraryCrate(_ id: UUID) {
        pendingLibraryCrate = CrateService.shared.crate(id: id)
        selectedTab = .library
    }

    /// Open Mixtape's profile from another tab.
    func openMixtapeProfile() {
        pendingMixtapeProfile = true
        selectedTab = .discover
    }

    /// Open a name on the Discover artist page, never the library one, so every credit leads to the same
    /// kind of page. Mirrors macOS `showOnlineArtist`.
    func openOnlineArtist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pendingDiscoverArtistName = trimmed
        selectedTab = .discover
    }

    /// Open an album by name on Discover. Mirrors macOS `showOnlineAlbum`.
    func openOnlineAlbum(title: String, artistName: String) {
        guard !title.isEmpty else { return }
        pendingDiscoverAlbum = OnlineTrack(title: "", artistName: artistName, albumTitle: title)
        selectedTab = .discover
    }

    /// Open the station seeded by one song.
    func openSongRadio(title: String, artistName: String) {
        guard !title.isEmpty, !artistName.isEmpty else { return }
        pendingSongRadio = SongRadioSeed(title: title, artistName: artistName)
        selectedTab = .discover
    }

    // MARK: - Metadata Review Queue

    /// Enrichment candidates waiting for user review, shown one at a time.
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

    /// Add Music is up. It shows the review itself, since the tab view can't present over it.
    var importSheetOpen = false

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
