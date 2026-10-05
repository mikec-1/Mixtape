// Shared by the app and widget extension: the song snapshot the widgets and
// Live Activity draw, and the intents their buttons run.

import Foundation
import AppIntents
#if os(iOS)
import ActivityKit
import Security
#endif

/// The widget and Live Activity buttons. An `AudioPlaybackIntent` pressed in a
/// widget runs in the app's process, so `perform` only ever runs there; the
/// extension compiles it for the type alone.
nonisolated struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play or Pause" }
    static var description: IntentDescription { "Pauses Mixtape, or carries on where it stopped." }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        MixtapeIntents.deps?.playbackEngine.togglePlayPause()
        await MixtapeIntents.refreshWidgets()
        #endif
        return .result()
    }
}

nonisolated struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Next Song" }
    static var description: IntentDescription { "Skips to the next song in Mixtape." }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MixtapeIntents.deps?.playbackEngine.playNext()
        await MixtapeIntents.refreshWidgets()
        #endif
        return .result()
    }
}

nonisolated struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Previous Song" }
    static var description: IntentDescription { "Goes back a song in Mixtape." }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MixtapeIntents.deps?.playbackEngine.playPrevious()
        await MixtapeIntents.refreshWidgets()
        #endif
        return .result()
    }
}

#if os(iOS)
/// The large widget's heart. A `LiveActivityIntent` so it runs in the app's
/// process; a plain intent would run in the extension, which can't reach the library.
nonisolated struct ToggleLikeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Like Song" }
    static var description: IntentDescription { "Adds the playing song to Liked Songs, or takes it out." }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let engine = MixtapeIntents.deps?.playbackEngine, let track = engine.queue.currentTrack {
            await engine.onRemoteLike?(track)
            engine.syncRemoteCommandState()
        }
        await MixtapeIntents.refreshWidgets()
        #endif
        return .result()
    }
}

nonisolated struct ToggleShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Shuffle" }
    static var description: IntentDescription { "Turns shuffle on or off in Mixtape." }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        MixtapeIntents.deps?.playbackEngine.queue.toggleShuffle()
        await MixtapeIntents.refreshWidgets()
        #endif
        return .result()
    }
}

/// The song the widgets draw: the app writes it, the extension reads it.
///
/// Stored in a shared keychain group since a personal team can't register an App
/// Group. The team prefix is hardcoded; an extension can't look it up.
nonisolated struct NowPlayingSnapshot: Codable, Sendable {
    struct Song: Codable, Sendable {
        var title: String
        var artist: String
        var artwork: Data?          // thumbnail, see NowPlayingSurfaces
    }

    var title: String
    var artist: String
    var album = ""
    var source: String?             // "Playing from ..."
    var isPlaying: Bool
    var isLiked = false
    var shuffle = false
    var artwork: Data?              // small JPEG, see NowPlayingSurfaces
    var tint: [Double] = []         // r, g, b from the artwork; empty for none
    var upNext: [Song] = []
    var elapsed: TimeInterval
    var duration: TimeInterval
    var at: Date                    // when `elapsed` was read

    /// When the song would have started had it played straight through, which
    /// is what a self-running progress bar needs.
    var startedAt: Date { at.addingTimeInterval(-elapsed) }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.mikey.Mixtape.nowPlaying",
         kSecAttrAccount as String: "snapshot",
         kSecAttrAccessGroup as String: "AG9N987UCK.com.mikey.Mixtape.shared"]
    }

    static func load() -> NowPlayingSnapshot? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let query = Self.item as CFDictionary
        if SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = Self.item
            add[kSecValueData as String] = data
            // Lock Screen widgets draw while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

nonisolated struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var startedAt: Date
        var tint: [Double]          // r, g, b from the artwork; empty for none
        /// The cover is read from the snapshot when the activity draws, so a
        /// cover arriving late has to change the state or nothing redraws.
        var hasArtwork: Bool
    }
}
#endif
