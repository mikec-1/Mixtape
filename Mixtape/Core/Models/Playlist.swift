// Playlist.swift
// Mixtape — Core Domain Models

import Foundation
import SwiftUI

/// Where a playlist came from, and therefore whether its owner is looking at it.
///
/// Until now every playlist in the library was the user's own, so "can I edit
/// this?" never had to be asked. Two kinds of playlist now arrive from outside:
/// a mix the app built, and someone else's published playlist. Neither is the
/// user's to change — the first is a snapshot of a moment, the second belongs to
/// the person who made it — so the distinction has to survive a relaunch rather
/// than live in whichever screen happened to create the row.
/// Where a playlist's cover comes from.
///
/// Three states, not two, because "no cover" and "no cover *yet*" are different
/// answers. A playlist that has never been given one borrows from its songs, and
/// should — that is the app filling in a blank. A playlist whose cover the user
/// deleted has been told, explicitly, that they don't want a picture there, and
/// putting the opening track's artwork back is the app arguing with them.
public enum PlaylistCoverKind: String, Codable, Hashable, Sendable {

    /// Composed by Mixtape from the playlist's own songs. The default, and the
    /// only kind `rebakeDerivedCover` will overwrite.
    case derived

    /// Picked by the user, or published alongside a playlist being followed.
    /// Never recomposed.
    case chosen

    /// Deliberately empty. Draws the placeholder glyph, and keeps drawing it —
    /// "Generate Cover" is how the user asks for a derived one back.
    case none
}

public enum PlaylistOrigin: String, Codable, Hashable, Sendable {

    /// Made here. Fully editable — the only kind that existed before.
    case owned

    /// Saved from a Mixtape mix. Frozen at the moment it was saved: the mix on
    /// Home goes on regenerating, this doesn't follow it.
    case mix

    /// Saved from someone else's public playlist. Follows their edits, which is
    /// exactly why it can't take yours — the next refresh would discard them.
    case subscribed

    /// Imported from Spotify and still following it. Same bargain as
    /// `subscribed`, with Spotify in the role of the owner: the account is the
    /// truth and Mixtape redraws itself to match, so a local edit would only
    /// survive until the next check. Unlinking (see `SpotifyFollowService`)
    /// turns it back into an ordinary `owned` playlist, songs and all — the
    /// import that doesn't want to follow never becomes one of these in the
    /// first place.
    case spotifyMirror
}

