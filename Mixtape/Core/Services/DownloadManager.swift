// DownloadManager.swift
// Mixtape — Core/Services
//
// Owns "is this song available without a network, and is there a file copy of
// it on disk" — two questions that used to be one.
//
// The old model had a single `DownloadStatus` that meant "an MP3 for this track
// exists in the user's export folder". That conflated three unrelated things:
// keeping a song playable offline, keeping a human-readable file, and having
// imported the song from disk in the first place. The result was that pressing
// Download on a playlist wrote a folder full of MP3s nobody asked for, songs
// imported from the user's own drive got downloaded a second time once they'd
// synced, and a playlist of local files could never finish "going offline".
//
// So there are now two axes:
//
//   • Availability — `TrackAvailability`. Streaming only, downloading, in the
//     offline store, or already local because the user imported it.
//   • Export — `isExported(_:)`. Does a file copy exist in the export folder?
//     Opt-in, and never a side effect of playing music.
//
// Downloading means "put a copy in `OfflineStore`". Keeping a file copy is a
// separate wish, honoured alongside a download when the user asks for it.

import Foundation
import Combine
import Network

/// How a track can be played on *this* device, right now.
public enum TrackAvailability: Equatable, Hashable {
    /// Nothing on disk — playing it needs the network.
    case streamOnly
    case downloading(progress: Double)
    /// Deliberately downloaded into the offline store.
    case offline
    /// Imported from the user's own disk. Offline by nature, so never something
    /// to download, and never something for this app to delete.
    case local
    /// Asked for, tried, and didn't land. A state that has to exist: a download
    /// that quietly falls back to "stream only" is indistinguishable from one
    /// that was never requested, which is exactly how a Download All over
    /// twenty-three songs finishes with eighteen and says nothing.
    case failed

    /// Plays with the network off.
    public var isAvailableOffline: Bool {
        self == .offline || self == .local
    }

    /// Whether "Remove Download" applies. Local files are the user's own —
    /// removing them isn't ours to offer.
    public var isRemovableDownload: Bool { self == .offline }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// The colour family a row badge is drawn in. Named by meaning rather than by
/// hue so the SwiftUI and AppKit sides can each resolve it to their own colour
/// type without inventing their own opinion about which state is which.
public enum AvailabilityBadgeTint {
    /// Here and playable with the network off.
    case positive
    /// Work in progress.
    case active
    /// Asked for, didn't arrive.
    case negative
}

/// How a track's availability draws as a row badge.
///
/// This lives on the state rather than in the views because there are two
/// renderers — SwiftUI rows on both platforms and an AppKit `NSTableCellView`
/// on the Mac — and every time a state was added they drifted: `.failed`
/// reached one and not the other, and `.local` reached neither. Adding a case
/// to `TrackAvailability` now breaks this switch, which is the point.
public extension TrackAvailability {

    /// SF Symbol for the badge, or nil for states that show none.
    var badgeSymbol: String? {
        switch self {
        case .offline:     return "arrow.down.circle.fill"
        case .local:       return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed:      return "exclamationmark.circle"
        // The ordinary case for a saved Discover song. Badging it would put a
        // marker on most of the library and say nothing by being everywhere.
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
        // Deliberately distinct wording, not just a distinct glyph: this file is
        // the user's own upload, which is why it is here and why the app will
        // never offer to delete it.
        case .local:       return "Added by you — available offline"
        case .downloading: return "Downloading"
        case .failed:      return "Download failed"
        case .streamOnly:  return nil
        }
    }
}

/// Why pressing Download on a track would do nothing.
///
/// The old code expressed all of this as `guard … else { return }`, which is the
/// same answer for "you already have it" and "there is no audio anywhere to
/// fetch" — silence. Every rejection now has a reason that can be shown.
public enum DownloadBlock: Equatable {
    /// Already in the offline store.
    case alreadyDownloaded
    /// The user's own imported file. Downloading it would mean fetching back a
    /// file they handed us.
    case alreadyLocal
    /// Queued or in flight already.
    case inFlight
    /// There is no audio to fetch, for the reason given.
    case unavailable(UnavailableReason)

