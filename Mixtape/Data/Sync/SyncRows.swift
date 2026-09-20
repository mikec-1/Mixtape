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
    /// `TrackOrigin.rawValue`. Optional on the wire so a client running against
    /// a database that predates the column still decodes.
    var origin:       String?
    /// Resolver key for `.online` rows — the only thing that makes an online
    /// placeholder playable on the user's other devices.
    var sourceRef:    String?
    /// Whether the catalogue calls this recording explicit. Optional on the
    /// wire for the same reason as `origin`.
    var isExplicit:   Bool?

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
        // A server that predates these columns sends nothing; keep whatever the
        // local row already worked out rather than blanking it back to a guess.
        if let origin { entity.originRaw = origin }
        if let sourceRef { entity.sourceRef = sourceRef }
        if let isExplicit { entity.isExplicit = isExplicit }

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
    /// Optional for the same reason as `coverKind`: a server that predates the
    /// column sends nil, and nil must leave the local pin alone rather than
    /// unpin everything.
    var isPinned: Bool?
    /// The user's arrangement — see `Playlist.sortIndex`. Optional for the same
    /// reason as `isPinned`: a client or server that predates the column sends
    /// nil, and nil must leave the local order alone rather than flattening it.
    var sortIndex: Int?
    /// Where this playlist came from — a mix, someone else's published list, or
    /// the user's own. Optional because a client that predates the column sends
    /// nil, which the migration defines as `owned`.
    ///
    /// Without this every playlist crossed devices as `owned`, so a mix saved on
    /// one device arrived on the other as a plain playlist: no Mixtape byline,
    /// no "Made for you", and editable when it should not have been.
    var origin: String?
    /// The publisher's name on a saved playlist, and the Mixtape byline on a
    /// mix. Meaningless without `origin`, and travels with it.
    var ownerName: String?
    /// When the playlist was made — what "Recently Added" orders by. This used
    /// to be local-only, so the order it drives disagreed between devices and
    /// the web had nothing to sort by at all. Optional because a client or
    /// server that predates the column sends nil, and nil means "unknown",
    /// which readers answer with `updatedAt` rather than with "just now".
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
        self.origin       = PlaylistRow.wireOrigin(entity.originRaw)
        self.ownerName    = entity.ownerName
        self.dateCreated  = entity.dateCreated
    }

    /// What a local origin becomes on the wire.
    ///
    /// Everything travels as itself except `spotifyMirror`, which is sent as
    /// `owned`. A mirror is only half a thing without the Spotify link that
    /// drives it, and that link is stored locally per device on purpose (see
    /// `SpotifyFollowService`). Sending the origin alone would give the other
    /// device a playlist it is forbidden to edit and has no way to unlink —
    /// read-only forever, with no control to release it. It becomes a mirror
    /// there when, and only when, that device follows the playlist itself.
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
        // Nothing from a server that predates the column: keep what this device
        // already worked out rather than calling every cover user-chosen.
        if let isPinned { entity.isPinned = isPinned }
        // Same reasoning: a server that predates the column has nothing to say
        // about the order, and saying nothing must not clear one.
        if let sortIndex { entity.sortIndex = sortIndex }
        // Nil is "a client that predates the column", which the migration
        // defines as `owned` — and that is already the local default, so
        // leaving the row alone says the same thing without overwriting an
        // origin this device worked out for itself.
        if let origin {
            // A local Spotify mirror keeps its origin whatever the wire says:
            // this device holds the link, so it is the one that knows. See
            // `wireOrigin`.
            if entity.originRaw != PlaylistOrigin.spotifyMirror.rawValue {
                entity.originRaw = origin
            }
            entity.ownerName = ownerName
        }
        if let coverKind {
            let wasNone = entity.coverKindRaw == PlaylistCoverKind.none.rawValue
            entity.coverKindRaw = coverKind

            if coverKind == PlaylistCoverKind.none.rawValue {
                // The other device deleted the cover. Rows are last-write-wins
                // and this row won, so that decision is the current one — drop
                // the local blob rather than letting the artwork pass hand it
                // back on the next sync.
                entity.artworkData              = nil
                entity.artworkKey               = nil
                entity.artworkRemoteStamp       = nil
                entity.artworkNeedsRemoteDelete = false
            } else if wasNone {
                // Coming back from "no cover" means there may be a file to
                // fetch again. Everything else is left to the bucket listing,
                // which knows whether the picture actually changed — marking on
                // the row's word alone re-downloaded every cover in the library
                // whenever a pull brought newer rows.
                entity.artworkRemoteStamp = nil
            }
        }
        // A creation date only ever gets more accurate: the earliest one wins,
        // so a row from a device that predates the column (nil) leaves the local
        // date alone instead of resetting it to today.
        if let dateCreated { entity.dateCreated = min(entity.dateCreated, dateCreated) }
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
            dateCreated:         row.dateCreated ?? row.updatedAt,
            dateModified:        row.updatedAt,
            isSoftDeleted:       row.isSystem ? false : row.isDeleted,
            originRaw:           row.origin ?? PlaylistOrigin.owned.rawValue,
            ownerName:           row.ownerName,
            coverKindRaw:        row.coverKind ?? PlaylistCoverKind.derived.rawValue,
            isPinned:            row.isPinned ?? false,
            sortIndex:           row.sortIndex,
            syncStatus:          SyncStatus.synced.rawValue,
            syncDeviceID:        row.syncDeviceID,
            syncLocalModifiedAt: row.updatedAt,
            syncServerModifiedAt: row.updatedAt,
            syncLastSyncedAt:    Date()
        )
    }
}

// MARK: - PlayHistoryRow
//
// Append-only, unlike every other row here: a play happened, and nothing ever
// edits it. So there is no `apply(to:)` — the pull inserts rows it hasn't seen
// and ignores the rest.

nonisolated struct PlayHistoryRow: Codable, Sendable {
    var id:            UUID
    var userID:        UUID
    var trackID:       UUID
    var playedAt:      Date
    var secondsPlayed: Double
    var syncDeviceID:  String
    var updatedAt:     Date
    var isDeleted:     Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userID        = "user_id"
        case trackID       = "track_id"
        case playedAt      = "played_at"
        case secondsPlayed = "seconds_played"
        case syncDeviceID  = "sync_device_id"
        case updatedAt     = "updated_at"
        case isDeleted     = "is_deleted"
    }

    init(entity: PlayHistoryEntity, userID: UUID) {
        self.id            = entity.id
        self.userID        = userID
        self.trackID       = entity.trackID
        self.playedAt      = entity.playedAt
        self.secondsPlayed = entity.secondsPlayed
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
            syncStatus:          SyncStatus.synced.rawValue,
            syncDeviceID:        syncDeviceID,
            syncLocalModifiedAt: updatedAt,
            syncServerModifiedAt: updatedAt,
            syncLastSyncedAt:    Date()
        )
    }
}
