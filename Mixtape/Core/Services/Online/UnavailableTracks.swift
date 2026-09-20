// UnavailableTracks.swift
// Mixtape — Core/Services/Online
//
// The songs nothing on the internet has.
//
// A queued song that has to be found online is normally found. A few never are
// — a bootleg, a regional block, a spelling no upload uses — and until now the
// only way to learn that was to wait for the queue to reach it and watch
// playback die on a song that was never coming. The queue already fetches ahead
// of itself, so the answer is usually known minutes early: this is where that
// answer is kept, so a row can wear a warning before anyone waits on it.
//
// In memory, deliberately. "Not found" is a fact about a search on a particular
// evening, not about the song, and a mark persisted across launches would
// outlive the upload appearing.

import Foundation
import Combine

@MainActor
public final class UnavailableTracks: ObservableObject {

    public static let shared = UnavailableTracks()

    /// Keyed by title|artist, not by Track.id: the same song reaches this from a
    /// library row, a queue mirror and a Deezer suggestion, each with its own id.
    @Published public private(set) var keys: Set<String> = []

    /// Songs a probe or a play has confirmed *are* out there. Kept so the
    /// scanner doesn't ask about the same song once per queue change: without
    /// it, "not decided yet" and "fine" look identical.
    @Published public private(set) var verified: Set<String> = []

    /// The songs the queue has just dropped. One list, read by both the card
    /// above the player and the notice at the bottom of the queue: they were
    /// separate properties with separate lifetimes, and a skip that showed up in
    /// one and not the other was the result. Short on purpose — this is a "that
    /// happened" list, not a log — and each entry clears itself, so a skip that
    /// nobody dismissed doesn't sit there for the rest of the evening.
    @Published public private(set) var recentSkips: [Announcement] = []

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

    /// `identityTitle` — the bare title the catalogue spells it with, so a
    /// library row printing "(feat. …)" matches the search that failed.
    public func contains(_ track: Track) -> Bool {
        keys.contains(Self.key(title: track.identityTitle, artist: track.artistName))
    }

    public func contains(title: String, artist: String) -> Bool {
        keys.contains(Self.key(title: title, artist: artist))
    }

    /// A song that just dropped. Carries its own id so two skips of the same
    /// song stack as two notices rather than collapsing into one.
    public struct Announcement: Equatable, Identifiable {
        public let id = UUID()
        public let title:  String
        public let artist: String

        public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    /// Record a song as not findable, and — when playback actually wanted it —
    /// say so on screen.
    ///
    /// Both halves in one call: every caller that learns a song cannot be found
    /// wants its queue row badged, and splitting the two is how one of them ends
    /// up missing on some path.
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
