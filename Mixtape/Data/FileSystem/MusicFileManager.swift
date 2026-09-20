// MusicFileManager.swift
// Mixtape — Data/FileSystem
//
// Copies imported audio files into the app's sandbox and computes a SHA-256
// content hash for deduplication. Files are stored at:
//   Application Support/Mixtape/Music/<sha256>.<extension>
//
// Content-addressed storage means importing the same file twice is a no-op.
//
// Application Support, not Documents and emphatically not Library/Caches: an
// imported original is frequently the only copy of that audio anywhere, so it
// must survive both an OS purge and a device restore. See `AudioPaths`.

import Foundation
import CryptoKit

public final class MusicFileManager {

    // MARK: - Paths

    /// Root directory for all imported music. Created on first use.
    public static var musicDirectory: URL { AudioPaths.importsDirectory }

    public init() {}

    // MARK: - Import

    /// Copy a file into the sandbox and return its `FileProvenance`.
    /// If a file with the same content hash already exists, the copy is skipped.
    ///
    /// - Parameter sourceURL: Security-scoped URL from the file picker.
    ///   The caller is responsible for starting/stopping security scope access.
    /// - Returns: `FileProvenance` describing the local file.
    public func importFile(from sourceURL: URL) throws -> FileProvenance {
        let hash     = try sha256(of: sourceURL)
        let ext      = sourceURL.pathExtension.lowercased()
        let filename = "\(hash).\(ext)"
        let destURL  = Self.musicDirectory.appending(path: filename)

        // Dedup: if the file is already there, reuse it
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        let attrs    = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        // Stored as a bare `Music/<file>` path rather than an absolute one: the
        // container's real path changes between installs and OS versions, and
        // `AudioPaths.resolve(localPath:)` knows every directory this can name.
        let relPath  = "Music/\(filename)"

        return FileProvenance(
            fileHash:  hash,
            fileSize:  fileSize,
            localPath: relPath
        )
    }

    // MARK: - Cache Management

    /// Total bytes used by all files in the Music sandbox folder.
    public func totalCacheSize() throws -> Int64 {
        let dir   = Self.musicDirectory
        let items = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return try items.reduce(0) { sum, url in
            let v = try url.resourceValues(forKeys: [.fileSizeKey])
            return sum + Int64(v.fileSize ?? 0)
        }
    }

    /// Delete a specific file by its stored path, wherever it resolves to.
    public func deleteFile(relativePath: String) throws {
        guard let url = AudioPaths.resolve(localPath: relativePath) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Delete all files in the Music sandbox folder.
    public func clearAll() throws {
        let dir = Self.musicDirectory
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        for item in items {
            try FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - SHA-256 (streaming, 1 MB chunks — handles large FLAC/WAV files)

    /// The content hash of a file that hasn't been imported: the same value
    /// `importFile` would store in its `FileProvenance`, without copying
    /// anything.
    public func contentHash(of url: URL) throws -> String {
        try sha256(of: url)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher    = SHA256()
        let chunkSize = 1024 * 1024  // 1 MB

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}
