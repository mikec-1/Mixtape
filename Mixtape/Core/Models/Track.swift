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
    /// Catalogue explicit flag. Drives the E badge and the resolver's pick.
    /// False when unknown.
    public var isExplicit: Bool

    // MARK: Import
    public var dateImported: Date

    // MARK: Sync + File
    public var sync: SyncMetadata
    public var file: FileProvenance

    // MARK: Soft-delete
    /// True once the user deletes the track; swept up by sync service.
    public var isDeleted: Bool

    /// Set on `.edit` songs: what they were made from.
    public var edit: SongEdit?

    // MARK: Init
    /// nonisolated so the local-files scan can build these off the main actor.
    public nonisolated init(
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
        isExplicit: Bool = false,
        dateImported: Date = Date(),
        sync: SyncMetadata,
        file: FileProvenance,
        isDeleted: Bool = false,
        edit: SongEdit? = nil
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
        self.isExplicit   = isExplicit
        self.dateImported = dateImported
        self.sync         = sync
        self.file         = file
        self.isDeleted    = isDeleted
        self.edit         = edit
    }

    // MARK: Computed helpers

    /// Where this track's audio comes from. See `TrackOrigin`.
    public var origin: TrackOrigin { file.origin }

    /// Stored origin, not a guess.
    nonisolated public var isOnline: Bool { file.origin == .online }

    /// A shared song with no file anywhere, minted from a snapshot. Upgrades in
    /// place when the real track arrives.
    public var isUnresolvableShare: Bool { file.origin == .unresolvableShare }

    /// Whether there's any way to get the audio. Use this, not
    /// isUnresolvableShare, since a share with a title can still resolve online.
    public var canResolveAudio: Bool { !isUnresolvableShare || sourceRef != nil }

    /// A watched-folder file. Derived from a scan, never stored or synced.
    public var isLocalFile: Bool { file.origin == .localFile }

    /// Title without the "(feat. ...)" credit, for display. The stored title keeps
    /// it because displayArtists reads the guests from there.
    nonisolated public var displayTitle: String { ImportService.bareTitle(title) }

    /// The printed credit: the stored artist plus whatever the title named.
    nonisolated public var displayArtistName: String {
        ImportService.displayArtists(title: title, artistName: artistName)
            .joined(separator: ", ")
    }

    /// The title spelling the id was hashed from. Can differ from `title` once a
    /// feature credit is printed on it. Build keys from this, never from `title`.
    public var identityTitle: String {
        let bare = ImportService.bareTitle(title)
        guard bare != title else { return title }
        let stored = file.sourceRef.flatMap { $0.isEmpty ? nil : $0 }
                  ?? (file.fileHash.contains("|") ? file.fileHash : nil)
        if let stored {
            let head = stored.split(separator: "|", maxSplits: 1).first.map(String.init) ?? stored
            return head == bare.lowercased() ? bare : title
        }
        return OnlineTrack.stableID(for: OnlineTrack.key(title: bare, artistName: artistName)) == id
             ? bare : title
    }

    /// The resolver key for rows without bytes.
    public var sourceRef: String? {
        if let ref = file.sourceRef, !ref.isEmpty { return ref }
        // Old rows kept the key in fileHash.
        if file.origin == .online, file.fileHash.contains("|") { return file.fileHash }
        // Rebuild the key from title and artist (same shape as OnlineTrack.id) so
        // the row stays resolvable. Shares are included since most are on Deezer anyway.
        // Uses identityTitle so a printed feature credit doesn't leak into the key.
        if file.origin == .online || file.origin == .unresolvableShare, !title.isEmpty {
            return OnlineTrack.key(title: identityTitle, artistName: artistName)
        }
        return nil
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
