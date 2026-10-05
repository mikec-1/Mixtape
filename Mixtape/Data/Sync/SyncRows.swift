// Codable rows for the Supabase tables. Each has an init from an entity (push)
// and `apply(to:)` (pull). Entities also get `init(from row:)` for new rows from
// other devices. Artwork syncs through storage, not here.

import Foundation
import SwiftData

// MARK: - TrackRow

nonisolated struct TrackRow: Codable, Sendable {
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
    /// `TrackOrigin.rawValue`. Optional so an older database still decodes.
    var origin:       String?
    /// Resolver key for `.online` rows, so other devices can play them.
    var sourceRef:    String?
    /// Explicit flag. Optional like `origin`.
    var isExplicit:   Bool?
    /// Recipe for `.edit` rows. The audio stays on the device that made it.
    var edit:         SongEdit?

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
        case origin
        case sourceRef     = "source_ref"
        case isExplicit    = "is_explicit"
        case edit
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
        self.origin       = entity.resolvedOrigin.rawValue
        self.sourceRef    = entity.sourceRef
        self.isExplicit   = entity.isExplicit
        self.edit         = entity.editData.flatMap { try? JSONDecoder().decode(SongEdit.self, from: $0) }
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
        // Nil from an older server: keep the local value.
        if let origin { entity.originRaw = origin }
        if let sourceRef { entity.sourceRef = sourceRef }
        if let isExplicit { entity.isExplicit = isExplicit }
        if let edit { entity.editData = try? JSONEncoder().encode(edit) }

        // From the server, so synced. Local deletes go through `softDelete()`.
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
            isExplicit:   row.isExplicit ?? false,
            dateImported: row.dateImported,
            isSoftDeleted:    row.isDeleted,
            fileHash:     row.fileHash,
            fileSize:     row.fileSize,
            localPath:    "",            // File not yet downloaded; set once it syncs.
            remoteKey:    row.remoteKey,
            fileUploaded: row.fileUploaded,
            originRaw:    row.origin,
            sourceRef:    row.sourceRef,
            // From the server, so never pushed back.
            syncStatus:           SyncStatus.synced.rawValue,
            syncDeviceID:         row.syncDeviceID,
            syncLocalModifiedAt:  row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:     Date()
        )
        editData = row.edit.flatMap { try? JSONEncoder().encode($0) }
    }
}

// MARK: - AlbumRow

