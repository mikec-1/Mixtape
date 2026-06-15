// MusicFileManager.swift
// Mixtape — Data/FileSystem
//
// Copies imported audio files into the app's sandbox and computes a SHA-256
// content hash for deduplication. Files are stored at:
//   Documents/Music/<sha256>.<extension>
//
// Content-addressed storage means importing the same file twice is a no-op.

import Foundation
import CryptoKit

public final class MusicFileManager {

    // MARK: - Paths

    /// Root directory for all imported music. Created on first use.
    public static var musicDirectory: URL {
        let docs = URL.documentsDirectory
        let music = docs.appending(path: "Music", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        return music
    }

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
        let relPath  = "Music/\(filename)"   // relative to Documents/

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

    /// Delete a specific file by its relative path.
    public func deleteFile(relativePath: String) throws {
        let url = URL.documentsDirectory.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
