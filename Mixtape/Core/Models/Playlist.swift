import Foundation
import SwiftUI

/// Where a playlist's cover comes from. `none` means the user removed it,
/// so don't fall back to track artwork.
public enum PlaylistCoverKind: String, Codable, Hashable, Sendable {

    /// Built from the playlist's songs. The only kind that gets rebaked.
    case derived

    /// User-picked or published with a followed playlist.
    case chosen

    /// User removed it. "Generate Cover" brings a derived one back.
    case none
}

public enum PlaylistOrigin: String, Codable, Hashable, Sendable {

    /// Made here, fully editable.
    case owned

    /// Saved mix. A frozen snapshot.
    case mix

    /// Someone else's playlist. Follows their edits, so it's read-only.
    case subscribed

    /// Follows a Spotify playlist, so local edits would be overwritten.
    /// Unlinking turns it back into `owned`.
    case spotifyMirror
}

/// A named stretch of a playlist, like one side of a tape.
public struct PlaylistSide: Codable, Hashable, Sendable {
    /// First song on this side. Nil for Side A, which starts at the top.
    public var start: UUID?
    public var name: String

    public init(start: UUID?, name: String = "") {
        self.start = start
        self.name  = name
    }

    /// "A", "B", ... then numbers past Z.
    public static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(65 + index)!) : String(index + 1)
    }
}

/// Liner notes: a few words on the playlist and on any of its songs. Synced, and sent with a share.
nonisolated public struct PlaylistNotes: Codable, Hashable, Sendable {
    public var text = ""
    /// By lowercase song id, the same keys the web reads.
    public var songs: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text  = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        songs = try c.decodeIfPresent([String: String].self, forKey: .songs) ?? [:]
    }

    public var isEmpty: Bool { text.isEmpty && songs.isEmpty }

    public subscript(song id: UUID) -> String? {
        get { songs[id.uuidString.lowercased()] }
        set { songs[id.uuidString.lowercased()] = newValue?.isEmpty == false ? newValue : nil }
    }

    /// Nil when empty, so most rows store nothing.
    var data: Data? { isEmpty ? nil : try? JSONEncoder().encode(self) }

    init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(PlaylistNotes.self, from: $0) } ?? PlaylistNotes()
    }
}

