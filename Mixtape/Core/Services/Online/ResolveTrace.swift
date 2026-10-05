// Stage timings from pressing play on a Discover row to hearing sound,
// across coordinator, resolver and engine. One shared trace; a new `begin`
// replaces the last (as a skip does).
// Enabled in DEBUG, or in release with
// `defaults write com.mikey.Mixtape MixtapeResolveTrace -bool YES`.
// Logged at .notice, public.

import Foundation
import OSLog

final class ResolveTrace: @unchecked Sendable {

    static let shared = ResolveTrace()

    private let lock = NSLock()
    private var start: DispatchTime?
    private var last:  DispatchTime?
    private var label = ""
    private var pressed: (at: DispatchTime, what: String)?

    private static let enabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "MixtapeResolveTrace")
        #endif
    }()

    /// A button was pressed. Separate from `begin` so main-actor work between the
    /// tap and the resolve is measured. `what` is the control, not the song (shuffle
    /// may not have chosen yet).
    func press(_ what: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        pressed = (DispatchTime.now(), what)
    }

    /// Starts a new attempt. `label` names the song.
    func begin(_ label: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now()
        // A recent press becomes the trace's zero so the total is the full wait.
        // Only presses in the last 10 s count, so auto-advance or a restored session
        // doesn't inherit an old press.
        let pressIsFresh = pressed.map {
            Double(now.uptimeNanoseconds &- $0.at.uptimeNanoseconds) / 1_000_000_000 < 10
        } ?? false
        if let pressed, pressIsFresh {
            start = pressed.at
            MixLog.playback.notice("[Resolve] ── \(label, privacy: .public)  (from \(pressed.what, privacy: .public) press)")
            MixLog.playback.notice("[Resolve]    \(self.pad("press → resolve"), privacy: .public)  Δ\(self.ms(from: pressed.at, to: now), privacy: .public)  t+\(self.ms(from: pressed.at, to: now), privacy: .public)")
            self.pressed = nil
        } else {
            self.pressed = nil
            start = now
            MixLog.playback.notice("[Resolve] ── \(label, privacy: .public)")
        }
        last  = now
        self.label = label
    }

    /// Records a leg: time since `begin` and since the last mark. Marks whose
    /// `owner` is a different song (prefetch, cache fill) are dropped. nil is kept.
    func mark(_ stage: String, owner: String? = nil) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if let owner, owner != label { return }
        guard let start, let previous = last else { return }
        let now = DispatchTime.now()
        last = now
        MixLog.playback.notice("[Resolve]    \(self.pad(stage), privacy: .public)  Δ\(self.ms(from: previous, to: now), privacy: .public)  t+\(self.ms(from: start, to: now), privacy: .public)")
    }

    /// Close the attempt. `outcome` says which path actually served the audio.
    func end(_ outcome: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard let start else { return }
        let total = ms(from: start, to: DispatchTime.now())
        MixLog.playback.notice("[Resolve] ══ \(self.label, privacy: .public) → \(outcome, privacy: .public) in \(total, privacy: .public)")
        self.start = nil
        self.last  = nil
    }

    private func ms(from: DispatchTime, to: DispatchTime) -> String {
        let millis = Double(to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000
        return String(format: "%6.0fms", millis)
    }

    private func pad(_ s: String) -> String {
        s.count >= 28 ? s : s + String(repeating: " ", count: 28 - s.count)
    }
}
