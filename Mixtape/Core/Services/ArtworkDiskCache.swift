// ArtworkDiskCache.swift
// Mixtape — Core/Services

import Foundation

/// Cover bytes, kept beside the store instead of only inside it.
///
/// The store is one account's local copy and goes away with it: signing into a
/// second account on this Mac drops it, and signing back in leaves a library
/// whose rows arrive long before their covers do — a few thousand objects
/// fetched 150 per sync run, which is the wait a returning user actually sees.
/// The bytes never needed re-fetching. This device uploaded most of them.
///
/// So they also live here, keyed by the bucket path they came from, in
/// `Library/Caches` — where a store wipe can't reach them, the OS may purge
/// them if the disk fills, and backups skip them. Nothing here is
/// authoritative: a miss is just a download, and that is the whole failure
/// mode.
///
/// Keyed by path alone for tracks, albums and artists, whose object paths are
/// derived from the row id and so never name different art. A playlist cover
/// *is* overwritten in place, so its callers pass the bucket's `updatedAt` and
/// get a different key each time the cover changes; nothing writes a playlist
/// cover here on upload, since the stamp it would be filed under isn't known
/// until the bucket reports one.
enum ArtworkDiskCache {

    /// Roughly two full libraries of covers. Past this the oldest go.
    private static let budget = 250 * 1024 * 1024

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first
        else { return nil }
        let dir = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ path: String, _ stamp: Date?) -> URL? {
        guard let directory, !path.isEmpty else { return nil }
        // The bucket path is already unique and filename-safe apart from its
        // separators — no hashing needed to tell two covers apart.
        var name = path.replacingOccurrences(of: "/", with: "-")
        if let stamp { name += "@\(Int(stamp.timeIntervalSince1970))" }
        return directory.appendingPathComponent(name)
    }

    static func data(for path: String, stamp: Date? = nil) -> Data? {
        guard let url = file(path, stamp) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ data: Data, for path: String, stamp: Date? = nil) {
        guard let url = file(path, stamp) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drops the oldest files until the folder is back under budget.
    ///
    /// Modification date, not access date: a cover that is read but never
    /// rewritten looks equally old either way, and the only thing being chosen
    /// between here is which library gets re-downloaded after a device has held
    /// several. Cheap enough to run at the end of a sync that wrote something,
    /// which is the only time this can have grown.
    static func trim() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }

        let sized = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                            .contentModificationDateKey]),
                  let size = v.fileSize else { return nil }
            return (url, size, v.contentModificationDate ?? .distantPast)
        }

        var total = sized.reduce(0) { $0 + $1.1 }
        guard total > budget else { return }
        for (url, size, _) in sized.sorted(by: { $0.2 < $1.2 }) {
            guard total > budget else { break }
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
        print("[ArtworkCache] 🧹 Trimmed to \(total / 1024 / 1024)MB")
    }
}
