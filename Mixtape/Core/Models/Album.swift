// Album.swift
// Mixtape — Core Domain Models

import Foundation

public struct Album: Identifiable, Codable, Hashable, Sendable {

    public let id: UUID
    public var title: String
    public var artistName: String
    public var year: Int?
    public var genre: String?
    public var artworkData: Data?
    public var artworkKey: String?
    /// Ordered list of track IDs. Order = disc + track number sort at import time.
    public var trackIDs: [UUID]
    public var dateCreated: Date

    // Sync
    public var sync: SyncMetadata
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        artistName: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        trackIDs: [UUID] = [],
        dateCreated: Date = Date(),
        sync: SyncMetadata,
        isDeleted: Bool = false
    ) {
        self.id          = id
        self.title       = title
        self.artistName  = artistName
        self.year        = year
        self.genre       = genre
        self.artworkData = artworkData
        self.artworkKey  = artworkKey
        self.trackIDs    = trackIDs
        self.dateCreated = dateCreated
        self.sync        = sync
        self.isDeleted   = isDeleted
    }

    public var trackCount: Int { trackIDs.count }
}

// MARK: - Mock Data

#if DEBUG
extension Album {
    static let previewAlbums: [Album] = [
        Album(title: "Horizons",     artistName: "Celeste Nova",  year: 2023, trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Album(title: "Structures",   artistName: "Iron Hollow",   year: 2022, trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Album(title: "Tender Noise", artistName: "Vela Drift",    year: 2024, trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
    ]
}
#endif
