// "Local Files": songs from the user's watched folders. These rows are derived
// from a scan and never written to the database, so there's nothing to go stale
// or resurrect. Nothing syncs or uploads. promote(_:) runs a normal import to
// make a real copy.

import Foundation
import Combine
import SwiftUI

@MainActor
@Observable
public final class LocalFilesService {

    /// The songs found in the watched folders, in the order they were scanned.
    public private(set) var tracks: [Track] = []
    /// True while a scan is running, for the spinner in Settings.
    public private(set) var isScanning = false
    /// When the last scan finished, for "Last checked" copy.
    public private(set) var lastScan: Date?

    private let folders: WatchedFoldersStore
    private let parser: MetadataParser
    private let deviceID: String
    private let defaults: UserDefaults

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    #if os(macOS)
    /// macOS only. Triggers the same scan as a manual rescan.
    @ObservationIgnored private var monitor: WatchedFolderMonitor?
    #endif
    @ObservationIgnored private var folderObserver: AnyCancellable?

    /// Promoted files: path -> library row id, so they don't show twice.
    /// Entries whose row is gone are pruned on each scan, putting the file back.
    @ObservationIgnored private var promoted: [String: UUID] = [:]
    private static let promotedKey = "localFiles.promoted.v2"

    /// Other files are ignored.
    public nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aiff", "aif", "wav", "flac", "ogg", "opus", "alac", "m4b"
    ]

    /// Injected so this doesn't need the whole library.
    private let isInLibrary: (UUID) -> Bool

    public init(folders: WatchedFoldersStore,
                parser: MetadataParser? = nil,
                deviceID: String,
                defaults: UserDefaults = .standard,
                isInLibrary: @escaping (UUID) -> Bool = { _ in true }) {
        self.isInLibrary = isInLibrary
        self.folders  = folders
        self.parser   = parser ?? MetadataParser()
        self.deviceID = deviceID
        self.defaults = defaults
        if let raw = defaults.data(forKey: Self.promotedKey),
           let decoded = try? JSONDecoder().decode([String: UUID].self, from: raw) {
            self.promoted = decoded
        }

        #if os(macOS)
        self.monitor = WatchedFolderMonitor { [weak self] in self?.rescan() }
        #endif

        // Folders changed, so re-arm and rescan.
        folderObserver = folders.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.foldersChanged() }
        armMonitor()
    }

    /// Points the monitor at the current folder list. Cheap, and a no-op on iOS.
    private func armMonitor() {
        #if os(macOS)
        monitor?.watch(folders.resolvedFolders().map(\.url))
        #endif
    }

    private func foldersChanged() {
        armMonitor()
        rescan()
    }

    // MARK: - Scanning

    /// Cancels any scan in flight, so it's cheap to call often.
    public func rescan() {
        scanTask?.cancel()
        let roots = folders.resolvedFolders().map(\.url)
        guard !roots.isEmpty else {
            tracks = []
            isScanning = false
            return
        }

        prunePromotions()

        isScanning = true
        let parser   = self.parser
        let deviceID = self.deviceID
        let promoted = Set(self.promoted.keys)

        scanTask = Task { [weak self] in
            let found = await Self.scan(roots: roots,
                                        parser: parser,
                                        deviceID: deviceID,
                                        promoted: promoted)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.tracks     = found
                self?.isScanning = false
                self?.lastScan   = Date()
            }
        }
    }

    /// Off the main actor, since it's one AVURLAsset load per file.
    private nonisolated static func scan(roots: [URL],
                                         parser: MetadataParser,
                                         deviceID: String,
                                         promoted: Set<String>) async -> [Track] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var out: [Track] = []

        for root in roots {
            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // for-in needs makeIterator, which isn't available in async code.
            while let next = walker.nextObject() {
                guard let url = next as? URL else { continue }
                if Task.isCancelled { return out }
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }

                let path = url.standardizedFileURL.path(percentEncoded: false)
                // Folders can nest.
                guard !seen.contains(path) else { continue }
                // Already promoted.
                guard !promoted.contains(path) else { continue }
                seen.insert(path)

                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let size = Int64(values?.fileSize ?? 0)

                out.append(await track(for: url, size: size, parser: parser, deviceID: deviceID))
            }
        }
        return out
    }

    /// One file as a track. Falls back to the filename when there are no tags.
    private nonisolated static func track(for url: URL,
                                          size: Int64,
                                          parser: MetadataParser,
                                          deviceID: String) async -> Track {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let meta = try? await parser.parse(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        let title = (meta?.title).flatMap { $0 == "Unknown Title" || $0.isEmpty ? nil : $0 }
            ?? fallbackTitle

        return Track(
            id:          stableID(forPath: path),
            title:       title,
            artistName:  meta?.artistName ?? "Unknown Artist",
            albumTitle:  meta?.albumTitle ?? "Local Files",
            duration:    meta?.duration ?? 0,
            trackNumber: meta?.trackNumber,
            discNumber:  meta?.discNumber,
            year:        meta?.year,
            genre:       meta?.genre,
            artworkData: meta?.artworkData,
            composer:    meta?.composer,
            sync:        SyncMetadata(deviceID: deviceID),
            file:        FileProvenance.localFile(path: path, fileSize: size)
        )
    }

    /// Stable per path so playback and the queue survive a rescan.
    public nonisolated static func stableID(forPath path: String) -> UUID {
        OnlineTrack.stableID(for: "localfile:\(path)")
    }

    // MARK: - Promotion

    /// Imports a local file normally: copied, hashed, given an .imported row and
    /// queued for upload. That's what lets it reach other devices.
    @discardableResult
    public func promote(_ track: Track, using importService: ImportService) async -> ImportResult {
        let path   = track.file.localPath
        let result = await importService.importTrack(from: URL(fileURLWithPath: path))
        switch result {
        case .imported(let saved, _):  markPromoted(path: path, trackID: saved.id)
        case .duplicate(let existing): markPromoted(path: path, trackID: existing.id)
        case .failed:                  break
        }
        return result
    }

    /// Records that this file now has a library row, so scans stop offering it.
    public func markPromoted(path: String, trackID: UUID) {
        promoted[path] = trackID
        savePromotions()
        tracks.removeAll { $0.file.localPath == path }
    }

    /// Drops promotions whose row is gone so the file shows again.
    private func prunePromotions() {
        let live = promoted.filter { isInLibrary($0.value) }
        guard live.count != promoted.count else { return }
        promoted = live
        savePromotions()
    }

    private func savePromotions() {
        guard let data = try? JSONEncoder().encode(promoted) else { return }
        defaults.set(data, forKey: Self.promotedKey)
    }

    public func isPromoted(path: String) -> Bool { promoted[path] != nil }

    /// For the "Save all" confirmation.
    public var totalSize: Int64 { tracks.reduce(0) { $0 + $1.file.fileSize } }
}
