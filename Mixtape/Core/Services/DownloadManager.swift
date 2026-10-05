// Answers two separate questions per song:
// - Availability (`TrackAvailability`): streaming only, downloading, in the offline store, or local
// because the user imported it.
// - Export (`isExported(_:)`): does a file copy exist in the export folder? Opt-in, never a side effect.
// Downloading means "put a copy in `OfflineStore`"; a file copy is a separate wish.

import Foundation
import Combine
import Network
import OSLog

/// How a track can be played on *this* device, right now.
public enum TrackAvailability: Equatable, Hashable {
    /// Nothing on disk; playing it needs the network.
    case streamOnly
    case downloading(progress: Double)
    /// Deliberately downloaded into the offline store.
    case offline
    /// Imported from the user's own disk: offline already, never downloaded or deleted by the app.
    case local
    /// Requested but didn't land. Kept separate so a failed download doesn't look like one never asked for.
    case failed

    /// Plays with the network off.
    public var isAvailableOffline: Bool {
        self == .offline || self == .local
    }

    /// Local files are the user's own, so only downloads can be removed.
    public var isRemovableDownload: Bool { self == .offline }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Badge colour by meaning, so SwiftUI and AppKit each map it to their own colour type.
public enum AvailabilityBadgeTint {
    /// Here and playable with the network off.
    case positive
    /// Work in progress.
    case active
    /// Asked for, didn't arrive.
    case negative
}

/// Row badge for each state. Lives here so the SwiftUI rows and the Mac's `NSTableCellView` can't drift;
/// a new case breaks this switch.
public extension TrackAvailability {

    /// SF Symbol for the badge, or nil for states that show none.
    var badgeSymbol: String? {
        switch self {
        case .offline:     return "arrow.down.circle.fill"
        case .local:       return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed:      return "exclamationmark.circle"
        // Most saved Discover songs; a badge on nearly every row says nothing.
        case .streamOnly:  return nil
        }
    }

    var badgeTint: AvailabilityBadgeTint {
        switch self {
        case .offline, .local:      return .positive
        case .downloading:          return .active
        case .failed:               return .negative
        case .streamOnly:           return .positive   // unused; no symbol
        }
    }

    /// True while the badge should animate.
    var badgePulses: Bool { isDownloading }

    /// Spoken by VoiceOver, and the Mac table's tooltip.
    var badgeDescription: String? {
        switch self {
        case .offline:     return "Downloaded for offline listening"
        // Different wording: this is the user's own file, which the app never offers to delete.
        case .local:       return "Added by you — available offline"
        case .downloading: return "Downloading"
        case .failed:      return "Download failed"
        case .streamOnly:  return nil
        }
    }
}

/// Why pressing Download on a track would do nothing, so the UI can say why.
public enum DownloadBlock: Equatable {
    /// Already in the offline store.
    case alreadyDownloaded
    /// The user's own imported file.
    case alreadyLocal
    /// Queued or in flight already.
    case inFlight
    /// There is no audio to fetch, for the reason given.
    case unavailable(UnavailableReason)

    nonisolated public func message(for title: String) -> String {
        switch self {
        case .alreadyDownloaded:
            return "Already downloaded"
        case .alreadyLocal:
            #if os(macOS)
            return "Already on your Mac"
            #else
            return "Already on this device"
            #endif
        case .inFlight:
            return "Downloading\u{2026}"
        case .unavailable(let reason):
            return reason.message(for: title)
        }
    }
}

/// The download values that change many times a second, split off `DownloadManager` so a percent tick
/// only redraws the progress views. See `DownloadManager.progress`.
@MainActor
public final class DownloadProgress: ObservableObject {
    /// Per-track fraction, already coalesced to whole percent by the manager.
    @Published public internal(set) var fractions: [UUID: Double] = [:]

    /// Songs finished and songs requested in the current run ("8 of 10"). Reset once nothing is in flight.
    @Published public internal(set) var completed = 0
    @Published public internal(set) var total = 0
}

@MainActor
public final class DownloadManager: ObservableObject {

    /// Throttled "downloads changed" signal (4 Hz) for views that redraw on it; `objectWillChange` fires
    /// dozens of times a second during a download. `latest: true` still delivers the final state.
    /// `lazy` for a stable identity: `.onReceive` re-subscribes when handed a new publisher.
    public private(set) lazy var didChangeThrottled: AnyPublisher<Void, Never> =
        objectWillChange
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()

    // MARK: - Published State

    /// In the offline store. Deliberate downloads only.
    @Published public private(set) var offlineTrackIDs = Set<UUID>() {
        didSet { downloadedTrackIDs = offlineTrackIDs.union(localTrackIDs) }
    }
    /// Imported from disk and the file is still there.
    @Published public private(set) var localTrackIDs = Set<UUID>() {
        didSet { downloadedTrackIDs = offlineTrackIDs.union(localTrackIDs) }
    }
    /// Everything playable offline: downloads plus local imports. Stored, since rows and discs read it per item.
    public private(set) var downloadedTrackIDs = Set<UUID>()
    /// A file copy exists in the export folder. Independent of the above.
    @Published public private(set) var exportedTrackIDs = Set<UUID>()

    @Published public private(set) var downloadingTrackIDs = Set<UUID>()
    /// Per-track fractions and batch counters live on their own object so a percent tick doesn't republish
    /// the whole manager (and every view reading its settings). Only the leaf views that draw them observe it.
    public let progress = DownloadProgress()

    /// Write-through access, so the rest of this file reads as it always did.
    public internal(set) var downloadProgress: [UUID: Double] {
        get { progress.fractions }
        set { progress.fractions = newValue }
    }
    /// Exhausted the retry budget. Stays set until the user asks again.
    @Published public private(set) var failedTrackIDs = Set<UUID>()
    /// Starts true: the path monitor reports within moments, and a false default read as "went offline".
    @Published public private(set) var isConnected: Bool = true
    @Published public private(set) var isWifi: Bool = false
    /// Ethernet, tracked apart from Wi-Fi because one screen names Wi-Fi specifically.
    @Published public private(set) var isWired: Bool = false

    /// Not billed by the byte. What "Wi-Fi only" means; a Mac on Ethernet isn't Wi-Fi.
    public var isUnmetered: Bool { isWifi || isWired }

    /// What went wrong, per track, for the tooltip on a failed row.
    @Published public private(set) var failureReasons = [UUID: String]()

    /// See `DownloadProgress.completed`.
    public internal(set) var batchCompleted: Int {
        get { progress.completed }
        set { progress.completed = newValue }
    }
    public internal(set) var batchTotal: Int {
        get { progress.total }
        set { progress.total = newValue }
    }

    /// Requested but not started: waiting on a slot, a connection, or a retry timer.
    public var pendingDownloadCount: Int { downloadQueue.count + retryTasks.count }

    /// Whether every one of these songs is on this device; the green disc's one definition.
    /// An empty list is not downloaded.
    public func isFullyDownloaded(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let have = downloadedTrackIDs
        return ids.allSatisfy { have.contains($0) }
    }

