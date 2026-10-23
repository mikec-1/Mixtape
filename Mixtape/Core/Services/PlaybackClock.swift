// The playback position on its own object, so its 5Hz ticks only redraw
// views that draw the position (scrubbers, synced lyrics). Everything else
// observes the engine. The engine owns the value; read it via
// `PlaybackEngine.currentTime` outside views.

import Foundation
import Combine
import Observation

@Observable
@MainActor
public final class PlaybackClock {

    /// Seconds into the current track. Written only by `PlaybackEngine`.
    public internal(set) var currentTime: TimeInterval = 0 {
        didSet { updatedAt = ProcessInfo.processInfo.systemUptime; currentTimeSubject.send(currentTime) }
    }

    /// For Combine code outside views; sent after the set.
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { currentTimeSubject.prepend(currentTime).eraseToAnyPublisher() }
    @ObservationIgnored private let currentTimeSubject = PassthroughSubject<TimeInterval, Never>()

    /// When `currentTime` last landed, on the monotonic clock.
    @ObservationIgnored public private(set) var updatedAt: TimeInterval = 0

    /// Position now, extrapolated from the last tick for smooth lyric sweeps.
    /// Capped so a pause freezes it.
    public func interpolatedTime() -> TimeInterval {
        currentTime + min(0.5, max(0, ProcessInfo.processInfo.systemUptime - updatedAt))
    }

    public init() {}
}
