// Copies imported audio into Application Support/Mixtape/Music/<sha256>.<ext>.
// Content-addressed, so importing the same file twice is a no-op. Not Caches:
// an import may be the only copy. See `AudioPaths`.

import Foundation
import CryptoKit

public final class MusicFileManager {

    // MARK: - Paths

    /// Root directory for all imported music. Created on first use.
    public static var musicDirectory: URL { AudioPaths.importsDirectory }

    public init() {}

    // MARK: - Import

    /// Copies a file in and returns its `FileProvenance`, skipping the copy if the
    /// hash already exists. The caller manages security scope.
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
        // Relative path, since the container path changes; `AudioPaths.resolve` handles it.
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

    // MARK: - SHA-256 (streaming, 1 MB chunks for large FLAC/WAV)

    /// A file's content hash without importing it.
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