    public func message(for title: String) -> String {
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

/// The download values that change many times a second.
///
/// Split off `DownloadManager` so a percent tick republishes only the progress
/// bar, not every view that happens to read a download setting. Read by
/// `DownloadStatusBar` and by nothing else that draws per frame — see the
/// comment on `DownloadManager.progress`.
@MainActor
public final class DownloadProgress: ObservableObject {
    /// Per-track fraction, already coalesced to whole percent by the manager.
    @Published public internal(set) var fractions: [UUID: Double] = [:]

    /// Songs finished, and songs asked for, in the run currently under way.
    ///
    /// "Downloading 8 of 10" is the only honest answer to "how long is this
    /// going to take" — a percentage of a 2,000-song library is a number that
    /// sits on 0 for several minutes and then on 1, which reads as broken. The
    /// pair resets to zero once nothing is left in flight, so the bar tells the
    /// truth about *this* run rather than accumulating across the session.
    @Published public internal(set) var completed = 0
    @Published public internal(set) var total = 0
}

@MainActor
public final class DownloadManager: ObservableObject {

    /// Coalesced "something about downloads changed", for views that redraw on it.
    ///
    /// `objectWillChange` is a firehose. This class has two dozen `@Published`
    /// properties, and the ones that move during a download move constantly —
    /// so a view subscribing to it redraws tens of times a second for as long as
    /// anything is downloading. Measured on the playlist page: 180 full body
    /// passes in the twelve seconds around a play, each one re-walking the whole
    /// track list to answer "is this playlist downloaded", and each one a layout
    /// pass over a page that can hold thousands of rows. Nothing on screen said
    /// anything new for the vast majority of them.
    ///
    /// A download ring cannot report anything the eye can read faster than a few
    /// times a second, so this throttles to 4 Hz. `latest: true` is what makes it
    /// safe rather than merely cheaper: the last event of a burst is always
    /// delivered, so the settled state after a download finishes still arrives.
    ///
    /// `lazy` for a stable identity — `.onReceive` re-subscribes when the
    /// publisher it is handed changes, so this must not be rebuilt per body pass.
    public private(set) lazy var didChangeThrottled: AnyPublisher<Void, Never> =
        objectWillChange
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()

    // MARK: - Published State

    /// In the offline store. Deliberate downloads only.
    @Published public private(set) var offlineTrackIDs = Set<UUID>()
    /// Imported from disk and the file is still there.
    @Published public private(set) var localTrackIDs = Set<UUID>()
    /// A file copy exists in the export folder. Independent of the above.
    @Published public private(set) var exportedTrackIDs = Set<UUID>()

    @Published public private(set) var downloadingTrackIDs = Set<UUID>()
    /// Per-track download fraction, and the batch counters.
    ///
    /// Deliberately not stored here. `ObservableObject` has one
    /// `objectWillChange` for all of its state, so a percent tick on one song
    /// republished this manager — and with it every view that reads
    /// `keepOfflineIDs`, `downloadQuality`, `isConnected` or any of the other
    /// two dozen properties on it, none of which moved. The main songs table
    /// rehashes the whole library when that happens, and it doesn't even draw
    /// the fraction (see `NativeTrackTable`, which collapses `.downloading` to
    /// a constant in its row hash).
    ///
    /// So the high-frequency values live on their own small object, and the two
    /// leaf views that actually draw them observe that instead.
    public let progress = DownloadProgress()

    /// Write-through access, so the rest of this file reads as it always did.
    public internal(set) var downloadProgress: [UUID: Double] {
        get { progress.fractions }
        set { progress.fractions = newValue }
    }
    /// Tried the full retry budget and never landed. Stays set until the user
    /// asks again, so the row can say so instead of looking untouched.
    @Published public private(set) var failedTrackIDs = Set<UUID>()
    /// Starts true: the path monitor reports within moments of launch, and a
    /// false default read as "went offline" to everything watching for that
    /// edge — which switched the Downloaded filter on at every launch.
    @Published public private(set) var isConnected: Bool = true
    @Published public private(set) var isWifi: Bool = false
    /// Plugged into Ethernet. Tracked separately from Wi-Fi because the two are
    /// different facts, and one screen still wants to say "Wi-Fi" specifically.
    @Published public private(set) var isWired: Bool = false

    /// A connection nobody is being billed by the byte for.
    ///
    /// This is what "Wi-Fi only" has always meant — don't spend my mobile data —
    /// and asking `isWifi` instead got it wrong on exactly one machine: a Mac on
    /// Ethernet reports `usesInterfaceType(.wifi) == false`, so with the setting
    /// at its default the whole queue silently refused to start and no screen
    /// said why.
    public var isUnmetered: Bool { isWifi || isWired }

    /// What went wrong, per track, for the tooltip on a failed row.
    @Published public private(set) var failureReasons = [UUID: String]()

    /// Songs finished, and songs asked for, in the run currently under way.
    ///
    /// "Downloading 8 of 10" is the only honest answer to "how long is this
    /// going to take" — a percentage of a 2,000-song library is a number that
    /// sits on 0 for several minutes and then on 1, which reads as broken. The
    /// pair resets to zero once nothing is left in flight, so the bar tells the
    /// truth about *this* run rather than accumulating across the session.
    /// Stored on `progress` for the same reason the fractions are; see there.
    public internal(set) var batchCompleted: Int {
        get { progress.completed }
        set { progress.completed = newValue }
    }
    public internal(set) var batchTotal: Int {
        get { progress.total }
        set { progress.total = newValue }
    }

    /// Songs asked for but not started yet — waiting on a slot, a connection, or
    /// a retry timer.
    public var pendingDownloadCount: Int { downloadQueue.count + retryTasks.count }

    /// Everything playable without a network — downloads plus local imports.
    public var downloadedTrackIDs: Set<UUID> {
        offlineTrackIDs.union(localTrackIDs)
    }

    /// Is every one of these songs on this device? The green disc's one
    /// definition — four screens used to carry their own copy of this line.
    /// An empty list is not "downloaded": a playlist with no songs has nothing
    /// to play offline, and a disc on it reads as a promise it can't keep.
    public func isFullyDownloaded(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let have = downloadedTrackIDs
        return ids.allSatisfy { have.contains($0) }
    }

    /// How far along a download of these songs is, or nil when none is running.
    ///
    /// Counts songs, not bytes, with the one song currently being fetched
    /// contributing its own fraction — the same arithmetic as the status bar,
    /// so a ring and the bar under it never disagree. Nil rather than 1.0 when
    /// nothing is in flight: the caller draws the finished disc for that, and a
    /// full ring that never goes away is worse than no ring.
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

    /// Songs the user downloaded one at a time, rather than by switching a
    /// playlist on. See `manualOfflineIDs`.
    private var manualOfflineKey: String {
        if let id = currentUserID {
            return "mix.manualOfflineTracks_\(id)"
        }
        return "mix.manualOfflineTracks"
    }

    /// Marks that this account's stored set has had the old seed's system-playlist
    /// guesses cleared out of it. See `repairSeededSystemPlaylists`.
    private var keepOfflineRepairKey: String {
        if let id = currentUserID {
            return "mix.keepOfflineRepaired_\(id)"
        }
        return "mix.keepOfflineRepaired"
    }

    /// The playlists the user has asked to keep on the device.
    ///
    /// Stored rather than worked out from the songs, because the two answers
    /// differ in the case that matters: importing a playlist made of songs you
    /// already downloaded produces a playlist every one of whose songs is on
    /// disk, and nobody said it should stay that way. A derived answer calls
    /// that playlist "downloaded" and then — since this set is also what makes
    /// songs added later download themselves — starts fetching things on its
    /// own. So the green button means "you pressed it", nothing else.
    ///
    /// Nothing seeds this set. It is written by `togglePlaylistOffline` and read
    /// back per account, and that is the only way an id gets into it — see
    /// `loadKeepOffline` for the inference that used to live there and why it
    /// had to go.
    @Published public private(set) var keepOfflineIDs: Set<UUID> = [] {
        didSet {
            guard keepOfflineIDs != oldValue else { return }
            UserDefaults.standard.set(keepOfflineIDs.map(\.uuidString), forKey: keepOfflineKey)
        }
    }

    /// Track lists last seen for the kept playlists, so a change publish can
    /// tell "a song was added" from "something else about the library moved".
    private var keptTrackIDs: [UUID: [UUID]] = [:]

    /// Songs the user asked for by name — the download button on a row, the
    /// menu item, a multi-selection — as opposed to ones that came down because
    /// a playlist they are in is being kept.
    ///
    /// A separate set from `keepOfflineIDs` because the two are different kinds
    /// of promise. A kept playlist is a standing subscription: songs added to it
    /// later download themselves. A song downloaded on its own is a claim on
    /// that one song and nothing else. Switching a playlist off has to honour
    /// both, and without this set there is no record that the second one was
    /// ever made — so a song downloaded by hand, later added to a playlist and
    /// then removed with it, lost the copy the user had personally asked for.
    ///
    /// Cleared by "Remove Download", which is the user taking the claim back.
    @Published public private(set) var manualOfflineIDs: Set<UUID> = [] {
        didSet {
            guard manualOfflineIDs != oldValue else { return }
            UserDefaults.standard.set(manualOfflineIDs.map(\.uuidString), forKey: manualOfflineKey)
        }
    }

    /// How much disk each download is allowed to take.
    ///
    /// Normal by default. A library of a few thousand songs kept at whatever
    /// bitrate the source happened to serve runs to tens of gigabytes, and
    /// almost nobody wants that as the unasked-for default. `.high` is one tap
    /// away for anyone who does.
    @Published public var downloadQuality: DownloadQuality {
        didSet {
            UserDefaults.standard.set(downloadQuality.rawValue, forKey: downloadQualityKey)
        }
    }

    /// When ON, downloads over a metered connection drop one quality step.
    @Published public var autoAdjustQuality: Bool {
        didSet {
            UserDefaults.standard.set(autoAdjustQuality, forKey: autoAdjustQualityKey)
        }
    }

    /// The quality the next download will actually use.
    ///
    /// Read at the moment a download starts rather than when it's queued: a
    /// queue can outlive the connection it was built on, and the honest answer
    /// to "what quality is this" is the one true when the bytes arrive.
    public var effectiveDownloadQuality: DownloadQuality {
        guard autoAdjustQuality, isConnected, !isUnmetered else { return downloadQuality }
        return downloadQuality.loweredForCellular
    }

    /// When ON, every download also drops a file copy in the export folder.
    ///
    /// OFF by default: a download is for listening, and most people don't want
    /// a second, much larger copy of their library appearing in Music. This
    /// setting is scoped to the download action only — adding a song to the
    /// library never writes a file on its own.
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

    /// When ON, a playlist that arrives from outside is kept on the device the
    /// moment it lands — a Spotify import, a saved mix, someone else's playlist.
    ///
    /// OFF by default, and it has to stay that way. This app used to do exactly
    /// this by inference and it went badly: see `loadKeepOffline`, where a seed
    /// that switched playlists on by itself turned every later import into a
    /// silent download with no green button anywhere to explain it. The
    /// difference now is that this is a switch the user threw, it names what it
    /// does, and every playlist it opts in shows its own button switched on —
    /// so the state is visible in the place you'd go to undo it.
    ///
    /// Only playlists that came from somewhere else. A playlist the user makes
    /// here is made from songs they already have.
    @Published public var autoDownloadImportedPlaylists: Bool {
        didSet {
            UserDefaults.standard.set(autoDownloadImportedPlaylists, forKey: autoDownloadImportedKey)
        }
    }

    // MARK: - Dependencies

    private let fileStorage:    SupabaseFileStorageService
    private let libraryService: LibraryService
    /// Held for the queue-observation hook; nothing downloads off playback any
    /// more (see the note on `setupQueueObservation`).
    private let queueService:   QueueService
    private let trackResolver:  any TrackResolver

    // MARK: - Private State

    private var downloadQueue:      [UUID] = []
    private var activeDownloads:    Set<UUID> = []
    private let pathMonitor =       NWPathMonitor()
    private let monitorQueue =      DispatchQueue(label: "mix.download.network")
    private var cancellables =      Set<AnyCancellable>()

    /// How many times each track has been tried this session.
    private var attempts: [UUID: Int] = [:]
    /// The download currently running for each track.
    ///
    /// These used to be fire-and-forget `Task {}`s that nothing held a handle
    /// to, which made an in-flight download impossible to stop: clearing
    /// `activeDownloads` only made the UI look calm while the task carried on,
    /// finished, and wrote the file into the offline store afterwards. Switching
    /// a 2,000-song playlist back off therefore deleted what had landed while
    /// the rest kept arriving, with no button anywhere reflecting it.
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]

    /// Sleeping retries, so they can be cancelled when the user changes their
    /// mind (or signs out) rather than firing into a different library.
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    /// Tracks being fetched again to land at a new quality. They're already in
    /// the offline store, so they skip the "already downloaded" check and their
    /// existing copy is ignored when choosing a source.
    private var requalifying: Set<UUID> = []

    /// The queue is only safe to drain once the library has actually loaded —
    /// before that every restored id looks like a track that no longer exists.
    private var hasSeenLibrary = false

    private static let maxAttempts = 3

    /// How many downloads run at once. The resolver decides, because it is the
    /// thing doing the work — the Mac's own yt-dlp scales with the machine,
    /// the hosted resolver does not (see `suggestedDownloadConcurrency`).
    private var maxConcurrentDownloads: Int {
        max(1, trackResolver.suggestedDownloadConcurrency)
    }

    /// 4s, then 16s. Long enough for a flaky resolver or a moment of no
    /// connectivity to pass, short enough that a Download All finishes while the
    /// user is still in the room.
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
        self.autoAdjustQuality      = UserDefaults.standard.object(forKey: "mix.autoAdjustQuality") as? Bool ?? true
        self.autoDownloadImportedPlaylists =
            UserDefaults.standard.object(forKey: "mix.autoDownloadImportedPlaylists") as? Bool ?? false

        self.offlineTrackIDs = OfflineStore.shared.trackIDs
        self.downloadQueue   = Self.restoreQueue(key: "mix.downloadQueue")

        // Signed-out defaults; `loadSettings` re-reads both under the account's
        // own keys the moment one is known.
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
                // Coming back online is the moment the songs that gave up
                // deserve another go: the overwhelmingly common cause of a
                // batch losing songs is a connection that wasn't there, and
                // without this they stay failed until the app is relaunched.
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
                    // Coalesced to whole percent. This publisher fires per
                    // received chunk — dozens of times a second per download —
                    // and `downloadProgress` is `@Published`, so every one of
                    // those republished this manager, then `AppDependencies`
                    // (which forwards it), then every view holding either. The
                    // songs table rehashes the whole library when that happens.
                    // A progress ring can't show more than whole percent
                    // anyway, so the rest of those publishes bought nothing.
                    let last = self.downloadProgress[trackID] ?? 0
                    guard progress.fraction - last >= 0.01 else { return }
                    self.downloadProgress[trackID] = progress.fraction
                } else {
                    // The file has landed, but it isn't a download until it's in
                    // the offline store — the worker below does that and clears
                    // the in-flight state itself.
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
        // Checked after the two "it's here" sets: a track that failed once and
        // arrived some other way isn't failed any more.
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

    /// Whether a file copy of this track exists in the export folder. Separate
    /// from availability: a song can be downloaded without a file copy, exported
    /// without being downloaded, or both.
    public func isExported(_ trackID: UUID) -> Bool {
        exportedTrackIDs.contains(trackID)
    }

    /// Why the download control is inert for this track, or nil if it's live.
    public func downloadUnavailableReason(for track: Track) -> String? {
        guard let block = blockReason(for: track) else { return nil }
        // Being downloaded, or already downloaded, isn't a reason the *control*
        // is inert — the menu shows Remove Download or a progress item instead.
        switch block {
        case .alreadyDownloaded, .inFlight: return nil
        case .alreadyLocal, .unavailable:   return block.message(for: track.title)
        }
    }

    /// Why this track can't be downloaded right now, or nil if it can.
    ///
    /// Decided from the filesystem via `AudioLocator` rather than from the
    /// published sets, because the sets are a cache of that answer and the
    /// action should be taken against what's actually on disk.
    ///
    /// Note what is deliberately *not* a block: having no connection. That's a
    /// reason to wait in the queue, not a reason to refuse.
    public func blockReason(for track: Track) -> DownloadBlock? {
        if downloadingTrackIDs.contains(track.id) || downloadQueue.contains(track.id) {
            return .inFlight
        }

        switch AudioLocator.locate(track) {
        case .ready(_, .offlineDownload):
            return .alreadyDownloaded
        // A watched-folder file is already on this device, in a folder the user
        // chose. Copying it into the offline store would only waste the space.
        case .ready(_, .importedFile), .ready(_, .watchedFolder):
            return .alreadyLocal
        // A cached copy or an exported file copy is a source, not a download.
        // Both used to fail the old `hasRemoteKey || isOnline` guard and drop
        // out of the queue without a word.
        case .ready(_, .cached), .ready(_, .exportedCopy):
            return nil
        case .remote, .resolvable:
            return nil
        case .unavailable(let reason):
            // Not a block when the resolver would have a go anyway. Playback
            // already does exactly this (PlaybackEngine.needsOnlineResolution),
            // so refusing here meant Download said a song had no audio while
            // the play button fetched it seconds later.
            return Self.resolverMightFind(reason) ? nil : .unavailable(reason)
        }
    }

    /// The reasons worth handing to the resolver rather than failing on.
    /// Deliberately the same set playback uses: a row stranded by a device that
    /// never uploaded, or one whose file went missing, can still be found by
    /// searching. A row shared out of someone else's library genuinely has no
    /// source to look for.
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

    /// Download a single track for offline playback. Returns why it didn't
    /// start, or nil when it's queued.
    @discardableResult
    public func download(_ track: Track) -> DownloadBlock? {
        let block = enqueueTrackDownload(track)
        // Pressing Download on one song is a claim on that song, remembered so
        // that switching some playlist off later can't quietly take it away.
        // Recorded even when the enqueue is refused because the copy is already
        // here or already on its way: the ask is the same either way. Not
        // recorded when there is nothing to claim — an imported file this app
        // never fetched, or a song with no audio anywhere.
        switch block {
        case .some(.alreadyLocal), .some(.unavailable):
            break
        default:
            manualOfflineIDs.insert(track.id)
        }
        return block
    }

    /// Writes a copy of `track` into the user's export folder, at the current
    /// download quality.
    ///
    /// This is "Save a File Copy", and it goes through the same source
    /// resolution as a download for one reason: it used to have its own, which
    /// went straight to `fileStorage` and therefore only ever worked for songs
    /// with a `remoteKey`. A Discover song has none — so the one menu item
    /// whose entire job is "put this song in my Music folder" failed on exactly
    /// the songs people wanted it for, with "Track file not downloaded locally
    /// yet." Resolving an online row is now part of the job, not a precondition.
    public func saveFileCopy(of track: Track) async throws {
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }

        // An existing offline copy is the ideal source — same audio, already
        // local — but it was written at this very quality setting, so encoding
        // it again would be a second lossy pass that changes nothing about the
        // bitrate. Copy those bytes straight through instead.
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

    /// True when at least one of these songs is queued, downloading, or sleeping
    /// between retries — i.e. the ring on a playlist button is describing work
    /// that is actually going to happen.
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

    /// Queues everything in this list that isn't on the device yet, from a clean
    /// attempt count — the "try again" behind a stalled playlist button.
    ///
    /// Kept separate from `retryFailedDownloads` because the two populations
    /// differ in the case this exists for: a song can be missing from a kept
    /// playlist without ever having been marked failed — the queue was dropped
    /// when the app quit, or the track arrived while the network was down and
    /// the retry chain has since been cancelled. Only asking `failedTrackIDs`
    /// would leave those sitting there forever.
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

    /// Fetches everything in the offline store again so it lands at the current
    /// quality.
    ///
    /// Changing the quality setting can't reach songs that are already on disk —
    /// those files are written, and their bitrate is a fact about the bytes, not
    /// a setting to re-read. Without this the picker would appear to do nothing
    /// for anyone whose library was already downloaded, which is most people who
    /// go looking for it.
    ///
    /// Imported files are untouched: they're the user's own, this app didn't
    /// fetch them, and re-encoding someone's own audio because they changed a
    /// download setting isn't ours to do.
    /// The existing file is left in place until its replacement has landed. The
    /// old version deleted first and re-fetched second, which turned "I changed
    /// my mind about bitrate" into "my downloads are gone" for every song whose
    /// fetch then failed — on a plane, exactly when it mattered.
    public func redownloadAllAtCurrentQuality() {
        for trackID in offlineTrackIDs {
            guard let track = libraryService.track(id: trackID) else { continue }
            requalifying.insert(trackID)
            // Refused (already queued, or nothing to fetch from): don't leave it
            // flagged, or a later ordinary download would ignore the very copy
            // it should be reusing.
            if enqueueTrackDownload(track, force: true) != nil {
                requalifying.remove(trackID)
            }
        }
    }

    // MARK: - Playlist Offline State Management

    /// True when every song in the playlist plays with the network off — whether
    /// it got there by being downloaded or by having been imported from disk.
    /// Whether the user has asked for this playlist to be kept on the device.
    ///
    /// Not "is every song here on disk" — see `keepOfflineIDs` for why those
    /// came apart.
    public func isPlaylistOffline(_ playlistID: UUID) -> Bool {
        keepOfflineIDs.contains(playlistID)
    }

    /// Whether anything still wants this song on the device.
    ///
    /// The question switching a playlist off has to ask before it deletes
    /// anything. A song can be in five playlists; the one being switched off is
    /// not the only voice, and the old code behaved as though it were — turning
    /// a playlist off took the copy away from every other playlist that had
    /// asked for the same song, and from the user who had downloaded it by hand.
    ///
    /// Two kinds of claim count, and both have to:
    ///
    /// - any *other* playlist the user is keeping. System playlists included:
    ///   All Songs and Favourites are never kept by default — see
    ///   `repairSeededSystemPlaylists` — so if one of them is in the set the
    ///   user pressed the button on it, and that is exactly as real an ask as
    ///   any other playlist's.
    /// - `manualOfflineIDs`, the songs downloaded one at a time.
    ///
    /// Call it *after* removing the playlist being switched off from
    /// `keepOfflineIDs`, or it answers "yes" for every song in it.
    ///
    /// Built once per toggle rather than asked per song: the membership test is
    /// a scan of every kept playlist's track list, and a 2,000-song playlist
    /// switching off would run it 2,000 times.
    private func claimedOfflineTrackIDs() -> Set<UUID> {
        var claimed = manualOfflineIDs
        for playlist in libraryService.playlists
        where keepOfflineIDs.contains(playlist.id) && !playlist.isDeleted {
            claimed.formUnion(playlist.trackIDs)
        }
        return claimed
    }

    /// The same question for a list of songs that isn't a stored playlist.
    ///
    /// Only songs this device could ever hold count. A track ID left behind by
    /// a song that has since left the library, or a collaborator's placeholder
    /// with no audio to fetch, can never be downloaded — and counting it meant
    /// a playlist whose every real song was on disk still reported "not
    /// downloaded", permanently, with no way for the user to fix it.
    public func isOffline(trackIDs: [UUID]) -> Bool {
        isOffline(tracks: resolve(trackIDs))
    }

    /// The same answer for songs already in hand.
    ///
    /// `libraryService.track(id:)` is a scan of the whole library, so the id
    /// version costs one of those per song — which a view redrawing on every
    /// progress tick, over an All Songs of a few thousand, feels. Every caller
    /// that is already holding the rows should hand them over.
    public func isOffline(tracks: [Track]) -> Bool {
        let downloadable = tracks.filter(\.canResolveAudio)
        guard !downloadable.isEmpty else { return false }
        return downloadable.allSatisfy { status(for: $0.id).isAvailableOffline }
    }

    /// True when there is nothing here this device could ever fetch.
    ///
    /// The empty playlist and the playlist of nothing but unresolvable shares
    /// are the same case: no work exists, so "not finished yet" is the wrong
    /// reading of them. `isOffline` deliberately answers `false` for both —
    /// an empty All Songs must not claim to be fully downloaded — so callers
    /// that also know the playlist is *kept* ask this alongside it.
    public func nothingToDownload(tracks: [Track]) -> Bool {
        tracks.allSatisfy { !$0.canResolveAudio }
    }

    public func nothingToDownload(trackIDs: [UUID]) -> Bool {
        nothingToDownload(tracks: resolve(trackIDs))
    }

    /// How much of a list of songs is on the device, from 0 to 1.
    ///
    /// The same population `isOffline` asks about, so the two can never
    /// disagree: a fraction of 1 and "it's all here" mean the same thing, and
    /// songs this device could never hold are outside both.
    ///
    /// A song being fetched right now counts for the part of it that has
    /// arrived. Without that the ring on a playlist of six long songs would sit
    /// still for a minute at a time and then jump a sixth, which reads as
    /// stalled rather than as working.
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

    /// Songs fully on the device, and songs that could be — for "18 of 240".
    ///
    /// Deliberately not `offlineFraction` rounded: a song half-downloaded is
    /// nought songs you can play on a plane, and the ring is already the place
    /// where partial progress shows. Counting only what's finished is what makes
    /// this number safe to put in a sentence about what you'd lose.
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

    /// Everything a download button needs to know about a list, in one pass.
    ///
    /// The playlist header used to ask five separate questions — is it offline,
    /// is there nothing to download, is any work in flight, what fraction is
    /// here, is there anything removable — and each one walked the whole track
    /// list calling `status(for:)` per song. On an All Songs of a few thousand
    /// that is five walks per body pass, and the page redraws whenever anything
    /// about downloads moves. Asking once and reading five answers off the
    /// result costs a fifth of that and cannot produce a self-contradicting
    /// button, since every answer is measured against the same instant.
    public struct ListDownloadSummary {
        /// Songs this device could ever fetch. Everything else — a placeholder
        /// with no resolvable audio — is outside every count here.
        public let downloadableCount: Int
        /// Of those, the ones fully on disk. Partial downloads are not counted:
        /// see `offlineCounts`.
        public let offlineCount: Int
        /// 0…1, counting a song being fetched for the part that has arrived.
        public let fraction: Double
        /// Anything downloading, queued, or waiting to retry.
        public let hasWorkInFlight: Bool
        /// Anything whose audio a "remove downloads" press would delete.
        public let hasRemovableDownloads: Bool

        /// Nothing here this device could ever fetch — empty, or nothing but
        /// unresolvable shares. Distinct from "finished".
        public var nothingToDownload: Bool { downloadableCount == 0 }

        /// Every fetchable song is on the device. False for an empty list, so
        /// an empty All Songs never claims to be fully downloaded.
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
            // Removed from the kept set *before* the claim check below, so this
            // playlist can't count as a reason to keep its own songs.
            keepOfflineIDs.remove(playlistID)
            keptTrackIDs.removeValue(forKey: playlistID)

            let claimed = claimedOfflineTrackIDs()
            let doomed = playlist.trackIDs.filter { !claimed.contains($0) }

            // Stop the backlog *first*. Deleting the finished copies while two
            // thousand more were still queued behind them is how switching this
            // off used to leave the folder growing. Only the unclaimed ones: a
            // song still on its way down for another kept playlist is work that
            // is still wanted, and cancelling it here left that playlist
            // permanently short of a song with nothing to say so.
            stopDownloads(for: doomed)
            // Only the copies this app made. Imported files stay exactly where
            // the user put them.
            for trackID in doomed where status(for: trackID).isRemovableDownload {
                removeDownload(for: trackID)
            }
        } else {
            keepPlaylistOffline(playlistID)
        }
    }

