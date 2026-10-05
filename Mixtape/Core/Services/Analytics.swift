import Foundation
import Supabase

/// Opt-in usage events (skips, searches, opens, screens). Nothing is sent unless the user turned on
/// "Help improve Mixtape", and never in a private session. Fire and forget: a lost event is fine.
enum Analytics {
    static let optInKey = "mix.analyticsOptIn"

    /// The account's choice wins over this device's. Nil means the account never chose.
    static func adoptRemote(_ on: Bool?) {
        guard let on else { return }
        UserDefaults.standard.set(on, forKey: optInKey)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: optInKey) && !PrivateSession.isActive
    }

    private static var lastActive: Date?

    /// A session start: first activation, or coming back after 30 idle minutes.
    /// The Mac goes active on every window focus, hence the gap.
    /// ponytail: the gap runs from the last activation, so hours of focused use then a refocus counts as a new open.
    static func appBecameActive() {
        defer { lastActive = Date() }
        if let lastActive, Date().timeIntervalSince(lastActive) < 30 * 60 { return }
        track("app_open", [:])
    }

    static func screen(_ name: String) {
        track("screen", ["screen": .string(name)])
    }

    static func track(_ name: String, _ props: [String: AnyJSON]) {
        guard isEnabled else { return }
        struct Row: Encodable {
            let name: String
            let props: [String: AnyJSON]
            let platform: String
            let app_version: String
        }
        let row = Row(name: name, props: props,
                      platform: SupabaseSyncService.platformName,
                      app_version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
        Task {
            // Signed out: the insert fails RLS and is dropped, which is what we want.
            try? await SupabaseConfig.client.from("events").insert(row).execute()
        }
    }
}
