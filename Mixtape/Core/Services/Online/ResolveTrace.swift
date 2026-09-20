// ResolveTrace.swift
// Mixtape — Core/Services/Online
//
// Stage timings for "user pressed play on a Discover row" → "sound comes out".
//
// The path crosses three files and two processes — coordinator, resolver, engine
// — so nobody could say which leg the wait was actually in, and the guesses were
// wrong: the obvious suspects (the yt-dlp spawn, the download) turned out to be
// a fraction of it. Every optimisation here is a trade, and trading against a
// leg that costs 300ms is wasted work.
//
// One play attempt at a time, so a single shared trace is enough — a new
// `begin` supersedes whatever came before, which is exactly what a skip does.
//
// Off unless asked for: DEBUG builds always, release builds behind
// `defaults write com.mikey.Mixtape MixtapeResolveTrace -bool YES`.

import Foundation

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

    /// A button was pressed. Stamped separately from `begin` because the trace
    /// used to start where the *resolve* starts, which silently excluded
    /// everything between the tap and that call — the header and list work the
    /// press triggers on the main actor. That leg was invisible, and "the
    /// resolver is slow" was the only conclusion the trace could support.
    ///
    /// `what` is the control, not the song: at press time the song may not be
    /// chosen yet, which is the entire point of shuffle.
    func press(_ what: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        pressed = (DispatchTime.now(), what)
    }

    /// Start a new attempt. `label` names the song so interleaved skips are
    /// still readable.
    func begin(_ label: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now()
        // A pending press becomes the trace's first leg, and its own zero: the
        // total at the bottom should be the wait the user actually sat through,
        // not the part of it that happened after the app got organised.
        // A press only owns the resolve that follows it promptly. Playback also
        // starts without one — auto-advance, a restored session, a prefetch
        // being promoted — and an unbounded press would attach itself to the
        // next of those and report a leg that is really the gap since the user
        // last touched anything.
        let pressIsFresh = pressed.map {
            Double(now.uptimeNanoseconds &- $0.at.uptimeNanoseconds) / 1_000_000_000 < 10
        } ?? false
        if let pressed, pressIsFresh {
            start = pressed.at
            print("[Resolve] ── \(label)  (from \(pressed.what) press)")
            print("[Resolve]    \(pad("press → resolve"))  Δ\(ms(from: pressed.at, to: now))  t+\(ms(from: pressed.at, to: now))")
            self.pressed = nil
        } else {
            self.pressed = nil
            start = now
            print("[Resolve] ── \(label)")
        }
        last  = now
        self.label = label
    }

    /// Record a completed leg: elapsed since `begin`, and since the last mark.
    ///
    /// `owner` is the query the work belongs to. Playback starts background work
    /// for *other* songs the moment it hands off — the next-track prefetch and
    /// the cache fill — and those run the same resolver code. Without this they
    /// print into the trace of the song the user is waiting on, which reads as a
    /// second search nobody asked for. Marks that name a different song are
    /// dropped; a nil owner is always kept.
    func mark(_ stage: String, owner: String? = nil) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if let owner, owner != label { return }
        guard let start, let previous = last else { return }
        let now = DispatchTime.now()
        last = now
        print("[Resolve]    \(pad(stage))  Δ\(ms(from: previous, to: now))  t+\(ms(from: start, to: now))")
    }

    /// Close the attempt. `outcome` says which path actually served the audio.
    func end(_ outcome: String) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard let start else { return }
        let total = ms(from: start, to: DispatchTime.now())
        print("[Resolve] ══ \(label) → \(outcome) in \(total)")
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