nonisolated struct AlbumRow: Codable, Sendable {
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

nonisolated struct ArtistRow: Codable, Sendable {
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

nonisolated struct PlaylistRow: Codable, Sendable {
    var id:            UUID
    var userID:        UUID
    var name:          String
    var description:   String?
    var trackIDs:      [UUID]
    var isSystem:      Bool
    var syncDeviceID:  String
    var updatedAt:     Date
    var isDeleted:     Bool
    /// Optional so a server that predates the column still decodes.
    var coverKind: String?
    /// Optional like `coverKind`: nil leaves the local pin alone.
    var isPinned: Bool?
    /// See `Playlist.sortIndex`. Nil leaves the local order alone.
    var sortIndex: Int?
    /// See `Playlist.sides`. Always sent, so removing the last side syncs; nil from
    /// an older client leaves the local sides alone.
    var sides: [PlaylistSide]?
    /// See `Playlist.notes`. Always sent like `sides`; nil leaves the local notes alone.
    var notes: PlaylistNotes?
    /// Mix, saved playlist or the user's own. Nil from older clients means `owned`.
    /// Without it mixes arrived on other devices as plain editable playlists.
    var origin: String?
    /// Publisher's name on a saved playlist, or the Mixtape byline on a mix. Travels with `origin`.
    var ownerName: String?
    /// Creation date, for "Recently Added". Nil from older clients means unknown;
    /// readers fall back to `updatedAt`.
    var dateCreated: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case name
        case description
        case trackIDs     = "track_ids"
        case isSystem     = "is_system"
        case coverKind    = "cover_kind"
        case isPinned     = "is_pinned"
        case sortIndex    = "sort_index"
        case sides
        case notes
        case origin
        case ownerName    = "owner_name"
        case dateCreated  = "created_at"
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
        self.coverKind    = entity.coverKindRaw
        self.isPinned     = entity.isPinned
        self.sortIndex    = entity.sortIndex
        self.sides        = [PlaylistSide](data: entity.sidesData)
        self.notes        = PlaylistNotes(data: entity.notesData)
        self.origin       = PlaylistRow.wireOrigin(entity.originRaw)
        self.ownerName    = entity.ownerName
        self.dateCreated  = entity.dateCreated
    }

    /// A local origin on the wire. Spotify mirrors go as `owned`: the link is local
    /// (see `SpotifyFollowService`), and a mirror without it would be read-only with no
    /// way to unlink. The other device makes it a mirror only if it follows it too.
    static func wireOrigin(_ raw: String) -> String {
        raw == PlaylistOrigin.spotifyMirror.rawValue
            ? PlaylistOrigin.owned.rawValue
            : raw
    }

    /// Overwrites a local entity's mutable fields with the server version.
    func apply(to entity: PlaylistEntity) {
        entity.name                = name
        entity.playlistDescription = description
        entity.trackIDsData        = trackIDs.toData()
        entity.isSoftDeleted       = isSystem ? false : isDeleted
        // Nil from an older server: keep the local pin.
        if let isPinned { entity.isPinned = isPinned }
        // Same for the order.
        if let sortIndex { entity.sortIndex = sortIndex }
        if let sides { entity.sidesData = sides.sidesData }
        if let notes { entity.notesData = notes.data }
        // Nil means `owned`, already the local default, so leave the row alone.
        if let origin {
            // A local Spotify mirror keeps its origin; this device holds the link. See `wireOrigin`.
            if entity.originRaw != PlaylistOrigin.spotifyMirror.rawValue {
                entity.originRaw = origin
            }
            entity.ownerName = ownerName
        }
        if let coverKind {
            let wasNone = entity.coverKindRaw == PlaylistCoverKind.none.rawValue
            entity.coverKindRaw = coverKind

            if coverKind == PlaylistCoverKind.none.rawValue {
                // The other device deleted the cover and this row won, so drop the local blob.
                entity.artworkData              = nil
                entity.artworkKey               = nil
                entity.artworkRemoteStamp       = nil
                entity.artworkNeedsRemoteDelete = false
            } else if wasNone {
                // Back from "no cover": there may be a file again. Otherwise the bucket listing
                // decides whether the picture changed.
                entity.artworkRemoteStamp = nil
            }
        }
        // Earliest date wins, so nil or newer never resets it.
        if let dateCreated { entity.dateCreated = min(entity.dateCreated, dateCreated) }
        // isSystem comes from the well-known UUID, not a stored flag.

        entity.syncStatus            = SyncStatus.synced.rawValue
        entity.syncLocalModifiedAt   = updatedAt
        entity.syncServerModifiedAt  = updatedAt
        entity.syncLastSyncedAt      = Date()
        entity.syncBaseTrackIDsData  = entity.trackIDsData
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
            dateCreated:         row.dateCreated ?? row.updatedAt,
            dateModified:        row.updatedAt,
            isSoftDeleted:       row.isSystem ? false : row.isDeleted,
            originRaw:           row.origin ?? PlaylistOrigin.owned.rawValue,
            ownerName:           row.ownerName,
            coverKindRaw:        row.coverKind ?? PlaylistCoverKind.derived.rawValue,
            isPinned:            row.isPinned ?? false,
            sortIndex:           row.sortIndex,
            sidesData:           row.sides?.sidesData,
            notesData:           row.notes?.data,
            syncStatus:          SyncStatus.synced.rawValue,
            syncDeviceID:        row.syncDeviceID,
            syncLocalModifiedAt: row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:    Date()
        )
        syncBaseTrackIDsData = trackIDsData
    }
}

// MARK: - PlayHistoryRow
// Append-only: plays are never edited, so no `apply(to:)`. Pulls insert unseen rows.

nonisolated struct PlayHistoryRow: Codable, Sendable {
    var id:            UUID
    var userID:        UUID
    var trackID:       UUID
    var playedAt:      Date
    var secondsPlayed: Double
    var sourceKind:    String?
    var sourceID:      String?
    var syncDeviceID:  String
    var platform:      String?
    var updatedAt:     Date
    var isDeleted:     Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID        = "user_id"
        case trackID       = "track_id"
        case playedAt      = "played_at"
        case secondsPlayed = "seconds_played"
        case sourceKind    = "source_kind"
        case sourceID      = "source_id"
        case syncDeviceID  = "sync_device_id"
        case platform
        case updatedAt     = "updated_at"
        case isDeleted     = "is_deleted"
    }

    init(entity: PlayHistoryEntity, userID: UUID) {
        self.id            = entity.id
        self.userID        = userID
        self.trackID       = entity.trackID
        self.playedAt      = entity.playedAt
        self.secondsPlayed = entity.secondsPlayed
        self.sourceKind    = entity.sourceKind
        self.sourceID      = entity.sourceID
        self.syncDeviceID  = entity.syncDeviceID
        self.updatedAt     = entity.syncLocalModifiedAt
        self.isDeleted     = false
    }

    func entity() -> PlayHistoryEntity {
        PlayHistoryEntity(
            id:                  id,
            trackID:             trackID,
            playedAt:            playedAt,
            secondsPlayed:       secondsPlayed,
            sourceKind:          sourceKind,
            sourceID:            sourceID,
            syncStatus:          SyncStatus.synced.rawValue,
            syncDeviceID:        syncDeviceID,
            syncLocalModifiedAt: updatedAt,
            syncServerModifiedAt: updatedAt,
            syncLastSyncedAt:    Date()
        )
    }
}
