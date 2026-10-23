// Settings helpers: storage breakdown, open at login, and reset to defaults.

import Foundation
import SwiftUI
import Combine
#if os(macOS)
import ServiceManagement
#endif
import OSLog
import Observation

// MARK: - Storage report

/// What Mixtape uses on this device, by bucket, so caches can be measured and cleared separately.
nonisolated struct SettingsStorageReport: Equatable {
    /// Downloaded songs. Deleting these costs offline playback.
    var offline:  Int64 = 0
    /// Every song cached on disk for faster starts, library or Discover.
    var playback: Int64 = 0
    /// Artwork and lyrics held on disk by the URL cache. Disposable.
    var images:   Int64 = 0

    var total: Int64 { offline + playback + images }

    static let empty = SettingsStorageReport()

    /// Measures every bucket off the main thread. `OfflineStore` is main-actor bound, so
    /// its total is passed in.
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

    /// Shallow: every directory here is flat.
    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        return contents.reduce(into: Int64(0)) { total, file in
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// "1.2 GB", or "None" for an empty bucket.
    static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "None" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Open at login (macOS)

#if os(macOS)
/// Wraps `SMAppService` as a `Bool`. Registration can fail (unsigned build, denied in
/// System Settings), so the value is re-read after every write.
@Observable
@MainActor
final class LaunchAtLogin {

    static let shared = LaunchAtLogin()

    private(set) var isEnabled: Bool
    /// Set when the last attempt failed, for display next to the switch.
    private(set) var failure: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Binding for the toggle: writes through to the login-item registration.
    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.set($0) })
    }

    private func set(_ enabled: Bool) {
        // Show the change now; the re-read corrects it.
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
            MixLog.launch.error("[LaunchAtLogin] Couldn't \(enabled ? "register" : "unregister"): \(error)")
        }

        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// It can change in System Settings while the app runs.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
#endif

// MARK: - Reset

enum SettingsReset {

    /// Keys not owned by a live object, so clearing the value is enough.
    private static let standaloneKeys = [
        "theme.appearance",
        "theme.density",
        "theme.motion",
        "theme.chrome",
        "theme.backdrop",
        "haptics.enabled",
        "mix.stats.shared",
        "updates.receiveDevelopmentBuilds",
        "mac.menuBarPlayer",
        HardwareAcceleration.key,
    ]

    /// Per-account preferences (`key` or `key_<uuid>`), cleared by prefix.
    private static let accountScopedPrefixes = [
        "mix.downloadOnWifiOnly",
        "mix.syncMetadataToDisk",
        "mix.keepFileCopyOnDownload",
        "mix.downloadQuality",
        "mix.editQuality",
        "mix.autoAdjustQuality",
        "mix.autoDownloadImportedPlaylists",
        "mix.eq.",
        "playback.rate",
        "playback.crossfadeMode",
        "playback.crossfadeDuration",
        "playback.crossfadeOnSkip",
        "playback.normalizeVolume",
        "playback.trimPadding",
        "playback.autoplay",
    ]

    /// Restores every preference to its default and updates live objects without a relaunch.
    /// Leaves the account, music, `mix.deviceID`, Last.fm credentials, the resolver override
    /// and auth/playback state alone.
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

        // These objects hold old values in memory and some re-persist, so reset each to its init default.
        theme.appearance = .dark
        theme.preset     = .normal
        theme.backdrop   = nil
        theme.removeWallpaper()

        deps.downloadManager.downloadQuality        = .normal
        deps.downloadManager.editQuality            = .normal
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

        MixLog.library.debug("[Settings] All preferences restored to defaults")
    }
}
