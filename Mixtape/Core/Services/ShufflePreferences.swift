// Per-list "always shuffle" for playlist, album and artist headers. Separate
// from the player bar's shuffle, which is the live queue's mode and never
// writes back here.

import Foundation
import Combine

@MainActor
public final class ShufflePreferences: ObservableObject {

    public static let shared = ShufflePreferences()

    /// List identity across types, so an album and playlist with the same name don't collide.
    public enum Key: Hashable {
        case playlist(UUID)
        case album(UUID)
        case artist(String)

        var storageKey: String {
            switch self {
            case .playlist(let id): return "playlist:\(id.uuidString)"
            case .album(let id):    return "album:\(id.uuidString)"
            // Artists are identified by case-folded name.
            case .artist(let name): return "artist:\(name.lowercased())"
            }
        }
    }

    private let defaultsKey = "mixtape.shufflesOnPlay"
    private let defaults: UserDefaults

    /// Only lists that shuffle are stored, so the set stays small.
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
