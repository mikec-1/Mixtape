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
    /// Whether the catalogue calls this recording explicit — what the "E" badge
    /// on a row is drawn from, and what tells the resolver to hold out for the
    /// uncensored master. Defaults to false for rows imported before it was
    /// stored, so an absent flag reads as "not known to be explicit" rather
    /// than as a claim that it's clean.
    public var isExplicit: Bool

    // MARK: Import
    public var dateImported: Date

    // MARK: Sync + File
    public var sync: SyncMetadata
    public var file: FileProvenance

    // MARK: Soft-delete
    /// True once the user deletes the track; swept up by sync service.
    public var isDeleted: Bool

    // MARK: Init
    /// `nonisolated` because the project defaults to main-actor isolation, and a
    /// value type that carries no reference has no business hopping actors to be
    /// built — the local-files scan makes one of these per file, off the main
    /// actor, and awaiting the main actor per file would serialise the whole
    /// scan through the UI thread.
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
        self.isExplicit   = isExplicit
        self.dateImported = dateImported
        self.sync         = sync
        self.file         = file
        self.isDeleted    = isDeleted
    }

    // MARK: Computed helpers

    /// Where this track's audio comes from. See `TrackOrigin`.
    public var origin: TrackOrigin { file.origin }

    /// True for a song that came from Discover rather than the user's own disk.
    ///
    /// This is now a stored fact, not a guess about file fields — a saved
    /// Discover song stays `.online` whether it is a bare placeholder, cached
    /// for replay, or downloaded for offline use.
    public var isOnline: Bool { file.origin == .online }

    /// A song from a shared playlist that this library has no copy of *and no way
    /// to get one* — someone else's local file.
    ///
    /// `LibraryService.importSharedTrack` mints these from a snapshot's metadata
    /// and nothing else: no path, no size, no hash, no remote key. A shared song
    /// that came from Discover is imported as an `.online` row instead, because
    /// that one *can* be resolved — which is why most of a joined playlist is
    /// not unresolvable.
    ///
    /// They exist so a collaborative playlist reads correctly on a device that
    /// doesn't own the music, and they upgrade in place the moment the real
    /// track arrives under the same id.
    public var isUnresolvableShare: Bool { file.origin == .unresolvableShare }

    /// Whether there is any route to this song's audio at all — a file, a
    /// server object, or a search the resolver can run.
    ///
    /// The one thing this excludes is a share with no title to look up, and
    /// that is the whole reason it exists. `isUnresolvableShare` names an
    /// *origin*, not a verdict, and every place that used it as a verdict was
    /// wrong in the same way: a share that knows what song it is resolves
    /// online exactly like a Discover row does, so filtering on the origin
    /// dropped playable songs out of Play, out of Download, and out of the
    /// offline counts. Worse, the origin can be applied by mistake — when a
    /// row's stored origin is missing, `FileProvenance.inferOrigin` reads an
    /// empty-shaped row as a share — so an ordinary song that merely lost its
    /// local copy could be written off everywhere at once.
    ///
    /// Ask this instead of the origin wherever the question is "can anything
    /// be done with this row". See `AudioLocator.locate`.
    public var canResolveAudio: Bool { !isUnresolvableShare || sourceRef != nil }

    /// True for a file in one of the user's watched folders — audio Mixtape can
    /// play but does not own a copy of. These rows are derived from a scan and
    /// are never in the database, so nothing about them syncs.
    public var isLocalFile: Bool { file.origin == .localFile }

    /// The song's name as it should be *printed*: the bracketed feature credit
    /// taken back off.
    ///
    /// Spotify's rule, and the one the app now follows everywhere a song is
    /// presented — "UK Rap" with the credit reading "Dave, Central Cee", rather
    /// than "UK Rap (feat. Central Cee)" by "Dave", which says the same thing
    /// twice and says the second half in the wrong place. The guests are not
    /// lost: `ImportService.displayArtists(title:artistName:)` reads them back
    /// out of the stored title, which is why the credit has to keep it.
    ///
    /// Display only. The stored `title` is untouched, because it is what the
    /// row was written with and what `identityTitle` reasons about — see there
    /// for why the stored spelling and the hashed one legitimately differ.
    public var displayTitle: String { ImportService.bareTitle(title) }

    /// The printed credit: the stored artist plus whatever the title named.
    public var displayArtistName: String {
        ImportService.displayArtists(title: title, artistName: artistName)
            .joined(separator: ", ")
    }

    /// This song's title in the spelling its *identity* was built from.
    ///
    /// Usually the stored title, and the two only part company over a printed
    /// feature credit. `OnlineTrack.asTrack` stores `displayTitle` — the title
    /// with "(feat. …)" put back on — on the library row, while the id, the
    /// `sourceRef` and the cache stem all stay hashed from the source's bare
    /// title. So from the moment credits started being printed, anything that
    /// rebuilt a key out of `title` derived a key this song has never been
    /// stored under: a cache miss on a file already downloaded, a resolver
    /// query asking a search engine for the credit as if it were the name, and
    /// — where the key is checked against the id as proof of origin — a
    /// perfectly ordinary Discover song written off as somebody else's file.
    ///
    /// Which spelling is right is not guessed. The row already carries the
    /// answer: its stored key if it has one, and otherwise its own id, which is
    /// the SHA-256 of the key it was minted under.
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

    /// The key the resolver needs to fetch this song's audio, for rows that have
    /// no bytes of their own.
    public var sourceRef: String? {
        if let ref = file.sourceRef, !ref.isEmpty { return ref }
        // Rows written before `sourceRef` existed carried the search key in the
        // hash field, which is where `OnlineTrack.asTrack` used to put it.
        if file.origin == .online, file.fileHash.contains("|") { return file.fileHash }
        // Neither field survived, but an online row still knows what song it is,
        // and that is all the resolver ever needed: `OnlinePlaybackCoordinator`
        // builds its query from the title and artist, not from this key. Same
        // shape as `OnlineTrack.id`, so a copy fetched under it lands in the
        // cache where the next lookup will find it.
        //
        // Without this, such a row answered "no reference" and `AudioLocator`
        // read that as `.sharedFromAnotherLibrary` — a dead end the playback
        // engine deliberately never retries. An offline copy hid it for as long
        // as one existed; deleting the download turned the song unplayable
        // everywhere, with a message about another library that was never true.
        //
        // `.unresolvableShare` is here for the same reason. That origin means
        // "someone else's local file", and the old conclusion was that no amount
        // of searching would produce it — which is only true of the *file*. The
        // song is usually on Deezer like any other, and a row that knows its own
        // title and artist can be looked up exactly like a Discover row can. It
        // is also an origin a row can be given *by mistake*: when the stored
        // origin is missing, `FileProvenance.inferOrigin` reads an empty-shaped
        // row as a share, so an ordinary song that lost its local file could be
        // reclassified into a dead end and told it came from another library.
        //
        // Built from `identityTitle`, never the stored one: a row whose title
        // has since gained a printed feature credit would otherwise derive a
        // key nothing else in the app uses, and send the resolver looking for a
        // song called "Ran To Atlanta (feat. Future & Molly Santana)".
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
