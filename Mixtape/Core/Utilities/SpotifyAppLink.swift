// Opens a Spotify link in the app if installed (via `spotify:`), otherwise
// the browser. The web link is what we store and share.

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum SpotifyAppLink {

    /// The `spotify:` URI for an `open.spotify.com` link, if it's a supported kind.
    public static func appURL(for web: URL) -> URL? {
        guard web.host?.hasSuffix("spotify.com") == true else { return nil }
        // /{kind}/{id}, including localized /intl-xx/ paths.
        let parts = web.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard parts.count >= 2 else { return nil }
        // /collection/tracks (Liked Songs) maps to `spotify:collection:tracks`.
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
        // `open` returns false when nothing handles the scheme.
        if !NSWorkspace.shared.open(app) { openInBrowser(web) }
        #else
        // The completion says whether it opened, without declaring the scheme in Info.plist for `canOpenURL`.
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
