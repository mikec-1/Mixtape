// PlaylistMetadataService.swift
// Mixtape — Core/Services
//
// Manages local-only metadata for playlists, such as pinning and last played times.
// This allows the app to dynamically sort playlists on this device without modifying
// the Supabase schema.

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

    /// Whether the library's lists offer the All Songs row.
    ///
    /// Off by default: Liked Songs is the list of what you own, and a second
    /// row holding everything you have ever imported reads as a duplicate of
    /// it until you have imported something you didn't like. The people who
    /// want the old shape turn it back on in Settings; search and ⌘K find All
    /// Songs either way. Applied in `LibrarySortOrder.sorted`, the one place
    /// every browse list orders through.
    ///
    /// Here rather than in the pane that sets it because this is what the
    /// sidebar and both library screens already observe — an `@AppStorage`
    /// would persist fine and redraw nothing.
    @Published public var showsAllSongs: Bool = UserDefaults.standard.bool(forKey: "mix.showAllSongs") {
        didSet { UserDefaults.standard.set(showsAllSongs, forKey: "mix.showAllSongs") }
    }
    /// Only ever non-empty between launch and the one-shot handover below.
    /// The order itself lives on the playlist row now — see `Playlist.sortIndex`.
    private var sidebarPlaylistIDs: [UUID] = []
    @Published public private(set) var playlistLastPlayedDates: [UUID: Date] = [:]
    
    private init() {
        loadMetadata()

        // "Recently played playlists" on Home is drawn from these dates, and
        // they live in UserDefaults — so a wipe that emptied every playlist left
        // the shelf still ranking them. See `UserDataReset`.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearLastPlayedDates() }
        }
    }

    /// Forget when each playlist was last played. The playlists themselves are
    /// not this service's to delete — only the ordering built on top of them.
    public func clearLastPlayedDates() {
        playlistLastPlayedDates = [:]
        saveLastPlayed()
    }
    
    // MARK: - State Management
    
    private func loadMetadata() {
        let defaults = UserDefaults.standard
        
        // Pins are no longer loaded here. They live on the playlist row so they
        // sync, and `LibraryService.refreshPlaylists()` publishes them through
        // `adoptPins`. The stored key is read exactly once more, by
        // `consumeLegacyPins()`, to carry this device's existing pins over.
        
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

    /// Writes a pin to the playlist row. Installed by `AppDependencies`.
    ///
    /// The pin is stored on the playlist now, so it syncs — but every screen
    /// asks this service, and this service has no repository. Rather than thread
    /// `LibraryService` through six call sites, the write goes back out through
    /// a hook, the same shape as `LibraryService.onTrackWillDelete`.
    public var pinWriter: ((UUID, Bool) -> Void)?

    public func togglePin(playlistID: UUID) {
        let pinning = !pinnedPlaylistIDs.contains(playlistID)
        if pinning {
            pinnedPlaylistIDs.insert(playlistID)
        } else {
            pinnedPlaylistIDs.remove(playlistID)
        }
        // Updated here as well as written through, so the badge and the row
        // order change on the tap rather than on the refresh that follows it.
        pinWriter?(playlistID, pinning)

        // `objectWillChange` only redraws the views reading this service — it
        // does not re-sort `LibraryService.playlists`, which is where pinned-
        // first ordering actually comes from. Without the notification a pin
        // updated its own badge and left the row sitting where it was until
        // something unrelated refreshed the library.
        objectWillChange.send()
        NotificationCenter.default.post(name: .mixPlaylistPinsChanged, object: nil)
    }

    /// Republishes the pin set from the playlist rows, which own it.
    ///
    /// Called by `LibraryService.refreshPlaylists()`. Guarded on equality
    /// because it runs inside the refresh that publishing would re-trigger.
    public func adoptPins(_ ids: Set<UUID>) {
        guard ids != pinnedPlaylistIDs else { return }
        pinnedPlaylistIDs = ids
    }

    /// The pins this device had in `UserDefaults` before pins moved onto the
    /// playlist, or nil once they have been handed over.
    ///
    /// One-shot: `LibraryService` stamps them onto the rows on the first launch
    /// after the upgrade, then clears the key. Without it, upgrading looks
    /// exactly like someone unpinning everything.
    public func consumeLegacyPins() -> Set<UUID>? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: pinnedKey) as? [String] else { return nil }
        defaults.removeObject(forKey: pinnedKey)
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }
    
    /// The drag order this device had in `UserDefaults` before the order moved
    /// onto the playlist, or nil once it has been handed over.
    ///
    /// One-shot, exactly like `consumeLegacyPins`: `LibraryService` stamps it
    /// onto the rows on the first launch after the upgrade, then clears the key.
    /// Without it, upgrading looks like someone's arrangement being thrown away.
    ///
    /// The rest of the old sidebar API is gone with it. It was a second, local
    /// answer to "what order are the playlists in", and a second answer that
    /// only one platform could see is what this whole change is about.
    public func consumeLegacySidebarOrder() -> [UUID]? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: sidebarKey) as? [String] else { return nil }
        defaults.removeObject(forKey: sidebarKey)
        sidebarPlaylistIDs = []
        return stored.compactMap { UUID(uuidString: $0) }
    }

    /// Albums have no stable row id across devices, so they're keyed by
    /// `SavedAlbumsService.key`.
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
