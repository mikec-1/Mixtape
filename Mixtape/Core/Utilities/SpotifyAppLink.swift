// SpotifyAppLink.swift
// Mixtape — Core/Utilities
//
// Opens something on Spotify in the Spotify app when it's installed, and in the
// browser when it isn't.
//
// Spotify publishes both: `https://open.spotify.com/playlist/{id}` and
// `spotify:playlist:{id}`. The web link works everywhere, which is why it's what
// gets stored and shared — but following it lands the user in a web player that
// asks them to log in again, next to the desktop app they are already logged
// into. The custom scheme goes straight to the app and does nothing at all when
// the app isn't there, so it's tried first and the web link is the fallback.

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum SpotifyAppLink {

    /// The `spotify:` URI for an `open.spotify.com` link, when it names one of
    /// the kinds Spotify's scheme understands.
    public static func appURL(for web: URL) -> URL? {
        guard web.host?.hasSuffix("spotify.com") == true else { return nil }
        // /playlist/{id}, /track/{id}, /album/{id}, /artist/{id} — and the
        // localized form, /intl-de/playlist/{id}.
        let parts = web.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard parts.count >= 2 else { return nil }
        // The library's own lists are addressed by name rather than by id:
        // /collection/tracks is Liked Songs, and `spotify:collection:tracks`
        // opens it in the app. Same shape, so it needs no special parsing —
        // only permission to be one of the kinds.
        let kinds: Set<String> = ["playlist", "track", "album", "artist", "user",
                                  "show", "episode", "collection"]
        guard kinds.contains(parts[0]) else { return nil }
        let id = parts[1].components(separatedBy: "?").first ?? parts[1]
        return URL(string: "spotify:\(parts[0]):\(id)")
    }

    /// Opens the app if it's installed, the web link otherwise.
    public static func open(_ web: URL) {
        guard let app = appURL(for: web) else { openInBrowser(web); return }
        #if os(macOS)
        // `open` returns false when nothing is registered for the scheme, which
        // is the whole test — no need to ask about installed applications.
        if !NSWorkspace.shared.open(app) { openInBrowser(web) }
        #else
        // iOS answers asynchronously. Asking `canOpenURL` first would need the
        // scheme declared in Info.plist; the completion handler says the same
        // thing without that.
        UIApplication.shared.open(app, options: [:]) { opened in
            if !opened { openInBrowser(web) }
        }
        #endif
    }

    private static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
