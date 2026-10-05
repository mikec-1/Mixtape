// A crate keeps playlists, albums and artists together. Items are references,
// never copies, so a crate follows the library. See `CrateService`.

import Foundation

public struct Crate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [CrateItem]
    public var dateCreated: Date
}

public struct CrateItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case playlist, album, artist }

    public var kind: Kind
    /// Playlist id, album title or artist name.
    public var key: String
    /// The album's artist. Nil for the other kinds.
    public var artist: String?

    public static func playlist(_ id: UUID) -> CrateItem {
        CrateItem(kind: .playlist, key: id.uuidString)
    }

    public static func album(title: String, artist: String) -> CrateItem {
        CrateItem(kind: .album, key: title, artist: artist)
    }

    public static func artist(_ name: String) -> CrateItem {
        CrateItem(kind: .artist, key: name)
    }

    /// Names match case-insensitively, like the library lookups.
    var identity: String {
        [kind.rawValue, key.lowercased(), (artist ?? "").lowercased()].joined(separator: "|")
    }
}

/// A crate item looked up in the library. Albums and artists that aren't held
/// still show, and open on Discover; a deleted playlist is dropped.
public enum CrateEntry: Identifiable {
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)
    case online(CrateItem)

    public var id: String { item.identity }

    public var title: String {
        switch self {
        case .playlist(let p): return p.name
        case .album(let a):    return a.title
        case .artist(let a):   return a.name
        case .online(let i):   return i.key
        }
    }

    public var item: CrateItem {
        switch self {
        case .playlist(let p): return .playlist(p.id)
        case .album(let a):    return .album(title: a.title, artist: a.artistName)
        case .artist(let a):   return .artist(a.name)
        case .online(let i):   return i
        }
    }
}
