// Sparkle auto-updates (macOS only). Builds aren't notarized, so updates
// are verified with Sparkle's EdDSA signature.

#if os(macOS)
import SwiftUI
import Combine
import Sparkle
import Observation

/// Owns the Sparkle updater and opts into the beta channel when enabled.
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {

    /// Backs the "Receive development builds" toggle.
    static let receiveDevelopmentBuildsKey = "updates.receiveDevelopmentBuilds"

    /// "1" in 2.0.0 beta 1, nil in stable and Xcode builds. See RELEASING.md.
    static let betaNumber: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "MixtapeBeta") as? String ?? ""
        return value.isEmpty ? nil : value
    }()

    @ObservationIgnored private(set) var updaterController: SPUStandardUpdaterController!

    var canCheckForUpdates = false
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    override init() {
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &bag)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Beta channel when development builds are on, otherwise stable only.
    /// A beta build starts with it on, so a tester who downloaded one keeps getting betas.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let wantsBeta = UserDefaults.standard.object(forKey: Self.receiveDevelopmentBuildsKey) as? Bool
            ?? (Self.betaNumber != nil)
        return wantsBeta ? ["beta"] : []
    }
}

/// The "Check for Updates..." menu command.
struct CheckForUpdatesView: View {
    var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#endif
