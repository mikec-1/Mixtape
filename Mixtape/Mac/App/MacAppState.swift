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

// MARK: - Sidebar Item

enum MacSidebarItem: String, Hashable, CaseIterable, Identifiable {
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    case playlists = "Playlists"
    case settings  = "Settings"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .songs:     return "music.note"
        case .albums:    return "square.stack"
        case .artists:   return "music.mic"
        case .playlists: return "music.note.list"
        case .settings:  return "gear"
        }
    }

    /// Items shown under the "Library" section.
    static var libraryItems: [MacSidebarItem] { [.songs, .albums, .artists, .playlists] }
}

// MARK: - Right Panel Mode

enum RightPanelMode: Equatable {
    case nowPlaying   // shows MacTrackInspector for `inspectorTrack`
    case queue        // shows MacQueuePanelView
}

// MARK: - MacAppState

@MainActor
final class MacAppState: ObservableObject {

    public var currentUserID: String? = nil {
        didSet {
            loadLibraryItems()
        }
    }

    private var libraryOrderKey: String {
        if let id = currentUserID {
            return "mixtape.sidebarLibraryOrder_\(id)"
        }
        return "mixtape.sidebarLibraryOrder"
    }

    @Published var libraryItems: [MacSidebarItem] = []

    // MARK: - Init (loads persisted UI scale)

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.scaleKey)
        _uiScale = Published(initialValue: saved > 0
            ? max(Self.scaleSteps.first!, min(Self.scaleSteps.last!, CGFloat(saved)))
            : 1.0)
            
        loadLibraryItems()
    }

    func loadLibraryItems() {
        if let storedOrder = UserDefaults.standard.array(forKey: libraryOrderKey) as? [String] {
            let loaded = storedOrder.compactMap { MacSidebarItem(rawValue: $0) }
            let filtered = loaded.filter { [.songs, .albums, .artists, .playlists].contains($0) }
            if filtered.count == 4 {
                libraryItems = filtered
            } else {
                libraryItems = [.songs, .albums, .artists, .playlists]
            }
        } else {
            libraryItems = [.songs, .albums, .artists, .playlists]
        }
    }
    
    func moveLibraryItem(from source: IndexSet, to destination: Int) {
        var items = libraryItems
        items.move(fromOffsets: source, toOffset: destination)
        libraryItems = items
        UserDefaults.standard.set(items.map { $0.rawValue }, forKey: libraryOrderKey)
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
    @Published var selection:        MacSidebarItem?               = .songs
    @Published var searchText:       String                        = ""
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    /// Album the user drilled into from any content view.
    /// Non-nil → MacContentRouter shows MacAlbumDetailView.
    /// Setting this to nil returns to whichever section was active.
    @Published var selectedAlbum: Album? = nil

    /// Playlist the user drilled into from the Playlists view.
    /// Non-nil → MacContentRouter shows PlaylistDetailView.
    /// Setting this to nil returns to the playlists list.
    @Published var selectedPlaylist: Playlist? = nil {
        didSet {
            selectedPlaylistID = (selectedPlaylist?.isSystem == false) ? selectedPlaylist?.id : nil
        }
    }

    // MARK: Toolbar Delete Selection
    /// Track IDs selected in MacSongsView — drives the toolbar trash button.
    @Published var selectedTrackIDs:   Set<Track.ID> = []
    /// Playlist ID selected in MacPlaylistsView (system playlists excluded).
    @Published var selectedPlaylistID: UUID? = nil

    /// True when the toolbar delete button should be enabled.
    var canDelete: Bool { !selectedTrackIDs.isEmpty || selectedPlaylistID != nil }

    /// Wipes both selection buckets — call on view disappear or after deletion.
    func clearDeleteSelection() {
        selectedTrackIDs   = []
        selectedPlaylistID = nil
    }

    // MARK: Right Panel stack
    @Published private(set) var panelStack: [RightPanelMode] = []

    /// Which track is shown when the panel is in .nowPlaying mode.
    @Published private(set) var inspectorTrack: Track? = nil

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

    var isSearching:      Bool            { !searchText.isEmpty }
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

    /// Toggle Queue — closes if already open, otherwise switches to it.
    func toggleQueue() {
        panelStack = (rightPanel == .queue) ? [] : [.queue]
    }

    /// Close the entire panel (X button on the inspector column).
    func closePanel() {
        panelStack.removeAll()
        inspectorTrack = nil
    }

    // MARK: - Backward-compat shims (used by "Get Info" context menus)

    func showInspector(for track: Track) { showNowPlaying(for: track) }
    func hideInspector()                 { closePanel() }
    func toggleInspector(for track: Track) { toggleNowPlaying(for: track) }

    // MARK: - Misc

    func clearSearch() { searchText = "" }
}

#endif
