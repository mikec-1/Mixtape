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
    /// Defaulted so the store migrates lightly: every row that predates the
    /// column reads as "not known to be explicit".
    public var isExplicit: Bool = false
    public var dateImported: Date
    public var isSoftDeleted: Bool

    // File provenance
    public var fileHash: String
    public var fileSize: Int64
    public var localPath: String
    public var remoteKey: String?
    public var fileUploaded: Bool
    public var fileDownloadedAt: Date?
    /// `TrackOrigin.rawValue`. Optional because rows written before origin was
    /// stored have none — `toDomain()` infers those once, on read.
    public var originRaw: String?
    /// Resolver key for `.online` rows.
    public var sourceRef: String?

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
        isExplicit: Bool = false,
        dateImported: Date = Date(),
        isSoftDeleted: Bool = false,
        fileHash: String,
        fileSize: Int64,
        localPath: String,
        remoteKey: String? = nil,
        fileUploaded: Bool = false,
        fileDownloadedAt: Date? = nil,
        originRaw: String? = nil,
        sourceRef: String? = nil,
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
        self.isExplicit           = isExplicit
        self.dateImported         = dateImported
        self.isSoftDeleted        = isSoftDeleted
        self.fileHash             = fileHash
        self.fileSize             = fileSize
        self.localPath            = localPath
        self.remoteKey            = remoteKey
        self.fileUploaded         = fileUploaded
        self.fileDownloadedAt     = fileDownloadedAt
        self.originRaw            = originRaw
        self.sourceRef            = sourceRef
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

    /// `PlaylistOrigin.rawValue`. Defaulted so the store migrates in place: every
    /// playlist that existed before playlists could come from anywhere else is
    /// one the user made.
    public var originRaw: String = PlaylistOrigin.owned.rawValue
    /// Display name of the owner, for playlists that aren't the user's own.
    public var ownerName: String?

    /// Where this playlist's cover came from, as a `PlaylistCoverKind` raw
    /// value.
    ///
    /// A chosen cover and a composed one used to be indistinguishable, and that
    /// is why covers differed per device: a composed cover was rebuilt locally
    /// from whichever tracks had artwork *on that device*, so no two devices
    /// drew the same tiles. The composed bytes are now baked into `artworkData`
    /// and synced like any other cover; this is what still allows them to be
    /// re-baked when the track list changes, what a chosen cover sets so it is
    /// never overwritten, and what a cleared cover sets so nothing is put back.
    ///
    /// Defaulted so the store migrates in place. `derived` is the right reading
    /// of every existing row — every cover before this existed either came from
    /// the songs or will simply be re-baked once, and a chosen one is marked the
    /// next time it is set.
    public var coverKindRaw: String = PlaylistCoverKind.derived.rawValue
    public var isPinned: Bool = false

    /// The user's own arrangement — see `Playlist.sortIndex`. Defaulted to nil
    /// so the store migrates in place and an existing library reads as
    /// "never arranged" until it is.
    public var sortIndex: Int? = nil

    /// When the bucket's copy of this cover was last written, as of the last
    /// time we looked.
    ///
    /// The playlists table has no artwork column, so the row cannot say the
    /// picture changed — and the first attempt at this marked every playlist
    /// stale whenever a pull brought newer rows, which re-downloaded the whole
    /// wall of covers. The bucket listing already carries a modified date per
    /// file, and one listing covers every playlist, so comparing against this is
    /// both exact and free: a cover is fetched when its file is genuinely newer
    /// than the copy on disk, and never otherwise.
    ///
    /// Local only. Never encoded into `PlaylistRow`, so it needs no column.
    public var artworkRemoteStamp: Date? = nil

    /// The user threw this cover away and the bucket has not been told yet.
    ///
    /// A deletion is the one cover change that cannot travel as an upload, and
    /// leaving the old file in place is worse than doing nothing: the download
    /// pass lists the folder, finds it, and hands the deleted cover straight
    /// back. Local only, cleared once the object is gone.
    public var artworkNeedsRemoteDelete: Bool = false

    /// Where this playlist's cover sits in the `artwork` bucket, once it's been
    /// uploaded. Local-only, unlike the track/album/artist equivalents: the
    /// path is `<userID>/playlists/<playlistID>.jpg` and both ids are already
    /// on every device, so it's derivable rather than something the row has to
    /// carry. What it records here is "this device has already sent it".
    public var artworkKey: String?

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
        originRaw: String = PlaylistOrigin.owned.rawValue,
        ownerName: String? = nil,
        coverKindRaw: String = PlaylistCoverKind.derived.rawValue,
        isPinned: Bool = false,
        sortIndex: Int? = nil,
        artworkKey: String? = nil,
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
        self.originRaw            = originRaw
        self.ownerName            = ownerName
        self.coverKindRaw         = coverKindRaw
        self.isPinned             = isPinned
        self.sortIndex            = sortIndex
        self.artworkKey           = artworkKey
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
    /// The account this rule belongs to. Nil only on rows from before rules had
    /// owners; `SmartPlaylistService` hands those to the next account to sign in.
    public var ownerID: String?
    /// Whether this rule is listed in Your Library. The shipped five arrive
    /// `false` — they live on Home and are added from their own page — while
    /// anything the user wrote themselves arrives `true`, since a rule you had
    /// to open a sheet to make is one you meant to keep.
    public var inLibrary: Bool = false

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "wand.and.stars",
        ruleData: Data = Data(),
        dateCreated: Date = Date(),
        ownerID: String? = nil,
        inLibrary: Bool = false
    ) {
        self.id          = id
        self.name        = name
        self.iconName    = iconName
        self.ruleData    = ruleData
        self.dateCreated = dateCreated
        self.ownerID     = ownerID
        self.inLibrary   = inLibrary
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

// MARK: - PlayedTrackSnapshot

/// A lightweight, persisted snapshot of a played track that is NOT in the
/// library — i.e. an online (Discover) song. The play-history table only stores
/// a bare `trackID`; for library songs that's enough (they resolve through the
/// TrackRepository), but online songs have no library row, so without this they
/// vanish from "Recently played" after a relaunch and never appear in listening
/// stats. We upsert one snapshot per unique online track (keyed by its stable
/// id) and resolve recently-played / stats lookups against it as a fallback.
@Model
public final class PlayedTrackSnapshotEntity {

    @Attribute(.unique) public var id: UUID
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    @Attribute(.externalStorage) public var artworkData: Data?
    /// The OnlineTrack key ("title|artist") so a replay can reconstruct it.
    public var sourceKey: String
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        artworkData: Data? = nil,
        sourceKey: String,
        updatedAt: Date = Date()
    ) {
        self.id          = id
        self.title       = title
        self.artistName  = artistName
        self.albumTitle  = albumTitle
        self.duration    = duration
        self.artworkData = artworkData
        self.sourceKey   = sourceKey
        self.updatedAt   = updatedAt
    }
}
