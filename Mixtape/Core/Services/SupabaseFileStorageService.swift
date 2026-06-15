// SupabaseFileStorageService.swift
// Mixtape — Core/Services
//
// Uploads and downloads audio files to/from Supabase Storage.
//
// Storage path: <userID>/<sha256>.<ext>  (content-addressed, per-user)
//
// • Upload is triggered by SupabaseSyncService during each sync cycle.
//   Files are read on a background thread to avoid blocking the main actor.
// • Download is on-demand — called by the playback engine when a
//   synced track has no local file yet.
// • Progress: start-of-transfer (0 bytes) + end-of-transfer (total bytes).
//   Real-time byte progress is a Supabase Swift SDK limitation.
//
// AppDependencies sets `currentUserID` after sign-in and clears it on sign-out.

import Foundation
import Supabase
import Combine

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

@MainActor
public final class SupabaseFileStorageService: ObservableObject, FileStorageProtocol {

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

    private let client: SupabaseClient
    private static let bucket = "audio"

    /// Set by AppDependencies when the user signs in; cleared on sign-out.
    public var currentUserID: UUID?

    // MARK: - Init

    public init(client: SupabaseClient) {
        self.client = client
        // Move any leftover files from the old Documents/Music/ cache location.
        Task.detached(priority: .background) {
            Self.migrateOldCacheIfNeeded()
        }
    }

    // MARK: - Upload

    /// Uploads the audio file for `track` and returns the remote storage path.
    /// The caller (SupabaseSyncService) writes the returned key back to the DB.
    public func upload(track: Track, accessToken: String) async throws -> String {
        guard let userID = currentUserID else { throw FileStorageError.notAuthenticated }
        guard !track.file.localPath.isEmpty else { throw FileStorageError.noLocalFile }

        let localURL = URL.documentsDirectory.appending(path: track.file.localPath)
        guard FileManager.default.fileExists(atPath: localURL.path(percentEncoded: false)) else {
            throw FileStorageError.noLocalFile
        }

        let ext        = localURL.pathExtension.lowercased()
        let remotePath = Self.remotePath(userID: userID, fileHash: track.file.fileHash, ext: ext)

        uploadSubject.send(
            TransferProgress(entityID: track.id, bytesTransferred: 0, totalBytes: track.file.fileSize)
        )

        do {
            // Read file on a background thread — large lossless files can be 100+ MB.
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

    /// Downloads the file for `track` to Documents/Music/ and returns the local URL.
    /// The playback engine or a "Download All" action calls this.
    /// Updating `localPath` in SwiftData is the caller's responsibility.
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

        // Save to Library/Caches/Music/<fileHash>.<ext>
        // Caches/ is invisible to the user in the Files app, is not included in
        // iCloud backup, and can be pruned by iOS when storage is low.
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

    /// Downloads the raw audio bytes from Supabase Storage without writing to the
    /// local playback cache. Use this when you only need the file for a one-off
    /// export so the `Documents/Music/` cache folder is never created as a side-effect.
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

    /// Library/Caches/Music/ — private to the app, invisible in Files, not backed up.
    /// `nonisolated` so it can be read from background threads (e.g. during migration).
    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }

    /// Moves any files that were cached in the old `Documents/Music/` location to
    /// `Library/Caches/Music/` and removes the old directory. Safe to call repeatedly —
    /// exits immediately if the old directory no longer exists.
    nonisolated static func migrateOldCacheIfNeeded() {
        let fm     = FileManager.default
        let oldDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                       .appendingPathComponent("Music")
        guard fm.fileExists(atPath: oldDir.path) else { return }

        let newDir = cacheDirectory
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        let items = (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)) ?? []
        for src in items {
            let dst = newDir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
        }
        // Remove the old directory (now empty, or force-remove any stragglers).
        try? fm.removeItem(at: oldDir)
        print("[FileStorage] Migrated playback cache from Documents/Music/ to Library/Caches/Music/")
    }

    public func localURL(for track: Track) -> URL? {
        // 0. Check the user's public exported Mixtape folder first.
        if let exportedURL = ExportManager.shared.exportedURL(for: track) {
            return exportedURL
        }

        // 1. Prefer the stored localPath (may be absolute or relative to Documents).
        if !track.file.localPath.isEmpty {
            let url = URL.documentsDirectory.appending(path: track.file.localPath)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        // 2. Check the current cache location: Library/Caches/Music/<hash>.<ext>
        if let remoteKey = track.file.remoteKey {
            let ext      = URL(fileURLWithPath: remoteKey).pathExtension.lowercased()
            let filename = "\(track.file.fileHash).\(ext)"
            let url      = Self.cacheDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        // 3. Legacy fallback: Documents/Music/ (old location before cache was moved).
        if let remoteKey = track.file.remoteKey {
            let ext      = URL(fileURLWithPath: remoteKey).pathExtension.lowercased()
            let filename = "\(track.file.fileHash).\(ext)"
            let url      = URL.documentsDirectory.appending(path: "Music/\(filename)")
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return nil
    }

    public func clearLocalCache() throws {
        for dir in [Self.cacheDirectory,
                    URL.documentsDirectory.appending(path: "Music")] {
            guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for url in items { try? FileManager.default.removeItem(at: url) }
        }
    }

    public func localCacheSize() throws -> Int64 {
        var total = Int64(0)
        for dir in [Self.cacheDirectory,
                    URL.documentsDirectory.appending(path: "Music")] {
            guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            let items = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
            for url in items {
                total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Internal Helpers (used by SupabaseSyncService)

    static func remotePath(userID: UUID, fileHash: String, ext: String) -> String {
        // Use lowercased UUID — PostgreSQL auth.uid()::text is lowercase,
        // so the folder name must match exactly for RLS to pass.
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