public struct Playlist: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Well-known IDs

    /// Stable UUID for the Favourites system playlist. Never changes across launches.
    nonisolated public static let favouritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    nonisolated public static let allSongsID   = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Properties

    public let id: UUID
    public var name: String
    public var description: String?
    /// Mutations bump sync.localModifiedAt.
    public var trackIDs: [UUID]
    public var artworkData: Data?
    public var dateCreated: Date
    public var dateModified: Date

    /// Whose playlist this is, and whether the user may change it.
    public var origin: PlaylistOrigin
    /// Byline owner ("Mixtape" for mixes, the publisher for subscriptions).
    /// Stored so the header doesn't pop in late.
    public var ownerName: String?

    /// Where this playlist's cover came from. See `PlaylistCoverKind`.
    public var coverKind: PlaylistCoverKind

    /// Pinned to the top. Synced so all devices agree.
    public var isPinned: Bool

    /// Manual order, low to high. Synced. Nil means never arranged, and those
    /// sort after the arranged ones.
    public var sortIndex: Int?

    /// Side A, B, ... in running order. Empty means no sides. Synced.
    public var sides: [PlaylistSide]

    /// See `PlaylistNotes`.
    public var notes: PlaylistNotes

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
        sides: [PlaylistSide] = [],
        notes: PlaylistNotes = PlaylistNotes(),
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
        self.sides        = sides
        self.notes        = notes
        self.sync         = sync
        self.isDeleted    = isDeleted
    }

    /// Ids with a song row here, set by the library when it publishes. A like can outlive its song or
    /// arrive before it, and the page only lists rows, so the count shouldn't include those.
    public var liveCount: Int?

    public var trackCount: Int { liveCount ?? trackIDs.count }

    /// System playlists are built-in and cannot be renamed or deleted.
    public var isSystem:     Bool { id == Playlist.favouritesID || id == Playlist.allSongsID }
    public var isFavourites: Bool { id == Playlist.favouritesID }

    public static let favouritesName = "Liked Songs"
    public var isAllSongs:   Bool { id == Playlist.allSongsID }

    /// Whether the user can change it. Not the same as isSystem: Liked Songs is
    /// system but editable, a saved mix isn't.
    public var isEditable: Bool { origin == .owned }

    /// Follows someone else's published playlist.
    public var followsRemoteSource: Bool { origin == .subscribed }

    /// Separate from followsRemoteSource, which drives PlaylistSharingService.
    public var followsSpotify: Bool { origin == .spotifyMirror }

    // MARK: Mutations (all bump dateModified + sync status)

    public mutating func addTrack(_ id: UUID) {
        guard !trackIDs.contains(id) else { return }
        trackIDs.append(id)
        touch()
    }

    /// Appends in one pass, skipping ids already present.
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

    public mutating func removeTracks(_ ids: [UUID]) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        let before = trackIDs
        trackIDs.removeAll(where: doomed.contains)
        guard trackIDs.count != before.count else { return }
        // A side whose first song goes starts at the next one that stays.
        if !sides.isEmpty {
            sides = sides.compactMap { side in
                guard let start = side.start, doomed.contains(start) else { return side }
                guard let at = before.firstIndex(of: start),
                      let next = before[(at + 1)...].first(where: { !doomed.contains($0) })
                else { return nil }
                return PlaylistSide(start: next, name: side.name)
            }
            sides = sideLayout.map(\.side)
        }
        touch()
    }

    public mutating func reorder(fromOffsets: IndexSet, toOffset: Int) {
        trackIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        touch()
    }

    // MARK: Sides

    /// Where each side starts in `trackIDs`, in running order. A break whose song
    /// has gone is skipped, two on one song keep the later, and a lone side means none.
    public var sideLayout: [(offset: Int, side: PlaylistSide)] {
        guard !sides.isEmpty else { return [] }
        var position: [UUID: Int] = [:]
        for (i, id) in trackIDs.enumerated() where position[id] == nil { position[id] = i }
        var byOffset: [Int: PlaylistSide] = [:]
        for side in sides {
            if let start = side.start {
                if let at = position[start] { byOffset[at] = side }
            } else {
                byOffset[0] = side
            }
        }
        guard byOffset.count > 1 else { return [] }
        return byOffset.sorted { $0.key < $1.key }.enumerated().map { i, entry in
            guard i == 0 else { return (entry.key, entry.value) }
            // Side A always starts at the top.
            return (0, PlaylistSide(start: nil, name: entry.value.name))
        }
    }

    /// Side number (0 is A) for each song. Empty when there are no sides.
    public func sideNumbers() -> [UUID: Int] {
        let layout = sideLayout
        guard !layout.isEmpty else { return [:] }
        var result: [UUID: Int] = [:]
        var side = 0
        for (i, id) in trackIDs.enumerated() {
            while side + 1 < layout.count, layout[side + 1].offset <= i { side += 1 }
            if result[id] == nil { result[id] = side }
        }
        return result
    }

    /// Starts a new side at `trackID`. The first song and existing starts already are one.
    public mutating func startSide(at trackID: UUID) {
        guard let at = trackIDs.firstIndex(of: trackID), at > 0 else { return }
        var next = sideLayout.map(\.side)
        guard !next.contains(where: { $0.start == trackID }) else { return }
        if next.isEmpty { next = [PlaylistSide(start: nil)] }
        next.append(PlaylistSide(start: trackID))
        sides = next
        sides = sideLayout.map(\.side)
        touch()
    }

    /// Folds the side starting at `trackID` into the one before it.
    public mutating func removeSide(startingAt trackID: UUID) {
        var next = sideLayout.map(\.side)
        guard next.contains(where: { $0.start == trackID }) else { return }
        next.removeAll { $0.start == trackID }
        sides = next
        sides = sideLayout.map(\.side)
        touch()
    }

    /// `start` is nil for Side A. An empty name shows just the letter.
    public mutating func renameSide(startingAt start: UUID?, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = sideLayout.map(\.side)
        guard let i = next.firstIndex(where: { $0.start == start }), next[i].name != name else { return }
        next[i].name = name
        sides = next
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
