// SyncRows.swift
// Mixtape — Data/Sync
//
// Codable row types that map domain entities to/from Supabase PostgREST tables.
// Each row type has:
//   - An init from a SwiftData entity + userID (for push)
//   - An apply(to:) method that updates an existing entity (for pull/update)
// TrackEntity/AlbumEntity/ArtistEntity also gain a convenience init(from row:)
// for creating new local entities from server records on another device.
//
// Artwork is intentionally excluded — it's large and syncs via file storage.

import Foundation
import SwiftData

// MARK: - TrackRow

struct TrackRow: Codable {
    var id:           UUID
    var userID:       UUID
    var title:        String
    var artistName:   String
    var albumTitle:   String
    var duration:     Double
    var trackNumber:  Int?
    var discNumber:   Int?
    var year:         Int?
    var genre:        String?
    var composer:     String?
    var dateImported: Date
    var fileHash:     String
    var fileSize:     Int64
    var remoteKey:    String?
    var fileUploaded: Bool
    var artworkKey:   String?
    var syncDeviceID: String
    var updatedAt:    Date
    var isDeleted:    Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID        = "user_id"
        case title
        case artistName    = "artist_name"
        case albumTitle    = "album_title"
        case duration
        case trackNumber   = "track_number"
        case discNumber    = "disc_number"
        case year
        case genre
        case composer
        case dateImported  = "date_imported"
        case fileHash      = "file_hash"
        case fileSize      = "file_size"
        case remoteKey     = "remote_key"
        case fileUploaded  = "file_uploaded"
        case artworkKey    = "artwork_key"
        case syncDeviceID  = "sync_device_id"
        case updatedAt     = "updated_at"
        case isDeleted     = "is_deleted"
    }

    init(entity: TrackEntity, userID: UUID) {
        self.id           = entity.id
        self.userID       = userID
        self.title        = entity.title
        self.artistName   = entity.artistName
        self.albumTitle   = entity.albumTitle
        self.duration     = entity.duration
        self.trackNumber  = entity.trackNumber
        self.discNumber   = entity.discNumber
        self.year         = entity.year
        self.genre        = entity.genre
        self.composer     = entity.composer
        self.dateImported = entity.dateImported
        self.fileHash     = entity.fileHash
        self.fileSize     = entity.fileSize
        self.remoteKey    = entity.remoteKey
        self.fileUploaded = entity.fileUploaded
        self.artworkKey   = entity.artworkKey
        self.syncDeviceID = entity.syncDeviceID
        self.updatedAt    = entity.syncLocalModifiedAt
        self.isDeleted    = entity.isSoftDeleted
    }

    func apply(to entity: TrackEntity) {
        entity.title        = title
        entity.artistName   = artistName
        entity.albumTitle   = albumTitle
        entity.duration     = duration
        entity.trackNumber  = trackNumber
        entity.discNumber   = discNumber
        entity.year         = year
        entity.genre        = genre
        entity.composer     = composer
        entity.fileHash     = fileHash
        entity.fileSize     = fileSize
        entity.remoteKey    = remoteKey
        entity.fileUploaded = fileUploaded
        entity.artworkKey   = artworkKey
        entity.isSoftDeleted = isDeleted

        // Always mark as synced — this record came from the server so it IS synced.
        // Local-initiated deletes go through softDelete() which sets .deleted separately.
        entity.syncStatus            = SyncStatus.synced.rawValue
        entity.syncLocalModifiedAt   = updatedAt
        entity.syncServerModifiedAt  = updatedAt
        entity.syncLastSyncedAt      = Date()
    }
}

