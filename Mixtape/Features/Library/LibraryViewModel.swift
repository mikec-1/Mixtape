// LibraryViewModel.swift
// Mixtape — Features/Library

import Foundation
import SwiftUI
import Combine

public enum LibrarySection: String, CaseIterable, Identifiable {
    case playlists  = "Playlists"
    /// Smart playlists used to hang off a permanent row above the playlist
    /// list. They're a kind of playlist, not a feature announcement, so they
    /// get a chip like every other shelf in the library.
    case smart      = "Smart"
    case albums     = "Albums"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .playlists:  return MixtapeIcons.playlist
        case .smart:      return "wand.and.stars"
        case .albums:     return MixtapeIcons.album
        }
    }
}

/// How the library list is ordered. Mirrors Spotify's own set, minus the ones
/// that need data Mixtape doesn't keep.
public enum LibrarySortOrder: String, CaseIterable, Identifiable {
    /// The arrangement the user dragged themselves, shared with the Mac sidebar
    /// and carried between devices on `Playlist.sortIndex`. The default: a list
    /// somebody has arranged by hand should stay arranged until they say
    /// otherwise, and an untouched library falls back to recents anyway.
    case manual         = "Custom Order"
    /// Most recently touched first — the reason the control can read "Recents"
    /// rather than "Sort".
    case recents        = "Recents"
    case recentlyAdded  = "Recently Added"
    case alphabetical   = "Alphabetical"
    /// Groups the app's mixes and other people's playlists away from your own.
    case creator        = "Creator"

    public var id: String { rawValue }

