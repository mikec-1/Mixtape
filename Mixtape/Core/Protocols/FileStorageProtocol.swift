// FileStorageProtocol.swift
// Mixtape — Core Protocols
//
// Implemented by StubFileStorageService and SupabaseFileStorageService.
// Handles audio file upload/download to/from Supabase Storage.

import Foundation
import Combine

// MARK: - Transfer Progress

public struct TransferProgress: Equatable {
    public let entityID: UUID
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

// MARK: - Protocol

public protocol FileStorageProtocol: AnyObject {

    /// Publisher emitting upload progress events.
    var uploadProgressPublisher: AnyPublisher<TransferProgress, Never> { get }
    /// Publisher emitting download progress events.
    var downloadProgressPublisher: AnyPublisher<TransferProgress, Never> { get }

    // MARK: Upload

    /// Upload the audio file for `track` to remote storage.
    /// Returns the remote object key (stored back into `track.file.remoteKey`).
    /// Uses content-addressed key: `audio/<userID>/<fileHash>.<ext>`.
    /// If the server already has a file with the same hash, returns the existing key (dedup).
    func upload(track: Track, accessToken: String) async throws -> String

    // MARK: Download

    /// Download the audio file for `track` to the local sandbox.
    /// Updates `track.file.localPath` and `track.file.downloadedAt`.
    func download(track: Track, accessToken: String) async throws -> URL

    // MARK: Delete

    /// Remove a file from remote storage (called when a track is hard-deleted).
    func delete(remoteKey: String, accessToken: String) async throws

    // MARK: Local cache management

    /// Returns the local file URL if it exists, nil otherwise.
    func localURL(for track: Track) -> URL?

    /// Remove all locally cached audio files (e.g. user taps "Clear Cache" in Settings).
    func clearLocalCache() throws

    /// Total size of the local audio cache in bytes.
    func localCacheSize() throws -> Int64
}
