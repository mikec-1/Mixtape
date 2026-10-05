// The playback position on its own object, so its 5Hz ticks only redraw
// views that draw the position (scrubbers, synced lyrics). Everything else
// observes the engine. The engine owns the value; read it via
// `PlaybackEngine.currentTime` outside views.

import Foundation
import Combine

@MainActor
public final class PlaybackClock: ObservableObject {

    /// Seconds into the current track. Written only by `PlaybackEngine`.
    @Published public internal(set) var currentTime: TimeInterval = 0 {
        didSet { updatedAt = ProcessInfo.processInfo.systemUptime }
    }

    /// When `currentTime` last landed, on the monotonic clock.
    public private(set) var updatedAt: TimeInterval = 0

    /// Position now, extrapolated from the last tick for smooth lyric sweeps.
    /// Capped so a pause freezes it.
    public func interpolatedTime() -> TimeInterval {
        currentTime + min(0.5, max(0, ProcessInfo.processInfo.systemUptime - updatedAt))
    }

    public init() {}
}
