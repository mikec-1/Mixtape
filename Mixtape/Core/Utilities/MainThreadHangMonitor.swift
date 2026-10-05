// Reports main-thread stalls. Debug builds only.

import Foundation
import OSLog

/// Times how long an empty block waits on the main queue; the wait is the hang.
/// Around 100 ms is where scrolling visibly stutters.
public final class MainThreadHangMonitor: @unchecked Sendable {

    public static let shared = MainThreadHangMonitor()

    /// Anything slower than this is reported.
    public var threshold: TimeInterval = 0.100

    /// Gap between probes. Short enough to catch a stutter, long enough that the
    /// monitor is not itself main-queue traffic worth mentioning.
    private let interval: TimeInterval = 0.050

    private let queue = DispatchQueue(label: "com.mikey.Mixtape.hang-monitor", qos: .utility)
    private var running = false

    private init() {}

    /// Starts watching. No-op in release builds or if already started.
    public func start() {
        #if DEBUG
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.loop()
        }
        #endif
    }

    public func stop() {
        queue.async { [weak self] in self?.running = false }
    }

    #if DEBUG
    /// Time of the last stack capture, so a storm of hangs costs one sample.
    private var lastCapture: CFAbsoluteTime = 0

    /// `sample` suspends the process, so capturing every hang would cause hangs.
    private let captureCooldown: TimeInterval = 10

    /// When the probe block ran. The semaphore orders the write before the read, so no lock.
    private final class Arrival { var at: CFAbsoluteTime = 0 }

    private func loop() {
        while running {
            let sent = CFAbsoluteTimeGetCurrent()
            let arrived = DispatchSemaphore(value: 0)
            let mark = Arrival()
            // The block stamps its own start so our sampling time isn't counted.
            DispatchQueue.main.async {
                mark.at = CFAbsoluteTimeGetCurrent()
                arrived.signal()
            }

            // Time out on `threshold` first to sample while the thread is still stuck,
            // not after it moved on.
            var outcome = arrived.wait(timeout: .now() + threshold)
            // Read the trail while still stuck; afterwards it names whatever ran next.
            var stuck: String? = nil
            if outcome == .timedOut {
                stuck = MainThreadActivity.shared.trail
                captureStackIfDue()
                // Bounded so a wedged main thread keeps being reported.
                outcome = arrived.wait(timeout: .now() + 5)
            }
            let waited = mark.at - sent

            if outcome == .timedOut {
                MixLog.hangs.error("Main thread unresponsive for over 5 s\(Self.blame(stuck))")
                // Don't race ahead of a block that hasn't run yet.
                arrived.wait()
            } else if waited >= threshold {
                // Logged on the launch timeline clock with the full window, since the line is emitted
                // when the probe lands and the hang reaches back from there.
                let endedAt = LaunchTimeline.elapsedMilliseconds()
                let beganAt = endedAt - Int(waited * 1000)
                MixLog.hangs.warning("""
                    Main thread hang: \(Int(waited * 1000), privacy: .public) ms                     (\(beganAt, privacy: .public)→\(endedAt, privacy: .public) ms)\
                    \(Self.blame(stuck), privacy: .public)
                    """)
            }

            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// " - in <trail>", or empty for unmarked work.
    private static func blame(_ trail: String?) -> String {
        guard let trail, !trail.isEmpty else { return "" }
        return " — in \(trail)"
    }

    /// Runs `sample` on our own pid while the main thread is stuck. Slow, so throttled.
    private func captureStackIfDue() {
        #if os(macOS)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCapture >= captureCooldown else { return }
        lastCapture = now

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let path = NSTemporaryDirectory() + "mixtape-hang-\(stamp).txt"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // One second is enough to see a stuck stack.
        proc.arguments = [String(ProcessInfo.processInfo.processIdentifier),
                          "1", "-mayDie", "-file", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                MixLog.hangs.error("Hang stack written to \(path, privacy: .public)")
            } else {
                MixLog.hangs.error("sample exited \(proc.terminationStatus, privacy: .public), no stack captured")
            }
        } catch {
            // A sandboxed build may refuse to exec.
            MixLog.hangs.error("Could not run sample: \(error.localizedDescription, privacy: .public)")
        }
        #else
        // No `Process` on iOS (including the simulator), so hangs log without a stack there.
        _ = captureCooldown
        #endif
    }
    #endif
}