    /// Switch a playlist on, without the "off" half.
    ///
    /// Idempotent, and separate from `togglePlaylistOffline` for a reason worth
    /// spelling out: toggling something already on switches it *off*, and the
    /// off branch deletes the downloads. Anything that means "make sure this is
    /// kept" — the auto-download hook below, or any future caller — has to come
    /// through here, or it will eventually run twice and wipe a playlist the
    /// user asked to keep.
    ///
    /// Safe to call before the songs land: `syncKeptPlaylists` downloads what
    /// arrives afterwards, and `keptTrackIDs` starts as whatever is here now, so
    /// nothing is counted as already-seen that hasn't been.
    public func keepPlaylistOffline(_ playlistID: UUID) {
        guard !keepOfflineIDs.contains(playlistID) else { return }
        guard let playlist = libraryService.playlists.first(where: { $0.id == playlistID }),
              !playlist.isDeleted
        else { return }

        keepOfflineIDs.insert(playlistID)
        keptTrackIDs[playlistID] = playlist.trackIDs
        enqueuePlaylistTracks(playlist)
    }

    /// Called when a playlist arrives from outside — see
    /// `LibraryService.onPlaylistImported`, which `AppDependencies` wires to
    /// this. Does nothing unless the user asked for it.
    ///
    /// All Songs and Favourites are excluded even though nothing imports into
    /// them by creating them: this is the one caller that hands out a standing
    /// subscription without anyone pressing a button, and `syncKeptPlaylists`
    /// explains at length why those two must never carry one. Pressing the
    /// button on them by hand still works, and still means only "what's in
    /// there now".
    public func autoKeepImportedPlaylist(_ playlistID: UUID) {
        guard autoDownloadImportedPlaylists else { return }
        guard libraryService.playlist(id: playlistID)?.isSystem == false else { return }
        keepPlaylistOffline(playlistID)
    }

