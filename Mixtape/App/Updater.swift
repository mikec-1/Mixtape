// Updater.swift
// Mixtape — App
//
// Sparkle auto-update integration (macOS only).
//
// Distribution is un-notarized, so update integrity is guaranteed by Sparkle's
// EdDSA signatures (SUPublicEDKey in Info.plist) rather than Apple notarization.
// The first manual install requires a one-time "Open Anyway" via System Settings
// → Privacy & Security (macOS 15+); every Sparkle update afterwards is seamless.

#if os(macOS)
import SwiftUI
import Combine
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// Created as a `@StateObject` on `MixtapeApp` so the updater starts with the app
/// and performs its scheduled background checks against `SUFeedURL`.
///
/// Also acts as the `SPUUpdaterDelegate` so it can opt the user into the `beta`
/// channel when "Receive development builds" is enabled in Settings.
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {

    /// UserDefaults key backing the "Receive development builds" toggle in Settings.
    /// Shared with `SettingsView` (`@AppStorage`) so both read/write the same flag.
    static let receiveDevelopmentBuildsKey = "updates.receiveDevelopmentBuilds"

    private(set) var updaterController: SPUStandardUpdaterController!

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable itself
    /// while a check is already in flight.
    @Published var canCheckForUpdates = false

    override init() {
        super.init()

        // startingUpdater: true → begins scheduled update checks immediately.
        // updaterDelegate: self → routes `allowedChannels(for:)` here.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Returns the set of appcast channels this app may receive.
    ///
    /// When the user has opted into development builds, we subscribe to `beta`
    /// (Sparkle still also offers channel-less / stable items). When off, an empty
    /// set means stable-only — beta-tagged items are ignored.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let wantsBeta = UserDefaults.standard.bool(forKey: Self.receiveDevelopmentBuildsKey)
        return wantsBeta ? ["beta"] : []
    }
}

/// The "Check for Updates…" menu command.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#endif
