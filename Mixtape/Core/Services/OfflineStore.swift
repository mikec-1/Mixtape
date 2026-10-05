// Where downloaded audio lives, for offline playback.
// Separate from the OnlineCache (purgeable, LRU-capped prefetch) and the user's export
// folder (human-named file copies). Application Support isn't purgeable or user-visible,
// and sits outside the online cache's budget, so downloads are never evicted.
// The directory is the source of truth: a download is `<trackID>.<ext>`. Downloads are
// device-local and never synced.

import Foundation
import Combine
import OSLog

// MARK: - Paths

/// The store's file layout, usable from any actor (playback resolves URLs off the main thread).
public nonisolated enum OfflineStorePaths {

    /// `Application Support/Mixtape/Offline`, created on first use.
    public static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory

        var dir = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Offline", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Downloads can be gigabytes and are re-downloadable, so skip iCloud backup.
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? dir.setResourceValues(resources)

        return dir
    }()

    /// Copies (or moves) `source` in as this track's offline file. Nonisolated so a large copy
    /// doesn't stall the main actor.
    static func install(_ source: URL, for trackID: UUID, moving: Bool) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(trackID.uuidString).\(ext)")

        // Clear any earlier copy first, including one under a different extension.
        if let existing = fileURL(for: trackID) {
            try? FileManager.default.removeItem(at: existing)
        }

        if moving {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// Installs `source` at `quality`, re-encoding first when a smaller file was asked for.
    /// A failed re-encode installs the original instead.
    static func install(_ source: URL,
                        for trackID: UUID,
                        moving: Bool,
                        quality: DownloadQuality) async throws -> URL {

        guard quality != .high else {
            return try await Task.detached(priority: .utility) {
                try install(source, for: trackID, moving: moving)
            }.value
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mix-encode-\(trackID.uuidString).m4a")

        func keepOriginal() async throws -> URL {
            try? FileManager.default.removeItem(at: scratch)
            return try await Task.detached(priority: .utility) {
                try install(source, for: trackID, moving: moving)
            }.value
        }

        do {
            try await AudioTranscoder.transcode(source, to: scratch, quality: quality)
        } catch {
            MixLog.playback.error("[OfflineStore] Couldn't re-encode \(trackID) at \(quality.rawValue), keeping the original: \(error)")
            return try await keepOriginal()
        }

        // A re-encode that isn't smaller (source already at or below the target rate) is discarded.
        let before = (try? source.resourceValues(forKeys:  [.fileSizeKey]).fileSize) ?? 0
        let after  = (try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard after > 0, before == 0 || after < before else {
            return try await keepOriginal()
        }

        // The scratch file is ours, so move it.
        let destination = try await Task.detached(priority: .utility) {
            try install(scratch, for: trackID, moving: true)
        }.value
        if moving { try? FileManager.default.removeItem(at: source) }
        return destination
    }

    /// The downloaded file for this track, or nil. Matches on the filename stem so any container works.
    public static func fileURL(for trackID: UUID) -> URL? {
        let stem = trackID.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let match = names.first(where: {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == stem
        }) else { return nil }
        return directory.appendingPathComponent(match)
    }
}

// MARK: - Store

@MainActor
public final class OfflineStore: ObservableObject {

    public static let shared = OfflineStore()

    /// Cached directory listing. Nil means not read yet; every mutation drops it.
    private var cachedMap: [UUID: URL]?

    private init() {}

    // MARK: - Reads

    public func url(for trackID: UUID) -> URL? { map()[trackID] }

    public func contains(_ trackID: UUID) -> Bool { map()[trackID] != nil }

    public var trackIDs: Set<UUID> { Set(map().keys) }

    public var count: Int { map().count }

    /// Total bytes on disk. Fine for Settings, too slow for a row body.
    public var totalBytes: Int64 {
        map().values.reduce(into: Int64(0)) { total, url in
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
    }

    // MARK: - Writes

    /// Stores `source` as this track's offline copy, off the main actor. Copies by default
    /// since the online cache and download cache still own their files.
    /// `quality` defaults to `.high` (keep as-is); only the download worker applies the setting.
    @discardableResult
    public func adopt(_ source: URL,
                      for trackID: UUID,
                      moving: Bool = false,
                      quality: DownloadQuality = .high) async throws -> URL {
        let destination = try await OfflineStorePaths.install(
            source, for: trackID, moving: moving, quality: quality
        )

        invalidate()
        return destination
    }

    /// Deletes this track's offline copy. Silent no-op when there isn't one.
    public func remove(_ trackID: UUID) {
        guard let url = map()[trackID] else { return }
        try? FileManager.default.removeItem(at: url)
        invalidate()
    }

    /// Deletes every download. Only ever called from an explicit Settings action.
    public func removeAll() {
        for url in map().values {
            try? FileManager.default.removeItem(at: url)
        }
        invalidate()
    }

    // MARK: - Directory listing

    private func map() -> [UUID: URL] {
        if let cachedMap { return cachedMap }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: OfflineStorePaths.directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var built: [UUID: URL] = [:]
        for url in contents {
            // Files not named after a track aren't ours to delete.
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            built[id] = url
        }

        cachedMap = built
        return built
    }

    private func invalidate() {
        cachedMap = nil
        objectWillChange.send()
    }
}
