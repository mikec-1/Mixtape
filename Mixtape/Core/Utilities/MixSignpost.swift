// os_log/os_signpost helpers with one subsystem and category set. Near-free
// until something listens (Console, `log stream`, Instruments).
// Console filter: subsystem:com.mikey.Mixtape [category:launch]
// Terminal: log stream --predicate 'subsystem == "com.mikey.Mixtape"' --style compact

import Foundation
import OSLog

public nonisolated enum MixLog {

    /// Same as the bundle id.
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
    /// Discover search stage timings. Filter Console on category "search".
    public static let search    = Logger(subsystem: subsystem, category: "search")
    /// Supabase sync, realtime, continuity and sharing.
    public static let sync      = Logger(subsystem: subsystem, category: "sync")
    /// The engine, resolving, the play cache, downloads and play history.
    public static let playback  = Logger(subsystem: subsystem, category: "playback")
    /// Lyrics lookups and the sources they came from.
    public static let lyrics    = Logger(subsystem: subsystem, category: "lyrics")
    /// Library upkeep, settings resets, stats and artwork.
    public static let library   = Logger(subsystem: subsystem, category: "library")
    /// Third-party catalogues: iTunes, Deezer, the Spotify Web API.
    public static let catalog   = Logger(subsystem: subsystem, category: "catalog")
    /// Sign-in, sign-out and session state.
    public static let auth      = Logger(subsystem: subsystem, category: "auth")
}

/// One signposter per category, so Instruments puts each on its own lane.
public enum MixSignpost {

    public static let launch    = OSSignposter(subsystem: MixLog.subsystem, category: "launch")
    public static let database  = OSSignposter(subsystem: MixLog.subsystem, category: "database")
    public static let importing = OSSignposter(subsystem: MixLog.subsystem, category: "import")
    public static let exporting = OSSignposter(subsystem: MixLog.subsystem, category: "export")
}

// MARK: - Interval helpers

public extension OSSignposter {

    /// Wraps `work` in a signpost interval. `name` must be a literal.
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

/// Launch milestones, measured from kernel process start so pre-main time counts.
@MainActor
public enum LaunchTimeline {

    /// Kernel process start via `KERN_PROC_PID`. Falls back to now.
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

    /// First usable window. Idempotent; later windows aren't launches.
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

    /// A named launch checkpoint, logging offset from process start and delta
    /// from the previous mark, to find time between the timed spans.
    public static func mark(_ label: String) {
        let now = elapsedMilliseconds()
        let delta = now - lastMark
        lastMark = now
        MixLog.launch.notice("⏱ \(label, privacy: .public) at \(now, privacy: .public) ms (+\(delta, privacy: .public) ms)")
    }

    /// `mark`, once per label (SwiftUI re-evaluates bodies freely).
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
