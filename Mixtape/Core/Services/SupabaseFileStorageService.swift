// Audio upload/download with Supabase Storage at
// `<userID>/<sha256>.<ext>` (content-addressed, per user).
// Uploads run during sync; downloads on demand when a synced track has no local
// file. Progress is start/end only (SDK limitation).
// `currentUserID` is set by AppDependencies on sign-in/out.

import Foundation
import Supabase
import Combine
import Observation

// MARK: - Errors

public enum FileStorageError: LocalizedError {
    case notAuthenticated
    case noLocalFile
    case noRemoteKey
    case uploadFailed(Error)
    case downloadFailed(Error)
    case saveFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "Not signed in."
        case .noLocalFile:            return "Local audio file not found."
        case .noRemoteKey:            return "Track has no remote storage key."
        case .uploadFailed(let e):    return "Upload failed: \(e.localizedDescription)"
        case .downloadFailed(let e):  return "Download failed: \(e.localizedDescription)"
        case .saveFailed(let e):      return "Could not save file: \(e.localizedDescription)"
        }
    }
}

// MARK: - Service

@Observable
@MainActor
public final class SupabaseFileStorageService: FileStorageProtocol {

    // MARK: - Progress Publishers

    private let uploadSubject   = PassthroughSubject<TransferProgress, Never>()
    private let downloadSubject = PassthroughSubject<TransferProgress, Never>()

