// StubSyncService.swift
// Mixtape — Core Services
//
// No-op SyncServiceProtocol implementation for tests and previews.

import Foundation
import Combine

@MainActor
public final class StubSyncService: ObservableObject, SyncServiceProtocol {

    @Published private(set) public var syncState: SyncState = .idle

    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        $syncState.eraseToAnyPublisher()
    }

    private var backgroundTask: Task<Void, Never>?

    public init() {}

    public func onSignIn(user: AppUser, accessToken: String) async {
        syncState = .idle
        print("[StubSyncService] signed in as \(user.email) — sync not yet implemented")
    }

    public func onSignOut() async {
        stopBackgroundSync()
        syncState = .idle
    }

    public func sync() async throws {
        // No-op; local-only
        print("[StubSyncService] sync() called — stub, no-op")
    }

    public func push<T: Codable>(_ entity: T, table: String) async throws {
        print("[StubSyncService] push() to '\(table)' — stub, no-op")
    }

    public func startBackgroundSync(intervalSeconds: TimeInterval) {
        stopBackgroundSync()
        backgroundTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                if !Task.isCancelled {
                    try? await sync()
                }
            }
        }
    }

    public func stopBackgroundSync() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    public func resolveConflict(entityID: UUID, resolution: ConflictResolution) async throws {
        print("[StubSyncService] resolveConflict for \(entityID) — stub, no-op")
    }
}
