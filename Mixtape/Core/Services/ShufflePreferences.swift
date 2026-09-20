// ShufflePreferences.swift
// Mixtape — Core/Services
//
// Remembers, per playlist / album / artist, whether pressing Play on its header
// starts shuffled.
//
// The header's shuffle button used to be bound straight to
// `QueueService.shuffleEnabled` — one app-wide flag — so toggling it in one
// playlist lit the button up in every other one, and the state had nothing to do
// with the list you were looking at. The two controls answer different
// questions and only look alike:
//
//   * the **player bar's** shuffle button is the live queue's mode: what is
//     happening to the songs that are playing right now.
//   * a **header's** shuffle button is a property of that list: "this one always
//     shuffles when I play it". It outlives the queue, and every list has its
//     own.
//
// Pressing Play applies the stored choice to the queue; changing the queue's
// mode from the player bar afterwards is a one-off and deliberately does *not*
// write back here.

import Foundation
import Combine

@MainActor
public final class ShufflePreferences: ObservableObject {

    public static let shared = ShufflePreferences()

    /// Identifies a list independently of the type that draws it, so playlists,
    /// albums and artists can share one store without colliding: an album and a
    /// playlist that happen to share a name are still two different lists.
    public enum Key: Hashable {
        case playlist(UUID)
        case album(UUID)
        case artist(String)

        var storageKey: String {
            switch self {
            case .playlist(let id): return "playlist:\(id.uuidString)"
            case .album(let id):    return "album:\(id.uuidString)"
            // Artists have no stable id of their own here — the library builds
            // them from the credited name — so the name *is* the identity,
            // case-folded so "ARTIK & ASTI" and "Artik & Asti" are one artist.
            case .artist(let name): return "artist:\(name.lowercased())"
            }
        }
    }

    private let defaultsKey = "mixtape.shufflesOnPlay"
    private let defaults: UserDefaults

    /// Only the lists that shuffle are stored. The overwhelming majority don't,
    /// and a set of the exceptions stays small no matter how big the library
    /// gets — where a dictionary of every list would grow forever.
    @Published private var shuffling: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults  = defaults
        self.shuffling = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func shuffles(_ key: Key) -> Bool {
        shuffling.contains(key.storageKey)
    }

    public func set(_ on: Bool, for key: Key) {
        let id = key.storageKey
        guard shuffling.contains(id) != on else { return }
        if on { shuffling.insert(id) } else { shuffling.remove(id) }
        defaults.set(Array(shuffling), forKey: defaultsKey)
    }

    public func toggle(_ key: Key) {
        set(!shuffles(key), for: key)
    }
}