    public var uploadProgressPublisher: AnyPublisher<TransferProgress, Never> {
        uploadSubject.eraseToAnyPublisher()
    }
    public var downloadProgressPublisher: AnyPublisher<TransferProgress, Never> {
        downloadSubject.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    // Deferred: building the client is slow and must stay off the launch path.
    private let clientProvider: () -> SupabaseClient
    @ObservationIgnored private lazy var client: SupabaseClient = clientProvider()
    static let bucket = "audio"

    /// Set by AppDependencies when the user signs in; cleared on sign-out.
    @ObservationIgnored public var currentUserID: UUID?

    // MARK: - Init

    public init(client: @autoclosure @escaping () -> SupabaseClient) {
        self.clientProvider = client
        // Move the old Documents/Music/ folder into the durable imports directory.
        Task.detached(priority: .background) {
            AudioPaths.migrateLegacyDocumentsMusic()
        }
    }

    // MARK: - Upload

    /// Uploads the track's audio and returns the storage path for the caller to save.
    public func upload(track: Track, accessToken: String) async throws -> String {
        guard let userID = currentUserID else { throw FileStorageError.notAuthenticated }
        guard !track.file.localPath.isEmpty else { throw FileStorageError.noLocalFile }

        guard let localURL = AudioPaths.resolve(localPath: track.file.localPath) else {
            throw FileStorageError.noLocalFile
        }

        let ext        = localURL.pathExtension.lowercased()
        let remotePath = Self.remotePath(userID: userID, fileHash: track.file.fileHash, ext: ext)

        uploadSubject.send(
            TransferProgress(entityID: track.id, bytesTransferred: 0, totalBytes: track.file.fileSize)
        )

        do {
            // Off the main thread; lossless files can be 100+ MB.
            let data = try await readFile(at: localURL)
            try await client.storage
                .from(Self.bucket)
                .upload(
                    remotePath,
                    data:    data,
                    options: FileOptions(contentType: Self.contentType(for: ext), upsert: true)
                )
        } catch {
            throw FileStorageError.uploadFailed(error)
        }

        uploadSubject.send(
            TransferProgress(
                entityID:         track.id,
                bytesTransferred: track.file.fileSize,
                totalBytes:       track.file.fileSize
            )
        )
        return remotePath
    }

    // MARK: - Download

    /// Downloads the track's audio into the cache and returns the local URL. The
    /// caller updates `localPath`.
    public func download(track: Track, accessToken: String) async throws -> URL {
        guard let remoteKey = track.file.remoteKey, !remoteKey.isEmpty else {
            throw FileStorageError.noRemoteKey
        }

        downloadSubject.send(
            TransferProgress(entityID: track.id, bytesTransferred: 0, totalBytes: track.file.fileSize)
        )

        let data: Data
        do {
            data = try await client.storage
                .from(Self.bucket)
                .download(path: remoteKey)
        } catch {
            throw FileStorageError.downloadFailed(error)
        }

        // Caches/: hidden from Files, not backed up, purgeable.
        let ext      = URL(fileURLWithPath: remoteKey).pathExtension.lowercased()
        let filename = "\(track.file.fileHash).\(ext)"
        let musicDir = Self.cacheDirectory
        let destURL  = musicDir.appending(path: filename)

        do {
            try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
            try await writeFile(data: data, to: destURL)
        } catch {
            throw FileStorageError.saveFailed(error)
        }

        downloadSubject.send(
            TransferProgress(
                entityID:         track.id,
                bytesTransferred: Int64(data.count),
                totalBytes:       Int64(data.count)
            )
        )
        return destURL
    }

    // MARK: - Raw Download (export-only, no cache)

    /// Raw bytes without touching the cache, for one-off exports.
    public func downloadRawData(track: Track, accessToken: String) async throws -> Data {
        guard let remoteKey = track.file.remoteKey, !remoteKey.isEmpty else {
            throw FileStorageError.noRemoteKey
        }
        do {
            return try await client.storage
                .from(Self.bucket)
                .download(path: remoteKey)
        } catch {
            throw FileStorageError.downloadFailed(error)
        }
    }

    // MARK: - Delete

    public func delete(remoteKey: String, accessToken: String) async throws {
        _ = try await client.storage
            .from(Self.bucket)
            .remove(paths: [remoteKey])
    }

    // MARK: - Local Cache

    /// Library/Caches/Music/: downloaded copies only. See `AudioPaths`.
    nonisolated static var cacheDirectory: URL { AudioPaths.cacheDirectory }

    /// The track's audio on disk, or nil. Delegates to `AudioLocator` so every
    /// caller agrees which copy wins.
    public func localURL(for track: Track) -> URL? {
        AudioLocator.readyURL(for: track)
    }

    /// Every directory that can hold library audio. Wipes must empty all of them.
    nonisolated static var audioDirectories: [URL] { AudioPaths.allAudioDirectories }

    /// Deletes all audio, imports included (Clear Everything / Delete All Music).
    /// Not the cache clear; see `clearLocalCache()`.
    nonisolated static func purgeLocalAudio() {
        let fm = FileManager.default
        for dir in audioDirectories {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items { try? fm.removeItem(at: url) }
        }
    }

    /// Clears re-fetchable audio only. Imports stay: they may be the only copy.
    public func clearLocalCache() throws {
        PlaybackCache.clear()
        // The legacy Documents folder counts as cache.
        let fm  = FileManager.default
        let old = AudioPaths.legacyDocumentsDirectory
        if fm.fileExists(atPath: old.path(percentEncoded: false)) {
            let items = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
            for url in items { try? fm.removeItem(at: url) }
        }
    }

    /// Size of the purgeable cache (what `clearLocalCache()` frees), Discover audio included.
    public func localCacheSize() throws -> Int64 {
        var total = PlaybackCache.totalBytes
        let old = AudioPaths.legacyDocumentsDirectory
        if FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) {
            let items = try FileManager.default.contentsOfDirectory(
                at: old, includingPropertiesForKeys: [.fileSizeKey])
            for url in items {
                total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Internal Helpers (used by SupabaseSyncService)

    static func remotePath(userID: UUID, fileHash: String, ext: String) -> String {
        // Lowercased to match `auth.uid()::text` for RLS.
        "\(userID.uuidString.lowercased())/\(fileHash).\(ext)"
    }

    static func contentType(for ext: String) -> String {
        switch ext {
        case "mp3":         return "audio/mpeg"
        case "m4a":         return "audio/mp4"
        case "aac":         return "audio/aac"
        case "flac":        return "audio/flac"
        case "wav":         return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default:            return "audio/mpeg"
        }
    }

    // MARK: - Private Threading Helpers

    /// Reads a file on the cooperative thread pool so the main actor is not blocked.
    private func readFile(at url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }

    /// Writes data on the cooperative thread pool so the main actor is not blocked.
    private func writeFile(data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: .atomic)
        }.value
    }
}
