// PlaybackCache.swift
// Mixtape — Core/Services
//
// One cache for every byte of audio that can be fetched again.
//
// There used to be two, and the split was invisible to the person paying for it:
// `Library/Caches/Music` held songs pulled down from Supabase, and
// `Library/Caches/OnlineCache` held Discover audio, each with its own size, its
// own budget, and its own row in Settings. On the Mac that authored the library
// the first one never filled — nothing is ever downloaded from the server there
// — so "Playback Cache" read 0 MB forever while the disk quietly filled up under
// the other name.
//
// They are the same kind of thing: a copy we keep so the song starts faster next
// time, and can throw away without losing anything. So they're one directory,
// one budget the user can set, and one number.
//
// What this is *not*: the offline store (`OfflineStore` — deliberate downloads,
// never evicted) or the imports directory (`AudioPaths.importsDirectory` — the
// user's own files, often the only copy in existence). Nothing in here is ever
// the last copy of anything.

import Foundation
import CryptoKit

public enum PlaybackCache {

    // MARK: - Location

    /// `Library/Caches/Music`. Purgeable by the OS, excluded from backup, and
    /// shared by both kinds of cached audio.
    public static var directory: URL {
        let dir = AudioPaths.cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where Discover audio used to live. Read on the way in and swept by
    /// `migrateLegacyOnlineCache()`; never written to again.
    public static var legacyOnlineCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlineCache", isDirectory: true)
    }

    /// Where a resolver writes while it's still downloading.
    ///
    /// Downloads land here first and are moved into the cache only once they're
    /// complete, because the two are told apart by name and nothing else: a
    /// half-written file sitting at the name `fileURL(forSourceRef:)` probes is
    /// indistinguishable from a finished one, and playing it is the "song cuts
    /// off after twenty seconds" bug. It also keeps a cancelled download from
    /// counting against the budget.
    public static var stagingDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Naming

    /// Cache filenames for online audio are derived from the resolver key, so a
    /// lookup is a `fileExists` and never needs an index to be correct. The
    /// index that does exist (which video we picked for a song) is an
    /// optimisation on top, and losing it costs a search, not a file.
    private static func stem(forSourceRef ref: String) -> String {
        let digest = SHA256.hash(data: Data(ref.utf8))
        return "online-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Extensions worth probing when we know the stem but not the container.
    private static let knownExtensions = ["m4a", "mp3", "opus", "webm", "aac", "flac", "wav"]

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

    /// Files written by the old Discover cache are named for the video id, not
    /// the song, so they can only be found through the coordinator's index.
    /// Registered at launch rather than looked up per call.
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

    /// Files the budget must not evict — the song playing now and whatever is
    /// queued next. Maintained by the coordinator as playback moves.
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

    /// Forgets one song's cached audio, so the next play resolves it fresh.
    /// Returns true when a file was actually removed.
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

    /// Records a file as just-used, so the budget evicts genuinely cold entries
    /// rather than whichever one happened to be written first.
    public static func touch(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    // MARK: - Budget

    static let budgetKey = "mix.playbackCacheBudgetBytes"

    /// How large the cache is allowed to get. User-set; the slider in Settings
    /// writes this.
    public static var budgetBytes: Int64 {
        get {
            let stored = UserDefaults.standard.object(forKey: budgetKey) as? NSNumber
            return stored?.int64Value ?? defaultBudgetBytes
        }
        set {
            UserDefaults.standard.set(NSNumber(value: max(minimumBudgetBytes, newValue)), forKey: budgetKey)
        }
    }

    public static let defaultBudgetBytes: Int64 = 2 * 1_024 * 1_024 * 1_024   // 2 GB
    public static let minimumBudgetBytes: Int64 = 256 * 1_024 * 1_024         // 256 MB
    public static let maximumBudgetBytes: Int64 = 50 * 1_024 * 1_024 * 1_024  // 50 GB

    /// Total bytes currently cached, across both the current directory and the
    /// legacy Discover folder that hasn't been swept yet.
    public static var totalBytes: Int64 {
        [directory, legacyOnlineCacheDirectory].reduce(0) { $0 + size(of: $1) }
    }

    private static func size(of dir: URL) -> Int64 {
        audioFiles(in: dir).reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// The audio in a directory, and only the audio. The index the coordinator
    /// keeps alongside these files is bookkeeping, not cached music: counting it
    /// would inflate the number in Settings and evicting it would lose the map
    /// of which upload each song resolved to.
    private static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { knownExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Evicts the coldest files until the cache fits its budget.
    ///
    /// Pinned files are never candidates: evicting the track that is playing to
    /// make room for the track after it is how a cache turns into a stutter.
    public static func enforceBudget() {
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
            guard !pinnedURLs.contains(entry.url) else { continue }
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    // MARK: - Maintenance

    /// Empties the cache. Safe by construction — everything here can be fetched
    /// again.
    ///
    /// Returns the number of audio files removed, which is what "Clear" in
    /// Settings reports back.
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

    /// Deletes anything left in staging by a download that was cancelled or died
    /// with the app. Called at launch — a partial file is never useful later.
    public static func sweepStaging() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }

    /// Moves whatever the old Discover cache still holds into the shared
    /// directory, keyed the new way, using the coordinator's index to work out
    /// which song each video id belonged to.
    ///
    /// Anything the index can't explain is deleted rather than kept: an
    /// unreachable cache file is just disk usage with no way to ever be hit.
    public static func migrateLegacyOnlineCache(index: [String: String]) {
        let fm = FileManager.default
        let legacy = legacyOnlineCacheDirectory
        guard fm.fileExists(atPath: legacy.path(percentEncoded: false)),
              let items = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }

        // index maps sourceRef → videoID; invert it to name files by song.
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
        if moved > 0 { print("[PlaybackCache] Adopted \(moved) file(s) from the old Discover cache") }
    }
}
