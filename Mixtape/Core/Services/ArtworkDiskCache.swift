import Foundation
import OSLog

/// Cover bytes cached outside the store, keyed by bucket path, in `Library/Caches`.
/// The store goes away on an account switch; this lets a returning account get its
/// covers back without re-downloading. Purgeable and never authoritative.
/// Track/album/artist paths never change art. Playlist covers are overwritten in place,
/// so callers pass the bucket's `updatedAt` to get a new key.
nonisolated enum ArtworkDiskCache {

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
        // Bucket paths are already unique.
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

    /// Drops the oldest files (by modification date) until under budget. Run after a sync that wrote something.
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
        MixLog.library.debug("[ArtworkCache] Trimmed to \(total / 1024 / 1024)MB")
    }
}
