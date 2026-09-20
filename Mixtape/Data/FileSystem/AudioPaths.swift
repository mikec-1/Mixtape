// AudioPaths.swift
// Mixtape — Data/FileSystem
//
// One place that knows where library audio lives on disk, and how to turn a
// stored `localPath` back into a real file.
//
// Three directories are in play, and the difference between them matters:
//
//   • Application Support/Mixtape/Music — IMPORTS. A file the user picked from
//     their disk. For a track that has never been uploaded this is the only
//     copy in existence, so it must be durable: not purgeable, and included in
//     backup.
//   • Library/Caches/Music — PLAYBACK CACHE. A copy downloaded from Supabase
//     Storage. Losing it costs a re-download and nothing else, so the OS is
//     welcome to reclaim it.
//   • Documents/Music — LEGACY. Where both of the above used to land, before
//     they were told apart. Read-only as far as new writes are concerned; the
//     one-time migration empties it.
//
// The bug this layout exists to prevent: a launch-time migration used to sweep
// *everything* out of Documents/Music into Library/Caches/Music. A freshly
// imported original — the user's only copy — was moved into a directory the OS
// may evict under disk pressure, and playback kept working off the cache copy
// so nothing looked wrong until the file was gone.

import Foundation

public enum AudioPaths {

    // MARK: - Directories

    /// Application Support/Mixtape/Music — durable, backed up. Imported originals.
    /// Created on first use.
    nonisolated public static var importsDirectory: URL { importsDirectoryOnce }

    /// Resolved and created exactly once.
    ///
    /// This used to issue a `createDirectory` syscall on *every* read, and it is
    /// read from `candidates(for:)` — which means once per audio-location check,
    /// and a location check happens per track. Starting a 2000-song playlist ran
    /// it two thousand times for a directory that has existed since the first
    /// import. A `let` is safe here: the path is derived from the search paths
    /// and cannot change while the process lives, and `createDirectory` with
    /// `withIntermediateDirectories` recreates it if something removes it out
    /// from under us on the next launch.
    nonisolated private static let importsDirectoryOnce: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Music",   isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Library/Caches/Music — purgeable, not backed up. Re-downloadable copies.
    nonisolated public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }

    /// Documents/Music — the pre-split location. Nothing is written here any more.
    nonisolated public static var legacyDocumentsDirectory: URL {
        URL.documentsDirectory.appending(path: "Music", directoryHint: .isDirectory)
    }

    /// Every directory that can hold library audio. Anything that wipes the
    /// library has to empty all of them — a wipe that clears one path leaves
    /// files on disk that `resolve(localPath:)` will happily go on playing.
    public static var allAudioDirectories: [URL] {
        [importsDirectory, cacheDirectory, legacyDocumentsDirectory]
    }

    /// The subset that is genuinely a cache: throwing these away costs a
    /// re-download. The "Clear Playback Cache" button must stop here — the
    /// imports directory holds files with no other copy anywhere.
    public static var purgeableAudioDirectories: [URL] {
        [cacheDirectory, legacyDocumentsDirectory]
    }

    // MARK: - Resolution

    /// Where a stored `localPath` actually is on disk, or `nil` if nowhere.
    ///
    /// `localPath` has three historical shapes and all of them still exist in
    /// live databases: an absolute path, `Music/<hash>.<ext>` (relative to
    /// whichever directory held the file at the time), and the Discover cache's
    /// `../Library/Caches/OnlineCache/<id>.m4a` (relative to Documents).
    public static func resolve(localPath: String) -> URL? {
        guard !localPath.isEmpty else { return nil }
        let fm = FileManager.default
        for candidate in candidates(for: localPath) {
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    /// Resolution that always yields a URL: the file if it exists, otherwise the
    /// location it *would* occupy. For callers that want a URL to check or write
    /// to rather than an optional.
    public static func url(forLocalPath localPath: String) -> URL {
        resolve(localPath: localPath) ?? candidates(for: localPath).first!
    }

    /// The file only where a *durable* copy would be — the imports directory or
    /// the legacy Documents folder. For callers that need to know whether the
    /// user's own file is still there, as distinct from a purgeable cache copy
    /// or an exported copy the user may move or delete at any time.
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

    /// Deletes every copy a stored path can name.
    ///
    /// `nonisolated`, along with the three directory properties it reaches
    /// through, so the sync's deleted-audio sweep can run the whole batch on a
    /// detached task. Nothing here touches shared mutable state — it is
    /// `FileManager` and path arithmetic. Deleting only the first match
    /// leaves a duplicate in another directory that resolution finds next time,
    /// so a "deleted" song carries on playing.
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

        // A bare `Music/<file>` path is a library file: imports first, since a
        // downloaded copy is replaceable and an import is not.
        if localPath.hasPrefix("Music/") {
            result.append(importsDirectory.appendingPathComponent(name))
            result.append(cacheDirectory.appendingPathComponent(name))
            result.append(legacyDocumentsDirectory.appendingPathComponent(name))
        } else {
            // Anything else (notably the Discover cache's `../Library/...` form)
            // is still Documents-relative.
            result.append(URL.documentsDirectory.appending(path: localPath))
            result.append(importsDirectory.appendingPathComponent(name))
            result.append(cacheDirectory.appendingPathComponent(name))
        }
        return result
    }

    // MARK: - Migration

    /// Moves everything left in `Documents/Music/` into the durable imports
    /// directory and removes the old folder.
    ///
    /// Deliberately the imports directory and not the cache: the old folder is a
    /// mix of imports and downloads with nothing on disk to tell them apart, and
    /// of the two possible mistakes — keeping a re-downloadable file longer than
    /// necessary, or letting the OS evict a user's only copy — only one is
    /// recoverable.
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
                try? fm.removeItem(at: src)   // same content hash — the copy already there wins
            } else if (try? fm.moveItem(at: src, to: dst)) != nil {
                moved += 1
            }
        }
        try? fm.removeItem(at: oldDir)
        if moved > 0 {
            print("[AudioPaths] Migrated \(moved) file(s) from Documents/Music/ to Application Support")
        }
    }

    /// Pulls back files that the old migration already swept into the purgeable
    /// cache but that are nobody's second copy — a track that was never uploaded
    /// has no server-side original to re-download.
    ///
    /// `unbackedFilenames` is supplied by the caller (it needs the library
    /// database to know which tracks those are).
    @discardableResult
    /// `nonisolated` so the launch path can hand it to a detached task: it is a
    /// `fileExists` per candidate name, which on a large library is hundreds of
    /// stat calls and has no business on the thread that draws.
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
            print("[AudioPaths] Reclaimed \(reclaimed) never-uploaded file(s) from the purgeable cache")
        }
        return reclaimed
    }
}
