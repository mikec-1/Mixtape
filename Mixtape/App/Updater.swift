// Updater.swift
// Mixtape — App
//
// Sparkle auto-update integration (macOS only).
//
// Distribution is un-notarized, so update integrity is guaranteed by Sparkle's
// EdDSA signatures (SUPublicEDKey in Info.plist) rather than Apple notarization.
// The first manual install requires a one-time right-click → Open; every Sparkle
// update afterwards is seamless.

#if os(macOS)
import SwiftUI
import Combine
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// Created as a `@StateObject` on `MixtapeApp` so the updater starts with the app
/// and performs its scheduled background checks against `SUFeedURL`.
final class UpdaterController: ObservableObject {

    let updaterController: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable itself
    /// while a check is already in flight.
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true → begins scheduled update checks immediately.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
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
