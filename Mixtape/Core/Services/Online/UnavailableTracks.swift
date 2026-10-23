// Songs no online source has. The queue resolves ahead, so we usually know
// early and can badge the row before playback reaches it.
// In memory only: "not found" is about tonight's search, not the song.

import Foundation
import Combine
import Observation

@Observable
@MainActor
public final class UnavailableTracks {

    public static let shared = UnavailableTracks()

    /// Keyed by title|artist, not Track.id, since the same song arrives with different ids.
    public private(set) var keys: Set<String> = []

    /// Songs confirmed findable, so the scanner doesn't re-ask on every queue change.
    public private(set) var verified: Set<String> = []

    /// Songs the queue just dropped. One short-lived list read by both the player
    /// card and the queue notice; entries clear themselves.
    public private(set) var recentSkips: [Announcement] = []

    private init() {}

    /// Whether this song has already been asked about, either way.
    public func isDecided(title: String, artist: String) -> Bool {
        let key = Self.key(title: title, artist: artist)
        return keys.contains(key) || verified.contains(key)
    }

    public func markFound(title: String, artist: String) {
        let key = Self.key(title: title, artist: artist)
        keys.remove(key)
        verified.insert(key)
    }

    public static func key(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    /// Uses `identityTitle` so a "(feat. ...)" row matches the failed search.
    public func contains(_ track: Track) -> Bool {
        keys.contains(Self.key(title: track.identityTitle, artist: track.artistName))
    }

    public func contains(title: String, artist: String) -> Bool {
        keys.contains(Self.key(title: title, artist: artist))
    }

    /// Own id so two skips of the same song show as two notices.
    public struct Announcement: Equatable, Identifiable {
        public let id = UUID()
        public let title:  String
        public let artist: String

        public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    /// Marks a song unfindable and, with `announce`, shows a notice. One call so no
    /// path does only half.
    public func mark(title: String, artist: String, announce: Bool = false) {
        let key = Self.key(title: title, artist: artist)
        keys.insert(key)
        verified.remove(key)
        guard announce else { return }
        let notice = Announcement(title: title, artist: artist)
        recentSkips.append(notice)
        if recentSkips.count > 4 { recentSkips.removeFirst() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.recentSkips.removeAll { $0.id == notice.id }
        }
    }

    public func dismiss(_ notice: Announcement) {
        recentSkips.removeAll { $0.id == notice.id }
    }

    /// A song that has just played is findable, whatever an earlier search said.
    public func clear(title: String, artist: String) {
        markFound(title: title, artist: artist)
    }
}
