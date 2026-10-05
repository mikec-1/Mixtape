// Where library audio lives on disk.
// Imports (App Support/Mixtape/Music) are durable, they may be the only copy.
// The cache (Library/Caches/Music) holds re-downloadable copies and is purgeable.
// Documents/Music is the old location and gets migrated away.

import Foundation
import OSLog

public nonisolated enum AudioPaths {

    // MARK: - Directories

    /// Imported originals. Durable and backed up.
    nonisolated public static var importsDirectory: URL { importsDirectoryOnce }

    /// Created once rather than on every read.
    nonisolated private static let importsDirectoryOnce: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Music",   isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Downloaded copies. Purgeable.
    nonisolated public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }

    /// Old location, only read and migrated.
    nonisolated public static var legacyDocumentsDirectory: URL {
        URL.documentsDirectory.appending(path: "Music", directoryHint: .isDirectory)
    }

    /// Everything a library wipe has to empty.
    public static var allAudioDirectories: [URL] {
        [importsDirectory, cacheDirectory, legacyDocumentsDirectory]
    }

    /// What "Clear Playback Cache" may delete. Imports are excluded.
    public static var purgeableAudioDirectories: [URL] {
        [cacheDirectory, legacyDocumentsDirectory]
    }

    // MARK: - Resolution

    /// The file a stored localPath points at, or nil. Handles absolute paths,
    /// `Music/<file>` and the Discover cache's `../Library/Caches/...` form.
    public static func resolve(localPath: String) -> URL? {
        guard !localPath.isEmpty else { return nil }
        let fm = FileManager.default
        for candidate in candidates(for: localPath) {
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    /// Like `resolve`, but falls back to where the file would be.
    public static func url(forLocalPath localPath: String) -> URL {
        resolve(localPath: localPath) ?? candidates(for: localPath).first!
    }

    /// The user's own copy (imports or legacy), ignoring cache copies.
    public static func durableURL(forLocalPath localPath: String) -> URL? {
        guard !localPath.isEmpty else { return nil }
        let fm   = FileManager.default
        let name = (localPath as NSString).lastPathComponent
        var checked: [URL] = []
        if localPath.hasPrefix("/") {
            checked = [URL(fileURLWithPath: localPath)]
        } else {
            checked = [importsDirectory.appendingPathComponent(name),
                       legacyDocumentsDirectory.appendingPathComponent(name)]
        }
        return checked.first { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Removes every copy, otherwise resolution finds the leftover duplicate.
    nonisolated public static func removeAllCopies(ofLocalPath localPath: String) {
        guard !localPath.isEmpty else { return }
        let fm = FileManager.default
        for url in candidates(for: localPath)
        where fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.removeItem(at: url)
        }
    }

    /// Ordered by preference, most-likely-correct first.
    nonisolated private static func candidates(for localPath: String) -> [URL] {
        if localPath.hasPrefix("/") { return [URL(fileURLWithPath: localPath)] }

        var result: [URL] = []
        let name = (localPath as NSString).lastPathComponent

        // Imports first: a download can be replaced, an import can't.
        if localPath.hasPrefix("Music/") {
            result.append(importsDirectory.appendingPathComponent(name))
            result.append(cacheDirectory.appendingPathComponent(name))
            result.append(legacyDocumentsDirectory.appendingPathComponent(name))
        } else {
            // Anything else is Documents-relative.
            result.append(URL.documentsDirectory.appending(path: localPath))
            result.append(importsDirectory.appendingPathComponent(name))
            result.append(cacheDirectory.appendingPathComponent(name))
        }
        return result
    }

    // MARK: - Migration

    /// Moves Documents/Music into imports, not the cache. Imports and downloads
    /// can't be told apart there, so err on the side of keeping them.
    public static func migrateLegacyDocumentsMusic() {
        let fm     = FileManager.default
        let oldDir = legacyDocumentsDirectory
        guard fm.fileExists(atPath: oldDir.path(percentEncoded: false)) else { return }

        let dest = importsDirectory
        let items = (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)) ?? []
        var moved = 0
        for src in items {
            let dst = dest.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
                try? fm.removeItem(at: src)  // same hash, keep the existing copy
            } else if (try? fm.moveItem(at: src, to: dst)) != nil {
                moved += 1
            }
        }
        try? fm.removeItem(at: oldDir)
        if moved > 0 {
            MixLog.library.debug("[AudioPaths] Migrated \(moved) file(s) from Documents/Music/ to Application Support")
        }
    }

    /// Moves never-uploaded files back out of the purgeable cache.
    @discardableResult
    nonisolated public static func reclaimFromCache(filenames unbackedFilenames: Set<String>) -> Int {
        guard !unbackedFilenames.isEmpty else { return 0 }
        let fm = FileManager.default
        let cache = cacheDirectory
        guard fm.fileExists(atPath: cache.path(percentEncoded: false)) else { return 0 }

        let dest = importsDirectory
        var reclaimed = 0
        for name in unbackedFilenames {
            let src = cache.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dst = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
                try? fm.removeItem(at: src)
            } else if (try? fm.moveItem(at: src, to: dst)) != nil {
                reclaimed += 1
            }
        }
        if reclaimed > 0 {
            MixLog.library.debug("[AudioPaths] Reclaimed \(reclaimed) never-uploaded file(s) from the purgeable cache")
        }
        return reclaimed
    }
}
