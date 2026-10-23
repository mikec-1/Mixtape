// How much the app may download before you ask for it. Prefetching lets the
// queue play gaplessly on a good connection; on a metered one it's wasted data.
// Separate from DownloadManager, which owns offline copies. This is the
// playback cache, which is temporary and evicted under a budget.

import Foundation
import Combine
import Observation

/// How far ahead of the song playing the queue is fetched.
public enum QueuePreloadDepth: Int, CaseIterable, Identifiable, Sendable {
    /// Nothing early. Every song pays its own way at the tap.
    case off   = 0
    /// The song after this one (the old default).
    case next  = 1
    case three = 3
    case five  = 5
    /// Everything queued, up to the cache budget's patience.
    case whole = 25

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off:   return "Off"
        case .next:  return "Next Song"
        case .three: return "Next 3 Songs"
        case .five:  return "Next 5 Songs"
        case .whole: return "Whole Queue"
        }
    }
}

@Observable
@MainActor
public final class PlaybackPrefetchSettings {

    public static let shared = PlaybackPrefetchSettings()

    private static let depthKey  = "mixtape.prefetch.queueDepth"
    private static let browseKey = "mixtape.prefetch.whileBrowsing"

    /// How many songs past the current one to fetch. Defaults to `.next`, which
    /// matches the behaviour before the setting existed.
    public var queueDepth: QueuePreloadDepth {
        didSet { UserDefaults.standard.set(queueDepth.rawValue, forKey: Self.depthKey) }
    }

    /// Prefetch on hover or when a page opens. Makes Discover feel instant;
    /// worth turning off on metered data.
    public var prefetchWhileBrowsing: Bool {
        didSet { UserDefaults.standard.set(prefetchWhileBrowsing, forKey: Self.browseKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Self.depthKey) as? Int,
           let depth = QueuePreloadDepth(rawValue: stored) {
            queueDepth = depth
        } else {
            queueDepth = .next
        }
        prefetchWhileBrowsing = (defaults.object(forKey: Self.browseKey) as? Bool) ?? true
    }

    /// Speculative downloads allowed at once. Two keeps ahead of in-order
    /// listening; a deeper queue gets one more slot, no more, so the song being
    /// buffered still wins.
    public var concurrentPrefetches: Int {
        switch queueDepth {
        case .off:            return 0
        case .next, .three:   return 2
        case .five, .whole:   return 3
        }
    }
}
