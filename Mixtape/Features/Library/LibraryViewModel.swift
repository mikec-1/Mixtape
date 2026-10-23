import Foundation
import SwiftUI
import Observation

public enum LibrarySection: String, CaseIterable, Identifiable {
    case playlists  = "Playlists"
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

/// Library sort orders. Spotify's set, minus ones needing data we don't keep.
public enum LibrarySortOrder: String, CaseIterable, Identifiable {
    /// The user's drag order, synced via `Playlist.sortIndex`. The default; an
    /// untouched library falls back to recents.
    case manual         = "Custom Order"
    /// Most recently touched first.
    case recents        = "Recents"
    case recentlyAdded  = "Recently Added"
    case alphabetical   = "Alphabetical"
    /// Groups the app's mixes and other people's playlists away from your own.
    case creator        = "Creator"

    public var id: String { rawValue }

    /// The single implementation of each order, so iOS Library, the Mac sidebar and
    /// the Mac Playlists page agree. Pins always go first after sorting.
    @MainActor public func sorted(_ playlists: [Playlist]) -> [Playlist] {
        // Every browse list goes through here, so the All Songs setting is applied here.
        // See `PlaylistMetadataService.showsAllSongs`.
        let playlists = PlaylistMetadataService.shared.showsAllSongs
            ? playlists : playlists.filter { !$0.isAllSongs }
        let sorted: [Playlist]
        switch self {
        case .manual:
            // Already in the shared order. See `LibraryService.refreshPlaylistsBody()`.
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

    /// Playlists, albums and smart playlists in one list by this order. Pins stay on
    /// top; in Custom Order albums follow by recency.
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

@Observable
@MainActor
public final class LibraryViewModel {

    // MARK: - Published State

    /// Nil is the unfiltered library. A chip narrows it; tapping again clears it.
    public var selectedSection: LibrarySection? = nil

    /// The Downloaded filter. Applies across sections, listing only what's fully on
    /// this device. Lives on the service, which also turns it on offline.
    public var downloadedOnly: Bool {
        get { libraryService.downloadedOnly }
        set { if newValue != libraryService.downloadedOnly { libraryService.downloadedOnly = newValue } }
    }

    // Read straight from the service, which is observable.
    public var tracks:    [Track]    { libraryService.displayTracks }
    public var albums:    [Album]    { libraryService.albums }
    public var artists:   [Artist]   { libraryService.artists }
    public var playlists: [Playlist] { libraryService.playlists }

    public var showImportSheet = false

    // MARK: - Search, sort, layout

    /// Whether search is open, separate from `searchText` so it can be open and blank.
    public var isSearching = false
    public var searchText  = ""

    /// `PlaylistSortSyncService.shared.sortOrder`, which owns and syncs it.
    public var sortOrder: LibrarySortOrder {
        get { PlaylistSortSyncService.shared.sortOrder }
        set { PlaylistSortSyncService.shared.sortOrder = newValue }
    }
    // Read in the initializer: LibraryView rebuilds this on every parent body, so init must not write.
    public var layout: LibraryLayout = UserDefaults.standard.string(forKey: LibraryViewModel.layoutKey)
        .flatMap(LibraryLayout.init(rawValue:)) ?? .list {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    private static let layoutKey = "library.layout"

    /// Playlists to draw: filtered by the query, then sorted, with pins on top.
    public var visiblePlaylists: [Playlist] {
        let matched = playlists.filter { matches($0.name) || matches($0.ownerName ?? "") }
        return sortOrder.sorted(downloaded(matched, ids: \.trackIDs))
    }

    /// Downloaded filter for anything holding song ids. All or nothing: a
    /// half-downloaded playlist offline is mostly grey rows.
    private func downloaded<T>(_ items: [T], ids: (T) -> [UUID]) -> [T] {
        guard downloadedOnly else { return items }
        let have = libraryService.offlinePlayableIDs()
        return items.filter { item in
            let list = ids(item)
            return !list.isEmpty && list.allSatisfy { have.contains($0) }
        }
    }

    /// Drag-reorder only in `.manual` and unfiltered, since hidden rows would have no position.
    public var canReorderPlaylists: Bool {
        sortOrder == .manual
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only albums the user saved. See `SavedAlbumsService`.
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

    /// Empty query matches everything, so callers can filter unconditionally.
    private func matches(_ field: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return field.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Dependencies

    private let libraryService: LibraryService

    // MARK: - Init

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    // MARK: - Actions

    /// Shows the library. Uses `loadForDisplay`, not `refresh`, since this runs every
    /// time the tab appears. Playlists publish before the expensive pass.
    public func load() async {
        await libraryService.loadForDisplay()
    }
}