public struct Playlist: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Well-known IDs

    /// Stable UUID for the Favourites system playlist. Never changes across launches.
    public static let favouritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Stable UUID for the All Songs system playlist. Contains every imported track automatically.
    public static let allSongsID   = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Properties

    public let id: UUID
    public var name: String
    public var description: String?
    /// Ordered track IDs. Reorder = mutate this array; mutations bump sync.localModifiedAt.
    public var trackIDs: [UUID]
    /// Artwork: first track's art by default; can be overridden by user (future feature).
    public var artworkData: Data?
    public var dateCreated: Date
    public var dateModified: Date

    /// Whose playlist this is, and whether the user may change it.
    public var origin: PlaylistOrigin
    /// Who it belongs to, for the header byline — "Mixtape" for a saved mix, the
    /// publisher's username for a subscribed one, nil for the user's own.
    ///
    /// Stored rather than resolved: the byline is the first thing drawn, and a
    /// playlist whose owner appears a moment after everything else reads as a
    /// glitch. It's a display name, so a stale one is cosmetic.
    public var ownerName: String?

    /// Where this playlist's cover came from. See `PlaylistCoverKind`.
    public var coverKind: PlaylistCoverKind

    /// Pinned to the top of the playlist list.
    ///
    /// On the playlist rather than in local preferences because a pin is a
    /// statement about the playlist, not about the device looking at it — and
    /// the user expects the phone and the Mac to agree. It used to live in
    /// `UserDefaults` (`PlaylistMetadataService`), which is exactly why they
    /// didn't.
    public var isPinned: Bool

    /// Where this playlist sits in the user's own arrangement, low to high.
    ///
    /// On the playlist for exactly the reason `isPinned` is: an order someone
    /// dragged into place is a statement about their library, not about the
    /// device they happened to drag it on. The Mac kept this in `UserDefaults`
    /// (`PlaylistMetadataService.sidebarPlaylistIDs`) and iOS didn't keep it at
    /// all, so the two never showed the same list.
    ///
    /// Optional because "never arranged" is a real answer, distinct from
    /// "arranged first". Playlists without one fall in behind the arranged ones
    /// in library order rather than all claiming position zero.
    public var sortIndex: Int?

    // Sync
    public var sync: SyncMetadata
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        trackIDs: [UUID] = [],
        artworkData: Data? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        origin: PlaylistOrigin = .owned,
        ownerName: String? = nil,
        coverKind: PlaylistCoverKind = .derived,
        isPinned: Bool = false,
        sortIndex: Int? = nil,
        sync: SyncMetadata,
        isDeleted: Bool = false
    ) {
        self.id           = id
        self.name         = name
        self.description  = description
        self.trackIDs     = trackIDs
        self.artworkData  = artworkData
        self.dateCreated  = dateCreated
        self.dateModified = dateModified
        self.origin       = origin
        self.ownerName    = ownerName
        self.coverKind    = coverKind
        self.isPinned     = isPinned
        self.sortIndex    = sortIndex
        self.sync         = sync
        self.isDeleted    = isDeleted
    }

    public var trackCount: Int { trackIDs.count }

    /// System playlists are built-in and cannot be renamed or deleted.
    public var isSystem:     Bool { id == Playlist.favouritesID || id == Playlist.allSongsID }
    public var isFavourites: Bool { id == Playlist.favouritesID }

    /// What the liked-songs list is called on screen. The id is the identity;
    /// this is only its name, which is why renaming it is a one-line change.
    public static let favouritesName = "Liked Songs"
    public var isAllSongs:   Bool { id == Playlist.allSongsID }

    /// Whether the user may change this playlist at all — its songs, its order,
    /// its name, its cover. False for anything that came from outside.
    ///
    /// Deliberately not the same question as `isSystem`: Favourites is a system
    /// playlist you add to constantly, and a saved mix is an ordinary-looking
    /// playlist you can't touch.
    public var isEditable: Bool { origin == .owned }

    /// Whether this playlist is kept in step with a source elsewhere — someone
    /// else's published playlist. A saved mix is not: it's a snapshot.
    public var followsRemoteSource: Bool { origin == .subscribed }

    /// Whether Spotify is this playlist's source of truth. Deliberately not part
    /// of `followsRemoteSource`: that one means "a Mixtape share owned by
    /// someone else", and it is what drives `PlaylistSharingService`, which
    /// knows nothing about Spotify and would report this playlist as deleted.
    public var followsSpotify: Bool { origin == .spotifyMirror }

    // MARK: Mutations (all bump dateModified + sync status)

    public mutating func addTrack(_ id: UUID) {
        guard !trackIDs.contains(id) else { return }
        trackIDs.append(id)
        touch()
    }

    /// Appends many at once, skipping anything already listed.
    ///
    /// `addTrack` in a loop is quadratic — its `contains` scans the whole list
    /// per song — which on a 2,200-song import is several million comparisons
    /// for a job that's one pass with a set.
    public mutating func addTracks(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var seen = Set(trackIDs)
        var added = false
        for id in ids where seen.insert(id).inserted {
            trackIDs.append(id)
            added = true
        }
        if added { touch() }
    }

    public mutating func removeTrack(_ id: UUID) {
        removeTracks([id])
    }

    /// One pass for a whole selection. Called per id, taking 2,100 songs out of
    /// Liked Songs was 2,100 full scans of a 2,100-long array.
    public mutating func removeTracks(_ ids: [UUID]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        let before = trackIDs.count
        trackIDs.removeAll(where: doomed.contains)
        guard trackIDs.count != before else { return }
        touch()
    }

    public mutating func reorder(fromOffsets: IndexSet, toOffset: Int) {
        trackIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        touch()
    }

    // internal so LibraryService and other module code can call p.touch() directly
    mutating func touch() {
        dateModified = Date()
        sync.markModified()
    }
}

// MARK: - Mock Data

#if DEBUG
extension Playlist {
    static let previewPlaylists: [Playlist] = [
        Playlist(name: "Late Night Drive",  description: "Slow, atmospheric tracks for the dark hours.", trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Playlist(name: "Morning Focus",     description: nil, trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
        Playlist(name: "Weekend Mix",       description: "A bit of everything.", trackIDs: [], sync: SyncMetadata(deviceID: "preview")),
    ]
}
#endif
