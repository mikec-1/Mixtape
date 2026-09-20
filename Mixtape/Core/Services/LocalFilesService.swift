// LocalFilesService.swift
// Mixtape — Core/Services
//
// "Local Files": the music in the user's watched folders, shown as songs.
//
// The one rule that shapes everything here is that these rows are DERIVED. A
// scan builds `Track` values in memory and nothing is ever written to the
// database. Remove a file from a watched folder and it disappears from Mixtape;
// put it back and it returns. There is no state to go stale, nothing to
// resurrect, and nothing to reconcile with another device.
//
// That is the lesson of the export-folder scan, which did the opposite: it
// minted permanent library rows from files on disk, so a song deleted on the
// phone came back on the Mac the next time anyone pressed Sync. A view over a
// folder cannot do that, by construction.
//
// Nothing here syncs and nothing here uploads. To put a local file on the phone
// or the web the user promotes it — see `promote(_:)` — which runs the ordinary
// import path and produces an honest `.imported` row with a copy Mixtape owns.

import Foundation
import Combine
import SwiftUI

@MainActor
public final class LocalFilesService: ObservableObject {

    /// The songs found in the watched folders, in the order they were scanned.
    @Published public private(set) var tracks: [Track] = []
    /// True while a scan is running, for the spinner in Settings.
    @Published public private(set) var isScanning = false
    /// When the last scan finished, for "Last checked" copy.
    @Published public private(set) var lastScan: Date?

    private let folders: WatchedFoldersStore
    private let parser: MetadataParser
    private let deviceID: String
    private let defaults: UserDefaults

    private var scanTask: Task<Void, Never>?

    #if os(macOS)
    /// Live watching, macOS only. The scan it triggers is the same derived scan
    /// as the manual one, so this can only ever make the list *fresher* — it has
    /// no path of its own to get anything wrong.
    private var monitor: WatchedFolderMonitor?
    #endif
    private var folderObserver: AnyCancellable?

    /// Files the user has already saved into Mixtape: absolute path → the id of
    /// the library row that now represents it.
    ///
    /// Recorded at promotion time — a fact, not a guess. Without it a promoted
    /// song would show twice: once as the imported copy Mixtape owns, and once
    /// as the original still sitting in the watched folder.
    ///
    /// The id is what keeps this from becoming another place for deletions to
    /// hide. Every scan drops entries whose library row is gone, so deleting a
    /// promoted song puts the file back under Local Files — which is the truth:
    /// the file is still in the folder. This prunes itself rather than hooking
    /// deletion, so a row removed by a sync from another device counts too.
    private var promoted: [String: UUID] = [:]
    private static let promotedKey = "localFiles.promoted.v2"

    /// File types worth opening. Anything else in the folder is ignored in
    /// silence — watched folders are the user's, and they may keep whatever
    /// they like in them.
    public nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aiff", "aif", "wav", "flac", "ogg", "opus", "alac", "m4b"
    ]

    /// Whether a library row with this id still exists. Injected rather than
    /// held as a reference so this service does not need the whole library.
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

        // Re-arm whenever the user adds or removes a folder, and rescan: the
        // list on screen is about a set of folders that just changed.
        folderObserver = folders.objectWillChange
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

    /// Re-reads every watched folder. Safe to call often: a scan already in
    /// flight is cancelled first, so a burst of launch/foreground/manual
    /// triggers costs one scan, not four.
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

    /// Walks the folders and reads tags. Off the main actor: a folder of a few
    /// thousand files is a few thousand `AVURLAsset` loads, and doing that on
    /// the main actor would freeze the very list it is filling.
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

            // `for … in walker` would use `makeIterator`, which is unavailable
            // from an async context. Pulling objects by hand is the same walk.
            while let next = walker.nextObject() {
                guard let url = next as? URL else { continue }
                if Task.isCancelled { return out }
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }

                let path = url.standardizedFileURL.path(percentEncoded: false)
                // Two watched folders can nest, and the same file can sit under
                // both. Show it once.
                guard !seen.contains(path) else { continue }
                // A file the user has already saved into Mixtape is represented
                // by its library row, not twice.
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

    /// One file as a song. Tags where the file has them, the filename where it
    /// doesn't — a folder of untagged rips should still read as a list of songs
    /// rather than a list of "Unknown".
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

    /// Same file, same id, every scan — so the queue, the now-playing row and
    /// "is this the song that's playing?" all keep working across a rescan.
    public nonisolated static func stableID(forPath path: String) -> UUID {
        OnlineTrack.stableID(for: "localfile:\(path)")
    }

    // MARK: - Promotion

    /// Saves a local file into Mixtape properly.
    ///
    /// This is just the ordinary import: the file is copied into Mixtape's own
    /// storage, hashed, given an `.imported` row and queued for upload, exactly
    /// as if the user had dragged it in. That means a second copy on disk, which
    /// is what "save it to Mixtape" has always meant — and it is the only shape
    /// that can reach the phone and the web, because the audio has to be
    /// somewhere both of them can read.
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

    /// Drops promotions whose library row no longer exists, so the file shows up
    /// under Local Files again. The file is still on disk; pretending otherwise
    /// would hide the user's own music from them.
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

    /// Total bytes of everything currently listed — for the confirmation on
    /// "Save all to Mixtape", which copies every one of these files.
    public var totalSize: Int64 { tracks.reduce(0) { $0 + $1.file.fileSize } }
}
