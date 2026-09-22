// NowPlayingShared.swift
// Compiled into the app and the widget extension — the `Shared` folder belongs
// to both targets. What the widgets and the Live Activity know about the song,
// and the buttons they press.

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
        #endif
        return .result()
    }
}

#if os(iOS)
/// The song the widgets draw: the app writes it, the extension reads it.
///
/// Through the keychain because there is no App Group — a personal team can't
/// register one — and a shared keychain access group is the one store an app and
/// its extension can both reach without it. Both targets list the group in
/// their entitlements; the team prefix is spelled out because an extension
/// has no way to look it up.
nonisolated struct NowPlayingSnapshot: Codable, Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artwork: Data?              // small JPEG, see NowPlayingSurfaces
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
    }
}
#endif
