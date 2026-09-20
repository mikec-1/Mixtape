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

    // Held as a provider rather than a value: building the SupabaseClient costs
    // ~1.3 s and, taken eagerly in `AppDependencies.init`, that whole second sat
    // on the main thread before the first frame. `@autoclosure` keeps every call
    // site written exactly as before while moving the work to first real use —
    // which is a network call, and so already off the launch path.
    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    private static let bucket = "audio"

    /// Set by AppDependencies when the user signs in; cleared on sign-out.
    public var currentUserID: UUID?

    // MARK: - Init

    public init(client: @autoclosure @escaping () -> SupabaseClient) {
        self.clientProvider = client
        // Empty the pre-split Documents/Music/ folder into the durable imports
        // directory. This used to sweep it into Library/Caches/Music/ instead,
        // which quietly made every imported original OS-purgeable.
        Task.detached(priority: .background) {
            AudioPaths.migrateLegacyDocumentsMusic()
        }
    }

    // MARK: - Upload

    /// Uploads the audio file for `track` and returns the remote storage path.
    /// The caller (SupabaseSyncService) writes the returned key back to the DB.
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

    /// Library/Caches/Music/ — private to the app, invisible in Files, not backed up,
    /// and evictable by the OS. Downloaded copies only; see `AudioPaths`.
    /// `nonisolated` so it can be read from background threads.
    nonisolated static var cacheDirectory: URL { AudioPaths.cacheDirectory }

    /// Where this track's audio is on disk, or nil if it isn't.
    ///
    /// Delegates to `AudioLocator` so that every caller — playback, downloads,
    /// export, the badge in the track list — agrees about which copy wins. The
    /// ordering used to be duplicated here and differed from the engine's, which
    /// is how a song could be "playable" and "not downloaded" simultaneously.
    public func localURL(for track: Track) -> URL? {
        AudioLocator.readyURL(for: track)
    }

    /// Every directory that can hold library audio. `localURL(for:)` reads from
    /// all of them, so anything that wipes audio has to empty all of them — a
    /// wipe that clears one path leaves files on disk the app goes on playing.
    nonisolated static var audioDirectories: [URL] { AudioPaths.allAudioDirectories }

    /// Empties every audio directory, imports included. This is the *deletion*
    /// path (Clear Everything / Delete All Music), not the cache-clear one —
    /// see `clearLocalCache()`. `nonisolated static` so the destructive library
    /// actions can reach it without holding a storage instance.
    nonisolated static func purgeLocalAudio() {
        let fm = FileManager.default
        for dir in audioDirectories {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items { try? fm.removeItem(at: url) }
        }
    }

    /// Clears only what can be fetched again. The imports directory is left
    /// alone on purpose: for a track that was never uploaded, the file there is
    /// the only copy that exists, and "Clear Playback Cache" is not a request to
    /// delete the user's music.
    public func clearLocalCache() throws {
        PlaybackCache.clear()
        // The legacy Documents folder is a cache too, for as long as anything is
        // still left in it.
        let fm  = FileManager.default
        let old = AudioPaths.legacyDocumentsDirectory
        if fm.fileExists(atPath: old.path(percentEncoded: false)) {
            let items = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
            for url in items { try? fm.removeItem(at: url) }
        }
    }

    /// Size of the purgeable cache only, to match what `clearLocalCache()` frees.
    ///
    /// This counts Discover audio as well now. It used to look only in the two
    /// directories that Supabase downloads land in, which on the Mac that
    /// authored the library are always empty — so the number was structurally
    /// zero no matter how much audio was actually cached.
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
