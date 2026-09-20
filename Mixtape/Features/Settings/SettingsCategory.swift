// SettingsCategory.swift
// Mixtape — Features/Settings
//
// The map of Settings: what the categories are, and every setting inside them
// that search can find.
//
// Splitting one 60-row scroll into pages makes each page readable and every
// setting one level deeper. The index below is what pays that back — it's the
// reason "quality" still lands you on Download Quality without knowing it lives
// under Downloads. Keeping it in the same file as the categories is deliberate:
// an entry that drifts from the row it points at is worse than no entry, so the
// two live where you can't edit one without seeing the other.

import SwiftUI
import Combine

// MARK: - Deep links

/// A request to open Settings somewhere specific.
///
/// The menus that used to present the Spotify importer as a sheet now point at
/// the page in Settings that owns it, and "open Settings, on Connections, with
/// the library picker up" is three things to say across two platforms whose
/// Settings shells share no navigation state. One tiny observable is cheaper
/// than threading a target through both.
@MainActor
final class SettingsRoute: ObservableObject {

    static let shared = SettingsRoute()

    /// Bumped on every request, so asking for the same page twice still moves.
    @Published private(set) var request: Request?

    struct Request: Equatable {
        let category: SettingsCategory
        /// Set for the one destination that isn't just a pane.
        var opensSpotifyLibrary: Bool = false
        /// Distinguishes two identical asks.
        let token = UUID()

        static func == (a: Request, b: Request) -> Bool { a.token == b.token }
    }

    func open(_ category: SettingsCategory) {
        request = Request(category: category)
    }

    func openSpotifyLibrary() {
        request = Request(category: .connections, opensSpotifyLibrary: true)
    }

    /// Called by whoever acted on it, so a later re-render doesn't act again.
    func consume() { request = nil }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case account
    case general
    case playback
    case downloads
    case storage
    case sync
    case connections
    case about
    case developer
    /// Last on purpose: everything that loses something for good, and nothing else.
    case dangerZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account:     return "Account"
        case .general:     return "General"
        case .playback:    return "Playback"
        case .downloads:   return "Downloads"
        case .storage:     return "Storage"
        case .sync:        return "Sync"
        case .connections: return "Connections"
        case .about:       return "About"
        case .developer:   return "Developer"
        case .dangerZone:  return "Danger Zone"
        }
    }

    /// One line in the root list, so a category can be chosen without opening it.
    var summary: String {
        switch self {
        case .account:     return "Profile, privacy, sign out"
        case .general:     return "Appearance and app behaviour"
        case .playback:    return "Equalizer, crossfade, speed"
        case .downloads:   return "Quality, network, file copies"
        case .storage:     return "What Mixtape is using on this device"
        case .sync:        return "Keep every device up to date"
        case .connections: return "Spotify, Last.fm and streaming"
        case .about:       return "Version and updates"
        case .developer:   return "Maintenance tools, developer accounts only"
        case .dangerZone:  return "Reset, erase, delete account"
        }
    }

    var icon: String {
        switch self {
        case .account:     return "person.crop.circle.fill"
        case .general:     return "gearshape.fill"
        case .playback:    return "play.circle.fill"
        case .downloads:   return "arrow.down.circle.fill"
        case .storage:     return "internaldrive.fill"
        case .sync:        return "arrow.triangle.2.circlepath"
        case .connections: return "link.circle.fill"
        case .about:       return "info.circle.fill"
        case .developer:   return "hammer.fill"
        case .dangerZone:  return "exclamationmark.triangle.fill"
        }
    }

    /// Colour is only used at this level — inside a page the glyphs go quiet.
    /// Distinct hues here are what let you find "the orange one" without reading.
    var tint: Color {
        switch self {
        case .account:     return Color(hex: "#5B8DEF")
        case .general:     return Color(hex: "#8E8E93")
        case .playback:    return .mixPrimary
        case .downloads:   return Color(hex: "#34C759")
        case .storage:     return Color(hex: "#AF7AE5")
        case .sync:        return Color(hex: "#32ADE6")
        case .connections: return Color(hex: "#D9435E")
        case .about:       return Color(hex: "#8E8E93")
        case .developer:   return Color(hex: "#F59E0B")
        case .dangerZone:  return .mixDestructive
        }
    }

    /// The categories to show. `developer` is hidden unless the signed-in
    /// account carries the role, and `account` unless someone is signed in.
    static func visible(isSignedIn: Bool, isDeveloper: Bool) -> [SettingsCategory] {
        allCases.filter { category in
            switch category {
            case .account, .dangerZone: return isSignedIn
            case .developer: return isDeveloper
            default:         return true
            }
        }
    }
}

