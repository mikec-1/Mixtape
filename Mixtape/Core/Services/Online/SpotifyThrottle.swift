// SpotifyThrottle.swift
// Mixtape — Core/Services/Online
//
// One place that knows Spotify is currently refusing us.
//
// A 429 from Spotify is an *app-wide* penalty, not a per-request or per-user
// one: once it lands, every call Mixtape makes fails until it lifts. That makes
// it a piece of app state rather than an error belonging to whichever screen
// happened to ask last — and the reason it needs to be here is that the way it
// used to surface, as a line of small text inside whichever sheet was open,
// looked exactly like Mixtape being broken. Sync did nothing, the connection
// card sat on "Reading your account…", and nothing anywhere said why.
//
// Set from `SpotifyClient` at the two places a 429 outlives its retries, and
// cleared by the first request that succeeds — Spotify's advised wait is a
// ceiling, and often the penalty lifts sooner.

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
        // Read through the clock rather than relying on a timer to clear it:
        // the penalty ends whether or not anything was watching.
        return until > .now
    }

    /// A sentence to put in front of the user. Deliberately says what Spotify
    /// is doing and what Mixtape will do about it, because the failure it
    /// explains is otherwise indistinguishable from a bug.
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
        // Never shorten a standing penalty on the strength of one endpoint's
        // smaller advice; the longest wait seen is the one that matters.
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