    /// Progress of a download of these songs, or nil when none is running. Counts songs, with the one being
    /// fetched adding its fraction, the same as the status bar. Nil when idle: callers draw the finished disc.
    public func downloadFraction(_ ids: [UUID]) -> Double? {
        guard !ids.isEmpty else { return nil }
        let running = ids.contains { downloadingTrackIDs.contains($0) || downloadQueue.contains($0) }
        guard running else { return nil }
        let have = downloadedTrackIDs
        let partial = ids.reduce(0.0) { sum, id in
            if have.contains(id) { return sum + 1 }
            return sum + (downloadProgress[id] ?? 0)
        }
        return min(1, partial / Double(ids.count))
    }

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

    private var keepFileCopyKey: String {
        if let id = currentUserID {
            return "mix.keepFileCopyOnDownload_\(id)"
        }
        return "mix.keepFileCopyOnDownload"
    }

    private var downloadQualityKey: String {
        if let id = currentUserID {
            return "mix.downloadQuality_\(id)"
        }
        return "mix.downloadQuality"
    }

    private var editQualityKey: String {
        if let id = currentUserID {
            return "mix.editQuality_\(id)"
        }
        return "mix.editQuality"
    }

    private var autoAdjustQualityKey: String {
        if let id = currentUserID {
            return "mix.autoAdjustQuality_\(id)"
        }
        return "mix.autoAdjustQuality"
    }

    private var autoDownloadImportedKey: String {
        if let id = currentUserID {
            return "mix.autoDownloadImportedPlaylists_\(id)"
        }
        return "mix.autoDownloadImportedPlaylists"
    }

    private var keepOfflineKey: String {
        if let id = currentUserID {
            return "mix.keepPlaylistsOffline_\(id)"
        }
        return "mix.keepPlaylistsOffline"
    }

    /// Songs downloaded one at a time rather than via a playlist; see `manualOfflineIDs`.
    private var manualOfflineKey: String {
        if let id = currentUserID {
            return "mix.manualOfflineTracks_\(id)"
        }
        return "mix.manualOfflineTracks"
    }

    /// Marks that this account's stored set had the old seed's system-playlist guesses removed.
    /// See `repairSeededSystemPlaylists`.
    private var keepOfflineRepairKey: String {
        if let id = currentUserID {
            return "mix.keepOfflineRepaired_\(id)"
        }
        return "mix.keepOfflineRepaired"
    }

    /// The playlists the user asked to keep on the device. Stored, not derived from the songs: a playlist
    /// made of already-downloaded songs isn't "kept" unless the user says so, and this set also makes songs
    /// added later download themselves. Only `togglePlaylistOffline` writes it.
    @Published public private(set) var keepOfflineIDs: Set<UUID> = [] {
        didSet {
            guard keepOfflineIDs != oldValue else { return }
            UserDefaults.standard.set(keepOfflineIDs.map(\.uuidString), forKey: keepOfflineKey)
        }
    }

    /// Last-seen track lists for kept playlists, to tell "a song was added" apart from other changes.
    private var keptTrackIDs: [UUID: [UUID]] = [:]

    /// Songs the user downloaded individually (row button, menu, selection), not via a kept playlist.
    /// Switching a playlist off keeps these. Cleared by "Remove Download".
    @Published public private(set) var manualOfflineIDs: Set<UUID> = [] {
        didSet {
            guard manualOfflineIDs != oldValue else { return }
            UserDefaults.standard.set(manualOfflineIDs.map(\.uuidString), forKey: manualOfflineKey)
        }
    }

    /// Disk budget per download. Normal by default; a big library at source bitrate runs to tens of GB.
    @Published public var downloadQuality: DownloadQuality {
        didSet {
            UserDefaults.standard.set(downloadQuality.rawValue, forKey: downloadQualityKey)
        }
    }

    /// What a saved song edit is rendered at. Normal by default.
    @Published var editQuality: EditQuality {
        didSet {
            UserDefaults.standard.set(editQuality.rawValue, forKey: editQualityKey)
        }
    }

    /// When ON, downloads over a metered connection drop one quality step.
    @Published public var autoAdjustQuality: Bool {
        didSet {
            UserDefaults.standard.set(autoAdjustQuality, forKey: autoAdjustQualityKey)
        }
    }

    /// The quality a download starting now will use, read when the bytes arrive, not when queued.
    public var effectiveDownloadQuality: DownloadQuality {
        guard autoAdjustQuality, isConnected, !isUnmetered else { return downloadQuality }
        return downloadQuality.loweredForCellular
    }

    /// When on, every download also writes a file copy to the export folder. Off by default; only
    /// applies to downloads, never to adding a song to the library.
    @Published public var keepFileCopyOnDownload: Bool {
        didSet {
            UserDefaults.standard.set(keepFileCopyOnDownload, forKey: keepFileCopyKey)
        }
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

    /// When on, a playlist from elsewhere (Spotify import, saved mix, someone else's playlist) is kept on
    /// the device as it lands. Off by default; each playlist it opts in shows its own button switched on.
    /// Playlists made here aren't included.
    @Published public var autoDownloadImportedPlaylists: Bool {
        didSet {
            UserDefaults.standard.set(autoDownloadImportedPlaylists, forKey: autoDownloadImportedKey)
        }
    }

    // MARK: - Dependencies

    private let fileStorage:    SupabaseFileStorageService
    private let libraryService: LibraryService
    /// Only for queue observation; nothing downloads off playback (see `setupQueueObservation`).
    private let queueService:   QueueService
    private let trackResolver:  any TrackResolver
    /// "Wrong version" picks and refusals, so a download skips the upload the user rejected.
    /// Set by AppDependencies; weak because it's created after.
    weak var onlineCoordinator: OnlinePlaybackCoordinator?
    /// Renders an edit this device has no file for, from its original. Set by AppDependencies.
    var editRebuilder: ((Track) async throws -> URL)?

    // MARK: - Private State

    private var downloadQueue:      [UUID] = []
    private var activeDownloads:    Set<UUID> = []
    private let pathMonitor =       NWPathMonitor()
    private let monitorQueue =      DispatchQueue(label: "mix.download.network")
    private var cancellables =      Set<AnyCancellable>()

    /// How many times each track has been tried this session.
    private var attempts: [UUID: Int] = [:]
    /// The running download task per track, so a download can be cancelled rather than finishing and
    /// writing into the offline store after the user switched it off.
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]

    /// Sleeping retries, cancellable when the user changes their mind or signs out.
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    /// Already-offline tracks being refetched at a new quality: skip the "already downloaded" check and
    /// ignore the existing copy as a source.
    private var requalifying: Set<UUID> = []

    /// Don't drain the queue until the library loads, or every restored id looks deleted.
    private var hasSeenLibrary = false

    private static let maxAttempts = 3

    /// Concurrent downloads, chosen by the resolver: the Mac's yt-dlp scales, the hosted one doesn't.
    /// See `suggestedDownloadConcurrency`.
    private var maxConcurrentDownloads: Int {
        max(1, trackResolver.suggestedDownloadConcurrency)
    }