extension TrackEntity {
    /// Create a new local entity from a server record on another device.
    convenience init(from row: TrackRow) {
        self.init(
            id:           row.id,
            title:        row.title,
            artistName:   row.artistName,
            albumTitle:   row.albumTitle,
            duration:     row.duration,
            trackNumber:  row.trackNumber,
            discNumber:   row.discNumber,
            year:         row.year,
            genre:        row.genre,
            artworkKey:   row.artworkKey,
            composer:     row.composer,
            dateImported: row.dateImported,
            isSoftDeleted:    row.isDeleted,
            fileHash:     row.fileHash,
            fileSize:     row.fileSize,
            localPath:    "",            // File not yet downloaded; set once it syncs.
            remoteKey:    row.remoteKey,
            fileUploaded: row.fileUploaded,
            // Always synced — this came from the server, never needs to be pushed back.
            syncStatus:           SyncStatus.synced.rawValue,
            syncDeviceID:         row.syncDeviceID,
            syncLocalModifiedAt:  row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:     Date()
        )
    }
}

// MARK: - AlbumRow

struct AlbumRow: Codable {
    var id:           UUID
    var userID:       UUID
    var title:        String
    var artistName:   String
    var year:         Int?
    var genre:        String?
    var trackIDs:     [UUID]
    var dateCreated:  Date
    var syncDeviceID: String
    var artworkKey:   String?
    var updatedAt:    Date
    var isDeleted:    Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case title
        case artistName   = "artist_name"
        case year
        case genre
        case trackIDs     = "track_ids"
        case dateCreated  = "date_created"
        case syncDeviceID = "sync_device_id"
        case artworkKey   = "artwork_key"
        case updatedAt    = "updated_at"
        case isDeleted    = "is_deleted"
    }

    init(entity: AlbumEntity, userID: UUID) {
        self.id           = entity.id
        self.userID       = userID
        self.title        = entity.title
        self.artistName   = entity.artistName
        self.year         = entity.year
        self.genre        = entity.genre
        self.trackIDs     = entity.trackIDsData.toUUIDArray()
        self.dateCreated  = entity.dateCreated
        self.syncDeviceID = entity.syncDeviceID
        self.artworkKey   = entity.artworkKey
        self.updatedAt    = entity.syncLocalModifiedAt
        self.isDeleted    = entity.isSoftDeleted
    }

    func apply(to entity: AlbumEntity) {
        entity.title        = title
        entity.artistName   = artistName
        entity.year         = year
        entity.genre        = genre
        entity.trackIDsData = trackIDs.toData()
        entity.artworkKey   = artworkKey
        entity.isSoftDeleted = isDeleted

        entity.syncStatus            = SyncStatus.synced.rawValue
        entity.syncLocalModifiedAt   = updatedAt
        entity.syncServerModifiedAt  = updatedAt
        entity.syncLastSyncedAt      = Date()
    }
}

extension AlbumEntity {
    convenience init(from row: AlbumRow) {
        self.init(
            id:           row.id,
            title:        row.title,
            artistName:   row.artistName,
            year:         row.year,
            genre:        row.genre,
            artworkKey:   row.artworkKey,
            trackIDsData: row.trackIDs.toData(),
            dateCreated:  row.dateCreated,
            isSoftDeleted:    row.isDeleted,
            syncStatus:           SyncStatus.synced.rawValue,
            syncDeviceID:         row.syncDeviceID,
            syncLocalModifiedAt:  row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:     Date()
        )
    }
}

// MARK: - ArtistRow

