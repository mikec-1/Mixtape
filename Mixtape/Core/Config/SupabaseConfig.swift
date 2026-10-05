// Shared SupabaseClient for auth, sync and storage.

import Foundation
import Supabase
import OSLog

public enum SupabaseConfig {

    // MARK: - Credentials

    nonisolated static let projectURL = URL(string: "https://ldayhsncewjbstsmtzad.supabase.co")!

    /// Publishable anon key, safe to ship in the client; access is gated by RLS.
    nonisolated static let anonKey = "sb_publishable_-ZKFsCnU1HKSxCBRt6hLOA_eWgjR6U6"

    // MARK: - Shared Client

    /// Single shared client. Don't create more.
    public nonisolated static let client = SupabaseClient(
        supabaseURL: projectURL,
        supabaseKey: anonKey,
        options: .init(
            auth: .init(
                // File-backed instead of Keychain to avoid keychain prompts with ad-hoc signing.
                // See FileAuthLocalStorage.
                storage: FileAuthLocalStorage(),
                emitLocalSessionAsInitialSession: true
            )
        )
    )

    // MARK: - Realtime Socket
}

extension SupabaseClient {

    /// Opens the Realtime socket once, before any channel subscribes. Two channels
    /// subscribing on a cold socket both call `connect()`, and the second wipes the first's
    /// event handler, leaving a silent socket (supabase-swift 2.47.0). `subscribe()` skips
    /// `connect()` on a live socket, so this must not call it on one either.
    func connectRealtimeSocket() async {
        guard realtimeV2.status != .connected else { return }
        await realtimeV2.connect()
    }

    /// Replaces the socket. iOS kills it in the background while `status` still reads
    /// `.connected`. Only for the retry path, after a join timed out.
    func reconnectRealtimeSocket() async {
        realtimeV2.disconnect()
        await realtimeV2.connect()
    }

    /// Subscribes with a deadline, throwing `JoinTimedOut`. The SDK retries 5 x 10s on a dead
    /// socket; a healthy join takes well under a second.
    func joinWithDeadline(_ channel: RealtimeChannelV2,
                          _ timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await channel.subscribeWithError() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw JoinTimedOut()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// For listeners: on timeout, replace the socket and try once more.
    func join(_ channel: RealtimeChannelV2, label: String) async {
        do {
            try await joinWithDeadline(channel)
        } catch {
            MixLog.sync.error("[Realtime] \(label) join failed (\(error)), replacing the socket")
            await reconnectRealtimeSocket()
            try? await channel.subscribeWithError()
        }
    }
}

struct JoinTimedOut: Error {}

extension SupabaseConfig {

    // MARK: - Warm-up

    /// Builds the shared client off the main actor so launch doesn't pay for it.
    /// `nonisolated async` leaves the main actor (SE-0338); `Task.detached` wouldn't.
    public nonisolated static func warm() async {
        _ = client
    }
}
