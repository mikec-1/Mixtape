// Local-only playlist metadata (last played dates etc.) used for sorting.

import Foundation
import Combine
import SwiftUI

@MainActor
public final class PlaylistMetadataService: ObservableObject {
    
    public static let shared = PlaylistMetadataService()
    
    public var currentUserID: String? = nil {
        didSet {
            loadMetadata()
        }
    }
    
    private var pinnedKey: String {
        if let id = currentUserID {
            return "MixtapePinnedPlaylists_\(id)"
        }
        return "MixtapePinnedPlaylists"
    }
    
    private var sidebarKey: String {
        if let id = currentUserID {
            return "MixtapeSidebarPlaylists_\(id)"
        }
        return "MixtapeSidebarPlaylists"
    }
    
    private var lastPlayedKey: String {
        if let id = currentUserID {
            return "MixtapePlaylistLastPlayed_\(id)"
        }
        return "MixtapePlaylistLastPlayed"
    }
    
    @Published public private(set) var pinnedPlaylistIDs: Set<UUID> = []

    /// Whether library lists show the All Songs row. Off by default; search and
    /// ⌘K still find it. Per account, `user_metadata.show_all_songs`; the default
    /// is only a cache for launch. Lives here because the sidebar and library
    /// screens already observe this service.
    @Published public var showsAllSongs: Bool = UserDefaults.standard.bool(forKey: "mix.showAllSongs") {
        didSet {
            guard showsAllSongs != oldValue else { return }
            UserDefaults.standard.set(showsAllSongs, forKey: "mix.showAllSongs")
            guard !isApplyingRemote else { return }
            showsAllSongsWriter?(showsAllSongs)
        }
    }
    /// Writes the switch to the account. Installed by `AppDependencies`.
    public var showsAllSongsWriter: ((Bool) -> Void)?

    /// Where songs imported from files and links go. All Songs leaves them unliked,
    /// so picking it shows All Songs. Per account, `user_metadata.imports_to`.
    @Published public var importDestination: ImportDestination =
        ImportDestination(rawValue: UserDefaults.standard.string(forKey: "mix.importsTo") ?? "") ?? .liked {
        didSet {
            guard importDestination != oldValue else { return }
            UserDefaults.standard.set(importDestination.rawValue, forKey: "mix.importsTo")
            guard !isApplyingRemote else { return }
            importDestinationWriter?(importDestination.rawValue)
            if importDestination == .allSongs { showsAllSongs = true }
        }
    }
    /// Installed by `AppDependencies`.
    public var importDestinationWriter: ((String) -> Void)?
    private var isApplyingRemote = false

    /// An account that never set it is off, the same default as the web.
    public func adoptRemoteShowsAllSongs(_ remote: Bool?) {
        let remote = remote ?? false
        guard remote != showsAllSongs else { return }
        isApplyingRemote = true
        showsAllSongs = remote
        isApplyingRemote = false
    }

    /// An account that never picked keeps the default, Liked Songs.
    public func adoptRemoteImportDestination(_ raw: String?) {
        let remote = raw.flatMap(ImportDestination.init(rawValue:)) ?? .liked
        guard remote != importDestination else { return }
        isApplyingRemote = true
        importDestination = remote
        isApplyingRemote = false
    }

    /// Whether imports should be liked.
    public var likesImports: Bool { importDestination == .liked }
    /// Only non-empty until the one-shot handover; order now lives on `Playlist.sortIndex`.
    private var sidebarPlaylistIDs: [UUID] = []
    @Published public private(set) var playlistLastPlayedDates: [UUID: Date] = [:]
    
