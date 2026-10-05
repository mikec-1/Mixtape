// Share links. They open the web player at mixtaped.tech, which renders a
// preview for anyone (mixtape-web src/pages/{track,album,artist,playlist}).
// Library songs use names instead of Deezer ids and the site resolves them.
// Playlists: see `PlaylistSharingService.linkShareID`.

import Foundation

public enum MixtapeLink {

    private static let base = "https://mixtaped.tech"

    public static func track(_ track: Track) -> URL {
        named("track", ["title": track.title, "artist": track.artistName])
    }

    public static func track(_ track: OnlineTrack) -> URL {
        guard let id = track.sourceID else {
            return named("track", ["title": track.title, "artist": track.artistName])
        }
        return path("track", String(id))
    }

    public static func album(_ album: OnlineAlbum) -> URL { path("album", String(album.id)) }

    public static func album(title: String, artist: String) -> URL {
        named("album", ["title": title, "artist": artist])
    }

    public static func artist(id: Int?, name: String) -> URL {
        id.map { path("artist", String($0)) } ?? named("artist", ["name": name])
    }

    /// Most items a crate link carries, so it stays a sane URL.
    public static let crateLimit = 50

    /// A whole crate, as base64url JSON in `d`: `{"n": name, "i": [["p", id], ["a", title, artist], ["r", name]]}`.
    public static func crate(name: String, items: [[String]]) -> URL {
        struct Payload: Encodable { let n: String; let i: [[String]] }
        let json = (try? JSONEncoder().encode(Payload(n: name, i: Array(items.prefix(crateLimit))))) ?? Data()
        let d = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(base)/crate?d=\(d)")!
    }

    public static func playlist(_ sharedID: UUID) -> URL {
        path("playlist", sharedID.uuidString.lowercased())
    }

    /// One monthly recap, by its random share token. Only opens for others once its owner shows it on their profile.
    public static func recap(shareID: String) -> URL { path("recap", shareID) }

    /// A community post, by its 12-character share code.
    public static func post(_ code: String) -> URL { path("post", code) }

    /// A site page. `focus` is a `data-key` on /account to scroll to and highlight.
    public static func web(_ page: String, focus: String? = nil) -> URL {
        URL(string: "\(base)/\(page)" + (focus.map { "?focus=\($0)" } ?? ""))!
    }

    // MARK: -

    private static func path(_ kind: String, _ id: String) -> URL {
        URL(string: "\(base)/\(kind)/\(id)")!
    }

    /// Unreserved only: URLSearchParams reads a bare `+` as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func named(_ kind: String, _ fields: KeyValuePairs<String, String>) -> URL {
        let query = fields.compactMap { key, value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            return "\(key)=\(encoded)"
        }
        return URL(string: "\(base)/\(kind)?\(query.joined(separator: "&"))")!
    }
}
