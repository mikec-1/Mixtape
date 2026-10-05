// One cache for all re-fetchable audio: Supabase downloads and Discover
// audio share one directory and one user-set budget. Not the offline store
// (never evicted) or imports (possibly the only copy).

import Foundation
import CryptoKit
import OSLog

public enum PlaybackCache {

    // MARK: - Location

    /// `Library/Caches/Music`: purgeable, not backed up.
    nonisolated public static var directory: URL {
        let dir = AudioPaths.cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Old Discover cache. Swept by `migrateLegacyOnlineCache()`, never written.
    nonisolated public static var legacyOnlineCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlineCache", isDirectory: true)
    }

    /// Downloads land here and move into the cache when complete, so a
    /// half-written file is never found at its cache name. Cancelled downloads don't
    /// count against the budget.
    public static var stagingDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Naming

    /// Online cache names derive from the resolver key, so lookup is a
    /// `fileExists`. The coordinator's index is only an optimisation.
    private static func stem(forSourceRef ref: String) -> String {
        let digest = SHA256.hash(data: Data(ref.utf8))
        return "online-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Extensions worth probing when we know the stem but not the container.
    nonisolated private static let knownExtensions = ["m4a", "mp3", "opus", "webm", "aac", "flac", "wav", "aiff", "aif", "ogg", "m4b"]

    // MARK: - Lookup

    /// The cached file for a Discover song, if this device still has it.
    public static func fileURL(forSourceRef ref: String) -> URL? {
        guard !ref.isEmpty else { return nil }
        return existingFile(stem: stem(forSourceRef: ref), in: directory)
            ?? legacyOnlineFile(forSourceRef: ref)
    }

    /// Where a fresh download of this song should be written.
    public static func destinationURL(forSourceRef ref: String, ext: String) -> URL {
        let cleaned = ext.isEmpty ? "m4a" : ext.lowercased()
        return directory.appendingPathComponent("\(stem(forSourceRef: ref)).\(cleaned)")
    }

    /// The cached copy of a Supabase-backed library file, if present.
    public static func fileURL(forRemoteHash hash: String) -> URL? {
        guard !hash.isEmpty else { return nil }
        return existingFile(stem: hash, in: directory)
    }

    private static func existingFile(stem: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        for ext in knownExtensions {
            let candidate = dir.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    /// Old Discover files are named by video id and only found via the
    /// coordinator's index. Registered at launch.
    private static var legacyIndex: [String: URL] = [:]

    static func registerLegacyFile(_ url: URL, forSourceRef ref: String) {
        legacyIndex[ref] = url
    }

    private static func legacyOnlineFile(forSourceRef ref: String) -> URL? {
        guard let url = legacyIndex[ref],
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    // MARK: - Writing

    /// Never evicted: the playing song and what's queued next. Kept by the coordinator.
    public static var pinnedURLs: Set<URL> = []

    /// Moves a freshly fetched file into the cache and returns where it landed.
    @discardableResult
    public static func adopt(_ source: URL, forSourceRef ref: String) throws -> URL {
        let destination = destinationURL(forSourceRef: ref, ext: source.pathExtension)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
        touch(destination)
        return destination
    }

    /// Removes one song's cached audio so it resolves fresh. True if a file was removed.
    @discardableResult
    public static func remove(forSourceRef ref: String) -> Bool {
        guard let url = fileURL(forSourceRef: ref) else { return false }
        legacyIndex.removeValue(forKey: ref)
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Forgets the cached copy of a Supabase-backed file.
    @discardableResult
    public static func remove(forRemoteHash hash: String) -> Bool {
        guard let url = fileURL(forRemoteHash: hash) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Marks a file as recently used for LRU eviction.
    public static func touch(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    // MARK: - Budget

    nonisolated static let budgetKey = "mix.playbackCacheBudgetBytes"

    /// User-set cache size limit (Settings slider).
    nonisolated public static var budgetBytes: Int64 {
        get {
            let stored = UserDefaults.standard.object(forKey: budgetKey) as? NSNumber
            return stored?.int64Value ?? defaultBudgetBytes
        }
        set {
            UserDefaults.standard.set(NSNumber(value: max(minimumBudgetBytes, newValue)), forKey: budgetKey)
        }
    }

    nonisolated public static let defaultBudgetBytes: Int64 = 2 * 1_024 * 1_024 * 1_024   // 2 GB
    nonisolated public static let minimumBudgetBytes: Int64 = 256 * 1_024 * 1_024         // 256 MB
    public static let maximumBudgetBytes: Int64 = 50 * 1_024 * 1_024 * 1_024  // 50 GB

    /// Total bytes cached, including the unswept legacy folder.
    nonisolated public static var totalBytes: Int64 {
        [directory, legacyOnlineCacheDirectory].reduce(0) { $0 + size(of: $1) }
    }

    nonisolated private static func size(of dir: URL) -> Int64 {
        audioFiles(in: dir).reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Audio files only; the coordinator's index isn't counted or evicted.
    nonisolated private static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { knownExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Evicts the coldest unpinned files until the cache fits its budget.
    public static func enforceBudget() { enforceBudget(pinned: pinnedURLs) }

    /// Off-main variant; the caller passes a copy of `pinnedURLs`.
    nonisolated public static func enforceBudget(pinned: Set<URL>) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]

        var entries: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for url in audioFiles(in: directory) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let used = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            total += size
            entries.append((url, size, used))
        }

        let budget = budgetBytes
        guard total > budget else { return }

        // Coldest first, pinned never.
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > budget else { break }
            guard !pinned.contains(entry.url) else { continue }
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    // MARK: - Maintenance

    /// Empties the cache. Returns the number of files removed.
    @discardableResult
    public static func clear() -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in [directory, legacyOnlineCacheDirectory, stagingDirectory] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items {
                let wasAudio = knownExtensions.contains(url.pathExtension.lowercased())
                if (try? fm.removeItem(at: url)) != nil, wasAudio { removed += 1 }
            }
        }
        legacyIndex.removeAll()
        return removed
    }

    /// Deletes partial downloads left in staging. Called at launch.
    public static func sweepStaging() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }

    /// Moves the old Discover cache into the shared directory using the
    /// coordinator's index. Files the index can't explain are deleted.
    public static func migrateLegacyOnlineCache(index: [String: String]) {
        let fm = FileManager.default
        let legacy = legacyOnlineCacheDirectory
        guard fm.fileExists(atPath: legacy.path(percentEncoded: false)),
              let items = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }

        // index maps sourceRef -> videoID; invert it to name files by song.
        var refForVideo: [String: String] = [:]
        for (ref, videoID) in index where refForVideo[videoID] == nil { refForVideo[videoID] = ref }

        var moved = 0
        for url in items {
            let videoID = url.deletingPathExtension().lastPathComponent
            guard let ref = refForVideo[videoID] else {
                try? fm.removeItem(at: url)
                continue
            }
            let destination = destinationURL(forSourceRef: ref, ext: url.pathExtension)
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                try? fm.removeItem(at: url)
            } else if (try? fm.moveItem(at: url, to: destination)) != nil {
                moved += 1
            }
        }
        try? fm.removeItem(at: legacy)
        if moved > 0 { MixLog.playback.debug("[PlaybackCache] Adopted \(moved) file(s) from the old Discover cache") }
    }
}
