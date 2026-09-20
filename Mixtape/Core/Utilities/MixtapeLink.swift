// MixtapeLink.swift
// Mixtape — Core/Utilities
//
// The links every Share hands out. They open the web player at mixtaped.tech,
// which renders a preview card for anyone, signed in or not (mixtape-web
// src/pages/{track,album,artist,playlist}).
//
// Library songs never had a Deezer id, so their links carry names instead and
// the site resolves them — which is why no link here needs a request to build.
// Playlists are the exception: see `PlaylistSharingService.linkShareID`.

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

    public static func playlist(_ sharedID: UUID) -> URL {
        path("playlist", sharedID.uuidString.lowercased())
    }

    /// A page on the site. `focus` is a row's `data-key` on /account, which the
    /// page scrolls to and highlights — it survives the sign-in redirect.
    public static func web(_ page: String, focus: String? = nil) -> URL {
        URL(string: "\(base)/\(page)" + (focus.map { "?focus=\($0)" } ?? ""))!
    }

    // MARK: -

    private static func path(_ kind: String, _ id: String) -> URL {
        URL(string: "\(base)/\(kind)/\(id)")!
    }

    /// Unreserved characters only: `URLComponents` leaves `+` bare, and the
    /// site's URLSearchParams reads a bare `+` as a space ("Mumford + Sons").
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