    /// 4s, then 16s.
    private static func retryDelay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(60, 1 << (2 * attempt)))
    }

    private var queueKey: String {
        if let id = currentUserID { return "mix.downloadQueue_\(id)" }
        return "mix.downloadQueue"
    }

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

        self.downloadOnWifiOnly     = UserDefaults.standard.object(forKey: "mix.downloadOnWifiOnly") as? Bool ?? true
        self.syncMetadataToDisk     = UserDefaults.standard.object(forKey: "mix.syncMetadataToDisk") as? Bool ?? true
        self.keepFileCopyOnDownload = UserDefaults.standard.object(forKey: "mix.keepFileCopyOnDownload") as? Bool ?? false
        self.downloadQuality        = DownloadQuality(rawValue: UserDefaults.standard.string(forKey: "mix.downloadQuality") ?? "") ?? .normal
        self.editQuality            = EditQuality(rawValue: UserDefaults.standard.string(forKey: "mix.editQuality") ?? "") ?? .normal
        self.autoAdjustQuality      = UserDefaults.standard.object(forKey: "mix.autoAdjustQuality") as? Bool ?? true
        self.autoDownloadImportedPlaylists =
            UserDefaults.standard.object(forKey: "mix.autoDownloadImportedPlaylists") as? Bool ?? false

        self.offlineTrackIDs = OfflineStore.shared.trackIDs
        self.downloadedTrackIDs = offlineTrackIDs
        self.downloadQueue   = Self.restoreQueue(key: "mix.downloadQueue")

        // Signed-out defaults; `loadSettings` re-reads them per account.
        loadKeepOffline()

        setupNetworkMonitoring()
        setupLibraryObservation()
        setupFileStorageObservation()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Network Status

    public var isConnectedForDownload: Bool {
        guard isConnected else { return false }
        if downloadOnWifiOnly {
            return isUnmetered
        }
        return true
    }

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            let wifi      = path.usesInterfaceType(.wifi)
            let wired     = path.usesInterfaceType(.wiredEthernet)

            Task { @MainActor in
                let couldDownload = self.isConnectedForDownload
                self.isConnected = connected
                self.isWifi      = wifi
                self.isWired     = wired
                // Coming back online, retry the songs that failed; lost connectivity is the usual cause.
                if !couldDownload, self.isConnectedForDownload {
                    self.retryFailedDownloads()
                }
                self.processDownloadQueue()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Library Observation

    private func setupLibraryObservation() {
        libraryService.$tracks
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                self.rescan(tracks: tracks)
            }
            .store(in: &cancellables)

        libraryService.$playlists
            .receive(on: RunLoop.main)
            .sink { [weak self] playlists in
                self?.syncKeptPlaylists(playlists)
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
                    // Coalesced to whole percent: this fires per chunk, and a ring can't show finer anyway.
                    let last = self.downloadProgress[trackID] ?? 0
                    guard progress.fraction - last >= 0.01 else { return }
                    self.downloadProgress[trackID] = progress.fraction
                } else {
                    // Not a download until it's in the offline store; the worker below does that and clears the state.
                    self.downloadProgress.removeValue(forKey: trackID)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    public func status(for trackID: UUID) -> TrackAvailability {
        if downloadingTrackIDs.contains(trackID) {
            return .downloading(progress: downloadProgress[trackID] ?? 0.0)
        }
        if offlineTrackIDs.contains(trackID) { return .offline }
        if localTrackIDs.contains(trackID)   { return .local }
        // After the "it's here" checks: a failed track that arrived another way isn't failed.
        if failedTrackIDs.contains(trackID)  { return .failed }
        return .streamOnly
    }

    /// What went wrong the last time this track was tried, if it failed.
    public func failureReason(for trackID: UUID) -> String? {
        failureReasons[trackID]
    }

    public func status(for track: Track) -> TrackAvailability {
        status(for: track.id)
    }

    /// Whether a file copy exists in the export folder. Independent of availability.
    public func isExported(_ trackID: UUID) -> Bool {
        exportedTrackIDs.contains(trackID)
    }

    /// Why the download control is inert for this track, or nil if it's live.
    public func downloadUnavailableReason(for track: Track) -> String? {
        guard let block = blockReason(for: track) else { return nil }
        // Downloading or downloaded doesn't make the control inert; the menu shows Remove Download or progress.
        switch block {
        case .alreadyDownloaded, .inFlight: return nil
        case .alreadyLocal, .unavailable:   return block.message(for: track.title)
        }
    }

    /// Why this track can't be downloaded right now, or nil. Checked against the disk via `AudioLocator`,
    /// not the published sets. No connection isn't a block: the song waits in the queue.
    public func blockReason(for track: Track) -> DownloadBlock? {
        if downloadingTrackIDs.contains(track.id) || downloadQueue.contains(track.id) {
            return .inFlight
        }

        switch AudioLocator.locate(track) {
        case .ready(_, .offlineDownload):
            return .alreadyDownloaded
        // A watched-folder file is already here, in a folder the user chose.
        case .ready(_, .importedFile), .ready(_, .watchedFolder):
            return .alreadyLocal
        // A cached copy or exported file copy is a source, not a download.
        case .ready(_, .cached), .ready(_, .exportedCopy):
            return nil
        case .remote, .resolvable:
            return nil
        case .unavailable(let reason):
            // Not a block when the resolver would try anyway, same as `PlaybackEngine.needsOnlineResolution`.
            return Self.resolverMightFind(reason) ? nil : .unavailable(reason)
        }
    }

    /// Reasons worth handing to the resolver, the same set playback uses. A row from someone else's
    /// shared library has nothing to search for.
    static func resolverMightFind(_ reason: UnavailableReason) -> Bool {
        reason == .notUploadedYet || reason == .fileMissing
    }

    /// True when Download is worth offering for this track.
    public func canDownload(_ track: Track) -> Bool {
        blockReason(for: track) == nil
    }

    public func reEvaluateDownloads() {
        rescan(tracks: libraryService.tracks)
    }

    /// Total size of the offline store, for the Settings row.
    public var offlineBytes: Int64 { OfflineStore.shared.totalBytes }

    public var offlineCount: Int { offlineTrackIDs.count }

    /// Downloads a single track. Returns why it didn't start, or nil when queued.
    @discardableResult
    public func download(_ track: Track) -> DownloadBlock? {
        let block = enqueueTrackDownload(track)
        // A single-song download is remembered so switching a playlist off later can't remove it. Recorded
        // even if the copy is already here or on its way; not when there's nothing to claim (an imported
        // file, or no audio anywhere).
        switch block {
        case .some(.alreadyLocal), .some(.unavailable):
            break
        default:
            manualOfflineIDs.insert(track.id)
        }
        return block
    }

    /// "Save a File Copy": writes `track` to the export folder at the current download quality.
    /// Uses the same source resolution as a download, so Discover songs (no `remoteKey`) work too.
    public func saveFileCopy(of track: Track) async throws {
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }

        // An offline copy is already at this quality, so copy its bytes rather than encode a second lossy pass.
        let fromOfflineStore: Bool
        if case .ready(_, .offlineDownload) = AudioLocator.locate(track) {
            fromOfflineStore = true
        } else {
            fromOfflineStore = false
        }

        let source = try await fetchAudio(for: track, ignoringOfflineCopy: false)
        if source.isTemporary { staged = source.container ?? source.url }

        try await ExportManager.shared.export(
            track: track,
            from: source.url,
            quality: fromOfflineStore ? .high : effectiveDownloadQuality
        )
        exportedTrackIDs.insert(track.id)
    }

    /// A local file of `track`'s audio for the song editor, fetched like a download when there isn't one.
    /// `scratch` is a temporary copy the caller deletes when done.
    public func localAudio(for track: Track) async throws -> (url: URL, scratch: URL?) {
        let source = try await fetchAudio(for: track, ignoringOfflineCopy: false)
        return (source.url, source.isTemporary ? (source.container ?? source.url) : nil)
    }

    /// Whether any of these songs is queued, downloading, or waiting to retry.
    public func hasWorkInFlight(tracks: [Track]) -> Bool {
        tracks.contains { track in
            downloadingTrackIDs.contains(track.id)
            || downloadQueue.contains(track.id)
            || retryTasks[track.id] != nil
        }
    }

    /// How many of these songs gave up.
    public func failedCount(tracks: [Track]) -> Int {
        tracks.reduce(0) { $0 + (failedTrackIDs.contains($1.id) ? 1 : 0) }
    }

    /// Queues everything in this list not on the device yet, with a fresh attempt count (the "try again"
    /// on a stalled playlist). Separate from `retryFailedDownloads`: a song can be missing without ever
    /// being marked failed, e.g. a queue dropped on quit or a cancelled retry.
    public func resumeDownloads(tracks: [Track]) {
        for track in tracks where track.canResolveAudio {
            let state = status(for: track.id)
            guard !state.isAvailableOffline, !state.isDownloading,
                  !downloadQueue.contains(track.id)
            else { continue }
            enqueueTrackDownload(track)
        }
    }

    /// Tries every track that gave up, from a clean attempt count.
    public func retryFailedDownloads() {
        for trackID in failedTrackIDs {
            guard let track = libraryService.track(id: trackID) else { continue }
            enqueueTrackDownload(track)
        }
    }

    /// Refetches everything in the offline store at the current quality, since changing the setting can't
    /// touch files already written. Imported files are left alone. Each old file stays until its
    /// replacement lands, so a failed fetch doesn't lose the download.
    public func redownloadAllAtCurrentQuality() {
        for trackID in offlineTrackIDs {
            guard let track = libraryService.track(id: trackID) else { continue }
            requalifying.insert(trackID)
            // Refused (already queued or no source): clear the flag, or a later download would ignore this copy.
            if enqueueTrackDownload(track, force: true) != nil {
                requalifying.remove(trackID)
            }
        }
    }

    /// Drops the downloaded file but keeps the wish for it ("Wrong version" on a downloaded song).
    /// Returns whether there was one; `refetch` brings it back.
    public func discardOfflineCopy(of track: Track) -> Bool {
        guard offlineTrackIDs.contains(track.id) else { return false }
        OfflineStore.shared.remove(track.id)
        offlineTrackIDs.remove(track.id)
        return true
    }

    /// Downloads a song again after `discardOfflineCopy`, without a claim of its own.
    public func refetch(_ track: Track) {
        enqueueTrackDownload(track, force: true)
    }

    // MARK: - Playlist Offline State Management

    /// Whether the user asked for this playlist to be kept on the device; not whether its songs are on disk.
    /// See `keepOfflineIDs`.
    public func isPlaylistOffline(_ playlistID: UUID) -> Bool {
        keepOfflineIDs.contains(playlistID)
    }

    /// Songs something still wants on the device: other kept playlists (system ones included; they're
    /// only in the set if the user pressed the button) and `manualOfflineIDs`.
    /// Call after removing the playlist being switched off from `keepOfflineIDs`. Built once per toggle,
    /// not per song.
    private func claimedOfflineTrackIDs() -> Set<UUID> {
        var claimed = manualOfflineIDs
        for playlist in libraryService.playlists
        where keepOfflineIDs.contains(playlist.id) && !playlist.isDeleted {
            claimed.formUnion(playlist.trackIDs)
        }
        return claimed
    }

    /// The same question for a list of songs that isn't a stored playlist. Only songs this device could
    /// ever hold count; a stale id or an unfetchable placeholder would keep it "not downloaded" forever.
    public func isOffline(trackIDs: [UUID]) -> Bool {
        isOffline(tracks: resolve(trackIDs))
    }

    /// The same for songs already in hand; `libraryService.track(id:)` scans the library per id.
    public func isOffline(tracks: [Track]) -> Bool {
        let downloadable = tracks.filter(\.canResolveAudio)
        guard !downloadable.isEmpty else { return false }
        return downloadable.allSatisfy { status(for: $0.id).isAvailableOffline }
    }

    /// True when there's nothing here this device could ever fetch (empty, or only unresolvable shares).
    /// `isOffline` answers false for these, so callers that know the playlist is kept ask this too.
    public func nothingToDownload(tracks: [Track]) -> Bool {
        tracks.allSatisfy { !$0.canResolveAudio }
    }

    public func nothingToDownload(trackIDs: [UUID]) -> Bool {
        nothingToDownload(tracks: resolve(trackIDs))
    }

    /// How much of a list is on the device, 0 to 1, over the same songs as `isOffline`. A song being
    /// fetched counts for the part that has arrived, so the ring moves smoothly.
    public func offlineFraction(trackIDs: [UUID]) -> Double {
        offlineFraction(tracks: resolve(trackIDs))
    }

    public func offlineFraction(tracks: [Track]) -> Double {
        let downloadable = tracks.filter(\.canResolveAudio)
        guard !downloadable.isEmpty else { return 0 }

        let done = downloadable.reduce(0.0) { total, track in
            switch status(for: track.id) {
            case .offline, .local:           return total + 1
            case .downloading(let progress): return total + min(max(progress, 0), 1)
            case .failed, .streamOnly:       return total
            }
        }
        return min(done / Double(downloadable.count), 1)
    }

    /// Songs fully on the device and songs that could be, for "18 of 240". Partial downloads don't count.
    public func offlineCounts(tracks: [Track]) -> (done: Int, total: Int) {
        let downloadable = tracks.filter(\.canResolveAudio)
        let done = downloadable.filter {
            switch status(for: $0.id) {
            case .offline, .local: return true
            default:               return false
            }
        }.count
        return (done, downloadable.count)
    }

    /// Everything a download button needs about a list, from one pass over the tracks. The header used to
    /// ask five separate questions, each a full walk, on every redraw.
    public struct ListDownloadSummary {
        /// Songs this device could ever fetch; unresolvable placeholders are outside every count.
        public let downloadableCount: Int
        /// Of those, the ones fully on disk.
        public let offlineCount: Int
        /// 0...1, counting a song being fetched for the part that has arrived.
        public let fraction: Double
        /// Anything downloading, queued, or waiting to retry.
        public let hasWorkInFlight: Bool
        /// Anything whose audio a "remove downloads" press would delete.
        public let hasRemovableDownloads: Bool

        /// Nothing fetchable here: empty or only unresolvable shares. Not the same as finished.
        public var nothingToDownload: Bool { downloadableCount == 0 }

        /// Every fetchable song is here. False for an empty list.
        public var isOffline: Bool {
            downloadableCount > 0 && offlineCount == downloadableCount
        }
    }

    public func downloadSummary(tracks: [Track]) -> ListDownloadSummary {
        var downloadable = 0
        var offline      = 0
        var progress     = 0.0
        var inFlight     = false
        var removable    = false

        for track in tracks {
            let state = status(for: track.id)
            if state.isRemovableDownload { removable = true }
            if !inFlight,
               downloadingTrackIDs.contains(track.id)
                || downloadQueue.contains(track.id)
                || retryTasks[track.id] != nil {
                inFlight = true
            }
            guard track.canResolveAudio else { continue }
            downloadable += 1
            switch state {
            case .offline, .local:
                offline  += 1
                progress += 1
            case .downloading(let fraction):
                progress += min(max(fraction, 0), 1)
            case .failed, .streamOnly:
                break
            }
        }

        return ListDownloadSummary(
            downloadableCount: downloadable,
            offlineCount: offline,
            fraction: downloadable == 0 ? 0 : min(progress / Double(downloadable), 1),
            hasWorkInFlight: inFlight,
            hasRemovableDownloads: removable
        )
    }

    /// Ids to rows, dropping any whose song has since left the library.
    private func resolve(_ trackIDs: [UUID]) -> [Track] {
        trackIDs.compactMap { libraryService.track(id: $0) }
    }

    public func togglePlaylistOffline(_ playlistID: UUID) {
        guard let playlist = libraryService.playlists.first(where: { $0.id == playlistID }) else { return }

        if isPlaylistOffline(playlistID) {
            // Removed before the claim check so this playlist doesn't count as a reason to keep its own songs.
            keepOfflineIDs.remove(playlistID)
            keptTrackIDs.removeValue(forKey: playlistID)

            let claimed = claimedOfflineTrackIDs()
            let doomed = playlist.trackIDs.filter { !claimed.contains($0) }

            // Stop the backlog first, but only unclaimed songs: one still coming down for another kept playlist
            // is still wanted.
            stopDownloads(for: doomed)
            // Only copies this app made; imported files stay put.
            for trackID in doomed where status(for: trackID).isRemovableDownload {
                removeDownload(for: trackID)
            }
        } else {
            keepPlaylistOffline(playlistID)
        }
    }

    /// Switches a playlist on, idempotently. Anything meaning "make sure this is kept" must come through
    /// here: toggling an already-kept playlist switches it off and deletes its downloads. Safe to call
    /// before the songs land; `syncKeptPlaylists` picks up later arrivals.
    public func keepPlaylistOffline(_ playlistID: UUID) {
        guard !keepOfflineIDs.contains(playlistID) else { return }
        guard let playlist = libraryService.playlists.first(where: { $0.id == playlistID }),
              !playlist.isDeleted
        else { return }

        keepOfflineIDs.insert(playlistID)
        keptTrackIDs[playlistID] = playlist.trackIDs
        enqueuePlaylistTracks(playlist)
    }

    /// Called when a playlist arrives from outside (`LibraryService.onPlaylistImported`, wired by
    /// `AppDependencies`). No-op unless the setting is on. All Songs and Favourites are excluded; see
    /// `syncKeptPlaylists`.
    public func autoKeepImportedPlaylist(_ playlistID: UUID) {
        guard autoDownloadImportedPlaylists else { return }
        guard libraryService.playlist(id: playlistID)?.isSystem == false else { return }
        keepPlaylistOffline(playlistID)
    }

    /// Loads the kept-offline set for the signed-in account. Nothing is inferred: the old seed from
    /// fully-downloaded playlists switched buttons on by itself, and via All Songs made every later
    /// import download silently.
    private func loadKeepOffline() {
        let defaults = UserDefaults.standard
        keepOfflineIDs = Set((defaults.stringArray(forKey: keepOfflineKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        manualOfflineIDs = Set((defaults.stringArray(forKey: manualOfflineKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        repairSeededSystemPlaylists()
        keptTrackIDs = Dictionary(uniqueKeysWithValues: libraryService.playlists
            .filter { keepOfflineIDs.contains($0.id) }
            .map { ($0.id, $0.trackIDs) })
    }

    /// Removes All Songs and Favourites left by the old seed (nobody presses the button there) and drops
    /// the backlog it queued, keeping songs from playlists the user did switch on. Nothing on disk is
    /// touched. Runs once per account.
    private func repairSeededSystemPlaylists() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: keepOfflineRepairKey) else { return }
        defaults.set(true, forKey: keepOfflineRepairKey)

        let seeded = keepOfflineIDs.intersection([Playlist.allSongsID, Playlist.favouritesID])
        guard !seeded.isEmpty else { return }
        keepOfflineIDs.subtract(seeded)

        let stillWanted = Set(libraryService.playlists
            .filter { keepOfflineIDs.contains($0.id) }
            .flatMap(\.trackIDs))
        let before = downloadQueue.count
        downloadQueue.removeAll { !stillWanted.contains($0) }
        if downloadQueue.count != before { persistQueue() }
    }

    /// Downloads songs that appeared in a kept playlist since last seen, and forgets playlists that left
    /// the library. All Songs and Favourites are skipped: a subscription to either would mean "download
    /// everything I ever add". Pressing the button on them still downloads what they hold now.
    private func syncKeptPlaylists(_ playlists: [Playlist]) {
        let live = Set(playlists.filter { !$0.isDeleted }.map(\.id))
        let gone = keepOfflineIDs.subtracting(live)
        if !gone.isEmpty {
            keepOfflineIDs.subtract(gone)
            for id in gone { keptTrackIDs.removeValue(forKey: id) }
        }

        for playlist in playlists
        where keepOfflineIDs.contains(playlist.id) && !playlist.isDeleted && !playlist.isSystem {
            let seen  = keptTrackIDs[playlist.id] ?? []
            guard playlist.trackIDs != seen else { continue }
            keptTrackIDs[playlist.id] = playlist.trackIDs

            let added = Set(playlist.trackIDs).subtracting(seen)
            guard !added.isEmpty else { continue }
            // `enqueueBatch` skips songs already on disk or queued; only drop the unfetchable ones here.
            enqueueBatch(playlist.trackIDs
                .filter { added.contains($0) }
                .compactMap { libraryService.track(id: $0) }
                .filter(\.canResolveAudio))
        }
    }

    private func loadSettings() {
        if currentUserID != nil {
            self.downloadOnWifiOnly     = UserDefaults.standard.object(forKey: downloadOnWifiOnlyKey) as? Bool ?? true
            self.syncMetadataToDisk     = UserDefaults.standard.object(forKey: syncMetadataToDiskKey) as? Bool ?? true
            self.keepFileCopyOnDownload = UserDefaults.standard.object(forKey: keepFileCopyKey) as? Bool ?? false
            self.downloadQuality        = DownloadQuality(rawValue: UserDefaults.standard.string(forKey: downloadQualityKey) ?? "") ?? .normal
            self.editQuality            = EditQuality(rawValue: UserDefaults.standard.string(forKey: editQualityKey) ?? "") ?? .normal
            self.autoAdjustQuality      = UserDefaults.standard.object(forKey: autoAdjustQualityKey) as? Bool ?? true
            self.autoDownloadImportedPlaylists =
                UserDefaults.standard.object(forKey: autoDownloadImportedKey) as? Bool ?? false

            // Clear the previous account's queue and progress, then pick up whatever this one left.
            cancelInFlightWork()
            activeDownloads.removeAll()
            downloadingTrackIDs.removeAll()
            downloadProgress.removeAll()
            failedTrackIDs.removeAll()
            failureReasons.removeAll()
            attempts.removeAll()
            requalifying.removeAll()
            downloadQueue = Self.restoreQueue(key: queueKey)

            rescan(tracks: libraryService.tracks)
            // After the rescan, once this account's offline store has been read.
            loadKeepOffline()
            processDownloadQueue()
        } else {
            // Signed out: reset to defaults and clear the in-memory lists. Files stay; the next sign-in rescans.
            self.downloadOnWifiOnly     = true
            self.syncMetadataToDisk     = true
            self.keepFileCopyOnDownload = false
            self.downloadQuality        = .normal
            self.editQuality            = .normal
            self.autoAdjustQuality      = true
            self.autoDownloadImportedPlaylists = false
            cancelInFlightWork()
            downloadQueue.removeAll()
            persistQueue()
            activeDownloads.removeAll()
            downloadingTrackIDs.removeAll()
            downloadProgress.removeAll()
            offlineTrackIDs.removeAll()
            localTrackIDs.removeAll()
            exportedTrackIDs.removeAll()
            failedTrackIDs.removeAll()
            failureReasons.removeAll()
            attempts.removeAll()
            requalifying.removeAll()
            // In-memory only; the stored set is read back on the account's next sign-in.
            keepOfflineIDs.removeAll()
            keptTrackIDs.removeAll()
            manualOfflineIDs.removeAll()
        }
        objectWillChange.send()
    }

    // MARK: - Scanning

    /// Recomputes both axes from the filesystem. The offline set is a directory listing, read here;
    /// the others stat one file per track, so they run in the background.
    private func rescan(tracks: [Track]) {
        offlineTrackIDs = OfflineStore.shared.trackIDs

        // The restored queue is only ids, so it waits for a library to look them up in.
        if !tracks.isEmpty, !hasSeenLibrary {
            hasSeenLibrary = true
            processDownloadQueue()
        }

        let exports = ExportManager.shared.lookup()
        Task {
            let scan = await Self.scanFilesystem(tracks: tracks, exports: exports)
            guard !Task.isCancelled else { return }
            self.localTrackIDs    = scan.0
            self.exportedTrackIDs = scan.1
        }
    }

    /// Probes the disk for every track: which are imported, which are exported.
    /// A `Task.detached` around a synchronous body, because under Swift 6.2 (SE-0461) `nonisolated async`
    /// runs on the caller's actor. Keep the body free of main-actor state.
    nonisolated private static func scanFilesystem(tracks: [Track],
                                                   exports: ExportManager.Lookup) async -> (Set<UUID>, Set<UUID>) {
        await Task.detached(priority: .utility) {
            scanFilesystemSynchronously(tracks: tracks, exports: exports)
        }.value
    }

    nonisolated private static func scanFilesystemSynchronously(tracks: [Track],
                                                                exports: ExportManager.Lookup) -> (Set<UUID>, Set<UUID>) {
        var local    = Set<UUID>()
        var exported = Set<UUID>()
        for track in tracks {
            if hasImportedFile(track) { local.insert(track.id) }
            if ExportManager.exportedURL(for: track, in: exports) != nil { exported.insert(track.id) }
        }
        return (local, exported)
    }

    /// True when this track came from the user's own disk and the file is still there. Narrower than
    /// `SupabaseFileStorageService.localURL`: exported and cached copies can vanish, so they don't count.
    nonisolated private static func hasImportedFile(_ track: Track) -> Bool {
        guard !track.isOnline else { return false }
        return AudioPaths.durableURL(forLocalPath: track.file.localPath) != nil
    }

    // MARK: - Download Worker

    private func enqueuePlaylistTracks(_ playlist: Playlist) {
        enqueueBatch(playlist.trackIDs.compactMap { libraryService.track(id: $0) })
    }

    /// Queues a whole list in one pass, skipping everything already on the device. Same rules as
    /// `enqueueTrackDownload`, but one queue write and one scheduler pass instead of one per song.
    @discardableResult
    private func enqueueBatch(_ tracks: [Track]) -> Int {
        var queued: Set<UUID> = Set(downloadQueue)
        var added:  [UUID] = []

        for track in tracks {
            // Already queued, or on its way down right now.
            guard !queued.contains(track.id),
                  !downloadingTrackIDs.contains(track.id)
            else { continue }

            switch AudioLocator.locate(track) {
            case .ready(_, .offlineDownload), .ready(_, .importedFile):
                // Already playable with the network off. Nothing to do.
                continue
            case .unavailable(let reason):
                // No audio anywhere is an answer: recorded, not dropped.
                markFailed(track.id, message: reason.message(for: track.title))
                continue
            case .ready, .remote, .resolvable:
                break
            }

            clearFailure(track.id)
            attempts.removeValue(forKey: track.id)
            retryTasks.removeValue(forKey: track.id)?.cancel()

            queued.insert(track.id)
            added.append(track.id)
            noteBatchEnqueued()
        }

        guard !added.isEmpty else { return 0 }
        downloadQueue.append(contentsOf: added)
        persistQueue()
        processDownloadQueue()
        return added.count
    }

    // MARK: - Stopping

    /// Stops everything in progress for these songs: queued, downloading, or waiting to retry.
    /// Leaves downloaded copies alone.
    public func stopDownloads(for trackIDs: [UUID]) {
        let doomed = Set(trackIDs)
        guard !doomed.isEmpty else { return }

        downloadQueue.removeAll(where: doomed.contains)
        persistQueue()

        for id in doomed {
            downloadTasks.removeValue(forKey: id)?.cancel()
            retryTasks.removeValue(forKey: id)?.cancel()
            activeDownloads.remove(id)
            downloadingTrackIDs.remove(id)
            downloadProgress.removeValue(forKey: id)
            attempts.removeValue(forKey: id)
            requalifying.remove(id)
            clearFailure(id)
        }

        // Slots just freed up, and the rest of the queue may still be wanted.
        processDownloadQueue()
        resetBatchIfIdle()
        objectWillChange.send()
    }

    /// Stop every download in progress, whatever it belongs to.
    public func stopAllDownloads() {
        cancelInFlightWork()
        downloadQueue.removeAll()
        persistQueue()
        activeDownloads.removeAll()
        downloadingTrackIDs.removeAll()
        downloadProgress.removeAll()
        attempts.removeAll()
        requalifying.removeAll()
        batchCompleted = 0
        batchTotal = 0
        objectWillChange.send()
    }

    /// Whether there's a run worth drawing a bar for.
    public var isDownloadingBatch: Bool { batchTotal > 0 && hasAnyWorkInFlight }

    private func noteBatchEnqueued() { batchTotal += 1 }

    /// Called once a song leaves the run, successfully or not, so the bar can reach its total.
    private func noteBatchFinished() {
        batchCompleted = min(batchCompleted + 1, batchTotal)
    }

    private func resetBatchIfIdle() {
        guard !hasAnyWorkInFlight else { return }
        batchCompleted = 0
        batchTotal = 0
    }

    /// True while anything at all is queued, downloading, or waiting to retry.
    public var hasAnyWorkInFlight: Bool {
        !downloadQueue.isEmpty || !activeDownloads.isEmpty || !retryTasks.isEmpty
    }

    /// Queues a track, or returns why it didn't go in. `force` is for the requalify pass, the one
    /// caller that refetches a song already offline.
    @discardableResult
    private func enqueueTrackDownload(_ track: Track, force: Bool = false) -> DownloadBlock? {
        if let block = blockReason(for: track) {
            switch block {
            case .inFlight:
                return block
            case .alreadyDownloaded:
                guard force else { return block }
            case .alreadyLocal:
                return block
            case .unavailable(let reason):
                // No audio anywhere is an answer: recorded, not dropped.
                guard force else {
                    markFailed(track.id, message: reason.message(for: track.title))
                    return block
                }
            }
        }

        // A fresh ask clears whatever the last one concluded.
        clearFailure(track.id)
        attempts.removeValue(forKey: track.id)
        retryTasks.removeValue(forKey: track.id)?.cancel()

        downloadQueue.append(track.id)
        noteBatchEnqueued()
        persistQueue()
        processDownloadQueue()
        return nil
    }

    /// Fills every free slot, not just one; regaining Wi-Fi or flipping Wi-Fi-only must restart them all.
    private func processDownloadQueue() {
        guard hasSeenLibrary, isConnectedForDownload else { return }

        while activeDownloads.count < maxConcurrentDownloads, !downloadQueue.isEmpty {
            let trackID = downloadQueue.removeFirst()
            persistQueue()

            // A restored queue can name songs that left the library: drop them and keep draining.
            guard let track = libraryService.track(id: trackID) else {
                requalifying.remove(trackID)
                continue
            }
            startDownload(of: track)
        }
    }

    private func startDownload(of track: Track) {
        let trackID = track.id
        activeDownloads.insert(trackID)
        downloadingTrackIDs.insert(trackID)
        downloadProgress[trackID] = 0.0

        downloadTasks[trackID] = Task {
            defer { finishDownload(trackID) }

            // Held for the whole attempt so a failure doesn't leave a scratch file behind.
            var staged: URL?
            func discardStaging() {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                staged = nil
            }

            do {
                let source = try await fetchAudio(for: track,
                                                  ignoringOfflineCopy: requalifying.contains(trackID))
                if source.isTemporary { staged = source.container ?? source.url }

                // Stops mostly land during the fetch; checked explicitly because the resolver and URL session don't
                // always honour cancellation.
                try Task.checkCancellation()

                // A rebuilt edit is filed with the imports, so a second copy in the offline store isn't needed.
                if track.origin == .edit {
                    localTrackIDs.insert(track.id)
                    attempts.removeValue(forKey: track.id)
                    clearFailure(track.id)
                    return
                }

                try await OfflineStore.shared.adopt(source.url,
                                                    for: track.id,
                                                    quality: effectiveDownloadQuality)

                // Adopting isn't interruptible, so a stop during it lands here: undo the copy.
                if Task.isCancelled {
                    OfflineStore.shared.remove(track.id)
                    discardStaging()
                    return
                }

                offlineTrackIDs.insert(track.id)
                requalifying.remove(track.id)
                attempts.removeValue(forKey: track.id)
                clearFailure(track.id)

                // File copy, only because the user asked for it in Settings. Exported from the source, not the
                // offline copy, so it's one encode deep rather than two.
                if keepFileCopyOnDownload {
                    do {
                        try await ExportManager.shared.export(track: track,
                                                              from: source.url,
                                                              quality: effectiveDownloadQuality)
                        exportedTrackIDs.insert(track.id)
                    } catch {
                        MixLog.playback.error("[DownloadManager] Downloaded but couldn't write a file copy: \(error)")
                    }
                }

                // Cleaned up last: the export above still needed to read it.
                discardStaging()
                source.supersededCacheEntry?()

                MixLog.playback.debug("[DownloadManager] Downloaded for offline playback: \(track.title)")
            } catch is CancellationError {
                // A stop, not a failure; marking it failed would show a retry button.
                discardStaging()
            } catch {
                discardStaging()
                guard !Task.isCancelled else { return }
                recordAttemptFailure(for: track, error: error)
            }
        }
    }

    // MARK: - Retry

    /// Retries, or gives up and says so. A YouTube rate limit is the usual failure and often clears
    /// seconds later.
    private func recordAttemptFailure(for track: Track, error: Error) {
        let attempt = (attempts[track.id] ?? 0) + 1
        attempts[track.id] = attempt

        guard attempt < Self.maxAttempts else {
            MixLog.playback.error("[DownloadManager] Gave up on \(track.title) after \(attempt) attempts: \(error)")
            requalifying.remove(track.id)
            markFailed(track.id, message: error.localizedDescription)
            return
        }

        let delay = Self.retryDelay(afterAttempt: attempt)
        MixLog.playback.error("[DownloadManager] \(track.title) failed (attempt \(attempt)), retrying: \(error)")

        retryTasks[track.id]?.cancel()
        retryTasks[track.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.retryTasks.removeValue(forKey: track.id) != nil else { return }
                // Straight onto the queue: the attempt count bounds this, and re-checking eligibility would refuse a
                // requalifying track.
                guard !self.downloadQueue.contains(track.id),
                      !self.downloadingTrackIDs.contains(track.id) else { return }
                self.downloadQueue.append(track.id)
                self.persistQueue()
                self.processDownloadQueue()
            }
        }
    }

    private func markFailed(_ trackID: UUID, message: String) {
        failedTrackIDs.insert(trackID)
        failureReasons[trackID] = message
    }

    private func clearFailure(_ trackID: UUID) {
        failedTrackIDs.remove(trackID)
        failureReasons.removeValue(forKey: trackID)
    }

    // MARK: - Queue persistence

    /// The queue is persisted so a download that outlasts the session resumes on next launch.
    private func persistQueue() {
        UserDefaults.standard.set(downloadQueue.map(\.uuidString), forKey: queueKey)
    }

    private static func restoreQueue(key: String) -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Where a track's audio can be got from, and whether we own the file.
    private struct AudioSource {
        let url: URL
        /// True for scratch files this app created and should clean up.
        let isTemporary: Bool
        /// The staging directory to remove with the file, if any; the resolver may leave a `.part` beside it.
        var container: URL? = nil
        /// Set when the bytes came from the playback cache, so that entry can be dropped once the offline
        /// store has its own copy (`AudioLocator` reads the offline store first).
        var supersededCacheEntry: (() -> Void)? = nil
    }

    /// Thrown so a download with no source reaches the retry/failure path.
    private struct NoAudioSource: LocalizedError {
        let reason: UnavailableReason
        let title: String
        var errorDescription: String? { reason.message(for: title) }
    }

    private func fetchAudio(for track: Track, ignoringOfflineCopy: Bool) async throws -> AudioSource {
        switch AudioLocator.locate(track, ignoringOfflineStore: ignoringOfflineCopy) {

        // Reuse anything usable on disk: the offline store (unless requalifying), the playback cache, an
        // import, or an exported copy.
        case .ready(let url, .cached):
            let ref  = track.sourceRef
            let hash = track.file.fileHash
            return AudioSource(url: url, isTemporary: false, supersededCacheEntry: {
                if let ref, !ref.isEmpty { PlaybackCache.remove(forSourceRef: ref) }
                PlaybackCache.remove(forRemoteHash: hash)
            })

        case .ready(let url, _):
            return AudioSource(url: url, isTemporary: false)

        case .resolvable:
            return try await resolveAudio(for: track)

        case .remote:
            // Supabase: drives the progress publisher and lands in the cache.
            let url = try await fileStorage.download(track: track, accessToken: "")
            return AudioSource(url: url, isTemporary: false)

        case .unavailable(let reason) where track.origin == .edit:
            guard let rebuild = editRebuilder else { throw NoAudioSource(reason: reason, title: track.title) }
            return AudioSource(url: try await rebuild(track), isTemporary: false)

        case .unavailable(let reason):
            // No file and no remote key, but findable; same as playback. See `resolverMightFind`.
            guard Self.resolverMightFind(reason) else {
                throw NoAudioSource(reason: reason, title: track.title)
            }
            return try await resolveAudio(for: track)
        }
    }

    /// Searches for this song and downloads the resolver's pick.
    private func resolveAudio(for track: Track) async throws -> AudioSource {
        let query = "\(track.artistName) \(track.title)".trimmingCharacters(in: .whitespaces)

        // Staged in its own directory and found by listing it: resolvers name the output after the video
        // they picked and the container varies (.m4a, .opus, .webm).
        let staging = PlaybackCache.stagingDirectory
            .appendingPathComponent(track.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let ref = track.sourceRef
        // The upload this song already plays from, so the download matches what was heard
        // (and a thumbs-up or "Go back" pick sticks).
        let res: ResolvedAudio
        if let pinned = ref.flatMap({ onlineCoordinator?.knownVideoID(forSourceRef: $0) }) {
            res = try await trackResolver.download(videoID: pinned, fallbackQuery: query,
                                                   name: track.id.uuidString, to: staging)
        } else {
            res = try await trackResolver.download(
                query: query,
                name: track.id.uuidString,
                to: staging,
                expectedDuration: track.duration,
                preferExplicit: track.isExplicit,
                excluding: ref.flatMap { onlineCoordinator?.exclusions(for: $0) } ?? []
            )
        }
        // So a later "Wrong version" on the downloaded copy has something to refuse.
        if let ref { onlineCoordinator?.recordVideoID(res.videoID, for: ref) }

        let landed = FileManager.default.fileExists(atPath: res.fileURL.path(percentEncoded: false))
            ? res.fileURL
            : (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?.first

        guard let landed else {
            try? FileManager.default.removeItem(at: staging)
            throw NoAudioSource(reason: .needsInternet, title: track.title)
        }

        // Not adopted into the playback cache: it's going into the offline store, which `AudioLocator`
        // checks first, so a cached copy would just double the disk use.
        return AudioSource(url: landed, isTemporary: true, container: staging)
    }

    private func finishDownload(_ trackID: UUID) {
        downloadTasks.removeValue(forKey: trackID)
        activeDownloads.remove(trackID)
        downloadingTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)
        // Not counted while a retry is pending; the song hasn't left the run yet.
        if retryTasks[trackID] == nil { noteBatchFinished() }
        processDownloadQueue()
        resetBatchIfIdle()
        objectWillChange.send()
    }

    // MARK: - Removal

    /// Removes the offline copy. Any file copy in the export folder stays; `deleteFileCopy(for:)` does that.
    public func removeDownload(for trackID: UUID) {
        removeDownloads(for: [trackID])
    }

    /// `removeDownload` for a selection, with the queue write and change notification done once.
    public func removeDownloads(for trackIDs: Set<UUID>) {
        guard !trackIDs.isEmpty else { return }
        var queueChanged = false
        for id in trackIDs where removeDownloadBody(id) { queueChanged = true }
        if queueChanged { persistQueue() }
        objectWillChange.send()
    }

    /// Returns whether the stored queue needs rewriting.
    @discardableResult
    private func removeDownloadBody(_ trackID: UUID) -> Bool {
        guard let track = libraryService.track(id: trackID) else { return false }

        // Never touch a file the user imported themselves.
        guard status(for: trackID) != .local else { return false }

        let queued = downloadQueue.contains(trackID)
        let wasInRun = queued || activeDownloads.contains(trackID)
        downloadQueue.removeAll(where: { $0 == trackID })
        downloadTasks.removeValue(forKey: trackID)?.cancel()
        activeDownloads.remove(trackID)
        // Removing a song mid-run takes it out of the run, and out of the count.
        if wasInRun { noteBatchFinished() }
        downloadingTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)
        retryTasks.removeValue(forKey: trackID)?.cancel()
        attempts.removeValue(forKey: trackID)
        requalifying.remove(trackID)
        clearFailure(trackID)

        // "Remove Download" withdraws the claim with the file, on every removal path.
        manualOfflineIDs.remove(trackID)

        OfflineStore.shared.remove(trackID)
        offlineTrackIDs.remove(trackID)

        // The purgeable cache too, or the song stays playable offline until the OS reclaims it. Routed
        // through PlaybackCache because online tracks have no remote key.
        if let ref = track.sourceRef, !ref.isEmpty {
            PlaybackCache.remove(forSourceRef: ref)
        }
        PlaybackCache.remove(forRemoteHash: track.file.fileHash)

        // The pre-Caches location, for libraries that predate the move.
        if let remoteKey = track.file.remoteKey, !remoteKey.isEmpty {
            let ext = URL(fileURLWithPath: remoteKey).pathExtension.lowercased()
            let legacyURL = AudioPaths.legacyDocumentsDirectory
                .appendingPathComponent("\(track.file.fileHash).\(ext)")
            try? FileManager.default.removeItem(at: legacyURL)
        }

        return queued
    }

    /// Deletes the exported file copy only; the song stays downloaded if it was.
    public func deleteFileCopy(for trackID: UUID) {
        guard let track = libraryService.track(id: trackID) else { return }
        ExportManager.shared.deleteExportedFile(for: track)
        exportedTrackIDs.remove(trackID)
        objectWillChange.send()
    }

    /// Clears the whole offline store. Exported file copies are untouched.
    public func removeAllDownloads() {
        cancelInFlightWork()
        downloadQueue.removeAll()
        persistQueue()
        activeDownloads.removeAll()
        downloadingTrackIDs.removeAll()
        downloadProgress.removeAll()
        failedTrackIDs.removeAll()
        failureReasons.removeAll()
        attempts.removeAll()
        requalifying.removeAll()
        batchCompleted = 0
        batchTotal = 0

        OfflineStore.shared.removeAll()
        offlineTrackIDs.removeAll()
        manualOfflineIDs.removeAll()
        objectWillChange.send()
    }

    /// Cancels running downloads and pending retries. One function because every caller needs both.
    private func cancelInFlightWork() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
    }
}
