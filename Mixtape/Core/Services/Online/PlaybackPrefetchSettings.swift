// PlaybackPrefetchSettings.swift
// Mixtape — Core/Services/Online
//
// How much the app is allowed to download before you ask for it.
//
// Everything an online song costs is paid at the moment of the tap: search,
// download, convert. The app has always done some of this early — hover a row
// and it starts fetching, and the song after the one playing is warmed once
// audio starts — but never more than one ahead and never as a choice anyone
// could make. On a good connection there is no reason a queue shouldn't be
// pulled down several songs deep and play gaplessly; on a metered one there is
// every reason not to touch a byte nobody asked for.
//
// So it's a setting, and this is where it lives. Deliberately not on
// DownloadManager: that owns *offline* copies — files the user keeps — and this
// owns the playback cache, which is temporary and evicted under a budget.

import Foundation
import Combine

/// How far ahead of the song playing the queue is fetched.
public enum QueuePreloadDepth: Int, CaseIterable, Identifiable, Sendable {
    /// Nothing early. Every song pays its own way at the tap.
    case off   = 0
    /// The song after this one — what the app did before this was a choice.
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

@MainActor
public final class PlaybackPrefetchSettings: ObservableObject {

    public static let shared = PlaybackPrefetchSettings()

    private static let depthKey  = "mixtape.prefetch.queueDepth"
    private static let browseKey = "mixtape.prefetch.whileBrowsing"

    /// How many songs past the one playing to fetch. Defaults to `.next`, which
    /// is exactly what the app did before the setting existed — a new preference
    /// should never change behaviour on its own.
    @Published public var queueDepth: QueuePreloadDepth {
        didSet { UserDefaults.standard.set(queueDepth.rawValue, forKey: Self.depthKey) }
    }

    /// Fetching a song because the pointer passed over it, or because the page
    /// it's on opened. Cheap on a laptop, and the reason Discover feels instant;
    /// worth switching off on a phone paying for data.
    @Published public var prefetchWhileBrowsing: Bool {
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

    /// Speculative downloads allowed at once.
    ///
    /// Two is enough to stay ahead of someone listening in order without
    /// competing with the song they're waiting on. Asking for a deeper queue is
    /// asking to spend more bandwidth ahead of time, so it buys one more slot —
    /// and no more than that, because the buffer being filled right now still
    /// has to win.
    public var concurrentPrefetches: Int {
        switch queueDepth {
        case .off:            return 0
        case .next, .three:   return 2
        case .five, .whole:   return 3
        }
    }
}
