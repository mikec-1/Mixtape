// The Settings categories plus the search index for every setting in them.
// Kept in one file so an index entry can't drift from the row it points at.

import SwiftUI
import Combine
import Observation

// MARK: - Deep links

/// A request to open Settings somewhere specific, e.g. Connections with the Spotify
/// library picker up. Shared by both platforms' Settings shells.
@Observable
@MainActor
final class SettingsRoute {

    static let shared = SettingsRoute()

    /// The pane macOS shows. Here so the window's back/forward history can restore it (MacAppState).
    var category: SettingsCategory = .general { didSet { categoryChanges.send(category) } }
    /// Every set after launch, for Combine users.
    @ObservationIgnored let categoryChanges = PassthroughSubject<SettingsCategory, Never>()

    /// Bumped on every request, so asking for the same page twice still moves.
    private(set) var request: Request?

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

    /// Colour only at this level; inside a page the glyphs stay monochrome.
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

    /// `developer` needs the account role; `account` needs a signed-in user.
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
    /// Search terms not in the title, like "bitrate" for Download Quality.
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        if category.title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.contains(needle) }
    }
}

enum SettingsSearchIndex {

    /// Every row worth finding, display-only rows (version, status) included.
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
            .init(id: "account.analytics", title: "Help Improve Mixtape", category: .account,
                  keywords: ["analytics", "usage", "data", "privacy", "tracking", "improve"]),
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
            .init(id: "playback.crossfadeOnSkip", title: "Crossfade on Skip", category: .playback,
                  keywords: ["skip", "next", "mid song", "blend", "fade"]),
            .init(id: "playback.normalizeVolume", title: "Normalize Volume", category: .playback,
                  keywords: ["loudness", "level", "volume", "replaygain", "sound check", "quiet", "loud"]),
            .init(id: "playback.trimPadding", title: "Trim Trailing Silence", category: .playback,
                  keywords: ["silence", "dead air", "padding", "skip silence", "end"]),
            .init(id: "playback.autoplay", title: "Autoplay", category: .playback,
                  keywords: ["radio", "suggestions", "keep playing", "queue", "endless"]),
            .init(id: "playback.smartShuffle", title: "Smart Shuffle", category: .playback,
                  keywords: ["shuffle", "smart", "mix in", "random", "recommendations"]),
            .init(id: "playback.suggestionFeedback", title: "Show These Again", category: .playback,
                  keywords: ["hidden", "hide song", "blocked artist", "don't suggest", "unhide"]),
            .init(id: "playback.privateSession", title: "Private Session", category: .playback,
                  keywords: ["private", "incognito", "history", "stats", "hide"]),
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
            .init(id: "general.backdrop", title: "Background Colour", category: .general,
                  keywords: ["background", "colour", "color", "gradient", "tint", "custom",
                             "wallpaper", "floating", "moving", "aesthetic"]),
            .init(id: "general.wallpaper", title: "Wallpaper", category: .general,
                  keywords: ["wallpaper", "picture", "photo", "image", "background", "glass"]),
            .init(id: "general.allSongs", title: "Show All Songs", category: .general,
                  keywords: ["all songs", "library", "sidebar", "everything",
                             "every song", "hide", "liked songs"]),
            .init(id: "general.importsTo", title: "Add Imported Songs To", category: .general,
                  keywords: ["import", "imports", "imported", "liked songs", "all songs",
                             "files", "youtube", "spotify", "like", "heart"]),
            .init(id: "general.notifications", title: "Notifications", category: .general,
                  keywords: ["alerts", "banners", "push", "permission", "messages", "jam", "release"]),
            .init(id: "general.hardwareAcceleration", title: "Hardware Acceleration", category: .general,
                  keywords: ["gpu", "metal", "graphics", "compatibility", "flicker", "glitch",
                             "performance", "advanced", "stems"]),

            // Downloads
            .init(id: "downloads.quality", title: "Download Quality", category: .downloads,
                  keywords: ["bitrate", "aac", "size", "compression", "audio quality", "high", "low"]),
            .init(id: "downloads.editQuality", title: "Song Edit Quality", category: .downloads,
                  keywords: ["edit", "edits", "slowed", "reverb", "sped up", "bitrate", "aac",
                             "size", "storage", "audio quality"]),
            .init(id: "downloads.resaveEdits", title: "Re-save Edits at This Quality", category: .downloads,
                  keywords: ["edit", "edits", "re-save", "resave", "re-render", "quality", "storage"]),
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
            .init(id: "connections.spotifyHistory", title: "Add Spotify Listening to Recaps", category: .connections,
                  keywords: ["spotify", "history", "recently played", "recap", "listening", "stats"]),
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

            // Danger Zone is indexed: "top artists are wrong" is something people search for.
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
            .init(id: "general.liveActivity", title: "Live Activity", category: .general,
                  keywords: ["lock screen", "dynamic island", "widget", "now playing"]),
            .init(id: "connections.streaming", title: "Streaming Server", category: .connections,
                  keywords: ["resolver", "discover", "connection", "test", "online"]),
        ]
        #endif

        #if os(macOS)
        entries += [
            .init(id: "general.menuBarPlayer", title: "Show Mini Player in Menu Bar", category: .general,
                  keywords: ["menu bar", "status bar", "tray", "controls", "now playing"]),
            .init(id: "general.launchAtLogin", title: "Open at Login", category: .general,
                  keywords: ["startup", "start up", "boot", "automatically", "launch"]),
            .init(id: "about.betaChannel", title: "Receive Development Builds", category: .about,
                  keywords: ["beta", "updates", "early", "channel", "prerelease"]),
        ]
        #endif

        return entries
    }()

    /// Hits for `query`, best-first. Title prefix matches beat keyword matches.
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
