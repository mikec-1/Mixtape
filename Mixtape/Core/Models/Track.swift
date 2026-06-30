// Track.swift
// Mixtape — Core Domain Models

import Foundation

public struct Track: Identifiable, Codable, Hashable, Sendable {

    // MARK: Identity
    public let id: UUID

    // MARK: Metadata (from AVAsset / ID3 / MP4 tags)
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval   // seconds
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var artworkData: Data?       // thumbnail JPEG/PNG, cached locally
    public var artworkKey: String?
    public var composer: String?
    public var lyrics: String?

    // MARK: Import
    public var dateImported: Date

    // MARK: Sync + File
    public var sync: SyncMetadata
    public var file: FileProvenance

    // MARK: Soft-delete
    /// True once the user deletes the track; swept up by sync service.
    public var isDeleted: Bool

    // MARK: Init
    public init(
        id: UUID = UUID(),
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        composer: String? = nil,
        lyrics: String? = nil,
        dateImported: Date = Date(),
        sync: SyncMetadata,
        file: FileProvenance,
        isDeleted: Bool = false
    ) {
        self.id           = id
        self.title        = title
        self.artistName   = artistName
        self.albumTitle   = albumTitle
        self.duration     = duration
        self.trackNumber  = trackNumber
        self.discNumber   = discNumber
        self.year         = year
        self.genre        = genre
        self.artworkData  = artworkData
        self.artworkKey   = artworkKey
        self.composer     = composer
        self.lyrics       = lyrics
        self.dateImported = dateImported
        self.sync         = sync
        self.file         = file
        self.isDeleted    = isDeleted
    }

    // MARK: Computed helpers

    /// True when this track is a standalone Discover/online track rather than a
    /// library row. Online tracks are minted by `OnlineTrack.asTrack(...)` with
    /// `fileSize == 0` and no `remoteKey`; once played they also carry a cache
    /// path under `OnlineCache`. Library/imported tracks always have a real
    /// `fileSize` (> 0), so this discriminates reliably even after the online
    /// track is given its cache `localPath` for playback.
    public var isOnline: Bool {
        file.localPath.contains("OnlineCache")
            || (file.remoteKey == nil && file.fileSize == 0)
    }

    public var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Mock Data

#if DEBUG
extension Track {
    static func mock(
        title: String = "Untitled Track",
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        duration: TimeInterval = 210,
        deviceID: String = "preview-device"
    ) -> Track {
        Track(
            title: title,
            artistName: artist,
            albumTitle: album,
            duration: duration,
            sync: SyncMetadata(deviceID: deviceID),
            file: FileProvenance(fileHash: UUID().uuidString, fileSize: 8_000_000, localPath: "mock/\(title).mp3")
        )
    }

    static let previewTracks: [Track] = [
        .mock(title: "Morning Light",      artist: "Celeste Nova",  album: "Horizons",     duration: 198),
        .mock(title: "Deep Current",       artist: "Celeste Nova",  album: "Horizons",     duration: 241),
        .mock(title: "After the Rain",     artist: "Celeste Nova",  album: "Horizons",     duration: 175),
        .mock(title: "Glass Bridges",      artist: "Iron Hollow",   album: "Structures",   duration: 263),
        .mock(title: "Static Dreams",      artist: "Iron Hollow",   album: "Structures",   duration: 312),
        .mock(title: "Quiet Hours",        artist: "Vela Drift",    album: "Tender Noise", duration: 187),
        .mock(title: "Parallel Lines",     artist: "Vela Drift",    album: "Tender Noise", duration: 223),
    ]
}
#endif
