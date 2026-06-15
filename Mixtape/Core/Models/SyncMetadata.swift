// SyncMetadata.swift
// Mixtape — Core Domain Models
//
// Embedded in every syncable entity.
// Tracks the record's relationship with the Supabase backend.

import Foundation

// MARK: - Sync Status

/// The lifecycle of a local record with respect to the remote server.
public enum SyncStatus: String, Codable, Hashable, CaseIterable {
    /// Created locally; no sync account exists or sync not yet attempted.
    case localOnly
    /// Queued for upload — local changes exist that haven't reached the server yet.
    case pending
    /// Local record matches the server's last-known state.
    case synced
    /// Local record has been modified since last sync; upload needed.
    case modified
    /// Server record changed AND local record also changed since last sync.
    /// Requires conflict resolution before next sync.
    case conflict
    /// Soft-deleted locally; server deletion pending confirmation.
    case deleted
}

// MARK: - Sync Metadata

/// Embedded in every entity that participates in cloud sync.
/// Updated by `SyncService` — do not mutate directly from the UI.
public struct SyncMetadata: Codable, Hashable {

    // MARK: Server identity
    /// The server-side UUID assigned by Supabase on first successful upload.
    /// `nil` until the record has been synced at least once.
    public var serverID: String?

    // MARK: Status
    public var status: SyncStatus

    // MARK: Timestamps
    /// Set on every local write. Used for Last-Write-Wins conflict resolution.
    public var localModifiedAt: Date
    /// The `updated_at` value returned by the server on the last successful sync.
    public var serverModifiedAt: Date?
    /// Wall-clock time of the last successful round-trip with the server.
    public var lastSyncedAt: Date?

    // MARK: Device identity
    /// Stable per-device identifier so the server can attribute changes.
    /// Stored in UserDefaults on first launch (no auth required).
    public var deviceID: String

    // MARK: Initialisers

    /// Full init used when restoring records from SwiftData persistence.
    public init(
        serverID: String?,
        status: SyncStatus,
        localModifiedAt: Date,
        serverModifiedAt: Date?,
        lastSyncedAt: Date?,
        deviceID: String
    ) {
        self.serverID           = serverID
        self.status             = status
        self.localModifiedAt    = localModifiedAt
        self.serverModifiedAt   = serverModifiedAt
        self.lastSyncedAt       = lastSyncedAt
        self.deviceID           = deviceID
    }

    /// Convenience init for brand-new local-only records.
    public init(deviceID: String) {
        self.serverID           = nil
        self.status             = .localOnly
        self.localModifiedAt    = Date()
        self.serverModifiedAt   = nil
        self.lastSyncedAt       = nil
        self.deviceID           = deviceID
    }

    // MARK: Helpers

    /// Mark the record as locally modified and queue it for upload.
    public mutating func markModified() {
        localModifiedAt = Date()
        status = (status == .localOnly) ? .localOnly : .modified
    }

    /// Called by SyncService after a successful push to the server.
    public mutating func markSynced(serverID: String, serverModifiedAt: Date) {
        self.serverID           = serverID
        self.serverModifiedAt   = serverModifiedAt
        self.lastSyncedAt       = Date()
        self.status             = .synced
    }

    /// Called by SyncService when it detects a conflict.
    public mutating func markConflict() {
        status = .conflict
    }

    /// Soft-delete: mark for server-side removal.
    public mutating func markDeleted() {
        status = .deleted
        localModifiedAt = Date()
    }
}

// MARK: - File Provenance

/// Additional sync metadata for entities backed by an audio file.
/// Enables content-addressed deduplication and lazy remote download.
public struct FileProvenance: Codable, Hashable {
    /// SHA-256 hex digest of the raw audio file bytes.
    /// Used for deduplication: if the server already has this hash, no upload is needed.
    public var fileHash: String
    /// File size in bytes.
    public var fileSize: Int64
    /// Path of the local file, relative to the app's Documents directory.
    /// Absolute path reconstruction: `URL.documentsDirectory.appending(path: localPath)`
    public var localPath: String
    /// Supabase Storage object key (e.g. `audio/<userID>/<hash>.m4a`).
    /// `nil` until the file has been uploaded.
    public var remoteKey: String?
    /// Whether the file has been successfully uploaded to Supabase Storage.
    public var uploaded: Bool
    /// When this device last downloaded the file from Supabase Storage.
    public var downloadedAt: Date?

    /// Convenience init for freshly imported files (not yet uploaded).
    public init(fileHash: String, fileSize: Int64, localPath: String) {
        self.fileHash     = fileHash
        self.fileSize     = fileSize
        self.localPath    = localPath
        self.remoteKey    = nil
        self.uploaded     = false
        self.downloadedAt = nil
    }

    /// Full init for restoring from SwiftData persistence.
    public init(
        fileHash: String,
        fileSize: Int64,
        localPath: String,
        remoteKey: String?,
        uploaded: Bool,
        downloadedAt: Date?
    ) {
        self.fileHash     = fileHash
        self.fileSize     = fileSize
        self.localPath    = localPath
        self.remoteKey    = remoteKey
        self.uploaded     = uploaded
        self.downloadedAt = downloadedAt
    }

    /// Full local URL, resolved against the app's Documents directory.
    public var localURL: URL {
        URL.documentsDirectory.appending(path: localPath)
    }
}
