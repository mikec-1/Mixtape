// OfflineStore.swift
// Mixtape — Core/Services
//
// Where deliberately downloaded audio lives.
//
// This is the Spotify-style store: press Download and the song lands here, in
// the app's own container, and plays without a network. It is deliberately NOT
// the same place as either of the two stores that already existed:
//
//   • Library/Caches/OnlineCache — the transient prefetch cache. It's in the
//     purgeable caches domain and capped by an LRU budget, so the OS or the
//     coordinator may delete a file at any moment. Fine for "the next song",
//     useless for "the flight tomorrow".
//   • The user's export folder (ExportManager) — real files, named for humans,
//     living in Music or wherever they chose. That's a *file copy*, an entirely
//     separate wish from "keep this playable offline".
//
// Application Support is neither purgeable nor user-visible, which is exactly
// what a download wants to be. It also sits outside the online cache's budget,
// so a download can never be evicted to make room for a prefetch.
//
// The directory is the only source of truth. There's no index to drift out of
// sync with the files: a download is a file named `<trackID>.<ext>`, and asking
// what's downloaded means listing the folder. Downloads are also, on purpose,
// device-local — never synced through Supabase, because what's on this disk is
// a fact about this disk.

import Foundation
import Combine

// MARK: - Paths

/// The store's filesystem layout, reachable from any actor.
///
/// Split out from `OfflineStore` because the playback path resolves file URLs
/// off the main thread, and the store itself is main-actor bound so its
/// published state stays safe to read from view bodies.
public enum OfflineStorePaths {

    /// `Application Support/Mixtape/Offline`, created on first use.
    public static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory

        var dir = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Offline", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Downloads are re-downloadable and can run to gigabytes; there's no
        // reason to push them through iCloud backups.
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? dir.setResourceValues(resources)

        return dir
    }()

    /// Copies (or moves) `source` in as this track's offline file and returns
    /// where it landed.
    ///
    /// Nonisolated on purpose: a song is tens of megabytes, and copying that on
    /// the main actor is a visible stall in a scrolling list.
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

    /// Brings `source` in at `quality`, re-encoding it first when the setting
    /// asks for something smaller than the file that arrived.
    ///
    /// A failed re-encode is not a failed download. The original goes in
    /// instead, so the song still plays offline — just larger than asked for.
    /// Losing the download outright because one file upset the encoder would be
    /// the worse trade, and the alternative — a half-written .m4a that looks
    /// like a finished download — is worse still.
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
            print("[OfflineStore] ⚠️ Couldn't re-encode \(trackID) at \(quality.rawValue), keeping the original: \(error)")
            return try await keepOriginal()
        }

        // A re-encode that came out no smaller is pure loss — worse audio *and*
        // the same disk. That happens whenever the source is already at or below
        // the target rate, which is routine for the online resolver's 128 kbps
        // AAC once someone picks Normal.
        let before = (try? source.resourceValues(forKeys:  [.fileSizeKey]).fileSize) ?? 0
        let after  = (try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard after > 0, before == 0 || after < before else {
            return try await keepOriginal()
        }

        // The scratch file is ours, so it moves rather than copies. `moving`
        // describes the caller's file, which we've finished reading by now.
        let destination = try await Task.detached(priority: .utility) {
            try install(scratch, for: trackID, moving: true)
        }.value
        if moving { try? FileManager.default.removeItem(at: source) }
        return destination
    }

    /// The downloaded file for this track, or nil if it isn't downloaded.
    ///
    /// Matches on the filename stem rather than guessing extensions, so a
    /// download keeps whatever container it arrived in.
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

    /// Cached directory listing, keyed by track. Nil means "not read yet";
    /// every mutation drops it so the next read goes back to the filesystem.
    private var cachedMap: [UUID: URL]?

    private init() {}

    // MARK: - Reads

    public func url(for trackID: UUID) -> URL? { map()[trackID] }

    public func contains(_ trackID: UUID) -> Bool { map()[trackID] != nil }

    public var trackIDs: Set<UUID> { Set(map().keys) }

    public var count: Int { map().count }

    /// Total bytes on disk. Fine for a Settings row — it stats a listing it
    /// already has — but not something to call from inside a row body.
    public var totalBytes: Int64 {
        map().values.reduce(into: Int64(0)) { total, url in
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
    }

    // MARK: - Writes

    /// Takes `source` into the store as this track's offline copy.
    ///
    /// Copies rather than moves by default: callers hand us files that other
    /// parts of the app still own (the online cache, the Supabase download
    /// cache), and moving one out from under them breaks playback of the very
    /// track just downloaded.
    /// The copy itself runs off the main actor, so a download finishing never
    /// stutters whatever the user is scrolling.
    ///
    /// `quality` decides whether the file is re-encoded on the way in. It
    /// defaults to `.high` — keep what arrived — so that callers who aren't the
    /// download worker (and have no business applying someone's storage setting)
    /// don't have to think about it.
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
            // A stray file that isn't named after a track is left alone rather
            // than deleted — it isn't ours to throw away.
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