    /// Loads the kept-offline set for whichever account is signed in.
    ///
    /// Nothing is inferred. This used to seed itself, when nothing was stored,
    /// from every playlist that happened to be fully on disk — so that updating
    /// wouldn't show a shelf of downloaded playlists all switched off. That seed
    /// was the one thing in the app that could switch the button on without
    /// anyone pressing it, which is precisely what the doc comment on
    /// `keepOfflineIDs` says must never happen, and it did the most damage where
    /// it was least visible: `All Songs` and `Favourites` are playlists like any
    /// other to this scan, and every import ends by adding its songs to
    /// `All Songs`. Getting caught by the seed once therefore meant every
    /// playlist imported afterwards quietly downloaded itself, with no green
    /// button anywhere to explain why and no way to call it off.
    ///
    /// It also ran per account rather than once, so a second account signing in
    /// on the same device inherited opt-ins derived from the first one's files.
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

    /// Undoes the old seed where it can be identified with certainty.
    ///
    /// `All Songs` and `Favourites` are the two entries nobody navigates to in
    /// order to press this button, and the two whose presence turns every future
    /// import into a download — so an account carrying them is almost certainly
    /// carrying the seed's guess rather than a decision. Ordinary playlists are
    /// left exactly as they are: the seed may have chosen those too, but their
    /// button is visible and green, which makes it something the user can see
    /// and undo.
    ///
    /// The backlog the seed already built is dropped along with it. The queue
    /// outlives the launch that made it, so an account caught by this is
    /// carrying hundreds of songs it never asked for, and leaving them in would
    /// mean the fix landing and the downloads continuing anyway. Only songs that
    /// belong to a playlist the user really did switch on survive the cut —
    /// nothing on disk is touched, and anything dropped in error comes back by
    /// pressing the button again.
    ///
    /// Runs once per account. Turning the button back on afterwards sticks.
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

