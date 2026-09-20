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
    public nonisolated init(
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
    public nonisolated init(deviceID: String) {
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
    /// Path of the local file. Historically Documents-relative; imports now live
    /// in Application Support, so resolve it through `AudioPaths`, never by
    /// appending to a directory yourself.
    public var localPath: String
    /// Supabase Storage object key (e.g. `audio/<userID>/<hash>.m4a`).
    /// `nil` until the file has been uploaded.
    public var remoteKey: String?
    /// Whether the file has been successfully uploaded to Supabase Storage.
    public var uploaded: Bool
    /// When this device last downloaded the file from Supabase Storage.
    public var downloadedAt: Date?
    /// Where the audio comes from, and therefore how it gets onto disk.
    /// Stored rather than inferred — see `TrackOrigin`.
    public var origin: TrackOrigin
    /// Resolver key for `.online` rows: the provider's video id once we've
    /// picked one, otherwise the `"title|artist"` search key. This is the whole
    /// content of an online placeholder — the row has no bytes, only this.
    public var sourceRef: String?

    /// Convenience init for freshly imported files (not yet uploaded).
    public init(fileHash: String, fileSize: Int64, localPath: String) {
        self.fileHash     = fileHash
        self.fileSize     = fileSize
        self.localPath    = localPath
        self.remoteKey    = nil
        self.uploaded     = false
        self.downloadedAt = nil
        self.origin       = .imported
        self.sourceRef    = nil
    }

    /// A Discover song saved to the library: metadata and a way to fetch it,
    /// nothing else. No path, no size, no upload.
    public static func onlinePlaceholder(sourceRef: String) -> FileProvenance {
        FileProvenance(
            fileHash:     "",
            fileSize:     0,
            localPath:    "",
            remoteKey:    nil,
            uploaded:     false,
            downloadedAt: nil,
            origin:       .online,
            sourceRef:    sourceRef
        )
    }

    /// A file in a watched folder, played where it lies.
    ///
    /// The path is absolute and points outside every Mixtape directory, which is
    /// deliberate: `AudioPaths.resolve` handles absolute paths, so playback works
    /// without a copy. `uploaded` is false and stays false — nothing ever offers
    /// these bytes to Supabase.
    public nonisolated static func localFile(path: String, fileSize: Int64) -> FileProvenance {
        FileProvenance(
            fileHash:     "",
            fileSize:     fileSize,
            localPath:    path,
            remoteKey:    nil,
            uploaded:     false,
            downloadedAt: nil,
            origin:       .localFile,
            sourceRef:    nil
        )
    }

    /// Full init for restoring from SwiftData persistence.
    public init(
        fileHash: String,
        fileSize: Int64,
        localPath: String,
        remoteKey: String?,
        uploaded: Bool,
        downloadedAt: Date?,
        origin: TrackOrigin = .imported,
        sourceRef: String? = nil
    ) {
        self.fileHash     = fileHash
        self.fileSize     = fileSize
        self.localPath    = localPath
        self.remoteKey    = remoteKey
        self.uploaded     = uploaded
        self.downloadedAt = downloadedAt
        self.origin       = origin
        self.sourceRef    = sourceRef
    }

    // MARK: Legacy inference

    /// What a row written before `origin` existed must have been.
    ///
    /// Only the persistence layer should call this, and only when the stored
    /// origin is absent. It reproduces the old heuristics exactly — an
    /// `OnlineCache` path or a `"title|artist"` hash meant Discover, empty
    /// everything meant an unresolvable shared row — so a store written by an
    /// older build reads back the way it always did.
    public static func inferOrigin(
        localPath: String,
        fileHash: String,
        fileSize: Int64,
        remoteKey: String?
    ) -> TrackOrigin {
        if localPath.contains("OnlineCache") || fileHash.contains("|") { return .online }
        if localPath.isEmpty && remoteKey == nil && fileSize == 0 && fileHash.isEmpty {
            return .unresolvableShare
        }
        if remoteKey == nil && fileSize == 0 { return .online }
        return .imported
    }

    /// Full local URL: the file if it's on disk, otherwise where it would go.
    public var localURL: URL {
        AudioPaths.url(forLocalPath: localPath)
    }
}