struct ArtistRow: Codable {
    var id:           UUID
    var userID:       UUID
    var name:         String
    var bio:          String?
    var isFollowed:   Bool
    var albumIDs:     [UUID]
    var trackIDs:     [UUID]
    var dateCreated:  Date
    var syncDeviceID: String
    var artworkKey:   String?
    var updatedAt:    Date
    var isDeleted:    Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case name
        case bio
        case isFollowed   = "is_followed"
        case albumIDs     = "album_ids"
        case trackIDs     = "track_ids"
        case dateCreated  = "date_created"
        case syncDeviceID = "sync_device_id"
        case artworkKey   = "artwork_key"
        case updatedAt    = "updated_at"
        case isDeleted    = "is_deleted"
    }

    init(entity: ArtistEntity, userID: UUID) {
        self.id           = entity.id
        self.userID       = userID
        self.name         = entity.name
        self.bio          = entity.bio
        self.isFollowed   = entity.isFollowed
        self.albumIDs     = entity.albumIDsData.toUUIDArray()
        self.trackIDs     = entity.trackIDsData.toUUIDArray()
        self.dateCreated  = entity.dateCreated
        self.syncDeviceID = entity.syncDeviceID
        self.artworkKey   = entity.artworkKey
        self.updatedAt    = entity.syncLocalModifiedAt
        self.isDeleted    = entity.isSoftDeleted
    }

    func apply(to entity: ArtistEntity) {
        entity.name        = name
        entity.bio         = bio
        entity.isFollowed  = isFollowed
        entity.albumIDsData = albumIDs.toData()
        entity.trackIDsData = trackIDs.toData()
        entity.artworkKey  = artworkKey
        entity.isSoftDeleted = isDeleted

        entity.syncStatus            = SyncStatus.synced.rawValue
        entity.syncLocalModifiedAt   = updatedAt
        entity.syncServerModifiedAt  = updatedAt
        entity.syncLastSyncedAt      = Date()
    }
}

extension ArtistEntity {
    convenience init(from row: ArtistRow) {
        self.init(
            id:           row.id,
            name:         row.name,
            bio:          row.bio,
            artworkKey:   row.artworkKey,
            isFollowed:   row.isFollowed,
            albumIDsData: row.albumIDs.toData(),
            trackIDsData: row.trackIDs.toData(),
            dateCreated:  row.dateCreated,
            isSoftDeleted:    row.isDeleted,
            syncStatus:           SyncStatus.synced.rawValue,
            syncDeviceID:         row.syncDeviceID,
            syncLocalModifiedAt:  row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:     Date()
        )
    }
}

// MARK: - PlaylistRow

struct PlaylistRow: Codable {
    var id:            UUID
    var userID:        UUID
    var name:          String
    var description:   String?
    var trackIDs:      [UUID]
    var isSystem:      Bool
    var syncDeviceID:  String
    var updatedAt:     Date
    var isDeleted:     Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case name
        case description
        case trackIDs     = "track_ids"
        case isSystem     = "is_system"
        case syncDeviceID = "sync_device_id"
        case updatedAt    = "updated_at"
        case isDeleted    = "is_deleted"
    }

    init(entity: PlaylistEntity, userID: UUID) {
        self.id           = entity.id
        self.userID       = userID
        self.name         = entity.name
        self.description  = entity.playlistDescription
        self.trackIDs     = entity.trackIDsData.toUUIDArray()
        self.isSystem     = entity.id == Playlist.favouritesID || entity.id == Playlist.allSongsID
        self.syncDeviceID = entity.syncDeviceID
        self.updatedAt    = entity.syncLocalModifiedAt
        self.isDeleted    = entity.isSoftDeleted
    }

    /// Overwrites a local entity's mutable fields with the server version.
    func apply(to entity: PlaylistEntity) {
        entity.name                = name
        entity.playlistDescription = description
        entity.trackIDsData        = trackIDs.toData()
        entity.isSoftDeleted       = isSystem ? false : isDeleted
        // isSystem is identity — determined by the well-known UUID, not a stored flag

        entity.syncStatus            = SyncStatus.synced.rawValue
        entity.syncLocalModifiedAt   = updatedAt
        entity.syncServerModifiedAt  = updatedAt
        entity.syncLastSyncedAt      = Date()
    }
}

extension PlaylistEntity {
    /// Create a new local entity from a server record received on another device.
    convenience init(from row: PlaylistRow) {
        self.init(
            id:                  row.id,
            name:                row.name,
            playlistDescription: row.description,
            trackIDsData:        row.trackIDs.toData(),
            dateCreated:         Date(),       // not stored in the server row
            dateModified:        row.updatedAt,
            isSoftDeleted:       row.isSystem ? false : row.isDeleted,
            syncStatus:          SyncStatus.synced.rawValue,
            syncDeviceID:        row.syncDeviceID,
            syncLocalModifiedAt: row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:    Date()
        )
    }
}
