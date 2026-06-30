// DownloadManager.swift
// Mixtape — Core/Services
//
// Manages background downloads of tracks for offline playback.
// Drives two features:
//   1. Smart Queue Prefetching (Option A): Automatically prefetch the next 1 or 2 tracks in the play queue.
//   2. Playlist Downloads (Option B): Offline download toggle for playlists.
// Respects "Download on Wi-Fi Only" setting and monitors network connections via NWPathMonitor.

import Foundation
import Combine
import Network

public enum DownloadStatus: Equatable, Hashable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
}

@MainActor
public final class DownloadManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var downloadedTrackIDs = Set<UUID>()
    @Published public private(set) var downloadingTrackIDs = Set<UUID>()
    @Published public private(set) var downloadProgress = [UUID: Double]()
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isWifi: Bool = false

    public var currentUserID: String? = nil {
        didSet {
            loadSettings()
        }
    }

    private var downloadOnWifiOnlyKey: String {
        if let id = currentUserID {
            return "mix.downloadOnWifiOnly_\(id)"
        }
        return "mix.downloadOnWifiOnly"
    }

    private var syncMetadataToDiskKey: String {
        if let id = currentUserID {
            return "mix.syncMetadataToDisk_\(id)"
        }
        return "mix.syncMetadataToDisk"
    }

    @Published public var syncMetadataToDisk: Bool {
        didSet {
            UserDefaults.standard.set(syncMetadataToDisk, forKey: syncMetadataToDiskKey)
        }
    }

    @Published public var downloadOnWifiOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadOnWifiOnly, forKey: downloadOnWifiOnlyKey)
            processDownloadQueue()
        }
    }

    // MARK: - Dependencies

    private let fileStorage:    SupabaseFileStorageService
    private let libraryService: LibraryService
    private let queueService:   QueueService
    private let trackResolver:  any TrackResolver

    // MARK: - Private State

    private var downloadQueue:      [UUID] = []
    private var activeDownloads:    Set<UUID> = []
    private let pathMonitor =       NWPathMonitor()
    private let monitorQueue =      DispatchQueue(label: "mix.download.network")
    private var cancellables =      Set<AnyCancellable>()

    // MARK: - Init

    public init(
        fileStorage:    SupabaseFileStorageService,
        libraryService: LibraryService,
        queueService:   QueueService,
        trackResolver:  any TrackResolver
    ) {
        self.fileStorage    = fileStorage
        self.libraryService = libraryService
        self.queueService   = queueService
        self.trackResolver  = trackResolver

        self.downloadOnWifiOnly = UserDefaults.standard.object(forKey: "mix.downloadOnWifiOnly") as? Bool ?? true
        self.syncMetadataToDisk = UserDefaults.standard.object(forKey: "mix.syncMetadataToDisk") as? Bool ?? true

        setupNetworkMonitoring()
        setupLibraryObservation()
        setupQueueObservation()
        setupFileStorageObservation()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Network Status

    public var isConnectedForDownload: Bool {
        guard isConnected else { return false }
        if downloadOnWifiOnly {
            return isWifi
        }
        return true
    }

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            let wifi      = path.usesInterfaceType(.wifi)

            Task { @MainActor in
                self.isConnected = connected
                self.isWifi      = wifi
                self.processDownloadQueue()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Library & Queue Observation

    private func setupLibraryObservation() {
        libraryService.$tracks
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                self.scanDownloadedTracks(tracks: tracks)
            }
            .store(in: &cancellables)
    }

    private func setupQueueObservation() {
        Publishers.CombineLatest(queueService.$currentIndex, queueService.$queue)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.prefetchNextTracks()
            }
            .store(in: &cancellables)
    }

    private func setupFileStorageObservation() {
        fileStorage.downloadProgressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self else { return }
                let trackID = progress.entityID
                if progress.fraction < 1.0 {
                    self.downloadProgress[trackID] = progress.fraction
                } else {
                    self.downloadProgress.removeValue(forKey: trackID)
                    self.downloadingTrackIDs.remove(trackID)
                    self.downloadedTrackIDs.insert(trackID)
                    self.activeDownloads.remove(trackID)
                    self.processDownloadQueue()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    public func status(for trackID: UUID) -> DownloadStatus {
        if downloadedTrackIDs.contains(trackID) {
            return .downloaded
        } else if downloadingTrackIDs.contains(trackID) {
            return .downloading(progress: downloadProgress[trackID] ?? 0.0)
        } else {
            return .notDownloaded
        }
    }

    public func reEvaluateDownloads() {
        scanDownloadedTracks(tracks: libraryService.tracks)
    }

    // MARK: - Playlist Offline State Management

    public func isPlaylistOffline(_ playlistID: UUID) -> Bool {
        guard let playlist = libraryService.playlists.first(where: { $0.id == playlistID }) else { return false }
        guard !playlist.trackIDs.isEmpty else { return false }
        return playlist.trackIDs.allSatisfy { status(for: $0) == .downloaded }
    }

    public func togglePlaylistOffline(_ playlistID: UUID) {
        guard let playlist = libraryService.playlists.first(where: { $0.id == playlistID }) else { return }
        
        if isPlaylistOffline(playlistID) {
            // Remove downloads for all tracks in this playlist
            for trackID in playlist.trackIDs {
                removeDownload(for: trackID)
            }
        } else {
            enqueuePlaylistTracks(playlist)
        }
    }

    private func loadSettings() {
        if currentUserID != nil {
            let key = downloadOnWifiOnlyKey
            self.downloadOnWifiOnly = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            
            let syncKey = syncMetadataToDiskKey
            self.syncMetadataToDisk = UserDefaults.standard.object(forKey: syncKey) as? Bool ?? true
            
            // Clear current transient download queue/progress states to prevent bleed
            downloadQueue.removeAll()
            activeDownloads.removeAll()
            downloadingTrackIDs.removeAll()
            downloadProgress.removeAll()
            
            // Re-evaluate what tracks are downloaded for this user
            scanDownloadedTracks(tracks: libraryService.tracks)
        } else {
            // Logged out: reset to defaults and wipe all memory lists immediately
            self.downloadOnWifiOnly = true
            self.syncMetadataToDisk = true
            downloadQueue.removeAll()
            activeDownloads.removeAll()
            downloadingTrackIDs.removeAll()
            downloadProgress.removeAll()
            downloadedTrackIDs.removeAll()
        }
        objectWillChange.send()
    }

    // MARK: - Queue Prefetching (Option A)

    private func prefetchNextTracks() {
        let queue = queueService.queue
        let currentIndex = queueService.currentIndex

        guard currentIndex >= 0, currentIndex < queue.count else { return }

        // Prefetch the next 2 tracks in the play queue
        let nextIndices = [currentIndex + 1, currentIndex + 2]
        for index in nextIndices where index < queue.count {
            let track = queue[index]
            enqueueTrackDownload(track)
        }
    }

    // MARK: - Download Worker

    private func scanDownloadedTracks(tracks: [Track]) {
        Task {
            let downloaded = await Task.detached(priority: .background) {
                var result = Set<UUID>()
                for track in tracks {
                    if ExportManager.shared.exportedURL(for: track) != nil {
                        result.insert(track.id)
                    }
                }
                return result
            }.value
            
            if !Task.isCancelled {
                self.downloadedTrackIDs = downloaded
            }
        }
    }

    private func enqueuePlaylistTracks(_ playlist: Playlist) {
        for trackID in playlist.trackIDs {
            if let track = libraryService.track(id: trackID) {
                enqueueTrackDownload(track)
            }
        }
    }

    private func enqueueTrackDownload(_ track: Track) {
        guard !downloadedTrackIDs.contains(track.id) else { return }
        guard !downloadingTrackIDs.contains(track.id) else { return }
        guard !downloadQueue.contains(track.id) else { return }
        
        let hasRemoteKey = track.file.remoteKey?.isEmpty == false
        guard hasRemoteKey || track.isOnline else { return }

        downloadQueue.append(track.id)
        processDownloadQueue()
    }

    private func processDownloadQueue() {
        guard isConnectedForDownload else { return }
        guard activeDownloads.count < 3 else { return } // Max 3 concurrent background downloads
        guard !downloadQueue.isEmpty else { return }

        let trackID = downloadQueue.removeFirst()
        activeDownloads.insert(trackID)
        downloadingTrackIDs.insert(trackID)
        downloadProgress[trackID] = 0.0

        Task {
            do {
                if let track = libraryService.track(id: trackID) {
                    if let tempURL = fileStorage.localURL(for: track),
                       !tempURL.path.contains("/Documents/Mixtape/") {
                        try ExportManager.shared.export(track: track, from: tempURL)
                        print("[DownloadManager] ✅ Copied track from local cache: \(track.title)")
                        
                        activeDownloads.remove(trackID)
                        downloadingTrackIDs.remove(trackID)
                        downloadProgress.removeValue(forKey: trackID)
                        downloadedTrackIDs.insert(trackID)
                        processDownloadQueue()
                        objectWillChange.send()
                    } else {
                        let tempURL: URL
                        if track.isOnline {
                            let query = "\(track.artistName) \(track.title)".trimmingCharacters(in: .whitespaces)
                            let allowed = CharacterSet.alphanumerics
                            let scrubbed = track.file.fileHash.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
                            let stem = String(scrubbed).prefix(80).description
                            
                            let cacheDir = FileManager.default.temporaryDirectory
                            let res = try await trackResolver.download(
                                query: query,
                                name: stem,
                                to: cacheDir,
                                expectedDuration: track.duration,
                                preferExplicit: false
                            )
                            tempURL = cacheDir.appendingPathComponent("\(res.videoID).m4a")
                        } else {
                            // Triggers the progress publisher.
                            tempURL = try await fileStorage.download(track: track, accessToken: "")
                        }
                        
                        // Export the downloaded file
                        try ExportManager.shared.export(track: track, from: tempURL)
                        print("[DownloadManager] ✅ Downloaded and exported track: \(track.title)")
                        
                        activeDownloads.remove(trackID)
                        downloadingTrackIDs.remove(trackID)
                        downloadProgress.removeValue(forKey: trackID)
                        downloadedTrackIDs.insert(trackID)
                        processDownloadQueue()
                        objectWillChange.send()
                    }
                } else {
                    activeDownloads.remove(trackID)
                    downloadingTrackIDs.remove(trackID)
                    downloadProgress.removeValue(forKey: trackID)
                    processDownloadQueue()
                    objectWillChange.send()
                }
            } catch {
                print("[DownloadManager] ❌ Failed to download track \(trackID): \(error)")
                activeDownloads.remove(trackID)
                downloadingTrackIDs.remove(trackID)
                downloadProgress.removeValue(forKey: trackID)
                processDownloadQueue()
                objectWillChange.send()
            }
        }
    }

    public func removeDownload(for trackID: UUID) {
        guard let track = libraryService.track(id: trackID) else { return }

        // Remove from memory states
        downloadQueue.removeAll(where: { $0 == trackID })
        activeDownloads.remove(trackID)
        downloadingTrackIDs.remove(trackID)
        downloadedTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)

        // Delete from public Mixtape folder
        ExportManager.shared.deleteExportedFile(for: track)

        // Delete cache files if they exist
        if let remoteKey = track.file.remoteKey {
            let ext      = URL(fileURLWithPath: remoteKey).pathExtension.lowercased()
            let filename = "\(track.file.fileHash).\(ext)"
            
            // 1. Current cache location: Library/Caches/Music/<hash>.<ext>
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Music", isDirectory: true)
            let cacheURL = cachesDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: cacheURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            
            // 2. Legacy cache location: Documents/Music/<hash>.<ext>
            let legacyURL = URL.documentsDirectory.appending(path: "Music/\(filename)")
            if FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }

        // Notify observers
        objectWillChange.send()
    }
}
