// MainThreadHangMonitor.swift
// Mixtape — Core/Utilities
//
// Reports stalls on the main thread.
//
// Debug builds only, and not because the measurement is expensive — it is a
// sleeping thread and one empty block per tick — but because a watchdog that
// ships is a watchdog someone eventually has to reason about in a crash report.

import Foundation
import OSLog

/// Watches how long an empty block takes to get through the main queue.
///
/// A stall is measured rather than inferred: the monitor posts a block that does
/// nothing and times how long it waits. Whatever the main thread was busy with —
/// a synchronous fetch, a decode, a layout pass over ten thousand rows — the
/// block cannot run until it is done, so the wait *is* the hang, with no
/// sampling and nothing to interpret.
///
/// The number to care about is 100 ms: past roughly that, a scroll visibly
/// stutters and a keystroke lands late.
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

    /// Starts watching. Does nothing in release builds, and nothing if already
    /// started.
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
    /// Wall-clock time of the last stack capture, so a storm of hangs costs one
    /// sample rather than one per hang.
    private var lastCapture: CFAbsoluteTime = 0

    /// Shortest gap between two captures. `sample` suspends the process to walk
    /// it, so capturing every hang during a storm would itself become the hang.
    private let captureCooldown: TimeInterval = 10

    /// Carries the instant the probe block actually ran, back from the main
    /// thread to this one. Safe without a lock: the semaphore that publishes it
    /// also orders the write before the read.
    private final class Arrival { var at: CFAbsoluteTime = 0 }

    private func loop() {
        while running {
            let sent = CFAbsoluteTimeGetCurrent()
            let arrived = DispatchSemaphore(value: 0)
            let mark = Arrival()
            // The block stamps its own start. Reading the clock back on this
            // thread instead would fold our own sampling time into the number
            // and report every sampled hang as a second long — poisoning the
            // one measurement this whole class exists to produce.
            DispatchQueue.main.async {
                mark.at = CFAbsoluteTimeGetCurrent()
                arrived.signal()
            }

            // Two waits, not one, and the split is the whole point. Timing out
            // on `threshold` means the main thread is stuck *right now*, which
            // is the only moment its stack says anything. Waiting for the block
            // to arrive and sampling afterwards reads whatever ran next — the
            // innocent work that followed the culprit.
            var outcome = arrived.wait(timeout: .now() + threshold)
            // Read while the thread is still stuck. Afterwards the trail has
            // already unwound and names whatever ran next, which is exactly the
            // mistake the two-wait split above exists to avoid.
            var stuck: String? = nil
            if outcome == .timedOut {
                stuck = MainThreadActivity.shared.trail
                captureStackIfDue()
                // Still bounded, so a wedged main thread reports and keeps
                // reporting rather than taking this thread down with it.
                outcome = arrived.wait(timeout: .now() + 5)
            }
            let waited = mark.at - sent

            if outcome == .timedOut {
                MixLog.hangs.error("Main thread unresponsive for over 5 s\(Self.blame(stuck))")
                // Don't race ahead of a block that hasn't run yet.
                arrived.wait()
            } else if waited >= threshold {
                // Reported on the same process-start clock as the ⏱ launch marks,
                // because the duration alone is routinely misread: this line is
                // emitted when the probe finally *lands*, so a hang's window
                // reaches backwards from here. A probe posted just before
                // `app/init` and unblocked at first paint looks like a single
                // multi-second stall when it is really "the launch was busy
                // throughout" — printing the window makes that legible without
                // subtracting timestamps by hand.
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

    /// " — in <trail>", or nothing when the stall happened somewhere unmarked.
    ///
    /// An empty suffix is the honest answer for unmarked work: inventing a label
    /// would send the next person reading the log to the wrong file.
    private static func blame(_ trail: String?) -> String {
        guard let trail, !trail.isEmpty else { return "" }
        return " — in \(trail)"
    }

    /// Spawn `sample` against our own pid while the main thread is still stuck.
    ///
    /// Unwinding another thread by hand means suspending it and walking frame
    /// pointers — `sample` already does that correctly, symbolicates the result,
    /// and cannot corrupt the process it reads. The cost is that it is slow, so
    /// this is throttled and never runs outside a hang.
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
        // One second of samples is plenty to see a stack that is not moving,
        // and short enough that the sample is over before the hang is.
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
                MixLog.hangs.error("sample exited \(proc.terminationStatus, privacy: .public) — no stack captured")
            }
        } catch {
            // A sandboxed build may refuse to exec, and that is worth saying out
            // loud rather than silently producing no stacks.
            MixLog.hangs.error("Could not run sample: \(error.localizedDescription, privacy: .public)")
        }
        #else
        // `sample` is a command-line tool and `Process` doesn't exist on iOS —
        // not even in the simulator, which is built against the iOS SDK. Tried
        // and rejected: `targetEnvironment(simulator)` does not help. Hangs are
        // still logged there, just without a stack, so on iOS only
        // `mixMainActivity` spans can name one.
        _ = captureCooldown
        #endif
    }
    #endif
}
