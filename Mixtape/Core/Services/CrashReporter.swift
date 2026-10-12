import Foundation
import MetricKit
import OSLog
import Supabase
#if canImport(Sentry)
import Sentry
#endif

/// Crashes, hangs and logged errors, behind the same opt-in as Analytics.
/// MetricKit hands crashes and hangs over about a day late. Sentry, once its package is added, sends them live.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    /// From sentry.io > Project Settings > Client Keys. Empty keeps Sentry off.
    #if os(iOS)
    static let sentryDSN = "https://16670ae8add36f70adcb229e75c6ccd6@o4512188157263872.ingest.de.sentry.io/4512188229681232"
    #else
    static let sentryDSN = "https://8dcdcf5d54c2d7813876a12053ad4694@o4512188157263872.ingest.de.sentry.io/4512188249145424"
    #endif

    func start() {
        MXMetricManager.shared.add(self)
        #if canImport(Sentry)
        // Read once at launch, so turning the opt-in on starts Sentry from the next launch.
        if Analytics.isEnabled, !Self.sentryDSN.isEmpty {
            SentrySDK.start { options in
                options.dsn = Self.sentryDSN
                options.sendDefaultPii = false
                // Only our own servers. Lyric and catalogue APIs 5xx all the time.
                options.failedRequestTargets = ["mixtaped.tech", "supabase.co"]
                #if DEBUG
                // Unoptimised builds stall on every sync; MainThreadHangMonitor covers hangs locally.
                options.environment = "debug"
                options.enableAppHangTracking = false
                #endif
            }
        }
        #endif
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var rows: [[String: AnyJSON]] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                rows.append([
                    "kind": .string("crash"),
                    "exception": .string(crash.exceptionType.map { "\($0)" } ?? ""),
                    "signal": .string(crash.signal.map { "\($0)" } ?? ""),
                    "reason": .string(crash.terminationReason ?? ""),
                    "build": .string(crash.metaData.applicationBuildVersion),
                    "os": .string(crash.metaData.osVersion),
                    "stack": .string(Self.stack(crash.callStackTree)),
                ])
            }
            for hang in payload.hangDiagnostics ?? [] {
                rows.append([
                    "kind": .string("hang"),
                    "seconds": .double(hang.hangDuration.converted(to: .seconds).value),
                    "build": .string(hang.metaData.applicationBuildVersion),
                    "os": .string(hang.metaData.osVersion),
                    "stack": .string(Self.stack(hang.callStackTree)),
                ])
            }
        }
        Task { @MainActor in rows.forEach { Analytics.track("crash", $0) } }
    }

    /// Unsymbolicated addresses; match them against the build's dSYM.
    nonisolated private static func stack(_ tree: MXCallStackTree) -> String {
        String(String(decoding: tree.jsonRepresentation(), as: UTF8.self).prefix(30_000))
    }

    // MARK: - Logged errors

    private static let flushedKey = "mix.errorsFlushedAt"

    /// Sends what MixLog logged at error or fault since the last flush. Interpolated values
    /// come back as <private>, so only the message shape leaves the device.
    /// ponytail: OSLogStore only sees this process, so errors from a run that crashed before flushing are lost.
    static func flushErrors() {
        guard Analytics.isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: flushedKey) as? Date
        // The Mac activates on every focus.
        if let last, Date().timeIntervalSince(last) < 10 * 60 { return }
        let since = last ?? Date().addingTimeInterval(-3600)
        UserDefaults.standard.set(Date(), forKey: flushedKey)
        Task {
            for (category, message, count) in await collectErrors(since: since) {
                Analytics.track("error", ["category": .string(category), "message": .string(message),
                                          "count": .integer(count)])
            }
        }
    }

    @concurrent nonisolated private static func collectErrors(since: Date) async -> [(String, String, Int)] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since),
                                                  matching: NSPredicate(format: "subsystem == %@", MixLog.subsystem))
        else { return [] }
        var counts: [String: (String, String, Int)] = [:]
        for case let entry as OSLogEntryLog in entries where entry.level == .error || entry.level == .fault {
            let message = String(entry.composedMessage.prefix(500))
            let key = entry.category + "|" + message
            counts[key, default: (entry.category, message, 0)].2 += 1
        }
        return Array(counts.values.sorted { $0.2 > $1.2 }.prefix(20))
    }
}
