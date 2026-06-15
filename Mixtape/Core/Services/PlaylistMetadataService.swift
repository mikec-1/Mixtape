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
    @Published public private(set) var sidebarPlaylistIDs: [UUID] = []
    @Published public private(set) var playlistLastPlayedDates: [UUID: Date] = [:]
    
    private init() {
        loadMetadata()
    }
    
    // MARK: - State Management
    
    private func loadMetadata() {
        let defaults = UserDefaults.standard
        
        // Load Pinned
        if let storedPins = defaults.array(forKey: pinnedKey) as? [String] {
            pinnedPlaylistIDs = Set(storedPins.compactMap { UUID(uuidString: $0) })
        } else {
            // Default setup: pin system playlists on first launch
            pinnedPlaylistIDs = [Playlist.allSongsID, Playlist.favouritesID]
            savePinned()
        }
        
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
    
    private func savePinned() {
        let strings = pinnedPlaylistIDs.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: pinnedKey)
    }
    
    private func saveSidebar() {
        let strings = sidebarPlaylistIDs.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: sidebarKey)
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
    
    public func togglePin(playlistID: UUID) {
        if pinnedPlaylistIDs.contains(playlistID) {
            pinnedPlaylistIDs.remove(playlistID)
        } else {
            pinnedPlaylistIDs.insert(playlistID)
        }
        savePinned()
        
        // Notify the app that metadata changed (LibraryService will listen to this)
        objectWillChange.send()
    }
    
    public func isInSidebar(playlistID: UUID) -> Bool {
        sidebarPlaylistIDs.contains(playlistID)
    }
    
    public func toggleSidebar(playlistID: UUID) {
        if let index = sidebarPlaylistIDs.firstIndex(of: playlistID) {
            sidebarPlaylistIDs.remove(at: index)
        } else {
            sidebarPlaylistIDs.append(playlistID)
        }
        saveSidebar()
        
        // Notify the app
        objectWillChange.send()
    }
    
    public func moveSidebarPlaylist(from source: IndexSet, to destination: Int) {
        sidebarPlaylistIDs.move(fromOffsets: source, toOffset: destination)
        saveSidebar()
        
        // Notify the app
        objectWillChange.send()
    }
    
    public func markPlayed(playlistID: UUID) {
        playlistLastPlayedDates[playlistID] = Date()
        saveLastPlayed()
        
        // Notify the app
        objectWillChange.send()
    }
}
