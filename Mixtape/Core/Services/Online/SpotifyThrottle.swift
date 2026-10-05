// App-wide Spotify rate-limit state. A 429 blocks every call until it lifts,
// so it's shown globally rather than as an error on one screen. Set by
// SpotifyClient when a 429 outlives its retries; cleared by the next success.

import Foundation
import Combine

@MainActor
public final class SpotifyThrottle: ObservableObject {

    public static let shared = SpotifyThrottle()

    /// When Spotify said it would start answering again, or nil when it is.
    @Published public private(set) var until: Date?

    private init() {}

    public var isThrottled: Bool {
        guard let until else { return false }
        // Checked against the clock, so no timer is needed.
        return until > .now
    }

    /// User-facing text saying what Spotify is doing and what happens next.
    public var sentence: String? {
        guard let until, until > .now else { return nil }
        return "Spotify is limiting how often Mixtape can talk to it. "
             + "Syncing and importing will start working again \(Self.phrase(until))."
    }

    /// The short form, for a line that already has context around it.
    public var phrase: String? {
        guard let until, until > .now else { return nil }
        return "Spotify is rate-limiting, try again \(Self.phrase(until))"
    }

    public func note(retryAfter seconds: TimeInterval) {
        let end = Date().addingTimeInterval(max(seconds, 1))
        // Never shorten a standing penalty; keep the longest wait.
        if let until, until > end { return }
        until = end
    }

    /// Spotify answered, so whatever penalty stood is over.
    public func clear() {
        guard until != nil else { return }
        until = nil
    }

    private static func phrase(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }
}