// MARK: - Search

/// One findable setting: where it lives, and what someone might call it.
struct SettingsSearchEntry: Identifiable, Hashable {
    /// Matches the `id` on the row itself, so a hit can highlight its target.
    let id: String
    let title: String
    let category: SettingsCategory
    /// Words that should find this row but don't appear in its title. The
    /// vocabulary someone searches with is rarely the label we chose — "bitrate"
    /// for Download Quality, "dark mode" for Appearance.
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        if category.title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.contains(needle) }
    }
}

enum SettingsSearchIndex {

    /// Every row worth finding. Rows that are pure display (version numbers,
    /// status badges) are indexed too — people search for those most of all.
    static let all: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [

            // Account
            .init(id: "account.myProfile", title: "My Profile", category: .account,
                  keywords: ["public", "profile page", "what others see", "playlists", "visible"]),
            .init(id: "account.findPeople", title: "Find People", category: .account,
                  keywords: ["friends", "follow", "search users", "social"]),
            .init(id: "account.manage", title: "Manage Account", category: .account,
                  keywords: ["email", "password", "profile", "avatar", "display name", "username"]),
            .init(id: "account.web", title: "Account Overview", category: .account,
                  keywords: ["website", "browser", "web", "mixtaped.tech", "devices", "sessions"]),
            .init(id: "account.export", title: "Download Your Data", category: .account,
                  keywords: ["export", "gdpr", "backup", "copy", "json", "takeout"]),
            .init(id: "account.privacy", title: "Privacy Policy", category: .account,
                  keywords: ["gdpr", "data", "personal information", "rights"]),
            .init(id: "account.activity", title: "Show My Listening Activity", category: .account,
                  keywords: ["privacy", "share", "stats", "friends", "public", "hide"]),
            .init(id: "account.signOut", title: "Sign Out", category: .account,
                  keywords: ["log out", "logout", "leave"]),

            // General
            .init(id: "general.appearance", title: "Appearance", category: .general,
                  keywords: ["dark mode", "light mode", "theme", "system", "colour", "color"]),

            // Playback
            .init(id: "playback.equalizer", title: "Equalizer", category: .playback,
                  keywords: ["eq", "bass", "treble", "presets", "tone"]),
            .init(id: "playback.crossfade", title: "Crossfade", category: .playback,
                  keywords: ["gapless", "transition", "blend", "mix", "fade"]),
            .init(id: "playback.crossfadeLength", title: "Crossfade Length", category: .playback,
                  keywords: ["seconds", "duration", "overlap"]),
            .init(id: "playback.speed", title: "Playback Speed", category: .playback,
                  keywords: ["rate", "tempo", "faster", "slower", "pitch"]),
            .init(id: "playback.preferCensored", title: "Prefer Censored Versions", category: .playback,
                  keywords: ["clean", "censored", "explicit", "radio edit", "swearing",
                             "bleeped", "uncensored", "family friendly"]),

            .init(id: "general.preset", title: "Look", category: .general,
                  keywords: ["preset", "normal", "minimal", "efficient", "compact",
                             "simple", "theme", "style", "performance", "low power"]),
            .init(id: "general.density", title: "Layout Density", category: .general,
                  keywords: ["compact", "comfortable", "size", "smaller", "tighter",
                             "row height", "spacing", "minimal"]),
            .init(id: "general.motion", title: "Animation", category: .general,
                  keywords: ["motion", "reduce motion", "animations", "still",
                             "cpu", "performance", "battery", "snappy"]),
            .init(id: "general.chrome", title: "Visual Effects", category: .general,
                  keywords: ["blur", "shadows", "gradient", "wash", "artwork colour",
                             "flat", "glossy", "transparency", "material"]),
            .init(id: "general.allSongs", title: "Show All Songs", category: .general,
                  keywords: ["all songs", "library", "sidebar", "everything",
                             "every song", "hide", "liked songs"]),

            // Downloads
            .init(id: "downloads.quality", title: "Download Quality", category: .downloads,
                  keywords: ["bitrate", "aac", "size", "compression", "audio quality", "high", "low"]),
            .init(id: "downloads.autoAdjust", title: "Lower Quality on Mobile Data", category: .downloads,
                  keywords: ["cellular", "mobile data", "metered", "network",
                             "auto adjust", "automatic quality", "bitrate", "roaming"]),
            .init(id: "downloads.autoImported", title: "Keep Imported Playlists Offline", category: .downloads,
                  keywords: ["automatic", "auto download", "import", "imported",
                             "offline", "always download", "new playlists", "saved"]),
            .init(id: "downloads.wifiOnly", title: "Download on Wi-Fi Only", category: .downloads,
                  keywords: ["cellular", "mobile data", "network", "roaming"]),
            .init(id: "downloads.queueDepth", title: "Download Ahead in the Queue", category: .downloads,
                  keywords: ["queue", "preload", "prefetch", "buffer", "gapless",
                             "smooth", "background", "next song", "ahead", "cache"]),
            .init(id: "downloads.browsePrefetch", title: "Fetch While Browsing", category: .downloads,
                  keywords: ["hover", "prefetch", "preload", "instant", "browsing",
                             "data", "cache", "background"]),
            .init(id: "downloads.redownload", title: "Re-download at This Quality", category: .downloads,
                  keywords: ["convert", "re-encode", "shrink", "reclaim"]),
            .init(id: "downloads.fileCopy", title: "Also Keep a File Copy", category: .downloads,
                  keywords: ["export", "mp3", "folder", "finder", "files app"]),
            .init(id: "downloads.metadataSync", title: "Update Files When Metadata Changes", category: .downloads,
                  keywords: ["tags", "id3", "rename", "artwork"]),
            .init(id: "localFiles.addFolder", title: "Add Folder", category: .downloads,
                  keywords: ["local files", "watched", "watch folder", "folder", "import",
                             "my music", "itunes", "library folder", "scan", "add music"]),
            .init(id: "localFiles.count", title: "Songs Found", category: .downloads,
                  keywords: ["local files", "watched folder", "count", "found"]),
            .init(id: "localFiles.rescan", title: "Rescan Now", category: .downloads,
                  keywords: ["local files", "rescan", "refresh", "scan", "watched folder"]),
            .init(id: "downloads.exportLocation", title: "Export Location", category: .downloads,
                  keywords: ["folder", "path", "where", "save", "directory", "music folder"]),

            // Storage
            .init(id: "storage.offline", title: "Offline Downloads", category: .storage,
                  keywords: ["space", "disk", "size", "gb", "mb", "usage"]),
            .init(id: "storage.discover", title: "Discover Cache", category: .storage,
                  keywords: ["temporary", "streaming", "clear", "space"]),
            .init(id: "storage.playback", title: "Playback Cache", category: .storage,
                  keywords: ["temporary", "clear", "space", "streamed"]),
            .init(id: "storage.images", title: "Images & Lyrics", category: .storage,
                  keywords: ["artwork", "covers", "photos", "cache", "clear"]),
            .init(id: "storage.removeAll", title: "Remove All Downloads", category: .storage,
                  keywords: ["delete", "free space", "clear offline"]),
            .init(id: "storage.mergeDuplicates", title: "Merge Duplicate Songs", category: .storage,
                  keywords: ["duplicate", "duplicates", "double", "doubled", "twice",
                             "same song", "copies", "repeated", "import", "merge", "clean up"]),

            .init(id: "storage.userLyrics", title: "Your Lyrics", category: .storage,
                  keywords: ["lyrics", "lrc", "words", "custom", "own", "added",
                             "import lyrics", "upload lyrics", "synced lyrics"]),

            // Sync
            .init(id: "sync.status", title: "Sync Status", category: .sync,
                  keywords: ["pending", "up to date", "cloud", "server"]),
            .init(id: "sync.now", title: "Sync Now", category: .sync,
                  keywords: ["refresh", "update", "pull", "push"]),
            .init(id: "sync.full", title: "Re-sync Everything", category: .sync,
                  keywords: ["full", "repair", "missing", "playlist", "restore", "rebuild"]),
            .init(id: "sync.covers", title: "Find Missing Covers", category: .sync,
                  keywords: ["artwork", "art", "album cover", "blank", "grey", "missing", "image"]),
            .init(id: "sync.coverQuality", title: "Upgrade Cover Quality", category: .sync,
                  keywords: ["artwork", "blurry", "pixelated", "low quality", "resolution",
                             "cover", "image", "sharp"]),
            .init(id: "sync.restore", title: "Restore Missing Songs", category: .sync,
                  keywords: ["missing", "disappeared", "gone", "vanished", "deleted",
                             "recover", "restore", "playlist count", "fewer songs"]),

            // Connections
            .init(id: "connections.spotify", title: "Spotify Account", category: .connections,
                  keywords: ["spotify", "connect", "sign in", "link", "account", "premium"]),
            .init(id: "connections.spotifyLibrary", title: "Import Spotify Library", category: .connections,
                  keywords: ["spotify", "import", "migrate", "playlists", "liked songs",
                             "saved songs", "albums", "transfer", "move", "bring over"]),
            .init(id: "connections.spotifyLink", title: "Import a Spotify Playlist Link", category: .connections,
                  keywords: ["spotify", "playlist", "link", "url", "paste", "import"]),
            .init(id: "connections.lastfm", title: "Last.fm Account", category: .connections,
                  keywords: ["scrobble", "api key", "connect", "username"]),
            .init(id: "connections.scrobble", title: "Scrobble What I Play", category: .connections,
                  keywords: ["last.fm", "track", "history"]),

            // About
            .init(id: "about.version", title: "Version", category: .about,
                  keywords: ["build", "release", "what version"]),
            .init(id: "about.changelog", title: "What's New", category: .about,
                  keywords: ["changelog", "release notes", "updates"]),
            .init(id: "about.help", title: "Help", category: .about,
                  keywords: ["support", "faq", "guide", "shortcuts"]),
            .init(id: "about.terms", title: "Terms of Service", category: .about,
                  keywords: ["terms", "legal", "conditions", "tos"]),

            // Danger Zone — indexed because "top artists are wrong" is a thing you
            // search for, not something you'd think to look for under a warning sign.
            .init(id: "danger.resetSettings", title: "Reset All Settings", category: .dangerZone,
                  keywords: ["defaults", "restore", "factory", "start over"]),
            .init(id: "danger.removeLyrics", title: "Remove All Your Lyrics", category: .dangerZone,
                  keywords: ["lyrics", "lrc", "delete", "clear", "custom"]),
            .init(id: "danger.resetHistory", title: "Reset Listening History", category: .dangerZone,
                  keywords: ["top artists", "listening history", "plays", "minutes",
                             "stats", "wrong artists", "stale", "profile", "clear"]),
            .init(id: "danger.deletePlaylists", title: "Delete All Playlists", category: .dangerZone,
                  keywords: ["remove", "wipe", "playlists", "clear"]),
            .init(id: "danger.deleteMusic", title: "Delete All Music", category: .dangerZone,
                  keywords: ["remove", "wipe", "songs", "tracks", "albums", "artists", "clear"]),
            .init(id: "danger.clearEverything", title: "Clear Everything", category: .dangerZone,
                  keywords: ["delete all", "wipe", "reset", "start over", "nuke",
                             "playlists", "songs", "artists", "liked songs", "favourites", "favorites"]),
            .init(id: "danger.signOutEverywhere", title: "Sign Out Everywhere", category: .dangerZone,
                  keywords: ["log out", "all devices", "sessions", "stolen", "lost", "security"]),
            .init(id: "danger.deleteAccount", title: "Delete Account", category: .dangerZone,
                  keywords: ["remove", "erase", "close account", "gdpr", "delete my account"]),
        ]

