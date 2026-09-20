// SettingsSystem.swift
// Mixtape — Features/Settings
//
// The three pieces of behaviour the redesigned Settings needed that didn't
// exist yet: a measured storage breakdown, "open at login", and a way back to
// defaults.

import Foundation
import SwiftUI
import Combine
#if os(macOS)
import ServiceManagement
#endif

// MARK: - Storage report

/// What Mixtape is using on this device, split by what each part costs you to
/// lose.
///
/// The old Settings showed one number — "16 songs · 50.3 MB" — which is the
/// least interesting of the four: it's the only bucket the user chose to fill.
/// The caches are where space goes missing without anyone asking, so they're
/// measured separately and cleared separately.
struct SettingsStorageReport: Equatable {
    /// Downloaded songs. Deleting these costs offline playback.
    var offline:  Int64 = 0
    /// Every song kept on disk so it starts faster next time — from the user's
    /// own library or from Discover. One number, because they're one cache: two
    /// rows here described a split the user never made and couldn't see, and on
    /// the Mac that authored the library one of them was always zero.
    var playback: Int64 = 0
    /// Artwork and lyrics held on disk by the URL cache. Disposable.
    var images:   Int64 = 0

    var total: Int64 { offline + playback + images }

    static let empty = SettingsStorageReport()

    /// Measures every bucket off the main thread.
    ///
    /// Only the download total is handed in: `OfflineStore` is main-actor bound
    /// and already holds the listing. Everything else is reachable from any
    /// thread, and walking a directory of a few thousand files is exactly the
    /// work that shouldn't happen on the main one.
    static func measure(offlineBytes: Int64) async -> SettingsStorageReport {

        let diskUsage = Int64(URLCache.shared.currentDiskUsage)

        return await Task.detached(priority: .utility) {
            SettingsStorageReport(
                offline:  offlineBytes,
                playback: PlaybackCache.totalBytes + directorySize(AudioPaths.legacyDocumentsDirectory),
                images:   diskUsage
            )
        }.value
    }

    /// Total size of the files directly inside `url`. Shallow on purpose — every
    /// directory measured here is flat, and a deep enumeration of a cache that's
    /// being written to concurrently is a good way to stall on nothing.
    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        return contents.reduce(into: Int64(0)) { total, file in
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// "1.2 GB", or "None" for an empty bucket — a row reading "Zero KB" looks
    /// like a measurement that failed.
    static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "None" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Open at login (macOS)

#if os(macOS)
/// Wraps `SMAppService` so the toggle can be a plain `Bool` binding.
///
/// Registration genuinely fails in some situations — an unsigned build, an app
/// running from a quarantined copy, a user who denied it in System Settings —
/// so the published value is re-read from the service after every write rather
/// than assumed. A switch that flips back is honest; one that lies isn't.
@MainActor
final class LaunchAtLogin: ObservableObject {

    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool
    /// Set when the last attempt failed, for display next to the switch.
    @Published private(set) var failure: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Binding for the toggle: writes through to the login-item registration.
    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.set($0) })
    }

    private func set(_ enabled: Bool) {
        // Show the intent immediately; the re-read below corrects it if the
        // system disagrees.
        isEnabled = enabled
        failure   = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
            print("[LaunchAtLogin] ⚠️ Couldn't \(enabled ? "register" : "unregister"): \(error)")
        }

        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the system state — it can change in System Settings while the
    /// app is running.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
#endif

// MARK: - Reset

enum SettingsReset {

    /// Preference keys that aren't owned by a live object, so clearing the
    /// stored value is the whole job.
    private static let standaloneKeys = [
        "theme.appearance",
        "theme.density",
        "theme.motion",
        "theme.chrome",
        "haptics.enabled",
        "mix.stats.shared",
        "updates.receiveDevelopmentBuilds",
    ]

    /// Per-account preferences, stored as `key` for a signed-out user and
    /// `key_<uuid>` once signed in. Cleared by prefix so switching accounts
    /// later doesn't resurrect an old setting.
    private static let accountScopedPrefixes = [
        "mix.downloadOnWifiOnly",
        "mix.syncMetadataToDisk",
        "mix.keepFileCopyOnDownload",
        "mix.downloadQuality",
        "mix.autoAdjustQuality",
        "mix.autoDownloadImportedPlaylists",
        "mix.eq.",
        "playback.rate",
        "playback.crossfadeMode",
        "playback.crossfadeDuration",
    ]

    /// Everything this deliberately leaves alone. Kept as a list because the
    /// interesting part of "reset all settings" is what it *doesn't* touch:
    /// your account, your music, and the identifiers that make sync work.
    ///
    /// - `mix.deviceID` — resetting it makes this device look new to sync.
    /// - Last.fm credentials — a connected account, not a preference. Reset
    ///   would silently disconnect it and the API key would have to be found
    ///   and pasted again.
    /// - The resolver override — developer-only, and not reachable from the
    ///   button that calls this.
    /// - Auth session and playback position — not preferences at all.

    /// Restores every preference to its default and updates the live objects so
    /// the change is visible without a relaunch.
    @MainActor
    static func restoreDefaults(deps: AppDependencies, theme: ThemeManager) {
        let defaults = UserDefaults.standard

        for key in standaloneKeys {
            defaults.removeObject(forKey: key)
        }

        for key in defaults.dictionaryRepresentation().keys
        where accountScopedPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }

        // The objects above are still holding the old values in memory, and
        // several re-persist on write — so each is set back to the same default
        // its own initialiser would have chosen.
        theme.appearance = .dark
        theme.preset     = .normal

        deps.downloadManager.downloadQuality        = .normal
        deps.downloadManager.autoAdjustQuality      = true
        deps.downloadManager.downloadOnWifiOnly     = true
        deps.downloadManager.syncMetadataToDisk     = true
        deps.downloadManager.keepFileCopyOnDownload = false
        deps.downloadManager.autoDownloadImportedPlaylists = false

        deps.playbackEngine.setRate(1.0)
        deps.playbackEngine.setCrossfadeMode(.off)
        deps.playbackEngine.setCrossfadeDuration(6)

        deps.equalizer.isEnabled = false
        deps.equalizer.apply(.flat)

        #if os(macOS)
        if LaunchAtLogin.shared.isEnabled {
            LaunchAtLogin.shared.binding.wrappedValue = false
        }
        #endif

        print("[Settings] ✅ All preferences restored to defaults")
    }
}
