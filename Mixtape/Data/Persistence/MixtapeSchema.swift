// SwiftData @Model definitions. Repositories map these to the domain structs.

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
    /// Defaulted for lightweight migration.
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
    /// `TrackOrigin.rawValue`. Nil on old rows; `toDomain()` infers it.
    public var originRaw: String?
    /// Resolver key for `.online` rows.
    public var sourceRef: String?
    /// JSON `SongEdit` for `.edit` rows. Defaulted for lightweight migration.
    public var editData: Data? = nil

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

    /// `PlaylistOrigin.rawValue`. Defaults to owned for rows from before origins existed.
    public var originRaw: String = PlaylistOrigin.owned.rawValue
    /// Display name of the owner, for playlists that aren't the user's own.
    public var ownerName: String?

    /// `PlaylistCoverKind` raw value. Composed covers are baked into `artworkData`
    /// and synced, so devices agree; this says whether it may be re-baked (derived),
    /// must be kept (chosen) or stays empty (none). Existing rows default to derived.
    public var coverKindRaw: String = PlaylistCoverKind.derived.rawValue
    public var isPinned: Bool = false

    /// User's arrangement, see `Playlist.sortIndex`. Nil means never arranged.
    public var sortIndex: Int? = nil

    /// JSON-encoded `[PlaylistSide]`. Nil means no sides.
    public var sidesData: Data? = nil

    /// JSON-encoded `PlaylistNotes`. Nil means none.
    public var notesData: Data? = nil

    /// Modified date of the bucket's copy of this cover when last checked. The
    /// playlist row has no artwork column, so the bucket listing is what says a cover
    /// changed. Local only.
    public var artworkRemoteStamp: Date? = nil

    /// Cover was removed and the bucket copy hasn't been deleted yet. Otherwise the
    /// download pass would bring it back. Local only.
    public var artworkNeedsRemoteDelete: Bool = false

    /// Set once this device has uploaded the cover. Local only: the path
    /// (`<userID>/playlists/<playlistID>.jpg`) is derivable on every device.
    public var artworkKey: String?

    // Sync
    public var syncStatus: String
    public var syncServerID: String?
    public var syncDeviceID: String
    public var syncLocalModifiedAt: Date
    public var syncServerModifiedAt: Date?
    public var syncLastSyncedAt: Date?
    /// Track list as of the last pull or push. A push replays only the changes made
    /// since then onto the server's list. Nil on rows from before this existed. Local only.
    public var syncBaseTrackIDsData: Data? = nil

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
        sidesData: Data? = nil,
        notesData: Data? = nil,
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
        self.sidesData            = sidesData
        self.notesData            = notesData
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
    /// Where the play came from: "playlist" with a uuid, or "name" with a display
    /// name (album, artist, search, mix). Nil on plays recorded before 2.0.
    public var sourceKind: String? = nil
    public var sourceID: String? = nil

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
        sourceKind: String? = nil,
        sourceID: String? = nil,
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
        self.sourceKind           = sourceKind
        self.sourceID             = sourceID
        self.syncStatus           = syncStatus
        self.syncServerID         = syncServerID
        self.syncDeviceID         = syncDeviceID
        self.syncLocalModifiedAt  = syncLocalModifiedAt
        self.syncServerModifiedAt = syncServerModifiedAt
        self.syncLastSyncedAt     = syncLastSyncedAt
    }
}

// MARK: - SmartPlaylistEntity
// Local-only auto-updating playlist defined by an encoded rule. Not synced; contents resolve live.

@Model
public final class SmartPlaylistEntity {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var iconName: String
    /// JSON-encoded SmartPlaylistRule (see SmartPlaylist.encodedRule()).
    public var ruleData: Data
    public var dateCreated: Date
    /// Owning account. Nil on old rows; `SmartPlaylistService` assigns those to the next sign-in.
    public var ownerID: String?
    /// Shown in Your Library. Built-in rules start false (they live on Home);
    /// user-made ones start true.
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

/// Snapshot of a played song that isn't in the library (a Discover song).
/// Play history only stores a track id, so without this those plays drop out of
/// Recently Played and stats after a relaunch. One per track id.
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