        #if os(iOS)
        entries += [
            .init(id: "general.haptics", title: "Haptic Feedback", category: .general,
                  keywords: ["vibration", "taptic", "buzz"]),
            .init(id: "connections.streaming", title: "Streaming Server", category: .connections,
                  keywords: ["resolver", "discover", "connection", "test", "online"]),
        ]
        #endif

        #if os(macOS)
        entries += [
            .init(id: "general.launchAtLogin", title: "Open at Login", category: .general,
                  keywords: ["startup", "start up", "boot", "automatically", "launch"]),
            .init(id: "about.betaChannel", title: "Receive Development Builds", category: .about,
                  keywords: ["beta", "updates", "early", "channel", "prerelease"]),
        ]
        #endif

        return entries
    }()

    /// Hits for `query`, best-first. An exact prefix on the title is what people
    /// usually mean, so those come before a match buried in a keyword list.
    static func results(for query: String,
                        isSignedIn: Bool,
                        isDeveloper: Bool) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let visible = Set(SettingsCategory.visible(isSignedIn: isSignedIn, isDeveloper: isDeveloper))
        let needle  = trimmed.lowercased()

        return all
            .filter { visible.contains($0.category) && $0.matches(trimmed) }
            .sorted { a, b in
                let aPrefix = a.title.lowercased().hasPrefix(needle)
                let bPrefix = b.title.lowercased().hasPrefix(needle)
                if aPrefix != bPrefix { return aPrefix }
                return a.title < b.title
            }
    }
}
