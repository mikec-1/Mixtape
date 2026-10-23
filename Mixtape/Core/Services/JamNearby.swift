// "Jams near you": a host advertises its code over Bonjour on the local
// network, and the Jam sheet and device picker look for codes while open.
// Joining still goes through join_jam, so this only saves typing the code.
// While the app runs it also watches, and banners each Jam that appears.

import Foundation
import Network
import Combine
import Observation

@Observable
@MainActor
public final class JamNearby {

    public struct Found: Hashable, Identifiable, Sendable {
        public let code: String
        public let host: String
        public var id: String { code }
    }

    /// Also listed under NSBonjourServices in Info.plist.
    nonisolated static let serviceType = "_mixtape-jam._tcp"

    public private(set) var found: [Found] = []

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var advertised: String?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var watchers = 0

    /// The session this device is already in, which isn't news.
    @ObservationIgnored var joined: String?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var announced: Set<String> = []
    /// Set once the Jam screens have browsed, so watching never raises the Local Network prompt itself.
    private static let usedKey = "jam.nearby.used"

    /// Keeps browsing while the app runs, and banners codes that show up.
    public func watch(_ on: Bool) {
        guard on != watching, !on || UserDefaults.standard.bool(forKey: Self.usedKey) else { return }
        watching = on
        if on { startBrowsing() } else { stopBrowsing() }
    }

    func advertise(code: String, host: String) {
        guard advertised != code else { return }
        stopAdvertising()
        guard let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: code, type: Self.serviceType,
                                              txtRecord: NWTXTRecord(["code": code, "host": host]))
        // Nobody connects: the listener exists to publish the service.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        self.listener = listener
        advertised = code
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        advertised = nil
    }

    /// Counted, since the sheet and the picker can both be open.
    public func startBrowsing() {
        watchers += 1
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .bonjour(let txt) = result.metadata,
                      let code = txt["code"], let host = txt["host"] else { return nil }
                return Found(code: code, host: host)
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.found = Array(Set(found)).sorted { $0.host < $1.host }
                self.announce()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Each code once per launch. Quiet while a Jam screen is open, since the list is right there.
    private func announce() {
        guard watching else { return }
        for jam in found where jam.code != advertised && jam.code != joined && announced.insert(jam.code).inserted {
            guard watchers == 1 else { continue }
            Task { await InviteNotifier.shared.announceJam(code: jam.code, host: jam.host) }
        }
    }

    public func stopBrowsing() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        browser?.cancel()
        browser = nil
        found = []
    }
}
