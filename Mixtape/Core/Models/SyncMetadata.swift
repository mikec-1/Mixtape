// Sync state embedded in every syncable entity.

import Foundation

// MARK: - Sync Status

/// The lifecycle of a local record with respect to the remote server.
public enum SyncStatus: String, Codable, Hashable, CaseIterable {
    /// Created locally; no sync account exists or sync not yet attempted.
    case localOnly
    /// Local changes waiting to upload.
    case pending
    /// Local record matches the server's last-known state.
    case synced
    /// Local record has been modified since last sync; upload needed.
    case modified
    /// Changed on both sides since the last sync.
    case conflict
    /// Soft-deleted locally; server deletion pending confirmation.
    case deleted
}

// MARK: - Sync Metadata

/// Written by SyncService only.
public struct SyncMetadata: Codable, Hashable {

    // MARK: Server identity
    /// Server id, nil until first upload.
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
    /// Per-device id, stored in UserDefaults.
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

/// File metadata for audio-backed entities.
public nonisolated struct FileProvenance: Codable, Hashable, Sendable {
    /// SHA-256 of the file, used to skip duplicate uploads.
    public var fileHash: String
    /// File size in bytes.
    public var fileSize: Int64
    /// Resolve through AudioPaths, not by appending to a directory.
    public var localPath: String
    /// Storage key, nil until uploaded.
    public var remoteKey: String?
    /// Whether the file has been successfully uploaded to Supabase Storage.
    public var uploaded: Bool
    /// When this device last downloaded the file from Supabase Storage.
    public var downloadedAt: Date?
    /// Stored, see TrackOrigin.
    public var origin: TrackOrigin
    /// Resolver key for online rows: the video id once picked, else "title|artist".
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

    /// A saved Discover song: metadata and a source ref only.
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

    /// An edit with no file on this device yet; rendered from its recipe when played.
    public static let editPlaceholder = FileProvenance(
        fileHash:     "",
        fileSize:     0,
        localPath:    "",
        remoteKey:    nil,
        uploaded:     false,
        downloadedAt: nil,
        origin:       .edit,
        sourceRef:    nil
    )

    /// A watched-folder file, played in place. Absolute path, never uploaded.
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

    /// Guesses the origin for rows written before it was stored.
    /// Persistence layer only.
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
