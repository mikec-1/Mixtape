// PlaybackClock.swift
// Mixtape — Core/Services
//
// The playback position, on its own object, so that the one value in the app
// that changes five times a second doesn't wake the views that don't care.
//
// `currentTime` used to be `@Published` on `PlaybackEngine`. Thirty-one views
// hold the engine as an `@EnvironmentObject` — the Mac root view, the sidebar,
// the songs table, every detail page — and an `ObservableObject` has exactly one
// `objectWillChange`, so a tick meant for the seek bar invalidated all of them.
// The re-evaluated bodies then did real work: re-filtering the whole library,
// re-hashing every visible row, scanning for tracks by id. Five times a second,
// on the main thread, for as long as music played.
//
// Splitting the value out is the whole fix. Views that draw the position
// (`MacProgressScrubber`, the Now Playing seek bar, both synced-lyrics views)
// observe *this*; everything else observes the engine and hears from it only
// when something it actually draws has changed — the track, the play state, the
// queue.
//
// The engine still owns the value; this is a publisher, not a source of truth.
// Read it through `PlaybackEngine.currentTime` in non-view code.

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

    /// The position *now*, carried forward from the last tick.
    ///
    /// The value above only moves five times a second — enough to pick a lyric
    /// line, far too coarse to sweep the highlight through one. The carry is
    /// capped so a pause, where ticks simply stop, freezes the sweep instead of
    /// running away from the audio.
    public func interpolatedTime() -> TimeInterval {
        currentTime + min(0.5, max(0, ProcessInfo.processInfo.systemUptime - updatedAt))
    }

    public init() {}
}
