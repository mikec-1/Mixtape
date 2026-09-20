// MainThreadActivity.swift
// Mixtape — Core/Utilities
//
// What the main thread is in the middle of, so a hang can name itself.

import Foundation
import os

/// A breadcrumb trail of what the main thread is currently doing.
///
/// `MainThreadHangMonitor` can only walk a stack on macOS — `sample` is a
/// command-line tool and there is no `Process` on iOS — so on the platform where
/// the hangs actually hurt, a stall was reported as a bare number of
/// milliseconds with nothing attached to it. Three seconds of *what* was the
/// question no log could answer.
///
/// This is the cheap substitute: instrumented sections push a label on the way
/// in and pop it on the way out, and the watchdog reads the innermost one while
/// the thread is still stuck. It is not a stack — it only knows about places
/// somebody thought to mark — but it is read from another thread *during* the
/// hang, which is the property that matters and the one a post-hoc log line
/// can't have.
///
/// Deliberately not `@MainActor`: the watchdog reads it from its own thread by
/// design. Writes only ever happen on the main thread and the read is a single
/// reference load, so the worst case is reporting a label one frame stale.
public final class MainThreadActivity: @unchecked Sendable {

    public static let shared = MainThreadActivity()

    private var stack: [String] = []

    private init() {}

    /// The innermost marked section, or nil if nothing is marked.
    public var current: String? { stack.last }

    /// The whole trail, outermost first — "sync ▸ library-refresh ▸ fetch",
    /// with the current async phase in front of it when one is set.
    public var trail: String? {
        let marked = stack.isEmpty ? nil : stack.joined(separator: " \u{25B8} ")
        switch (currentPhase, marked) {
        case (nil, let m):     return m
        case (let p?, nil):    return "[\(p)]"
        case (let p?, let m?): return "[\(p)] \u{25B8} \(m)"
        }
    }

    /// What long-running async work is in flight, if any.
    ///
    /// Deliberately *not* a span, and deliberately not measured. An async
    /// operation like a sync is a chain of main-actor segments separated by
    /// awaits: timing it end to end would charge it for every suspension, and
    /// `run` is right to refuse that. But the watchdog asks a different
    /// question — it fires while the thread is genuinely stuck, and needs to
    /// know what the app was in the middle of. A phase answers that without
    /// claiming the whole interval was main-thread work.
    ///
    /// Read from the watchdog thread; see the note on this class's isolation.
    private var currentPhase: String?

    /// Names the async work in flight for the duration of `body`.
    @MainActor
    public func phase<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let previous = currentPhase
        currentPhase = label
        defer { currentPhase = previous }
        return try await body()
    }

    /// Runs `body` with `label` on the trail.
    ///
    /// Non-escaping and synchronous on purpose: this marks a span of main-thread
    /// work, and work that suspends has already given the thread back, so there
    /// is nothing left for a watchdog to blame it for.
    @MainActor
    public func run<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        stack.append(label)
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            let trail = stack.joined(separator: " \u{25B8} ")
            stack.removeLast()
            record(trail, milliseconds: ms)
        }
        return try body()
    }

    // MARK: - Measurement

    /// What a labelled span has cost so far this session.
    public struct Cost {
        public var calls   = 0
        public var totalMS = 0.0
        public var worstMS = 0.0
    }

    /// A span this long is, by itself, a dropped frame or several. Logged the
    /// moment it happens rather than only in the summary, because the
    /// interesting question during a stall is *which* span is running now.
    private static let reportThresholdMS = 100.0

    private var costs: [String: Cost] = [:]

    private func record(_ trail: String, milliseconds ms: Double) {
        var cost = costs[trail] ?? Cost()
        cost.calls  += 1
        cost.totalMS += ms
        cost.worstMS = max(cost.worstMS, ms)
        costs[trail] = cost

        if ms >= Self.reportThresholdMS {
            MixLog.hangs.info("main-actor span \(trail, privacy: .public) \(Int(ms), privacy: .public) ms")
        }
    }

    /// Every span measured so far, worst total first.
    ///
    /// The per-call threshold above catches one bad span; this catches the
    /// other shape of the same problem — a cheap span called four hundred
    /// times, which no single log line would ever look like a fault.
    public func costsByTotal() -> [(trail: String, cost: Cost)] {
        costs.map { (trail: $0.key, cost: $0.value) }
             .sorted { $0.cost.totalMS > $1.cost.totalMS }
    }

    /// Writes the table to the log. Call it after doing the slow thing.
    @MainActor
    public func logReport(_ context: String) {
        let rows = costsByTotal()
        guard !rows.isEmpty else { return }
        MixLog.hangs.info("main-actor cost report — \(context, privacy: .public)")
        for row in rows.prefix(20) {
            MixLog.hangs.info("  \(Int(row.cost.totalMS), privacy: .public) ms total / \(row.cost.calls, privacy: .public) calls / worst \(Int(row.cost.worstMS), privacy: .public) ms — \(row.trail, privacy: .public)")
        }
    }

    /// Clears the table, so a measurement can be scoped to one action.
    @MainActor
    public func resetCosts() { costs.removeAll() }
}

/// Marks a span of main-thread work, so a hang inside it can say its name.
@MainActor
public func mixMainActivity<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    try MainThreadActivity.shared.run(label, body)
}

/// Names a stretch of async work, so a hang during it can say what was running.
///
/// Unlike `mixMainActivity` this measures nothing — see `MainThreadActivity.phase`.
@MainActor
public func mixPhase<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    try await MainThreadActivity.shared.phase(label, body)
}
