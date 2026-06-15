// Artist.swift
// Mixtape — Core Domain Models
//
// Artist records are derived from track metadata — never fetched from the internet.
// The bio is auto-generated from aggregated metadata (genres, years, album count).

import Foundation

public struct Artist: Identifiable, Codable, Hashable, Sendable {

    public let id: UUID
    /// Canonical artist name as extracted from track metadata.
    public var name: String
    /// Short biography assembled locally from metadata (no network calls).
    public var bio: String?
    /// Best artwork found across all of this artist's tracks (highest resolution).
    public var artworkData: Data?
    public var artworkKey: String?
    /// Whether the user has followed this artist inside the app.
    public var isFollowed: Bool
    /// Ordered album IDs (newest first by year).
    public var albumIDs: [UUID]
    /// All track IDs for this artist.
    public var trackIDs: [UUID]
    public var dateCreated: Date

    // Sync
    public var sync: SyncMetadata
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        bio: String? = nil,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        isFollowed: Bool = false,
        albumIDs: [UUID] = [],
        trackIDs: [UUID] = [],
        dateCreated: Date = Date(),
        sync: SyncMetadata,
        isDeleted: Bool = false
    ) {
        self.id          = id
        self.name        = name
        self.bio         = bio
        self.artworkData = artworkData
        self.artworkKey  = artworkKey
        self.isFollowed  = isFollowed
        self.albumIDs    = albumIDs
        self.trackIDs    = trackIDs
        self.dateCreated = dateCreated
        self.sync        = sync
        self.isDeleted   = isDeleted
    }

    public var albumCount: Int  { albumIDs.count }
    public var trackCount: Int  { trackIDs.count }
}

// MARK: - Mock Data

#if DEBUG
extension Artist {
    static let previewArtists: [Artist] = [
        Artist(name: "Celeste Nova",  isFollowed: true,  albumIDs: [], trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Artist(name: "Iron Hollow",   isFollowed: false, albumIDs: [], trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Artist(name: "Vela Drift",    isFollowed: true,  albumIDs: [], trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
    ]
}
#endif