    private init() {
        loadMetadata()

        // Home's "recently played" reads these, so a data reset must clear them.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearLastPlayedDates() }
        }
    }

    /// Forgets last-played dates; doesn't touch the playlists.
    public func clearLastPlayedDates() {
        playlistLastPlayedDates = [:]
        saveLastPlayed()
    }
    
    // MARK: - State Management
    
    private func loadMetadata() {
        let defaults = UserDefaults.standard
        
        // Pins live on the playlist row now (so they sync), published via
        // `adoptPins`. The old key is read once by `consumeLegacyPins()`.
        
        // Load Sidebar
        if let storedSidebar = defaults.array(forKey: sidebarKey) as? [String] {
            sidebarPlaylistIDs = storedSidebar.compactMap { UUID(uuidString: $0) }
        } else {
            sidebarPlaylistIDs = []
        }
        
        // Load Last Played
        if let storedDates = defaults.dictionary(forKey: lastPlayedKey) as? [String: Double] {
            var dates: [UUID: Date] = [:]
            for (key, timestamp) in storedDates {
                if let uuid = UUID(uuidString: key) {
                    dates[uuid] = Date(timeIntervalSince1970: timestamp)
                }
            }
            playlistLastPlayedDates = dates
        }
    }
    
    
    private func saveLastPlayed() {
        var dict: [String: Double] = [:]
        for (id, date) in playlistLastPlayedDates {
            dict[id.uuidString] = date.timeIntervalSince1970
        }
        UserDefaults.standard.set(dict, forKey: lastPlayedKey)
    }
    
    // MARK: - Actions
    
    public func isPinned(playlistID: UUID) -> Bool {
        pinnedPlaylistIDs.contains(playlistID)
    }

    /// Writes a pin to the playlist row. Installed by `AppDependencies`, since
    /// this service has no repository.
    public var pinWriter: ((UUID, Bool) -> Void)?

    public func togglePin(playlistID: UUID) {
        let pinning = !pinnedPlaylistIDs.contains(playlistID)
        if pinning {
            pinnedPlaylistIDs.insert(playlistID)
        } else {
            pinnedPlaylistIDs.remove(playlistID)
        }
        // Updated locally too, so the UI changes on tap.
        pinWriter?(playlistID, pinning)

        // Pinned-first ordering comes from `LibraryService.playlists`, so it has to
        // be told to re-sort.
        objectWillChange.send()
        NotificationCenter.default.post(name: .mixPlaylistPinsChanged, object: nil)
    }

    /// Republishes pins from the playlist rows. Equality guard because this runs
    /// inside `refreshPlaylists()`.
    public func adoptPins(_ ids: Set<UUID>) {
        guard ids != pinnedPlaylistIDs else { return }
        pinnedPlaylistIDs = ids
    }

    /// Pre-migration pins from UserDefaults, or nil once handed over. One-shot,
    /// so upgrading doesn't look like unpinning everything.
    public func consumeLegacyPins() -> Set<UUID>? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: pinnedKey) as? [String] else { return nil }
        defaults.removeObject(forKey: pinnedKey)
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }
    
    /// Pre-migration sidebar order, or nil once handed over. One-shot, like
    /// `consumeLegacyPins`.
    public func consumeLegacySidebarOrder() -> [UUID]? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: sidebarKey) as? [String] else { return nil }
        defaults.removeObject(forKey: sidebarKey)
        sidebarPlaylistIDs = []
        return stored.compactMap { UUID(uuidString: $0) }
    }

    /// Albums are keyed by `SavedAlbumsService.key` (no stable row id).
    public private(set) var albumLastPlayedDates: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "MixtapeAlbumLastPlayed") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }()

    public func markAlbumPlayed(title: String, artistName: String) {
        albumLastPlayedDates[SavedAlbumsService.key(title: title, artistName: artistName)] = Date()
        UserDefaults.standard.set(albumLastPlayedDates.mapValues(\.timeIntervalSince1970), forKey: "MixtapeAlbumLastPlayed")
        objectWillChange.send()
    }

    public func markPlayed(playlistID: UUID) {
        playlistLastPlayedDates[playlistID] = Date()
        saveLastPlayed()
        
        // Notify the app
        objectWillChange.send()
    }
}

public extension Notification.Name {
    /// A playlist was pinned or unpinned. `LibraryService` re-sorts on this.
    static let mixPlaylistPinsChanged = Notification.Name("mix.playlistPinsChanged")
}

/// Where imported songs show up.
public enum ImportDestination: String, CaseIterable, Identifiable, Sendable {
    case liked
    case allSongs = "all_songs"
    public var id: String { rawValue }
    public var title: String { self == .liked ? "Liked Songs" : "All Songs" }
}