    /// Downloads whatever has appeared in a kept playlist since it was last
    /// seen, and forgets playlists that have left the library.
    ///
    /// This is the whole point of the button being a stored choice: "keep this
    /// playlist on my device" has to include the songs added to it tomorrow,
    /// and that is a promise only the playlists the user actually opted in to
    /// are allowed to make.
    ///
    /// All Songs and Favourites are deliberately not among them. They are the
    /// two playlists nobody curates — every import, every saved mix, every song
    /// added from Discover lands in All Songs by definition — so a standing
    /// subscription to one of those isn't "keep this list offline", it is "from
    /// now on, download everything I ever add", which is not what pressing a
    /// button on one page can reasonably be taken to mean. It is also invisible
    /// afterwards: the songs arrive on disk with no green button anywhere near
    /// them to explain why, which is exactly the report this rule comes from.
    /// Pressing the button on those two still downloads what they hold right
    /// now, which is the whole of what it looked like it was offering.
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
            // `enqueueBatch` applies the already-on-disk and already-queued
            // rules itself, so this only has to drop the rows that can never
            // be fetched at all.
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
            self.autoAdjustQuality      = UserDefaults.standard.object(forKey: autoAdjustQualityKey) as? Bool ?? true
            self.autoDownloadImportedPlaylists =
                UserDefaults.standard.object(forKey: autoDownloadImportedKey) as? Bool ?? false

