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

    /// Uploads to `audio/<userID>/<fileHash>.<ext>`, returning the existing key
    /// if that hash is already there.
    func upload(track: Track, accessToken: String) async throws -> String

    // MARK: Download

    func download(track: Track, accessToken: String) async throws -> URL

    // MARK: Delete

    /// Remove a file from remote storage (called when a track is hard-deleted).
    func delete(remoteKey: String, accessToken: String) async throws

    // MARK: Local cache management

    /// Returns the local file URL if it exists, nil otherwise.
    func localURL(for track: Track) -> URL?

    func clearLocalCache() throws

    /// Total size of the local audio cache in bytes.
    func localCacheSize() throws -> Int64
}
