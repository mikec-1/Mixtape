// MainThreadActivity.swift
// Mixtape - Core/Utilities
//
// What the main thread is in the middle of, so a hang can name itself.

import Foundation
import os

/// Breadcrumb trail of what the main thread is doing. `sample` isn't available on iOS,
/// so instrumented sections push a label and the watchdog reads the innermost one
/// during a hang.
/// Not `@MainActor`: the watchdog reads from its own thread. Writes are main-thread only
/// and the read is one reference load, so at worst a label is one frame stale.
public final class MainThreadActivity: @unchecked Sendable {

    public static let shared = MainThreadActivity()

    private var stack: [String] = []

    private init() {}

    /// The innermost marked section, or nil if nothing is marked.
    public var current: String? { stack.last }

    /// The trail, outermost first ("sync > library-refresh > fetch"), prefixed by the current phase.
    public var trail: String? {
        let marked = stack.isEmpty ? nil : stack.joined(separator: " \u{25B8} ")
        switch (currentPhase, marked) {
        case (nil, let m):     return m
        case (let p?, nil):    return "[\(p)]"
        case (let p?, let m?): return "[\(p)] \u{25B8} \(m)"
        }
    }

    /// Long-running async work in flight. Not a timed span, since an async operation spans
    /// many awaits; it just tells the watchdog what the app was doing.
    private var currentPhase: String?

    /// Names the async work in flight for the duration of `body`.
    @MainActor
    public func phase<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let previous = currentPhase
        currentPhase = label
        defer { currentPhase = previous }
        return try await body()
    }

    /// Runs `body` with `label` on the trail. Synchronous: suspended work has already given
    /// the thread back.
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

    /// A span this long is a dropped frame, so log it immediately.
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

    /// Every span so far, worst total first. Catches cheap spans called many times.
    public func costsByTotal() -> [(trail: String, cost: Cost)] {
        costs.map { (trail: $0.key, cost: $0.value) }
             .sorted { $0.cost.totalMS > $1.cost.totalMS }
    }

    /// Writes the table to the log. Call it after doing the slow thing.
    @MainActor
    public func logReport(_ context: String) {
        let rows = costsByTotal()
        guard !rows.isEmpty else { return }
        MixLog.hangs.info("main-actor cost report, \(context, privacy: .public)")
        for row in rows.prefix(20) {
            MixLog.hangs.info("  \(Int(row.cost.totalMS), privacy: .public) ms total / \(row.cost.calls, privacy: .public) calls / worst \(Int(row.cost.worstMS), privacy: .public) ms, \(row.trail, privacy: .public)")
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

/// Names a stretch of async work for hang reports. Measures nothing, see `MainThreadActivity.phase`.
@MainActor
public func mixPhase<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    try await MainThreadActivity.shared.phase(label, body)
}
