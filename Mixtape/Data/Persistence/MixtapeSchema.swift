// MixtapeSchema.swift
// Mixtape — Data Layer
//
// SwiftData @Model definitions. These are the persistence representations.
// Domain structs (Track, Album, etc.) are mapped to/from these by their repositories.
//
// Minimum deployment: iOS 17 / macOS 14

import Foundation
import SwiftData

// MARK: - TrackEntity

@Model
public final class TrackEntity {

    // Core
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    @Attribute(.externalStorage) public var artworkData: Data?
    public var artworkKey: String?
    public var composer: String?
    public var dateImported: Date
    public var isSoftDeleted: Bool

    // File provenance
    public var fileHash: String
    public var fileSize: Int64
    public var localPath: String
    public var remoteKey: String?
    public var fileUploaded: Bool
    public var fileDownloadedAt: Date?

    // Sync metadata
    public var syncStatus: String      // SyncStatus.rawValue
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

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
        dateImported: Date = Date(),
        isSoftDeleted: Bool = false,
        fileHash: String,
        fileSize: Int64,
        localPath: String,
        remoteKey: String? = nil,
        fileUploaded: Bool = false,
        fileDownloadedAt: Date? = nil,
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.title                = title
        self.artistName           = artistName
        self.albumTitle           = albumTitle
        self.duration             = duration
        self.trackNumber          = trackNumber
        self.discNumber           = discNumber
        self.year                 = year
        self.genre                = genre
        self.artworkData          = artworkData
        self.artworkKey           = artworkKey
        self.composer             = composer
        self.dateImported         = dateImported
        self.isSoftDeleted        = isSoftDeleted
        self.fileHash             = fileHash
        self.fileSize             = fileSize
        self.localPath            = localPath
        self.remoteKey            = remoteKey
        self.fileUploaded         = fileUploaded
        self.fileDownloadedAt     = fileDownloadedAt
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - AlbumEntity

@Model
public final class AlbumEntity {

    @Attribute(.unique) public var id: UUID
    public var title: String
    public var artistName: String
    public var year: Int?
    public var genre: String?
    @Attribute(.externalStorage) public var artworkData: Data?
    public var artworkKey: String?
    public var trackIDsData: Data    // JSON-encoded [UUID]
    public var dateCreated: Date
    public var isSoftDeleted: Bool

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        artistName: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        trackIDsData: Data = Data(),
        dateCreated: Date = Date(),
        isSoftDeleted: Bool = false,
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.title                = title
        self.artistName           = artistName
        self.year                 = year
        self.genre                = genre
        self.artworkData          = artworkData
        self.artworkKey           = artworkKey
        self.trackIDsData         = trackIDsData
        self.dateCreated          = dateCreated
        self.isSoftDeleted        = isSoftDeleted
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - ArtistEntity

@Model
public final class ArtistEntity {

    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var name: String
    public var bio: String?
    @Attribute(.externalStorage) public var artworkData: Data?
    public var artworkKey: String?
    public var isFollowed: Bool
    public var albumIDsData: Data    // JSON-encoded [UUID]
    public var trackIDsData: Data    // JSON-encoded [UUID]
    public var dateCreated: Date
    public var isSoftDeleted: Bool

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        bio: String? = nil,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        isFollowed: Bool = false,
        albumIDsData: Data = Data(),
        trackIDsData: Data = Data(),
        dateCreated: Date = Date(),
        isSoftDeleted: Bool = false,
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.name                 = name
        self.bio                  = bio
        self.artworkData          = artworkData
        self.artworkKey           = artworkKey
        self.isFollowed           = isFollowed
        self.albumIDsData         = albumIDsData
        self.trackIDsData         = trackIDsData
        self.dateCreated          = dateCreated
        self.isSoftDeleted        = isSoftDeleted
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - PlaylistEntity

@Model
public final class PlaylistEntity {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var playlistDescription: String?
    public var trackIDsData: Data    // JSON-encoded [UUID], order preserved
    @Attribute(.externalStorage) public var artworkData: Data?
    public var dateCreated: Date
    public var dateModified: Date
    public var isSoftDeleted: Bool

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        playlistDescription: String? = nil,
        trackIDsData: Data = Data(),
        artworkData: Data? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        isSoftDeleted: Bool = false,
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.name                 = name
        self.playlistDescription  = playlistDescription
        self.trackIDsData         = trackIDsData
        self.artworkData          = artworkData
        self.dateCreated          = dateCreated
        self.dateModified         = dateModified
        self.isSoftDeleted        = isSoftDeleted
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - PlayHistoryEntity

@Model
public final class PlayHistoryEntity {

    @Attribute(.unique) public var id: UUID
    public var trackID: UUID
    public var playedAt: Date
    public var secondsPlayed: TimeInterval

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        playedAt: Date = Date(),
        secondsPlayed: TimeInterval = 0,
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.trackID              = trackID
        self.playedAt             = playedAt
        self.secondsPlayed        = secondsPlayed
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - SmartPlaylistEntity
//
// Local-only auto-updating playlist defined by an encoded rule.
// No Supabase sync metadata — its contents are resolved live, never stored.

@Model
public final class SmartPlaylistEntity {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var iconName: String
    /// JSON-encoded SmartPlaylistRule (see SmartPlaylist.encodedRule()).
    public var ruleData: Data
    public var dateCreated: Date

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "wand.and.stars",
        ruleData: Data = Data(),
        dateCreated: Date = Date()
    ) {
        self.id          = id
        self.name        = name
        self.iconName    = iconName
        self.ruleData    = ruleData
        self.dateCreated = dateCreated
    }
}

// MARK: - FavoriteEntity

@Model
public final class FavoriteEntity {

    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var trackID: UUID
    public var addedAt: Date

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        addedAt: Date = Date(),
        syncStatus: String = SyncStatus.localOnly.rawValue,
        syncServerID: String? = nil,
        syncDeviceID: String,
        syncLocalModifiedAt: Date = Date(),
        syncServerModifiedAt: Date? = nil,
        syncLastSyncedAt: Date? = nil
    ) {
        self.id                   = id
        self.trackID              = trackID
        self.addedAt              = addedAt
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}
