// SupabaseConfig.swift
// Mixtape — Core/Config
//
// The SupabaseClient is created once here and shared across all
// Supabase-backed services (auth, metadata sync, file storage).

import Foundation
import Supabase

public enum SupabaseConfig {

    // MARK: - Credentials

    static let projectURL = URL(string: "https://ldayhsncewjbstsmtzad.supabase.co")!

    /// Publishable anon key — safe to ship in the client; access is gated by RLS.
    static let anonKey = "sb_publishable_-ZKFsCnU1HKSxCBRt6hLOA_eWgjR6U6"

    // MARK: - Shared Client

    /// Single SupabaseClient shared by all services.
    /// Owns its own URLSession; do not create additional instances.
    public static let client = SupabaseClient(
        supabaseURL: projectURL,
        supabaseKey: anonKey,
        options: .init(
            auth: .init(
                // File-backed session storage instead of the Keychain — avoids
                // the recurring keychain-password prompt caused by ad-hoc
                // signing. See FileAuthLocalStorage for the full rationale.
                storage: FileAuthLocalStorage(),
                emitLocalSessionAsInitialSession: true
            )
        )
    )

    // MARK: - Realtime Socket
}

extension SupabaseClient {

    /// Opens the Realtime socket once, before any channel subscribes.
    ///
    /// Two channels subscribing on a *cold* socket both call the SDK's
    /// `connect()`. Its second run installs a fresh WebSocket event handler and
    /// then cancels the first listener task — and that stream's `onTermination`
    /// sets `onEvent = nil`, wiping the handler that just replaced it. The
    /// socket stays open and completely silent: every `phx_reply` is dropped, so
    /// each join burns 5 attempts × 10 s and fails with "Maximum retry attempts
    /// reached" (supabase-swift 2.47.0). That is what kept continuity, the
    /// library listener and the revocation listener all dead for the first
    /// ~70 s after launch, when they subscribe together.
    ///
    /// Connecting first avoids it: `subscribe()` skips `connect()` entirely when
    /// the socket is already connected — which is also why this must not call
    /// `connect()` on a live socket.
    func connectRealtimeSocket() async {
        guard realtimeV2.status != .connected else { return }
        await realtimeV2.connect()
    }

    /// Throws the socket away and opens a new one.
    ///
    /// iOS tears the websocket down while the app is backgrounded without the
    /// SDK noticing: `status` still reads `.connected`, so `connectRealtimeSocket()`
    /// correctly no-ops and the next `subscribe()` waits on a socket that will
    /// never answer. Only for the retry path — a join that timed out has already
    /// proved the socket is dead.
    func reconnectRealtimeSocket() async {
        await realtimeV2.disconnect()
        await realtimeV2.connect()
    }

    /// Subscribes with a deadline, throwing `JoinTimedOut` past it.
    ///
    /// The SDK can't tell a slow join from one whose reply will never arrive,
    /// so it burns 5 attempts × 10 s before erroring — a minute of a listener
    /// simply not working. A healthy join is ~0.4 s, so anything past ten
    /// seconds is a dead socket, not a slow network.
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

    /// The listeners' version: they have nowhere to report a failure to, so a
    /// timeout replaces the socket and tries once more on the fresh one.
    func join(_ channel: RealtimeChannelV2, label: String) async {
        do {
            try await joinWithDeadline(channel)
        } catch {
            print("[Realtime] \(label) join failed (\(error)) — replacing the socket")
            await reconnectRealtimeSocket()
            await channel.subscribe()
        }
    }
}

struct JoinTimedOut: Error {}

extension SupabaseConfig {

    // MARK: - Warm-up

    /// Builds the shared client off the main actor.
    ///
    /// `client` is a `static let`, so it is already lazy — the cost is simply
    /// paid by whoever touches it first, and that used to be `AppDependencies.init`
    /// on the main thread before the first frame (~1.3 s). Every holder now defers
    /// its access, but the auth listener wakes moments after launch and would just
    /// rebuild it on the main actor instead. `nonisolated` + `async` is what
    /// actually leaves the main actor (SE-0338); `Task.detached` would not, because
    /// the closure literal inherits the caller's isolation.
    public nonisolated static func warm() async {
        _ = client
    }
}
