// MixSignpost.swift
// Mixtape — Core/Utilities
//
// Logging and signposts, in one place so the subsystem string and the category
// names are decided once.
//
// Everything here is os_log / os_signpost rather than `print`. The difference
// that matters is that these are off by default and cost close to nothing until
// something is listening: Console.app, `log stream`, or Instruments. `print`
// formats its arguments and writes to stderr whether or not anyone cares, which
// is exactly the wrong trade for a measurement that has to sit in a hot path.
//
// Filtering in Console.app:
//   subsystem:com.mikey.Mixtape
//   subsystem:com.mikey.Mixtape category:launch
//
// From the terminal:
//   log stream --predicate 'subsystem == "com.mikey.Mixtape"' --style compact
//   log show  --last 5m --predicate 'subsystem == "com.mikey.Mixtape"' --info

import Foundation
import OSLog

public enum MixLog {

    /// Matches the bundle identifier so Console's subsystem filter and the
    /// app's own identity are the same string.
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.mikey.Mixtape"

    /// App startup through to the first usable window.
    public static let launch    = Logger(subsystem: subsystem, category: "launch")
    /// Store opening, fetches, and the library refresh that publishes them.
    public static let database  = Logger(subsystem: subsystem, category: "database")
    /// Local file imports and Spotify transfers.
    public static let importing = Logger(subsystem: subsystem, category: "import")
    /// Export to disk and to Spotify.
    public static let exporting = Logger(subsystem: subsystem, category: "export")
    /// Main-thread responsiveness. See `MainThreadHangMonitor`.
    public static let hangs     = Logger(subsystem: subsystem, category: "hangs")
    /// Discover search: how long each stage of a query took. A search is a
    /// chain of third-party round trips, so when it feels slow the only useful
    /// question is *which* stage spent the time — this is where that is
    /// answered. Filter Console on category "search".
    public static let search    = Logger(subsystem: subsystem, category: "search")
}

/// Signposters, one per category.
///
/// Separate from the `Logger`s because Instruments groups intervals by
/// signposter category — sharing one across launch and import would put an
/// eight-minute transfer and a two-second launch on the same lane.
public enum MixSignpost {

    public static let launch    = OSSignposter(subsystem: MixLog.subsystem, category: "launch")
    public static let database  = OSSignposter(subsystem: MixLog.subsystem, category: "database")
    public static let importing = OSSignposter(subsystem: MixLog.subsystem, category: "import")
    public static let exporting = OSSignposter(subsystem: MixLog.subsystem, category: "export")
}

// MARK: - Interval helpers

public extension OSSignposter {

    /// Wraps `work` in a signpost interval.
    ///
    /// `name` has to be a literal because that is what `OSSignposter` records —
    /// the interval name is baked into the trace, not formatted at runtime.
    func interval<Result>(_ name: StaticString,
                          _ work: () throws -> Result) rethrows -> Result {
        let state = beginInterval(name, id: makeSignpostID())
        defer { endInterval(name, state) }
        return try work()
    }

    func interval<Result>(_ name: StaticString,
                          _ work: () async throws -> Result) async rethrows -> Result {
        let state = beginInterval(name, id: makeSignpostID())
        defer { endInterval(name, state) }
        return try await work()
    }
}

// MARK: - Launch timeline

/// The three moments a launch is measured between.
///
/// `processStart` is taken from the kernel rather than from the first line of
/// Swift that runs, because everything before `main` — dyld, framework loading,
/// the Objective-C runtime — is part of what a cold launch costs and is usually
/// the larger half of it. Measuring from `MixtapeApp.init` would report a
/// flattering number that no user experiences.
@MainActor
public enum LaunchTimeline {

    /// Kernel-recorded process start, via `KERN_PROC_PID`. Falls back to now,
    /// which makes the first reading a lower bound rather than a wrong one.
    public static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    private static var signpostState: OSSignpostIntervalState?
    private static var firstWindowReported = false

    /// Called as early as the app can run code. Opens the launch interval.
    public static func begin() {
        guard signpostState == nil else { return }
        signpostState = MixSignpost.launch.beginInterval("launch", id: MixSignpost.launch.makeSignpostID())
        MixLog.launch.info("Launch began; \(elapsedMilliseconds(), privacy: .public) ms already spent before main")
    }

    /// Called when the first window has content on screen and is usable.
    ///
    /// Idempotent: `RootView` can appear again — a second window, a scene
    /// restore — and only the first one is a launch.
    public static func firstWindowVisible() {
        guard !firstWindowReported else { return }
        firstWindowReported = true

        let ms = elapsedMilliseconds()
        if let state = signpostState {
            MixSignpost.launch.endInterval("launch", state)
            signpostState = nil
        }
        MixSignpost.launch.emitEvent("first-window-visible")
        MixLog.launch.notice("First window visible \(ms, privacy: .public) ms after process start")
    }

    /// A named point on the launch path.
    ///
    /// The instrumented spans inside `AppDependencies.init` accounted for about
    /// half a second of a twelve-second launch, which meant the rest was
    /// happening somewhere nothing was watching. Timed spans only measure what
    /// you already suspect; these marks measure the gaps *between* the things
    /// you suspect, which is where that time turned out to be.
    ///
    /// Each line reports both the absolute offset from process start and the
    /// delta from the previous mark, so a single log read top to bottom shows
    /// which stretch is expensive without any arithmetic.
    public static func mark(_ label: String) {
        let now = elapsedMilliseconds()
        let delta = now - lastMark
        lastMark = now
        MixLog.launch.notice("⏱ \(label, privacy: .public) at \(now, privacy: .public) ms (+\(delta, privacy: .public) ms)")
    }

    /// `mark`, but only the first time for a given label.
    ///
    /// SwiftUI evaluates a body whenever it likes; the first evaluation is the
    /// launch, and every one after it is noise.
    @discardableResult
    public static func markOnce(_ label: String) -> Bool {
        guard marked.insert(label).inserted else { return false }
        mark(label)
        return true
    }

    private static var marked: Set<String> = []
    private static var lastMark = 0

    /// Milliseconds since the process started, rounded.
    public static func elapsedMilliseconds() -> Int {
        Int((Date().timeIntervalSince(processStart) * 1000).rounded())
    }
}