            // Clear current transient download queue/progress states to prevent
            // bleed, then pick up whatever this account left unfinished.
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
            // After the rescan: the seed asks what is on disk, and the answer is
            // only true once this account's offline store has been read.
            loadKeepOffline()
            processDownloadQueue()
        } else {
            // Logged out: reset to defaults and wipe all memory lists immediately.
            // The files stay — they belong to whoever downloaded them, and the
            // next sign-in re-derives the lists from disk.
            self.downloadOnWifiOnly     = true
            self.syncMetadataToDisk     = true
            self.keepFileCopyOnDownload = false
            self.downloadQuality        = .normal
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
            // In-memory only. The stored set belongs to the account that made
            // it and is read back on the next sign-in, exactly like the queue.
            keepOfflineIDs.removeAll()
            keptTrackIDs.removeAll()
            manualOfflineIDs.removeAll()
        }
        objectWillChange.send()
    }

    // MARK: - Scanning

    /// Recomputes both axes from the filesystem.
    ///
    /// The offline set is a directory listing, so it's read on the main actor.
    /// The other two stat one file per track, so they go to the background.
    private func rescan(tracks: [Track]) {
        offlineTrackIDs = OfflineStore.shared.trackIDs

        // The restored queue holds track ids and nothing else, so it can't be
        // drained until there's a library to look them up in.
        if !tracks.isEmpty, !hasSeenLibrary {
            hasSeenLibrary = true
            processDownloadQueue()
        }

        Task {
            let scan = await Self.scanFilesystem(tracks: tracks)
            guard !Task.isCancelled else { return }
            self.localTrackIDs    = scan.0
            self.exportedTrackIDs = scan.1
        }
    }

    /// Probe the disk for every track: which are imported, which are exported.
    ///
    /// This is `nonisolated` and `async` on purpose, and the two together are
    /// the whole point. A non-isolated async function runs on the global
    /// executor even when an actor calls it (SE-0338), so the scan genuinely
    /// leaves the main thread.
    ///
    /// It used to be a `Task.detached` closure written inline, which read as
    /// backgrounded and was not. `DownloadManager` is `@MainActor`, so the
    /// closure literal inherited that isolation, and `Task.detached` takes an
    /// `@isolated(any)` closure — it honours the isolation the closure carries
    /// instead of stripping it. The task therefore ran *on the main actor*: one
    /// `UserDefaults` dictionary decode and up to thirty `fileExists` probes per
    /// track, for the whole library, blocking the UI. A sampled main-thread
    /// stack during a 1242 ms hang sat squarely in here.
    ///
    /// Keep the body free of anything main-actor-isolated. Touching such a
    /// member would re-introduce hops and quietly undo this.
    /// Note the shape: a `Task.detached` around a `nonisolated` *synchronous*
    /// body. `nonisolated async` on its own is not enough under Swift 6.2 —
    /// SE-0461 made a `nonisolated async` function run on its **caller's**
    /// actor, so awaiting one from here put it straight back on the main thread.
    nonisolated private static func scanFilesystem(tracks: [Track]) async -> (Set<UUID>, Set<UUID>) {
        await Task.detached(priority: .utility) {
            scanFilesystemSynchronously(tracks: tracks)
        }.value
    }

    nonisolated private static func scanFilesystemSynchronously(tracks: [Track]) -> (Set<UUID>, Set<UUID>) {
        var local    = Set<UUID>()
        var exported = Set<UUID>()
        for track in tracks {
            if hasImportedFile(track) { local.insert(track.id) }
            if ExportManager.shared.exportedURL(for: track) != nil { exported.insert(track.id) }
        }
        return (local, exported)
    }

    /// True when this track came from the user's own disk and the file is still
    /// where the library says it is.
    ///
    /// Deliberately narrower than `SupabaseFileStorageService.localURL`, which
    /// also counts the export folder and the purgeable download cache. Neither
    /// makes a song *local* — an exported copy is a file the user may move or
    /// delete at any time, and a cached copy is one the OS may reclaim.
    nonisolated private static func hasImportedFile(_ track: Track) -> Bool {
        guard !track.isOnline else { return false }
        return AudioPaths.durableURL(forLocalPath: track.file.localPath) != nil
    }

    // MARK: - Download Worker

    private func enqueuePlaylistTracks(_ playlist: Playlist) {
        enqueueBatch(playlist.trackIDs.compactMap { libraryService.track(id: $0) })
    }

    /// Queue a whole list in one pass, skipping everything already on the
    /// device.
    ///
    /// Same admission rules as `enqueueTrackDownload`, but paid for once
    /// instead of per song. The per-track path writes the queue to
    /// UserDefaults and re-drives the scheduler on every id, and its
    /// `downloadQueue.contains` check is a linear scan of the queue it is in
    /// the middle of filling — so switching on a 2,000-song playlist meant
    /// 2,000 disk writes and a quadratic sweep before a single byte was
    /// fetched.
    ///
    /// The skipping is the point of the whole method: a playlist with 10 of
    /// its 12 songs already downloaded enqueues the 2 that are missing and
    /// leaves the 10 alone. Nothing is ever re-fetched to satisfy a button.
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
                // The user asked, and "there is no audio for this anywhere" is
                // the answer — recorded rather than silently dropped.
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

    /// Stop everything in progress for these songs: queued, downloading, or
    /// sleeping between retries.
    ///
    /// Every one of those three had its own way of surviving a stop. Queued ids
    /// sat in `downloadQueue` waiting for a slot; in-flight tasks were untracked
    /// and ran to completion; retry tasks slept through it and re-enqueued
    /// afterwards. Clearing one without the others is what made pressing the
    /// button look like it worked while files kept landing.
    ///
    /// Leaves downloaded copies alone — this is "stop", not "remove".
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

        // Free slots just opened up, and anything left in the queue for a
        // *different* playlist is still wanted.
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

    /// Called once a song leaves the run for good, successfully or not: a
    /// failure that has given up is still one fewer song to wait for, and a bar
    /// that stops short of its own total never disappears.
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

    /// Puts a track in the queue, or says why it didn't go in.
    ///
    /// `force` is for the re-download-at-new-quality pass, which is the one
    /// caller with a legitimate reason to fetch a song that's already offline.
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
                // Worth recording rather than dropping: the user asked, and
                // "this song has no audio anywhere" is the answer.
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

    /// Fills every free slot, rather than starting exactly one download.
    ///
    /// The old version took one item per call, which was fine when the only
    /// caller was "a download just finished" and wrong for every other one:
    /// regaining Wi-Fi, or flipping the Wi-Fi-only switch, restarted a single
    /// song and left the rest of the queue sitting there.
    private func processDownloadQueue() {
        guard hasSeenLibrary, isConnectedForDownload else { return }

        while activeDownloads.count < maxConcurrentDownloads, !downloadQueue.isEmpty {
            let trackID = downloadQueue.removeFirst()
            persistQueue()

            // A restored queue can name songs that have since left the library.
            // Dropping them is right — but keep draining, or one stale id stalls
            // everything behind it.
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

            // Tracked across the whole attempt so a failure part-way through
            // doesn't leave a scratch file behind for every song in a batch.
            var staged: URL?
            func discardStaging() {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                staged = nil
            }

            do {
                let source = try await fetchAudio(for: track,
                                                  ignoringOfflineCopy: requalifying.contains(trackID))
                if source.isTemporary { staged = source.container ?? source.url }

                // The fetch is the slow part, so this is where a stop lands
                // nearly every time. Checked explicitly because the resolver and
                // the URL session are not uniformly cancellation-aware, and a
                // song adopted after the user pressed stop is the exact
                // behaviour this is here to prevent.
                try Task.checkCancellation()

                try await OfflineStore.shared.adopt(source.url,
                                                    for: track.id,
                                                    quality: effectiveDownloadQuality)

                // Adopting isn't interruptible, so a stop during it lands here
                // instead: undo the copy rather than keep a file nobody asked for.
                if Task.isCancelled {
                    OfflineStore.shared.remove(track.id)
                    discardStaging()
                    return
                }

                offlineTrackIDs.insert(track.id)
                requalifying.remove(track.id)
                attempts.removeValue(forKey: track.id)
                clearFailure(track.id)

                // A file copy is a second, separate wish — honoured here only
                // because the user asked for it in Settings.
                //
                // Exported from the source rather than from the offline copy:
                // below High that copy has already been re-encoded, and
                // encoding it again would stack a second lossy pass on top for
                // no gain. From the source, both files are one encode deep.
                if keepFileCopyOnDownload {
                    do {
                        try await ExportManager.shared.export(track: track,
                                                              from: source.url,
                                                              quality: effectiveDownloadQuality)
                        exportedTrackIDs.insert(track.id)
                    } catch {
                        print("[DownloadManager] ⚠️ Downloaded but couldn't write a file copy: \(error)")
                    }
                }

                // Cleaned up last: the export above still needed to read it.
                discardStaging()
                source.supersededCacheEntry?()

                print("[DownloadManager] ✅ Downloaded for offline playback: \(track.title)")
            } catch is CancellationError {
                // Asked to stop, not a failure. Marking it failed would light up
                // the retry button for something the user deliberately called off.
                discardStaging()
            } catch {
                discardStaging()
                guard !Task.isCancelled else { return }
                recordAttemptFailure(for: track, error: error)
            }
        }
    }

    // MARK: - Retry

    /// Books another go, or gives up and says so.
    ///
    /// A resolver that returns nothing because YouTube rate-limited the third
    /// request in a row is the single most common way a batch download loses
    /// songs, and it's also the most likely thing to work ten seconds later.
    private func recordAttemptFailure(for track: Track, error: Error) {
        let attempt = (attempts[track.id] ?? 0) + 1
        attempts[track.id] = attempt

        guard attempt < Self.maxAttempts else {
            print("[DownloadManager] ❌ Gave up on \(track.title) after \(attempt) attempts: \(error)")
            requalifying.remove(track.id)
            markFailed(track.id, message: error.localizedDescription)
            return
        }

        let delay = Self.retryDelay(afterAttempt: attempt)
        print("[DownloadManager] ⚠️ \(track.title) failed (attempt \(attempt)), retrying: \(error)")

        retryTasks[track.id]?.cancel()
        retryTasks[track.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.retryTasks.removeValue(forKey: track.id) != nil else { return }
                // Straight onto the queue: the attempt count is what limits
                // this, and re-running eligibility would refuse a requalifying
                // track for still being downloaded.
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

    /// The queue outlives the launch that built it.
    ///
    /// Downloading a playlist over a slow connection routinely outlasts the
    /// session — quitting used to silently abandon whatever hadn't started,
    /// which reads as "it downloaded some of them".
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
        /// The staging directory to remove along with the file, when there is
        /// one — the resolver may have left a `.part` or an info file beside it.
        var container: URL? = nil
        /// Set when the bytes came from the playback cache, so the cache entry
        /// can be dropped once the offline store has its own copy. Keeping both
        /// is pure waste: `AudioLocator` reads the offline store first, so the
        /// cached file could never be hit again.
        var supersededCacheEntry: (() -> Void)? = nil
    }

    /// Thrown rather than returned so a download that can't find a source
    /// reaches the retry/failure path instead of quietly succeeding at nothing.
    private struct NoAudioSource: LocalizedError {
        let reason: UnavailableReason
        let title: String
        var errorDescription: String? { reason.message(for: title) }
    }

    private func fetchAudio(for track: Track, ignoringOfflineCopy: Bool) async throws -> AudioSource {
        switch AudioLocator.locate(track, ignoringOfflineStore: ignoringOfflineCopy) {

        // Something usable is already on disk — the offline store (when this
        // isn't a requalify), the playback cache, the user's own import, or an
        // exported copy. Reuse it rather than pulling the bytes down twice.
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
            // Supabase — triggers the progress publisher, lands in the cache.
            let url = try await fileStorage.download(track: track, accessToken: "")
            return AudioSource(url: url, isTemporary: false)

        case .unavailable(let reason):
            // Nothing on disk and no remote key, but findable — the same shot
            // playback gives it. See `resolverMightFind`.
            guard Self.resolverMightFind(reason) else {
                throw NoAudioSource(reason: reason, title: track.title)
            }
            return try await resolveAudio(for: track)
        }
    }

    /// Search for this song and pull down what comes back. The resolver is the
    /// only thing that decides which upload is the right one.
    private func resolveAudio(for track: Track) async throws -> AudioSource {
        let query = "\(track.artistName) \(track.title)".trimmingCharacters(in: .whitespaces)

        // Staged in its own directory, then found by listing it. The
        // resolvers name their output after the video they picked and
        // ignore the `name:` they're handed, so the old code's
        // `tempDir/<videoID>.m4a` was a guess at both the id *and* the
        // container — and any download that came back as .opus or .webm
        // "succeeded" onto a path with no file at it. That is the download
        // that silently goes missing from a batch.
        let staging = PlaybackCache.stagingDirectory
            .appendingPathComponent(track.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let res = try await trackResolver.download(
            query: query,
            name: track.id.uuidString,
            to: staging,
            expectedDuration: track.duration,
            preferExplicit: track.isExplicit
        )

        let landed = FileManager.default.fileExists(atPath: res.fileURL.path(percentEncoded: false))
            ? res.fileURL
            : (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?.first

        guard let landed else {
            try? FileManager.default.removeItem(at: staging)
            throw NoAudioSource(reason: .needsInternet, title: track.title)
        }

        // Deliberately *not* adopted into the playback cache on the way
        // past. It's about to go into the offline store, and `AudioLocator`
        // checks that first — so a cached copy would never be read and the
        // song would occupy twice the disk it asked for, on every download.
        return AudioSource(url: landed, isTemporary: true, container: staging)
    }

    private func finishDownload(_ trackID: UUID) {
        downloadTasks.removeValue(forKey: trackID)
        activeDownloads.remove(trackID)
        downloadingTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)
        // Not counted while a retry is still pending — the song hasn't left the
        // run yet, and counting it here would march the bar past songs that are
        // about to be attempted again.
        if retryTasks[trackID] == nil { noteBatchFinished() }
        processDownloadQueue()
        resetBatchIfIdle()
        objectWillChange.send()
    }

    // MARK: - Removal

    /// Removes the offline copy. Leaves any file copy in the export folder
    /// alone: that's a file in the user's own Music folder, and deleting it
    /// behind their back for pressing "remove download" would be a betrayal of
    /// two different intentions. `deleteFileCopy(for:)` does that explicitly.
    public func removeDownload(for trackID: UUID) {
        removeDownloads(for: [trackID])
    }

    /// The same withdrawal for a whole selection, with the two costs that don't
    /// belong per song — writing the stored queue and telling SwiftUI — hoisted
    /// out of the loop. Deleting a large import calls this once per song, and
    /// 2,100 defaults writes and 2,100 `objectWillChange` sends on the main
    /// thread is most of why that froze the app.
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
        // Removing a song mid-run takes it out of the run, not out of the count
        // — otherwise the bar's total outlives the work it was measuring.
        if wasInRun { noteBatchFinished() }
        downloadingTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)
        retryTasks.removeValue(forKey: trackID)?.cancel()
        attempts.removeValue(forKey: trackID)
        requalifying.remove(trackID)
        clearFailure(trackID)

        // "Remove Download" is the user withdrawing the ask, so the claim goes
        // with the file. Here rather than at the call sites, so every path that
        // removes a copy — a row menu, a selection, a song leaving the library —
        // clears it.
        manualOfflineIDs.remove(trackID)

        OfflineStore.shared.remove(trackID)
        offlineTrackIDs.remove(trackID)

        // The purgeable cache too, or the song stays playable offline by
        // accident until the OS gets round to reclaiming it. Routed through
        // PlaybackCache rather than rebuilt from a remote key: an online track
        // has no remote key at all, so the old code left its cached audio in
        // place and "Remove Download" appeared to do nothing.
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

    /// Deletes the exported file copy, and only that — the song stays downloaded
    /// if it was.
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

    /// Cancel every task this manager is running — downloads in progress and
    /// retries waiting to fire.
    ///
    /// One function rather than two because every caller wants both, and the
    /// ones that only cancelled retries (an account switch, a sign-out) left
    /// downloads running into whatever library came next.
    private func cancelInFlightWork() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
    }
}
