// SyncServiceProtocol.swift
// Mixtape — Core Protocols
//
// Implemented by StubSyncService and SupabaseSyncService.
// The sync service is the only component that talks to the remote database.
// All other services go through local repositories; sync runs in the background.

import Foundation
import Combine

// MARK: - Sync State

public enum SyncState: Equatable {
    /// No sync account; user is offline or unauthenticated.
    case idle
    /// Actively pushing/pulling records.
    case syncing
    /// Last sync completed without errors.
    case upToDate(lastSynced: Date)
    /// Pending local changes not yet uploaded (e.g. offline).
    case pendingChanges(count: Int)
    /// Last sync attempt failed.
    case error(String)
}

// MARK: - Conflict Resolution Strategy

public enum ConflictResolution {
    /// Server record wins — overwrites the local change.
    case serverWins
    /// Local record wins — will be re-pushed to the server.
    case localWins
}

// MARK: - Protocol

public protocol SyncServiceProtocol: AnyObject {

    /// Observable sync state for displaying in Settings / status indicators.
    var syncState: SyncState { get }
    var syncStatePublisher: AnyPublisher<SyncState, Never> { get }

    // MARK: Lifecycle

    /// Called after successful sign-in. Registers this device with the server.
    func onSignIn(user: AppUser, accessToken: String) async

    /// Called on sign-out. Stops background sync and clears any in-flight state.
    func onSignOut() async

    // MARK: Sync triggers

    /// Full sync: push all pending local changes, then pull all remote changes.
    func sync() async throws

    /// Push a single entity change immediately (e.g. playlist rename).
    /// Falls back to queuing if offline.
    func push<T: Codable>(_ entity: T, table: String) async throws

    // MARK: Background sync

    /// Start periodic background sync (call once on app foreground).
    func startBackgroundSync(intervalSeconds: TimeInterval)
    /// Stop background sync (call on app background / sign-out).
    func stopBackgroundSync()

    // MARK: Conflict resolution

    /// Resolve a conflict for the given entity ID.
    func resolveConflict(entityID: UUID, resolution: ConflictResolution) async throws
}