    /// The one place this sort actually gets applied, so every screen that
    /// shows a playlist list — iOS's `LibraryViewModel`, the macOS sidebar,
    /// and the macOS Playlists overview — can never disagree about what a
    /// given order means. Always partitions pinned ahead of unpinned after
    /// sorting: a pin is an override of the sort, not a sort key, so letting
    /// the sort move a pinned playlist would make the pin mean nothing in
    /// three of the four orders.
    @MainActor public func sorted(_ playlists: [Playlist]) -> [Playlist] {
        // Every browse list — Mac sidebar, Mac Playlists, iOS Library — orders
        // through here, which is the whole reason the All Songs setting is
        // applied here too. See `PlaylistMetadataService.showsAllSongs`.
        let playlists = PlaylistMetadataService.shared.showsAllSongs
            ? playlists : playlists.filter { !$0.isAllSongs }
        let sorted: [Playlist]
        switch self {
        case .manual:
            // `library.playlists` is already in the shared order — see
            // `LibraryService.refreshPlaylistsBody()`.
            sorted = playlists
        case .recents:
            sorted = playlists.sorted { Self.recency($0) > Self.recency($1) }
        case .recentlyAdded:
            sorted = playlists.sorted { $0.dateCreated > $1.dateCreated }
        case .alphabetical:
            sorted = playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .creator:
            sorted = playlists.sorted {
                let a = $0.ownerName ?? "", b = $1.ownerName ?? ""
                if a == b { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        return sorted.filter(\.isPinned) + sorted.filter { !$0.isPinned }
    }
}

/// One row of the unfiltered library.
public enum LibraryItem: Identifiable {
    case playlist(Playlist), album(Album), smart(SmartPlaylist)
    public var id: UUID {
        switch self { case .playlist(let p): p.id; case .album(let a): a.id; case .smart(let s): s.id }
    }
}

extension LibrarySortOrder {
    /// Recents = last played or edited, whichever is later.
    @MainActor static func recency(_ p: Playlist) -> Date {
        max(p.dateModified, PlaylistMetadataService.shared.playlistLastPlayedDates[p.id] ?? .distantPast)
    }

    /// Playlists, albums and smart playlists interleaved by this order. Pins
    /// stay on top; Custom Order has nowhere to put albums, so they follow
    /// by recency.
    @MainActor public func mixed(_ playlists: [Playlist], albums: [Album], smart: [SmartPlaylist]) -> [LibraryItem] {
        let meta = PlaylistMetadataService.shared, saved = SavedAlbumsService.shared
        let ordered = sorted(playlists)
        let pinned = ordered.filter(\.isPinned).map(LibraryItem.playlist)
        var rest = ordered.filter { !$0.isPinned }.map(LibraryItem.playlist)
        func date(_ i: LibraryItem, added: Bool) -> Date {
            switch i {
            case .playlist(let p): return added ? p.dateCreated : Self.recency(p)
            case .album(let a):
                let at = saved.savedAt(a) ?? .distantPast
                return added ? at : max(at, meta.albumLastPlayedDates[SavedAlbumsService.key(title: a.title, artistName: a.artistName)] ?? .distantPast)
            case .smart(let s): return added ? s.dateCreated : max(s.dateCreated, meta.playlistLastPlayedDates[s.id] ?? .distantPast)
            }
        }
        func name(_ i: LibraryItem) -> String {
            switch i { case .playlist(let p): p.name; case .album(let a): a.title; case .smart(let s): s.name }
        }
        func creator(_ i: LibraryItem) -> String {
            switch i { case .playlist(let p): p.ownerName ?? ""; case .album(let a): a.artistName; case .smart: "Mixtape" }
        }
        let others = albums.map(LibraryItem.album) + smart.map(LibraryItem.smart)
        switch self {
        case .manual:
            rest += others.sorted { date($0, added: false) > date($1, added: false) }
        case .recents, .recentlyAdded:
            let added = self == .recentlyAdded
            rest = (rest + others).sorted { date($0, added: added) > date($1, added: added) }
        case .alphabetical:
            rest = (rest + others).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        case .creator:
            rest = (rest + others).sorted {
                let a = creator($0), b = creator($1)
                if a == b { return name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        return pinned + rest
    }
}

public enum LibraryLayout: String {
    case list, grid
}

@MainActor
public final class LibraryViewModel: ObservableObject {

    // MARK: - Published State

    /// Nil is Spotify's unfiltered library: playlists, saved albums and smart
    /// playlists in one list. A chip narrows it; tapping it again clears it.
    @Published public var selectedSection: LibrarySection? = nil

    /// The Downloaded filter. Not a section: it cuts across all of them, so
    /// Playlists/Albums/Artists stay browsable and each one lists only what is
    /// wholly on this device. Mirrored onto the service, which is where the
    /// song lists read it from.
    @Published public var downloadedOnly: Bool = false {
        didSet {
            guard downloadedOnly != oldValue else { return }
            libraryService.downloadedOnly = downloadedOnly
        }
    }

    @Published public private(set) var tracks:    [Track]    = []
    @Published public private(set) var albums:    [Album]    = []
    @Published public private(set) var artists:   [Artist]  = []
    @Published public private(set) var playlists: [Playlist] = []

    @Published public var showImportSheet = false

    // MARK: - Search, sort, layout

    /// Whether the search field is showing. Separate from `searchText` being
    /// empty, so the field can be open and blank.
    @Published public var isSearching = false
    @Published public var searchText  = ""

    /// Remembered across launches: both of these are a statement about how this
    /// person likes to read their library, not about this visit to the tab.
    /// A mirror of `PlaylistSortSyncService.shared.sortOrder`, which owns the
    /// value, persists it and carries it to the Mac — this stays a `@Published`
    /// here only so the screens that bind to it keep working unchanged.
    @Published public var sortOrder: LibrarySortOrder = .manual {
        didSet {
            guard sortOrder != oldValue else { return }
            PlaylistSortSyncService.shared.sortOrder = sortOrder
        }
    }
    @Published public var layout: LibraryLayout = .list {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    private static let layoutKey = "library.layout"

    /// The playlists to draw: filtered by the query, then ordered — with pins
    /// held at the top of whatever order is chosen.
    ///
    /// A pin is not a sort key, it is an override of one. Letting the sort move
    /// a pinned playlist would make the pin mean nothing in three of the four
    /// orders, which is not what the user asked for when they pinned it.
    public var visiblePlaylists: [Playlist] {
        let matched = playlists.filter { matches($0.name) || matches($0.ownerName ?? "") }
        return sortOrder.sorted(downloaded(matched, ids: \.trackIDs))
    }

    /// The filter, applied to anything that is a bag of song ids. Whole thing
    /// or nothing: a half-downloaded playlist opened offline is a list of grey
    /// rows, which is not what "Downloaded" offered.
    private func downloaded<T>(_ items: [T], ids: (T) -> [UUID]) -> [T] {
        guard downloadedOnly else { return items }
        let have = libraryService.offlinePlayableIDs()
        return items.filter { item in
            let list = ids(item)
            return !list.isEmpty && list.allSatisfy { have.contains($0) }
        }
    }

    /// Whether the playlist list can be dragged into a new order right now.
    ///
    /// Only in `.manual`, and only unfiltered: a drop inside a filtered list is
    /// a statement about rows that aren't on screen, and there's no honest way
    /// to guess where the hidden ones were meant to land.
    public var canReorderPlaylists: Bool {
        sortOrder == .manual
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only albums the user added — a song in the library no longer lists
    /// its album. See `SavedAlbumsService`.
    public var visibleAlbums: [Album] {
        let saved = SavedAlbumsService.shared
        let list = downloaded(albums.filter { saved.isSaved($0) && (matches($0.title) || matches($0.artistName)) },
                              ids: \.trackIDs)
        if sortOrder == .alphabetical {
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return list.sorted { (saved.savedAt($0) ?? .distantPast) > (saved.savedAt($1) ?? .distantPast) }
    }

    public func visibleSmart(_ smart: [SmartPlaylist], ids: (SmartPlaylist) -> [UUID]) -> [SmartPlaylist] {
        downloaded(smart.filter { matches($0.name) }, ids: ids)
    }

    /// Empty query matches everything, so every caller can filter
    /// unconditionally instead of branching on whether search is open.
    private func matches(_ field: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return field.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Dependencies

    private let libraryService: LibraryService
    private var cancellables   = Set<AnyCancellable>()

    // MARK: - Init

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
        sortOrder = PlaylistSortSyncService.shared.sortOrder
        PlaylistSortSyncService.shared.$sortOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] order in self?.sortOrder = order }
            .store(in: &cancellables)
        if let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
           let saved = LibraryLayout(rawValue: raw) {
            layout = saved
        }
        bindLibraryService()
        SavedAlbumsService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        PlaylistMetadataService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Puts the library on screen.
    ///
    /// `loadForDisplay`, not `refresh`: this runs from the view's `.task`, so it
    /// fires every time the Library tab comes back, and a full re-read there
    /// cost a second of main-thread time to arrive at the values the bindings
    /// below were already publishing. It also publishes the playlists before the
    /// expensive pass, so the list this screen opens on is not held behind a
    /// read it doesn't depend on.
    public func load() async {
        await libraryService.loadForDisplay()
    }

    // MARK: - Private

    private func bindLibraryService() {
        // Republished on the offline flag too: the same array resolves to a
        // shorter list once songs that aren't on the device are hidden.
        libraryService.$tracks
            .combineLatest(libraryService.$downloadedOnly)
            .map { [weak libraryService] _, _ in libraryService?.displayTracks ?? [] }
            .receive(on: RunLoop.main)
            .assign(to: &$tracks)

        // The service switches the filter on when the network goes; this keeps
        // the chip in step with it.
        libraryService.$downloadedOnly
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.downloadedOnly = on }
            .store(in: &cancellables)

        libraryService.$albums
            .receive(on: RunLoop.main)
            .assign(to: &$albums)

        libraryService.$artists
            .receive(on: RunLoop.main)
            .assign(to: &$artists)

        libraryService.$playlists
            .receive(on: RunLoop.main)
            .assign(to: &$playlists)
    }
}
