// Playlist.swift
// Mixtape — Core Domain Models

import Foundation
import SwiftUI

public struct Playlist: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Well-known IDs

    /// Stable UUID for the Favourites system playlist. Never changes across launches.
    public static let favouritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Stable UUID for the All Songs system playlist. Contains every imported track automatically.
    public static let allSongsID   = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Properties

    public let id: UUID
    public var name: String
    public var description: String?
    /// Ordered track IDs. Reorder = mutate this array; mutations bump sync.localModifiedAt.
    public var trackIDs: [UUID]
    /// Artwork: first track's art by default; can be overridden by user (future feature).
    public var artworkData: Data?
    public var dateCreated: Date
    public var dateModified: Date

    // Sync
    public var sync: SyncMetadata
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        trackIDs: [UUID] = [],
        artworkData: Data? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        sync: SyncMetadata,
        isDeleted: Bool = false
    ) {
        self.id           = id
        self.name         = name
        self.description  = description
        self.trackIDs     = trackIDs
        self.artworkData  = artworkData
        self.dateCreated  = dateCreated
        self.dateModified = dateModified
        self.sync         = sync
        self.isDeleted    = isDeleted
    }

    public var trackCount: Int { trackIDs.count }

    /// System playlists are built-in and cannot be renamed or deleted.
    public var isSystem:     Bool { id == Playlist.favouritesID || id == Playlist.allSongsID }
    public var isFavourites: Bool { id == Playlist.favouritesID }
    public var isAllSongs:   Bool { id == Playlist.allSongsID }

    // MARK: Mutations (all bump dateModified + sync status)

    public mutating func addTrack(_ id: UUID) {
        guard !trackIDs.contains(id) else { return }
        trackIDs.append(id)
        touch()
    }

    public mutating func removeTrack(_ id: UUID) {
        trackIDs.removeAll { $0 == id }
        touch()
    }

    public mutating func reorder(fromOffsets: IndexSet, toOffset: Int) {
        trackIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        touch()
    }

    // internal so LibraryService and other module code can call p.touch() directly
    mutating func touch() {
        dateModified = Date()
        sync.markModified()
    }
}

// MARK: - Mock Data

#if DEBUG
extension Playlist {
    static let previewPlaylists: [Playlist] = [
        Playlist(name: "Late Night Drive",  description: "Slow, atmospheric tracks for the dark hours.", trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Playlist(name: "Morning Focus",     description: nil, trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Playlist(name: "Weekend Mix",       description: "A bit of everything.", trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
    ]
}
#endif
