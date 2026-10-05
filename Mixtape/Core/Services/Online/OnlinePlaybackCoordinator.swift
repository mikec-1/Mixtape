// Discover click-to-play. Hover prefetches in the background; a click reuses
// that task (or starts one) and plays once the file is on disk.
// Downloading a 128 kbps m4a (3-6 s) beats resolving a stream URL with -g,
// which needs YouTube's nsig decryption (10-20 s) and throttles.
// 1. Cache hit: play now.
// 2. Hover task running: await it, then play.
// 3. Cold click: download, await, play.
// 4. Add to Library promotes a cached file via ImportService.

import Foundation
import Combine
import AVFoundation

@MainActor
public final class OnlinePlaybackCoordinator: ObservableObject {

    /// ID of the OnlineTrack currently being resolved (drives per-row spinners).
    @Published public private(set) var resolvingID: String? = nil
    /// The OnlineTrack playing through the engine, for Discover's now-playing
    /// indicator. Nil when no online track plays.
    @Published public private(set) var nowPlayingID: String? = nil
    /// Non-nil briefly when a play attempt fails. Auto-clears after 4 s.
    @Published public private(set) var errorMessage: String? = nil
    /// Non-error status (e.g. a "wrong version" result). Goes to the app toast.
    public var onStatus: ((String) -> Void)?

    /// The song the user is waiting on and its progress. Drives the loading bar
    /// above the player. Only songs asked for, never prefetches or cache fills.
    @Published public private(set) var preparing: PreparingTrack? = nil

    /// Asked after "Wrong version" lands on a new upload: keep it, try another, or go back.
    @Published public private(set) var versionCheck: VersionCheck? = nil

    public struct VersionCheck: Identifiable {
        public let id = UUID()
        let result: OnlineTrack
        /// The upload before the switch. Nil when nothing was recorded, so there's no going back.
        let previousVideoID: String?
        let replay: () async -> Void

        public var sourceRef: String { result.id }
        public var title: String { result.title }
        public var canGoBack: Bool { previousVideoID != nil }
    }

    /// What the loading bar shows. Carries its own title since the song may not
    /// be in any list on screen.
    public struct PreparingTrack: Equatable {
        public let id: String
        public let title: String
        public let artist: String
        public var progress: ResolveProgress

        /// "Searching", "Downloading", "Converting": printed after the song's name.
        public var phaseLabel: String {
            switch progress.phase {
            case .searching:   return "finding audio"
            case .downloading: return "downloading"
            case .converting:  return "finishing up"
            }
        }
    }

    private let ytdlp:         any TrackResolver
    private let engine:        PlaybackEngine
    private let importService: ImportService
    private let deviceID:      String

    /// Whether there's a network, supplied by AppDependencies. beginSession
    /// refuses to start a resolve that can only time out.
    public var isOnline: () -> Bool = { true }

    /// Bumped on every play(). A slow download checks it before playing so a
    /// newer click wins.
    private var playToken = 0

    /// The song playFromContext is resolving, so a second tap on the same row
    /// doesn't restart it. resolvingID is the published row-spinner state.
    private var resolvingTrackID: String?
    /// Bumped each time playFromContext claims resolvingTrackID, so only the run
    /// that made the claim can release it. Otherwise a cancelled resolve could clear
    /// a retry's claim, or leave its own stale claim blocking the retry.
    private var resolveRun = 0

    /// Running download tasks keyed by OnlineTrack.id. Added by prefetch(),
    /// reused or replaced by play(), removed on completion.
    private var prefetchTasks: [String: Task<ResolvedAudio, Error>] = [:]

    /// Speculative downloads currently running (see `maxConcurrentPrefetches`).
    private var inFlightPrefetches = 0

    /// Songs warmed on the resolver this session. One warm per song is enough.
    private var warmedTrackIDs: Set<String> = []
    /// Warms currently in flight, capped alongside prefetches.
    private var inFlightWarms = 0

    /// OnlineTrack.id -> resolved YouTube videoID. Loaded lazily from index.json.
    private var _videoIDIndex: [String: String]? = nil

    /// The list the current online track was played from. Skip and auto-advance
    /// step through it. Empty when no online context is active.
    private var context: [OnlineTrack] = []
    /// One lane per context slot (see QueueOrigin). The queue panel mirrors this
    /// list during a session, so lanes follow their slots and keep the local queue's
    /// order: manual, context, recommendation. alignedContextLanes() is the backstop.
    private var contextLanes: [QueueOrigin] = []
    /// Index of the currently playing track within `context`.
    private var contextIndex = 0
    /// `context` as Tracks for the Queue panel. Built when the context is set;
    /// the playing slot is swapped for the full track so its artwork shows.
    private var contextDisplayTracks: [Track] = []
    /// Bumped on each mirror rebuild so a slow artwork fetch can't overwrite a newer one.
    private var displayArtworkToken = 0
    /// Artwork the UI handed over for the current play.
    private var contextArtwork: Data?
    /// Which song contextArtwork belongs to, so a session started without artwork
    /// doesn't show the previous session's cover.
    private var contextArtworkID: String?
    /// Track details already fetched this launch, keyed by Deezer track id.
    private var trackDetails: [Int: (contributors: [String], coverURL: URL?)] = [:]
    /// Library tracks standing in for context slots, keyed by OnlineTrack.id.
    /// Mixed lists (Jump back in, history) play owned songs from their own file.
    private var localSubstitutes: [String: Track] = [:]

    public init(
        ytdlp: any TrackResolver,
        engine: PlaybackEngine,
        importService: ImportService,
        deviceID: String
    ) {
        self.ytdlp         = ytdlp
        self.engine        = engine
        self.importService = importService
        self.deviceID      = deviceID
        migrateLegacyCache()
        dropUngatedPicks()

        // Probe whenever the queue changes, not when the preload depth reaches a
        // song, or the warning shows up too late to be useful.
        engine.queue.$queue
            .sink { [weak self] _ in self?.scanQueueAvailability() }
            .store(in: &scanCancellables)
        engine.queue.$currentIndex
            .sink { [weak self] _ in self?.scanQueueAvailability() }
            .store(in: &scanCancellables)
    }

    // MARK: - Availability scan

    private var scanCancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var scanDirty = false

    /// How far down the queue to probe. Same preference as prefetch depth.
    private var scanDepth: Int { PlaybackPrefetchSettings.shared.queueDepth.rawValue }

    /// Checks ahead which queued songs can actually be found.
    /// ponytail: one probe at a time, scanDepth rows deep. Each probe is a resolver
    /// search, so long queues take a while. Batch it if that matters.
    private func scanQueueAvailability() {
        // One runner with a "go again" flag rather than cancel-and-restart. The
        // queue republishes constantly, so restarting never finished a probe.
        guard scanTask == nil else { scanDirty = true; return }
        scanTask = Task { [weak self] in
            defer { self?.scanTask = nil }
            repeat {
                self?.scanDirty = false
                try? await Task.sleep(for: .seconds(1.5))
                await self?.scanQueueAvailabilityBody()
            } while self?.scanDirty == true
        }
    }

    private func scanQueueAvailabilityBody() async {
        // Probing spends the network like prefetching, so it obeys the same setting.
        guard PlaybackPrefetchSettings.shared.queueDepth != .off else { return }

        for online in upcomingProbeTargets() {
            guard !Task.isCancelled else { return }
            guard !UnavailableTracks.shared.isDecided(title: online.title,
                                                      artist: online.artistName) else { continue }
            if cacheURL(for: online) != nil {
                UnavailableTracks.shared.markFound(title: online.title, artist: online.artistName)
                continue
            }
            do {
                let stream = try await ytdlp.resolveStream(query: online.searchQuery,
                                                           expectedDuration: online.duration,
                                                           preferExplicit: online.isExplicit)
                // nil means the resolver can't stream, not that the song is missing.
                // Only a thrown "no result" counts.
                if stream != nil {
                    UnavailableTracks.shared.markFound(title: online.title, artist: online.artistName)
                }
            } catch {
                if isSongNotFound(error) {
                    UnavailableTracks.shared.mark(title: online.title, artist: online.artistName)
                }
            }
        }
    }

    private func end(from start: Int, count: Int) -> Int { min(count, start + scanDepth) }

    /// Upcoming songs without a file of their own, from the playhead on.
    private func upcomingProbeTargets() -> [OnlineTrack] {
        if hasActiveOnlineSession, !context.isEmpty {
            let start = max(contextIndex + 1, 0)
            guard start < context.count else { return [] }
            return context[start..<end(from: start, count: context.count)]
                .filter { localSubstitutes[$0.id] == nil }
        }
        let queue = engine.queue.queue
        let start = max(engine.queue.currentIndex + 1, 0)
        guard start < queue.count else { return [] }
        return queue[start..<end(from: start, count: queue.count)]
            .filter { !engine.canPlayLocally($0) }
            .map(Self.onlineForm)
    }

    // MARK: - Cache paths

    /// Staging dir for downloads in progress. PlaybackCache owns the finished files.
    static var cacheDir: URL { PlaybackCache.stagingDirectory }

    /// The cached file for `result`, or nil. Keyed by the song, not the video,
    /// so losing the videoID index doesn't orphan the cache.
    func cacheURL(for result: OnlineTrack) -> URL? {
        PlaybackCache.fileURL(forSourceRef: result.id)
    }

    // MARK: - VideoID index (persistent)

    /// Which upload each song resolved to. Informational: lets "wrong version"
    /// tell whether the pick changed.
    private var indexFileURL: URL { PlaybackCache.directory.appendingPathComponent("online-index.json") }

    /// The pre-merge location, read once so existing mappings survive the move.
    private var legacyIndexFileURL: URL {
        PlaybackCache.legacyOnlineCacheDirectory.appendingPathComponent("index.json")
    }

    /// In-memory copy of the index. Missing or corrupt file gives an empty index.
    private var videoIDIndex: [String: String] {
        get {
            dropPinsIfPreferenceFlipped()
            if let cached = _videoIDIndex { return cached }
            // Thumbs-up picks outlive a cleared cache and the censored-version flip.
            let loaded = (decodeIndex(at: indexFileURL) ?? decodeIndex(at: legacyIndexFileURL) ?? [:])
                .merging(confirmedVideoIDs) { _, confirmed in confirmed }
            _videoIDIndex = loaded
            return loaded
        }
        set {
            _videoIDIndex = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: indexFileURL, options: .atomic)
            }
        }
    }

    /// Uploads the user rejected, per track. Persisted so they survive a restart.
    private var rejectedFileURL: URL {
        PlaybackCache.directory.appendingPathComponent("online-rejected.json")
    }

    private var _rejectedVideoIDs: [String: [String]]? = nil

    private var rejectedVideoIDs: [String: [String]] {
        get {
            if let cached = _rejectedVideoIDs { return cached }
            let loaded = (try? Data(contentsOf: rejectedFileURL))
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            _rejectedVideoIDs = loaded
            return loaded
        }
        set {
            _rejectedVideoIDs = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: rejectedFileURL, options: .atomic)
            }
        }
    }

    /// What a resolve for this track must not return.
    func exclusions(for trackID: String) -> Set<String> {
        Set(rejectedVideoIDs[trackID] ?? [])
    }

    private func reject(_ videoID: String, for trackID: String) {
        var all = rejectedVideoIDs
        var list = all[trackID] ?? []
        guard !list.contains(videoID) else { return }
        list.append(videoID)
        all[trackID] = list
        rejectedVideoIDs = all
        // A recap clip cut from the rejected upload would otherwise play for months.
        RecapClipStore.url(for: OnlineTrack.stableID(for: trackID)).map { try? FileManager.default.removeItem(at: $0) }
    }

    /// Uploads the user gave a thumbs up, per track. Only another "Wrong version" clears one.
    private var confirmedFileURL: URL {
        PlaybackCache.directory.appendingPathComponent("online-confirmed.json")
    }

    private var _confirmedVideoIDs: [String: String]? = nil

    private var confirmedVideoIDs: [String: String] {
        get {
            if let cached = _confirmedVideoIDs { return cached }
            let loaded = decodeIndex(at: confirmedFileURL) ?? [:]
            _confirmedVideoIDs = loaded
            return loaded
        }
        set {
            _confirmedVideoIDs = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: confirmedFileURL, options: .atomic)
            }
        }
    }

    /// Resets a track once every upload has been rejected, so it stays playable.
    private func clearRejections(for trackID: String) {
        var all = rejectedVideoIDs
        guard all.removeValue(forKey: trackID) != nil else { return }
        rejectedVideoIDs = all
    }

    /// Drops pinned uploads when the censored-version preference flips. Pins skip
    /// the search, so without this the setting would only affect unplayed songs.
    private func dropPinsIfPreferenceFlipped() {
        let key = "mixtape.resolver.pinsPreferCensored"
        let want = ResolverPreferences.preferCensored
        guard UserDefaults.standard.bool(forKey: key) != want else { return }
        UserDefaults.standard.set(want, forKey: key)
        try? FileManager.default.removeItem(at: indexFileURL)
        _videoIDIndex = confirmedVideoIDs
    }

    private func decodeIndex(at url: URL) -> [String: String]? {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    /// The upload this device picked for a song, keyed by sourceRef. Public so
    /// continuity can hand it to the device taking over.
    public func knownVideoID(forSourceRef ref: String) -> String? {
        let id = videoIDIndex[ref]
        return id.flatMap { exclusions(for: ref).contains($0) ? nil : $0 }
    }

    /// Adopt another device's pick, unless this device has already rejected it.
    public func adoptVideoID(_ videoID: String, forSourceRef ref: String) {
        guard videoIDIndex[ref] == nil, !exclusions(for: ref).contains(videoID) else { return }
        recordVideoID(videoID, for: ref)
    }

    /// Record the resolved videoID for `trackID` and persist the index.
    func recordVideoID(_ videoID: String, for trackID: String) {
        var idx = videoIDIndex
        idx[trackID] = videoID
        videoIDIndex = idx
    }

    /// Picks from before the resolver checked titles were made on runtime alone, so
    /// some are another song by the same artist. A pinned pick skips the search, so
    /// they never heal. Forgets every one the user didn't confirm, once.
    private func dropUngatedPicks() {
        let key = "online.ungatedPicksDropped"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let confirmed = confirmedVideoIDs
        for ref in videoIDIndex.keys where confirmed[ref] == nil {
            PlaybackCache.remove(forSourceRef: ref)
        }
        videoIDIndex = confirmed
        // Cut from those files.
        RecapClipStore.removeAll()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Adopts the old Discover cache once at launch, then forgets it.
    private func migrateLegacyCache() {
        let index = videoIDIndex                    // reads the legacy file if that's all there is
        PlaybackCache.migrateLegacyOnlineCache(index: index)
        PlaybackCache.sweepStaging()
        if !index.isEmpty { videoIDIndex = index }   // re-persist at the new location

        // Nothing is pinned yet, so apply the budget now. Otherwise an over-budget
        // cache stays that way until the next download.
        PlaybackCache.pinnedURLs = []
        PlaybackCache.enforceBudget()
    }

    /// Deletes every cached song and the videoID index. Cancels downloads first.
    /// Returns the number of files removed.
    @discardableResult
    public func clearCache() -> Int {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()

        let removed = PlaybackCache.clear()

        // Drop the persisted index so stale id -> videoID mappings don't resurrect.
        try? FileManager.default.removeItem(at: indexFileURL)
        _videoIDIndex = confirmedVideoIDs
        try? FileManager.default.removeItem(at: rejectedFileURL)
        _rejectedVideoIDs = [:]
        return removed
    }

    /// Forgets one track's cached source so the next play re-resolves it.
    /// Returns true if a file was removed.
    @discardableResult
    public func clearCache(for result: OnlineTrack) -> Bool {
        prefetchTasks[result.id]?.cancel()
        prefetchTasks.removeValue(forKey: result.id)

        let removed = PlaybackCache.remove(forSourceRef: result.id)

        if videoIDIndex[result.id] != nil {
            var idx = videoIDIndex
            idx.removeValue(forKey: result.id)
            videoIDIndex = idx
        }
        // Only re-resolve lands here, and pressing it again takes the thumbs up back.
        if confirmedVideoIDs[result.id] != nil {
            confirmedVideoIDs.removeValue(forKey: result.id)
        }
        return removed
    }

    /// "Wrong version": forget the cached source and play again so the resolver
    /// re-picks. Toasts whether it found a different upload.
    public func reResolveAndPlay(_ result: OnlineTrack, context: [OnlineTrack] = []) async {
        await reResolve(result) { await self.playRespectingRejections(result, context: context) }
    }

    /// Only songs the resolver found have a source to swap.
    public func canReResolve(_ track: Track) -> Bool { track.sourceRef != nil }

    /// "Wrong version" from the queue or player. The playing song is refetched in
    /// place; a later one forgets its source and re-picks when reached. Callers drop
    /// any downloaded copy first (see AppDependencies.reResolve).
    public func reResolve(_ track: Track, at index: Int? = nil) async {
        guard canReResolve(track) else { return }
        if hasActiveOnlineSession,
           let slot = [index, playingSlot].compactMap({ $0 }).first(where: {
               contextDisplayTracks.indices.contains($0) && contextDisplayTracks[$0].id == track.id
           }),
           context.indices.contains(slot) {
            // A library song in this slot is the rejected version, so resolve it online now.
            localSubstitutes[context[slot].id] = nil
            let result = context[slot]
            guard slot == playingSlot else { return forgetSource(result) }
            await reResolve(result) { await self.playFromContext(at: slot, skippingUnfindable: false) }
            return
        }

        // From the engine's own queue: fetch into the cache and reload. A session
        // would reset the queue to its context and lose the rest of the user's queue.
        let result = Self.onlineForm(track)
        guard engine.queue.currentTrack?.id == track.id,
              index == nil || index == engine.queue.currentIndex else { return forgetSource(result) }
        // ponytail: a copy downloaded before its pick was recorded has nothing to
        // reject, so the first press can land on the same upload; the second moves on.
        await reResolve(result) {
            self.beginPreparing(result)
            defer { self.endPreparing(result.id) }
            // Nil after a rejection; set when "Go back" restored the old pick.
            let task = self.makeDownloadTask(for: result,
                                             pinnedVideoID: self.knownVideoID(forSourceRef: result.id))
            self.prefetchTasks[result.id] = task
            let fetched = (try? await task.value) != nil
            if self.prefetchTasks[result.id] == task { self.prefetchTasks[result.id] = nil }
            guard fetched else { return }
            await self.engine.reloadCurrent()
        }
    }

    /// A song further down the queue: reject its upload now, re-pick on reach.
    private func forgetSource(_ result: OnlineTrack) {
        if let previous = videoIDIndex[result.id] { reject(previous, for: result.id) }
        clearCache(for: result)
        flashStatus("“\(result.title)” will use a different version when it comes up.")
    }

    private func reResolve(_ result: OnlineTrack, replay: @escaping () async -> Void) async {
        versionCheck = nil
        let previousVideoID = videoIDIndex[result.id]

        // Record the rejection before searching. The search is deterministic, so
        // without the list repeated presses would return the same upload.
        if let previousVideoID { reject(previousVideoID, for: result.id) }
        clearCache(for: result)

        let refused = exclusions(for: result.id)
        flashStatus(refused.count > 1
                    ? "Looking for another version of “\(result.title)” (\(refused.count) ruled out)…"
                    : "Finding a different source for “\(result.title)”…")

        await replay()

        // Compare against the cleared id to tell the user whether anything changed.
        var newVideoID = videoIDIndex[result.id]

        // Nothing found while refusing uploads: forget the refusals and try once more
        // so the song doesn't become unplayable.
        if newVideoID == nil, !refused.isEmpty {
            clearRejections(for: result.id)
            clearCache(for: result)
            await replay()
            newVideoID = videoIDIndex[result.id]
            if newVideoID != nil {
                flashStatus("That's every version we could find for “\(result.title)” — back to the first.")
                return
            }
        }

        if let newVideoID, newVideoID != previousVideoID {
            // The card says it, so no toast on top.
            versionCheck = VersionCheck(result: result, previousVideoID: previousVideoID, replay: replay)
        } else if newVideoID != nil {
            flashStatus("That's the only version we could find for “\(result.title)”.")
        }
        // newVideoID == nil -> the play attempt failed; setError already surfaced it.
    }

    /// Thumbs up: this upload is the song. Survives a cleared cache until the next "Wrong version".
    public func confirmVersion() {
        guard let check = versionCheck else { return }
        versionCheck = nil
        guard let videoID = videoIDIndex[check.sourceRef] else { return }
        confirmedVideoIDs[check.sourceRef] = videoID
        flashStatus("Keeping this version of “\(check.title)”.")
    }

    /// Thumbs down: same as pressing "Wrong version" again.
    public func tryAnotherVersion() async {
        guard let check = versionCheck else { return }
        await reResolve(check.result, replay: check.replay)
    }

    /// The old upload was better after all. Rules out the new one and keeps the old.
    public func restorePreviousVersion() async {
        guard let check = versionCheck, let previous = check.previousVideoID else { return }
        versionCheck = nil
        let ref = check.sourceRef
        if let current = videoIDIndex[ref] { reject(current, for: ref) }
        var all = rejectedVideoIDs
        all[ref]?.removeAll { $0 == previous }
        rejectedVideoIDs = all
        PlaybackCache.remove(forSourceRef: ref)
        recordVideoID(previous, for: ref)
        confirmedVideoIDs[ref] = previous
        await check.replay()
        flashStatus("Back to the earlier version of “\(check.title)”.")
    }

    public func dismissVersionCheck() { versionCheck = nil }

    private func playRespectingRejections(_ result: OnlineTrack, context: [OnlineTrack]) async {
        if context.isEmpty {
            await play(result)
        } else {
            await play(result, context: context)
        }
    }

    // MARK: - Prefetch (hover)

    /// Starts downloading `result` so play() is instant. No-op if cached or
    /// already downloading.
    public func prefetch(_ result: OnlineTrack) {
        // Browsing prefetch obeys the browsing setting. Queued songs use preload.
        guard PlaybackPrefetchSettings.shared.prefetchWhileBrowsing else { return }
        preload(result)
    }

    /// Prefetch regardless of the browsing setting, for queued songs.
    private func preload(_ result: OnlineTrack) {
        guard cacheURL(for: result) == nil else { return }   // already cached
        guard prefetchTasks[result.id] == nil else { return }
        // Speculative work is capped so it doesn't starve the song the user tapped.
        guard speculativeInFlight < maxConcurrentPrefetches else { return }

        inFlightPrefetches += 1
        // Pinned when the upload is already known, which skips the search.
        let task = makeDownloadTask(for: result,
                                    priority: .background,
                                    pinnedVideoID: knownVideoID(forSourceRef: result.id))
        prefetchTasks[result.id] = task
        // Release the slot however it ends. A successful prefetch stays for play()
        // to reuse; a failed one is evicted, or the next press would rethrow its stale
        // error instantly.
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                self?.prefetchTasks.removeValue(forKey: result.id)
                // Silent: nobody's waiting on it. The queue row shows the warning.
                if isSongNotFound(error) {
                    UnavailableTracks.shared.mark(title: result.title,
                                                  artist: result.artistName)
                }
            }
            self?.inFlightPrefetches -= 1
            // A slot freed up, so take the next queued song. preload doesn't remember
            // refusals, so without this the depth setting collapses to the slot count.
            self?.topUpQueuePrefetch()
        }
    }

    /// Prefetches as deep into the queue as the setting and budget allow. Cheap
    /// and idempotent; safe to call whenever a slot frees.
    private func topUpQueuePrefetch() {
        mixMainActivity("online/top-up-prefetch") { topUpQueuePrefetchBody() }
    }

    private func topUpQueuePrefetchBody() {
        let depth = PlaybackPrefetchSettings.shared.queueDepth.rawValue
        guard depth > 0, contextIndex >= 0 else { return }
        for offset in 1...depth {
            let ahead = contextIndex + offset
            guard context.indices.contains(ahead) else { break }
            let next = context[ahead]
            if localSubstitutes[next.id] == nil { preload(next) }
        }
    }

    /// Max concurrent speculative downloads. A preference on macOS. On iOS the
    /// hosted resolver serves two at a time, so one slot is kept free for taps.
    private var maxConcurrentPrefetches: Int {
        let preference = max(PlaybackPrefetchSettings.shared.concurrentPrefetches, 1)
        #if os(iOS)
        return min(preference, 1)
        #else
        return preference
        #endif
    }

    /// Prefetches and warms share one budget since both use the resolver.
    private var speculativeInFlight: Int { inFlightPrefetches + inFlightWarms }

    /// Cancels speculative work for other songs to free a resolver slot. iOS only;
    /// the Mac resolves locally.
    private func standDownSpeculativeWork(except keepID: String) {
        #if os(iOS)
        for (id, task) in prefetchTasks where id != keepID {
            task.cancel()
            prefetchTasks.removeValue(forKey: id)
        }
        #endif
    }

    /// Warms `result` on the resolver without downloading it here. iOS's /resolve
    /// searches and downloads the whole track before answering, so asking early
    /// leaves the file in the server's cache and the real tap only pays for the
    /// search. One HTTP request, unlike prefetch, which spends cellular data.
    public func warm(_ result: OnlineTrack) {
        guard PlaybackPrefetchSettings.shared.prefetchWhileBrowsing else { return }
        guard cacheURL(for: result) == nil else { return }   // already on disk
        guard prefetchTasks[result.id] == nil else { return } // a real prefetch owns it
        guard warmedTrackIDs.insert(result.id).inserted else { return }
        guard speculativeInFlight < maxConcurrentPrefetches else {
            warmedTrackIDs.remove(result.id)
            return
        }

        inFlightWarms += 1
        let ytdlp = self.ytdlp
        let query = result.searchQuery
        let dur   = result.duration
        let exp   = result.isExplicit
        let trackID = result.id
        let refused = exclusions(for: trackID)
        let pinned  = knownVideoID(forSourceRef: trackID)
        Task(priority: .background) { [weak self] in
            let stream = try? await ytdlp.resolveStream(query: query,
                                                        expectedDuration: dur,
                                                        preferExplicit: exp,
                                                        excluding: refused,
                                                        pinnedVideoID: pinned)
            await MainActor.run {
                guard let self else { return }
                self.inFlightWarms -= 1
                if let stream {
                    self.recordVideoID(stream.videoID, for: trackID)
                } else {
                    // A failed warm shouldn't block a later attempt.
                    self.warmedTrackIDs.remove(trackID)
                }
            }
        }
    }

    /// Warms library rows that can only play by resolving online, such as a
    /// joined shared playlist. Only the first few, so a long playlist doesn't fill
    /// the cache with songs nobody played.
    public func prefetchResolvable(_ tracks: [Track], limit: Int? = nil) {
        guard PlaybackPrefetchSettings.shared.prefetchWhileBrowsing else { return }
        // Capped by the queue depth setting too. Off means off.
        let limit = limit ?? max(PlaybackPrefetchSettings.shared.queueDepth.rawValue, 1)
        var started = 0
        for track in tracks where started < limit {
            // canPlayLocally covers a file on disk and a remoteKey; neither needs the resolver.
            guard !engine.canPlayLocally(track), !track.title.isEmpty else { continue }
            prefetch(Self.onlineForm(track))
            started += 1
        }
    }

    /// Builds a download task. The resolver writes to staging, the file moves
    /// into the playback cache under the song's key, the videoID is recorded and
    /// the budget checked. The task returns the adopted URL.
    /// `pinnedVideoID` skips the search when the video is already known.
    private func makeDownloadTask(for result: OnlineTrack,
                                  priority: TaskPriority = .userInitiated,
                                  pinnedVideoID: String? = nil) -> Task<ResolvedAudio, Error> {
        let ytdlp = self.ytdlp
        let query = result.searchQuery
        let stem  = result.cacheStem
        let dir   = PlaybackCache.stagingDirectory
        let dur   = result.duration
        let exp   = result.isExplicit
        let trackID = result.id
        let refused = exclusions(for: trackID)
        return Task(priority: priority) { [weak self] in
            // Every download reports progress, prefetches included, since a clicked
            // prefetch is the common cold play. updatePreparing ignores other songs.
            let report: @Sendable (ResolveProgress) -> Void = { [weak self] step in
                // The resolver reports from any thread; the bar reads on the main actor.
                Task { @MainActor [weak self] in self?.updatePreparing(trackID, step) }
            }
            let res: ResolvedAudio
            if let pinnedVideoID {
                res = try await ytdlp.download(videoID: pinnedVideoID, fallbackQuery: query,
                                               name: stem, to: dir, onProgress: report)
            } else {
                res = try await ytdlp.download(query: query, name: stem, to: dir,
                                               expectedDuration: dur, preferExplicit: exp,
                                               excluding: refused,
                                               onProgress: report)
            }
            // This Task inherits the main actor, so the file move and queue walk are
            // main-thread work.
            let adopted = mixMainActivity("online/download-finished ▸ adopt") {
                (try? PlaybackCache.adopt(res.fileURL, forSourceRef: trackID)) ?? res.fileURL
            }
            mixMainActivity("online/download-finished ▸ budget") {
                self?.recordVideoID(res.videoID, for: trackID)
                self?.enforceCacheBudget()
            }
            return ResolvedAudio(fileURL: adopted, videoID: res.videoID)
        }
    }

    // MARK: - Play

    /// Plays `result` on its own, with no skip context.
    public func play(_ result: OnlineTrack, artworkData: Data? = nil) async {
        await play(result, context: [result], artworkData: artworkData)
    }

    /// Plays `result` within `context` (search results, album, popular list).
    /// Skip and auto-advance step through `context`, downloading on demand.
    public func play(_ result: OnlineTrack, context: [OnlineTrack], artworkData: Data? = nil) async {
        await beginSession(result, context: context, artworkData: artworkData, localSubstitutes: [:])
    }

    /// Shared body of play(_:context:artworkData:). `localSubstitutes` maps
    /// OnlineTrack.id to a library track to play from its own file.
    private func beginSession(
        _ result: OnlineTrack,
        context: [OnlineTrack],
        artworkData: Data?,
        localSubstitutes: [String: Track]
    ) async {
        // Offline with nothing on disk: fail now instead of waiting on a dead
        // network. Cached files and library substitutes still play.
        if !isOnline(), localSubstitutes[result.id] == nil, cacheURL(for: result) == nil {
            setError("“\(result.title)” isn't downloaded — you're offline.")
            return
        }
        // Mirroring another device: send the song there. Checked here because the
        // engine only sees an online song after it's fetched.
        if engine.remoteTransport != nil,
           engine.remotePlayRedirect?(result.asTrack(deviceID: deviceID),
                                      context.map { $0.asTrack(deviceID: deviceID) }) == true {
            return
        }
        // Manually queued songs carry over to the next session. Captured before
        // localSubstitutes is replaced so file-backed rows keep their substitutes.
        let carriedManual = carryableManualSlots()
        let carriedSubs   = carriedManual.reduce(into: [String: Track]()) { subs, slot in
            subs[slot.online.id] = self.localSubstitutes[slot.online.id]
        }
        self.localSubstitutes = localSubstitutes.merging(carriedSubs.compactMapValues { $0 }) { _, new in new }
        // Fall back to a one-item context.
        let ctx = context.isEmpty ? [result] : context
        // If `result` isn't in ctx, prepend it so the requested track plays.
        if let idx = ctx.firstIndex(of: result) {
            self.context      = ctx
            self.contextIndex = idx
        } else {
            self.context      = [result] + ctx
            self.contextIndex = 0
        }
        // All context, plus carried songs spliced in after the playing one.
        self.contextLanes = Array(repeating: .context, count: self.context.count)
        if !carriedManual.isEmpty {
            let at = min(self.contextIndex + 1, self.context.count)
            self.context.insert(contentsOf: carriedManual.map(\.online), at: at)
            self.contextLanes.insert(contentsOf: carriedManual.map { _ in QueueOrigin.manual }, at: at)
        }
        self.contextArtwork = artworkData
        self.contextArtworkID = artworkData == nil ? nil : result.id
        // The old slot index belongs to the previous session.
        self.playingSlot = -1
        self.awaitingHandoff = true
        // Build the display mirror so the Queue panel shows the whole session.
        // Library-backed slots show their own track and artwork.
        let carriedDisplay = Dictionary(carriedManual.compactMap { slot in
            slot.display.map { (slot.online.id, $0) }
        }, uniquingKeysWith: { _, new in new })
        self.contextDisplayTracks = self.context.map {
            carriedDisplay[$0.id] ?? self.localSubstitutes[$0.id] ?? $0.asTrack(deviceID: deviceID)
        }
        loadDisplayArtwork()
        await playFromContext(at: contextIndex, artworkData: artworkData,
                              skippingUnfindable: false)
    }

    /// Manual rows still ahead of playback, carried into the next session.
    private func carryableManualSlots() -> [(online: OnlineTrack, display: Track?)] {
        carryableManualSlotIndices().map { i in
            (context[i], contextDisplayTracks.indices.contains(i) ? contextDisplayTracks[i] : nil)
        }
    }

    /// Extends the session with suggestions so playback keeps going. They join
    /// `context` and the mirror. No-op without an online session.
    /// Called by QueueSuggestionService.
    public func appendOnlineSuggestions(_ tracks: [OnlineTrack]) {
        guard !context.isEmpty else { return }
        // Deduped, unlike a queue action: a repeat suggestion is just noise.
        let existing = Set(context.map { $0.id })
        insertIntoContext(contentsOf: tracks.filter { !existing.contains($0.id) },
                          lane: .recommendation)
    }

    /// Context plays in flight. Keeps hasActiveOnlineSession true in the gap
    /// between the engine dropping its handlers and this reinstalling them.
    private var startingCount = 0

    /// The slot actually playing, or -1. Not contextIndex, which moves on click
    /// while the previous song still plays. Set at each handoff.
    private var playingSlot: Int = -1

    /// Set while a new session is built but its first song hasn't started.
    /// Mirror pushes in that window would carry the new list with an index into the
    /// old one, showing an unrelated song on the player bar. So the push waits.
    /// Needs no reset on failure: it only holds while something is playing.
    private var awaitingHandoff = false

    /// Pushes the display mirror to the player's queue. The list always goes out
    /// so added songs show at once. The index names the slot actually playing, so
    /// the bar doesn't show a resolving song over the previous one's audio. -1
    /// lists every row as upcoming.
    private func publishDisplayQueue() {
        // Only while this coordinator owns playback. A late push (e.g. artwork
        // arriving) would otherwise overwrite the live queue after a local play.
        guard hasActiveOnlineSession else { return }
        // Don't repaint the bar before the new session's song starts.
        guard !awaitingHandoff || engine.queue.currentTrack == nil else { return }
        let slot = context.indices.contains(playingSlot) ? playingSlot : -1
        mixMainActivity("queue/publish-online") {
            engine.queue.setOnlineDisplayQueue(contextDisplayTracks,
                                               currentIndex: slot,
                                               lanes: alignedContextLanes(),
                                               source: .named("Discover"))
        }
    }

    /// contextLanes, repaired if it drifted out of step with `context`.
    private func alignedContextLanes() -> [QueueOrigin] {
        guard contextLanes.count != context.count else { return contextLanes }
        var lanes = Array(contextLanes.prefix(context.count))
        while lanes.count < context.count { lanes.append(.context) }
        return lanes
    }

    /// Newly queued songs go after the playing slot, or the resolving one.
    private var queueAnchor: Int { max(playingSlot, contextIndex) }

    /// Where a new row of `lane` goes: manual first, then context, then top-ups.
    /// Matches the local queue.
    private func contextInsertionIndex(for lane: QueueOrigin) -> Int {
        let lanes = alignedContextLanes()
        var i = min(max(queueAnchor + 1, 0), context.count)
        while i < context.count, lanes[i] <= lane { i += 1 }
        return i
    }

    /// True while an online session is driving playback. Decides whether queue
    /// actions go into the context or the local queue. `context` is never emptied,
    /// so it can't answer this; the engine's handlers can, since any local play()
    /// drops them. startingCount covers the gap while they're being reinstalled.
    public var hasActiveOnlineSession: Bool {
        !context.isEmpty && (engine.hasOnlineContext || startingCount > 0)
    }

    /// The online track in the player, for Add to Library / queue actions outside Discover.
    /// Nil once a local play takes over: the finished session's context lingers.
    public var currentOnlineTrack: OnlineTrack? {
        guard hasActiveOnlineSession, let id = nowPlayingID else { return nil }
        return context.first { $0.id == id }
    }

    /// Plays a Queue panel row during an online session, through the normal
    /// resolve path. False when there's no session or the row isn't in it, so the
    /// caller can fall back to local playback.
    @discardableResult
    public func playQueueTrack(at index: Int, track: Track) async -> Bool {
        // A finished session's context lingers; don't revive it.
        guard hasActiveOnlineSession else { return false }
        // The queue mirrors contextDisplayTracks, so the row's position is the
        // context position (the same song can appear twice). The id check guards a
        // drifted mirror.
        if contextDisplayTracks.indices.contains(index),
           contextDisplayTracks[index].id == track.id {
            await playFromContext(at: index, skippingUnfindable: false)
            return true
        }
        guard let found = contextDisplayTracks.firstIndex(where: { $0.id == track.id })
        else { return false }
        await playFromContext(at: found, skippingUnfindable: false)
        return true
    }

    // MARK: - Standalone replay (history / recently-played / home)

    /// True when this Track can only play by resolving online. Needs no local
    /// bytes too: a downloaded Discover song is still `.online` but plays from disk.
    public func isStandaloneOnline(_ track: Track) -> Bool {
        track.isOnline && !engine.canPlayLocally(track)
    }

    /// Plays an online track outside the active context (history, Home) by
    /// rebuilding its OnlineTrack, so it resolves instead of hitting the file path.
    public func playStandaloneOnline(_ track: Track, context: [Track]) async {
        // Rebuild OnlineTracks so next/prev work. Artwork comes from the loaded data.
        let onlineCtx: [OnlineTrack] = mixMainActivity("online/context-form") {
            context.map(Self.onlineForm)
        }
        let target = Self.onlineForm(track)
        // Mixed contexts (Jump back in) contain songs the user owns. Only the tapped
        // song is checked here; canPlayLocally does filesystem probes, so checking a
        // 2000-song context up front delayed playback. The rest is filled in behind.
        var substitutes: [String: Track] = [:]
        substitutes[target.id] = engine.canPlayLocally(track) ? track : nil
        // Safe to start first: it suspends immediately and beginSession assigns
        // localSubstitutes synchronously, so this merges into it.
        fillLocalSubstitutes(for: onlineCtx, originals: context)
        await beginSession(target, context: onlineCtx,
                           artworkData: track.artworkData,
                           localSubstitutes: substitutes)
    }

    /// Finds which remaining slots the user owns, off the press path. Stays on
    /// the main actor (AudioLocator does) but yields every hundred tracks. Merges
    /// rather than assigns, then republishes the mirror once.
    private func fillLocalSubstitutes(for onlineCtx: [OnlineTrack], originals: [Track]) {
        substitutesToken &+= 1
        let token = substitutesToken
        Task { @MainActor [weak self] in
            var found: [String: Track] = [:]
            for (i, pair) in zip(onlineCtx, originals).enumerated() {
                if i % 100 == 0 {
                    await Task.yield()
                    guard let self, token == self.substitutesToken else { return }
                }
                if self?.engine.canPlayLocally(pair.1) == true { found[pair.0.id] = pair.1 }
            }
            guard let self, token == self.substitutesToken, !found.isEmpty else { return }
            for (id, track) in found where self.localSubstitutes[id] == nil {
                self.localSubstitutes[id] = track
            }
            for (i, online) in self.context.enumerated()
            where self.contextDisplayTracks.indices.contains(i) {
                if let local = self.localSubstitutes[online.id] {
                    self.contextDisplayTracks[i] = local
                }
            }
            self.publishDisplayQueue()
        }
    }

    /// Supersedes an in-flight substitutes pass when a new session starts.
    private var substitutesToken: UInt64 = 0

    /// Something AVPlayer can open for a library song without touching the queue: the
    /// playback cache, else a stream. Nil when neither works.
    public func clipSource(for track: Track) async -> StreamResolution? {
        let online = Self.onlineForm(track)
        if let url = cacheURL(for: online) { return StreamResolution(url: url, videoID: "") }
        guard let stream = try? await ytdlp.resolveStream(query: online.searchQuery,
                                                          expectedDuration: online.duration,
                                                          preferExplicit: online.isExplicit,
                                                          excluding: exclusions(for: online.id),
                                                          pinnedVideoID: knownVideoID(forSourceRef: online.id))
        else { return nil }
        recordVideoID(stream.videoID, for: online.id)
        return stream
    }

    /// The song downloaded into the playback cache, for when a stream won't open.
    /// Shares an in-flight download with the queue's prefetch.
    public func clipFile(for track: Track) async -> StreamResolution? {
        guard let file = try? await resolveCachedFile(for: Self.onlineForm(track)) else { return nil }
        return StreamResolution(url: file.url, videoID: file.videoID)
    }

    /// A library Track as an OnlineTrack, for resolving.
    static func onlineForm(_ track: Track) -> OnlineTrack {
        // identityTitle, so the id, cacheStem and query match what the song was
        // saved under. track.title would split feature-credited songs in two.
        OnlineTrack(
            title: track.identityTitle,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration,
            // Carried so library plays resolve with the right explicit flag.
            isExplicit: track.isExplicit
        )
    }

    /// Fetches covers for the queue mirror in the background, then re-pushes once.
    private func loadDisplayArtwork() {
        displayArtworkToken &+= 1
        let token = displayArtworkToken
        let needed: [(index: Int, url: URL)] = context.indices.compactMap { i in
            guard contextDisplayTracks.indices.contains(i),
                  contextDisplayTracks[i].artworkData == nil,
                  // Never overwrite a slot showing the user's own library track.
                  localSubstitutes[context[i].id] == nil,
                  let url = context[i].artworkURL else { return nil }
            return (i, url)
        }
        guard !needed.isEmpty else { return }
        Task { [weak self] in
            var fetched: [Int: Data] = [:]
            await withTaskGroup(of: (Int, Data?).self) { group in
                for item in needed {
                    group.addTask {
                        let data = (try? await URLSession.shared.data(from: item.url))?.0
                        return (item.index, data)
                    }
                }
                for await (i, data) in group where data != nil { fetched[i] = data }
            }
            await MainActor.run {
                guard let self, token == self.displayArtworkToken, !fetched.isEmpty else { return }
                for (i, data) in fetched where self.contextDisplayTracks.indices.contains(i) {
                    self.contextDisplayTracks[i] = self.context[i].asTrack(artworkData: data, deviceID: self.deviceID)
                }
                // Covers often land while the clicked song resolves; the guard handles that.
                self.publishDisplayQueue()
            }
        }
    }

    /// Steps forward, downloading on demand. Installed as onlineNextHandler, so
    /// it handles the next button, media keys and auto-advance.
    public func playNextInContext() async {
        // Repeat applies to online sessions too.
        if engine.queue.repeatMode == .one, context.indices.contains(contextIndex) {
            await playFromContext(at: contextIndex)
            return
        }
        // The repeat group can end before the context does (rows dragged below the
        // boundary). Mirror positions are context positions.
        let lastLooping = engine.queue.repeatBoundaryIndex ?? context.count - 1
        if engine.queue.repeatMode == .all, !context.isEmpty, contextIndex >= lastLooping {
            await playFromContext(at: 0)
            return
        }
        guard contextIndex + 1 < context.count else {
            // End of context: hand back to the engine and stop.
            engine.clearOnlineContext()
            engine.stopPlayback()
            nowPlayingID = nil
            playingSlot  = -1
            return
        }
        await playFromContext(at: contextIndex + 1)
    }

    /// Moves past an unfindable song without stopping what's playing. With
    /// nowhere to go, the session lets go and leaves the audio alone.
    private func skipUnfindable(from index: Int) async {
        guard index + 1 < context.count else {
            engine.clearOnlineContext()
            nowPlayingID = nil
            playingSlot  = -1
            return
        }
        await playFromContext(at: index + 1)
    }

    /// The song with guests and cover filled in from Deezer when the listing had
    /// neither (type-ahead rows). The id is title|artist, so it's still the same song.
    private func enriched(_ result: OnlineTrack) async -> OnlineTrack {
        guard let id = result.sourceID,
              result.contributors.isEmpty || result.artworkURL == nil else { return result }
        let detail: (contributors: [String], coverURL: URL?)
        if let cached = trackDetails[id] {
            detail = cached
        } else {
            detail = await ITunesSearchClient.trackDetail(trackID: id)
            trackDetails[id] = detail
        }
        guard !detail.contributors.isEmpty || detail.coverURL != nil else { return result }
        return OnlineTrack(
            title: result.title, artistName: result.artistName, albumTitle: result.albumTitle,
            duration: result.duration,
            artworkURL: result.artworkURL ?? detail.coverURL,
            sourceID: id, isExplicit: result.isExplicit,
            contributors: result.contributors.isEmpty ? detail.contributors : result.contributors
        )
    }

    /// Step backward through the current online context.
    /// Steps over songs already known to be missing, or back would land on one and
    /// skip forward again.
    public func playPreviousInContext() async {
        var target = contextIndex - 1
        while context.indices.contains(target), localSubstitutes[context[target].id] == nil,
              UnavailableTracks.shared.contains(title: context[target].title,
                                                artist: context[target].artistName) {
            target -= 1
        }
        guard target >= 0 else { return }
        await playFromContext(at: target)
    }

    /// Resolves the track at `index` (cache, prefetch or download) and plays it,
    /// honouring playToken so rapid skips don't fight. Then installs skip handlers
    /// and prefetches the next one. `skippingUnfindable` is false for a direct press:
    /// a known-missing song still gets one more search if asked for by hand.
    private func playFromContext(at index: Int, artworkData: Data? = nil,
                                 skippingUnfindable: Bool = true) async {
        guard context.indices.contains(index) else { return }
        startingCount += 1
        defer { startingCount -= 1 }
        // Fill in credit and cover first. The id doesn't change.
        let result = await enriched(context[index])
        guard context.indices.contains(index) else { return }
        context[index] = result

        // Already known to be missing: say so and move on.
        if skippingUnfindable, localSubstitutes[result.id] == nil,
           UnavailableTracks.shared.contains(title: result.title, artist: result.artistName) {
            UnavailableTracks.shared.mark(title: result.title, artist: result.artistName,
                                          announce: true)
            contextIndex = index
            await skipUnfindable(from: index)
            return
        }
        let artwork = artworkData ?? (contextArtworkID == result.id ? contextArtwork : nil)

        // Engine generation at start. If it changes, someone else took over the
        // player, so this resolve only fills the cache.
        var entryGeneration = engine.playbackGeneration
        func takenOver() -> Bool { engine.playbackGeneration != entryGeneration }

        // One resolve per song. Double-clicking the artwork fires both the click
        // and double-click handlers. Keyed on the song, so a different row still
        // supersedes via playToken.
        guard resolvingTrackID != result.id else { return }
        resolveRun &+= 1
        let run = resolveRun
        resolvingTrackID = result.id
        defer { if resolveRun == run { resolvingTrackID = nil } }

        ResolveTrace.shared.begin(result.searchQuery)

        // A slot the user owns: play their file. Re-checked since it may have gone.
        if let local = localSubstitutes[result.id] {
            if engine.canPlayLocally(local) {
                guard !takenOver() else { return }
                playToken &+= 1
                await startLocalPlayback(local, index: index, token: playToken)
                return
            }
            // File gone: resolve online like any other.
            localSubstitutes[result.id] = nil
        }

        // Fetch lyrics alongside the audio. Best-effort.
        LyricsService.shared.prefetch(for: result.asTrack(deviceID: deviceID))

        playToken &+= 1
        let token = playToken
        resolvingID = result.id
        defer { if token == playToken { resolvingID = nil } }

        // Clear the bar on every exit.
        defer { if token == playToken { endPreparing(result.id) } }

        // Cache hit, but check the duration to catch a stale music-video pick.
        if let cached = cacheURL(for: result) {
            let matches = await Self.cachedDurationMatches(cached, expected: result.duration)
            ResolveTrace.shared.mark("cache probe (hit=\(matches))")
            if matches {
                guard token == playToken, !takenOver() else { return }
                PlaybackCache.touch(cached)
                await startPlayback(result, index: index, artwork: artwork, token: token)
                prefetchTasks.removeValue(forKey: result.id)
                ResolveTrace.shared.mark("engine handoff (cache)")
                return
            } else {
                // Wrong version cached: delete and re-download.
                PlaybackCache.remove(forSourceRef: result.id)
                prefetchTasks.removeValue(forKey: result.id)
            }
        }

        // Cold track: ask for a stream URL so AVPlayer starts on the first buffer,
        // and fill the cache in the background. Streams even if a prefetch is running
        // (an unfinished download is slower); the prefetch is only stopped once the
        // stream resolves. A resolver that can't stream returns nil.
        // Set when a stream resolved but never played: the fallback download skips the search.
        var deadStreamVideoID: String?

        // Genuinely cold from here. Stop speculative work so the tap gets a resolver
        // slot; warmAfterPlayback restarts it once audio plays.
        standDownSpeculativeWork(except: result.id)
        beginPreparing(result)

        // The video this song resolved to last time, skipping the search. Not used
        // if the user rejected it.
        let known = videoIDIndex[result.id]
        let pinned = known.flatMap { exclusions(for: result.id).contains($0) ? nil : $0 }

        if let stream = try? await ytdlp.resolveStream(query: result.searchQuery,
                                                       expectedDuration: result.duration,
                                                       preferExplicit: result.isExplicit,
                                                       excluding: exclusions(for: result.id),
                                                       pinnedVideoID: pinned) {
            guard token == playToken else { return }
            ResolveTrace.shared.mark("stream resolve TOTAL")
            // Cancelling stops the yt-dlp child. warmAfterPlayback restarts it as a
            // cache fill pinned to the playing video.
            if let inFlight = prefetchTasks.removeValue(forKey: result.id) {
                inFlight.cancel()
                ResolveTrace.shared.mark("prefetch stood down for stream")
            }
            recordVideoID(stream.videoID, for: result.id)
            // Found and buffering; stop saying "finding audio".
            updatePreparing(result.id, ResolveProgress(phase: .downloading, fraction: nil))
            guard !takenOver() else { return }
            await startStreaming(result, stream: stream, index: index, artwork: artwork, token: token)
            // Our own handoff moved the generation; re-baseline.
            entryGeneration = engine.playbackGeneration
            ResolveTrace.shared.mark("engine handoff (stream)")

            // A resolved URL can still fail in AVPlayer (e.g. a 403), leaving the engine
            // stuck in .loading. Wait for the stream to start and fall back to a download
            // if it doesn't. Meanwhile poll the buffered range so the bar shows progress.
            let streamingID = result.id
            let expectedDuration = result.duration
            let bufferReporter = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, expectedDuration > 0,
                          let buffered = self.engine.remoteBufferedSeconds else { continue }
                    self.updatePreparing(streamingID,
                                         ResolveProgress(phase: .downloading,
                                                         fraction: min(buffered / expectedDuration, 1)))
                }
            }
            let streamOutcome = await engine.awaitStreamStart(timeout: Self.streamStartDeadline)
            bufferReporter.cancel()

            switch streamOutcome {
            case .playing:
                // Cache fill + next-track warm, now that this song is audible.
                warmAfterPlayback(cacheFillFor: result,
                                  pinnedVideoID: stream.videoID, token: token)
                return
            case .failed, .timedOut:
                guard token == playToken else { return }
                ResolveTrace.shared.mark("stream never started — downloading instead")
                // Tell the resolver so it stops picking this source.
                await ytdlp.noteStreamUnplayable(videoID: stream.videoID)
                deadStreamVideoID = stream.videoID
            }
        }

        // Reuse the hover prefetch if running, else download. Not after a dead stream:
        // that prefetch was cancelled and the video id is already known.
        let downloadTask: Task<ResolvedAudio, Error>
        let reusedPrefetch: Bool
        if let deadStreamVideoID {
            downloadTask = makeDownloadTask(for: result, pinnedVideoID: deadStreamVideoID)
            prefetchTasks[result.id] = downloadTask
            reusedPrefetch = false
        } else if let existing = prefetchTasks[result.id] {
            downloadTask = existing
            reusedPrefetch = true
        } else {
            // Known video: skip the search.
            downloadTask = makeDownloadTask(for: result, pinnedVideoID: pinned)
            prefetchTasks[result.id] = downloadTask
            reusedPrefetch = false
        }

        // These are mid-flight or skip the search, so show "downloading" now. The
        // task's reporter replaces it with a real percentage.
        if reusedPrefetch || deadStreamVideoID != nil {
            updatePreparing(result.id, ResolveProgress(phase: .downloading, fraction: nil))
        }

        do {
            _ = try await downloadTask.value
            ResolveTrace.shared.mark("download await TOTAL")
            guard token == playToken, !takenOver() else {
                prefetchTasks.removeValue(forKey: result.id)
                return
            }
            await startPlayback(result, index: index, artwork: artwork, token: token)
            // The engine closes the trace when sound actually starts.
            ResolveTrace.shared.mark(reusedPrefetch ? "engine handoff (reused prefetch)"
                                                    : "engine handoff (fresh download)")
        } catch {
            // A press never inherits a prefetch's failure: retry once with a fresh
            // download. Only for a reused task, so a real failure doesn't loop.
            prefetchTasks.removeValue(forKey: result.id)
            if reusedPrefetch, token == playToken, !takenOver(), !(error is CancellationError) {
                ResolveTrace.shared.mark("stale prefetch failed — downloading fresh")
                let retry = makeDownloadTask(for: result)
                prefetchTasks[result.id] = retry
                do {
                    _ = try await retry.value
                    ResolveTrace.shared.mark("download await TOTAL (retry)")
                    guard token == playToken, !takenOver() else {
                        prefetchTasks.removeValue(forKey: result.id)
                        return
                    }
                    await startPlayback(result, index: index, artwork: artwork, token: token)
                    ResolveTrace.shared.mark("engine handoff (fresh download after stale prefetch)")
                    prefetchTasks.removeValue(forKey: result.id)
                    return
                } catch {
                    if isSongNotFound(error) {
                        UnavailableTracks.shared.mark(title: result.title,
                                                     artist: result.artistName, announce: true)
                        endPreparing(result.id)
                        // Skip to the next song instead of stopping on a missing one.
                        if token == playToken, !takenOver() { await skipUnfindable(from: index) }
                    } else if token == playToken {
                        setError(userFacingPlaybackMessage(for: error, title: result.title))
                    }
                    ResolveTrace.shared.end("FAILED — \(error.localizedDescription)")
                    prefetchTasks.removeValue(forKey: result.id)
                    return
                }
            }
            if isSongNotFound(error) {
                UnavailableTracks.shared.mark(title: result.title, artist: result.artistName,
                                              announce: true)
                // The skip below bumps playToken, so the deferred clear wouldn't run.
                endPreparing(result.id)
                if token == playToken, !takenOver() { await skipUnfindable(from: index) }
            } else if token == playToken {
                setError(userFacingPlaybackMessage(for: error, title: result.title))
            }
            ResolveTrace.shared.end("FAILED — \(error.localizedDescription)")
        }
        prefetchTasks.removeValue(forKey: result.id)
    }

    /// Plays a context slot backed by a library track. Same wiring as
    /// startPlayback, but nothing is resolved.
    private func startLocalPlayback(_ local: Track, index: Int, token: Int) async {
        contextIndex = index
        await engine.play(track: local, in: [local], resolved: true)
        guard token == playToken else { return }

        // engine.play() reset the queue; re-mirror the context.
        playingSlot = index
        awaitingHandoff = false
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks[index] = local
        }
        publishDisplayQueue()

        // No online track is playing, so Discover shows none as current.
        nowPlayingID = nil

        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

        // Warm the next neighbour unless it's another local file (nothing to warm).
        if context.indices.contains(index + 1) {
            let next = context[index + 1]
            if localSubstitutes[next.id] == nil { prefetch(next) }
        }
    }

    /// Plays a downloaded context track, reinstalls skip handlers (engine.play
    /// clears them) and warms the next one. Fetches artwork first if missing and
    /// re-checks `token` after that await.
    private func startPlayback(_ result: OnlineTrack, index: Int, artwork: Data?, token: Int) async {
        // It played, so whatever an earlier search concluded is out of date.
        UnavailableTracks.shared.clear(title: result.title, artist: result.artistName)
        var artwork = artwork
        if artwork == nil, let url = result.artworkURL {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                guard token == playToken else { return }
                artwork = data
            }
        }

        // No localPath: cache entries can be evicted. AudioLocator finds the cached
        // copy by the song's key.
        let track = result.asTrack(artworkData: artwork, deviceID: deviceID)
        contextIndex = index
        // resolved: this ends a resolve, so skip the double-click guard.
        await engine.play(track: track, in: [track], resolved: true)

        // engine.play() reset the queue; re-mirror the context with the full track
        // in the playing slot.
        playingSlot = index
        awaitingHandoff = false
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks[index] = track
        }
        publishDisplayQueue()

        nowPlayingID = result.id

        // Route skip / auto-advance back here while this online track plays.
        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

        // Warm the next song. Library-backed slots need nothing.
        if context.indices.contains(index + 1) {
            let next = context[index + 1]
            if localSubstitutes[next.id] == nil { prefetch(next) }
        }
    }

    /// Streaming form of startPlayback. Same context wiring; the cache fill runs
    /// separately.
    private func startStreaming(_ result: OnlineTrack, stream: StreamResolution, index: Int, artwork: Data?, token: Int) async {
        var artwork = artwork
        if artwork == nil, let url = result.artworkURL {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                guard token == playToken else { return }
                artwork = data
            }
        }

        let track = result.asTrack(artworkData: artwork, deviceID: deviceID)
        contextIndex = index
        await engine.playOnlineStream(url: stream.url, headers: stream.headers, track: track)

        // The engine reset the queue; re-mirror the context.
        mixMainActivity("online/post-handoff") {
            playingSlot = index
            awaitingHandoff = false
            if contextDisplayTracks.indices.contains(index) {
                contextDisplayTracks[index] = track
            }
            publishDisplayQueue()
        }

        nowPlayingID = result.id

        // Route skip / auto-advance back here while this online track streams.
        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

    }

    /// Cache fill and next-track warm after a stream, held until audio plays.
    /// Starting them at handoff made three transfers compete with the first buffer.
    private func warmAfterPlayback(cacheFillFor result: OnlineTrack,
                                   pinnedVideoID: String,
                                   token: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.engine.waitUntilPlaying(timeout: Self.warmupDeadline)
            // Skipped while waiting: the new song owns the bandwidth now.
            guard token == self.playToken else { return }

            if self.prefetchTasks[result.id] == nil, self.cacheURL(for: result) == nil {
                let fill = self.makeDownloadTask(for: result,
                                                 priority: .background,
                                                 pinnedVideoID: pinnedVideoID)
                self.prefetchTasks[result.id] = fill
                // Evicted on failure, same as preload.
                Task { [weak self] in
                    do { _ = try await fill.value }
                    catch { self?.prefetchTasks.removeValue(forKey: result.id) }
                }
            }
            // Prefetch ahead up to the depth setting. preload skips cached songs and
            // respects the cap, so a deep queue fills in order.
            self.topUpQueuePrefetch()
        }
    }

    /// How long speculative work waits for audio before giving up on the stream.
    private static let warmupDeadline: TimeInterval = 8

    /// How long a stream gets to start before the download takes over. Refused
    /// URLs fail fast, so this only catches stalls.
    private static let streamStartDeadline: TimeInterval = 5

    // MARK: - Add to Library

    /// Saves `result` to the library as metadata only: artwork, album, artist and
    /// the key to resolve it again. No file is copied or uploaded, so it syncs and
    /// resolves on other devices. Offline copies are the separate Download action.
    public func addToLibrary(_ result: OnlineTrack, albumOnly: Bool = false) async {
        if albumOnly {
            SavedAlbumsService.shared.markAlbumOnly(result.stableTrackID, title: result.albumTitle, artistName: result.artistName)
        } else {
            SavedAlbumsService.shared.promote(result.stableTrackID)
        }
        defer { if !albumOnly { importService.libraryService.saveToLibrary(trackID: result.stableTrackID) } }
        resolvingID = result.id
        defer { resolvingID = nil }

        // A replayed track has no artworkURL but its display Track has artwork.
        let loadedArtwork = contextDisplayTracks.first { $0.id == result.stableTrackID }?.artworkData
            ?? (result.id == nowPlayingID ? engine.queue.currentTrack?.artworkData : nil)

        _ = await importService.saveOnlineTrack(
            sourceRef: result.id,
            // Same id as the display track, so "in library?" stays correct.
            id: result.stableTrackID,
            // The reconstructed title (see OnlineTrack.displayTitle).
            title: result.displayTitle,
            artistName: result.artistName,
            albumTitle: result.albumTitle,
            duration: result.duration,
            artworkURL: result.artworkURL,
            artworkData: loadedArtwork,
            isExplicit: result.isExplicit
        )
    }

    /// Saves a Discover album as album-only rows, so the songs aren't liked.
    /// Songs already in the library are left alone.
    public func addAlbumToLibrary(_ tracks: [OnlineTrack]) async {
        for song in tracks where importService.libraryService.track(id: song.stableTrackID) == nil {
            await addToLibrary(song, albumOnly: true)
        }
    }

    // MARK: - Queue (Discover context menu)

    /// Inserts `result` after the current track. During an online session the
    /// engine's queue is only a mirror, so the song joins `context` instead.
    /// Otherwise it goes into the local queue.
    public func playNext(_ result: OnlineTrack) async {
        if hasActiveOnlineSession {
            insertIntoContext(result, at: min(max(queueAnchor + 1, 0), context.count),
                              prefetchNow: true, lane: .manual)
            return
        }
        await enqueue(result) { [weak self] track in
            self?.engine.queue.insertNext(track)
        }
    }

    /// Bulk playNext, not a loop (see addToQueue(_ results:)).
    public func playNext(_ results: [OnlineTrack]) async {
        guard !results.isEmpty else { return }
        if hasActiveOnlineSession {
            insertIntoContext(contentsOf: results, lane: .manual,
                              at: min(max(queueAnchor + 1, 0), context.count))
            return
        }
        engine.queue.insertNext(contentsOf: results.map { $0.asTrack(deviceID: deviceID) })
        await fillQueueArtwork(for: results)
    }

    /// Appends `result` to the queue (context or local, as in playNext).
    /// `manual` is false for the queue's own top-ups, which go in the
    /// recommendation lane.
    public func addToQueue(_ result: OnlineTrack, manual: Bool = true) async {
        let lane: QueueOrigin = manual ? .manual : .recommendation
        if hasActiveOnlineSession {
            insertIntoContext(result, at: contextInsertionIndex(for: lane),
                              prefetchNow: false, lane: lane)
            return
        }
        await enqueue(result) { [weak self] track in
            self?.engine.queue.append(contentsOf: [track], lane: lane)
        }
    }

    /// Appends a mix or playlist in one go. Rows land immediately (they resolve
    /// when reached) and covers fill in behind, with one queue publish.
    /// Looping addToQueue(_:) would download each song first. `lane` is .manual for
    /// the menu and .recommendation for top-ups.
    public func addToQueue(_ results: [OnlineTrack], lane: QueueOrigin = .manual) async {
        guard !results.isEmpty else { return }
        if hasActiveOnlineSession {
            insertIntoContext(contentsOf: results, lane: lane)
            return
        }
        // Duplicates are allowed; each queue row has its own identity.
        engine.queue.append(contentsOf: results.map { $0.asTrack(deviceID: deviceID) }, lane: lane)
        await fillQueueArtwork(for: results)
    }

    /// "Add to Queue" for library songs. In an online session they join the
    /// context, each as a local substitute so it plays from the user's file.
    public func addToQueue(localTracks tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard hasActiveOnlineSession else {
            engine.queue.append(contentsOf: tracks)
            return
        }
        if sentToJam(tracks) { return }
        var additions: [OnlineTrack] = []
        var subs: [String: Track] = [:]
        for track in tracks {
            let online = Self.onlineForm(track)
            if engine.canPlayLocally(track) { subs[online.id] = track }
            additions.append(online)
        }
        localSubstitutes.merge(subs) { _, new in new }
        // After the user's queued run, not the end of the list.
        let at = contextInsertionIndex(for: .manual)
        contextLanes = alignedContextLanes()
        context.insert(contentsOf: additions, at: at)
        contextDisplayTracks.insert(contentsOf: tracks, at: min(at, contextDisplayTracks.count))
        contextLanes.insert(contentsOf: additions.map { _ in .manual }, at: at)
        if at <= playingSlot  { playingSlot  += additions.count }
        if at <= contextIndex { contextIndex += additions.count }
        publishDisplayQueue()
    }

    /// A Jam guest's adds go to the host's queue, even while this device plays
    /// the Jam's song through its own online session.
    private func sentToJam(_ tracks: [Track]) -> Bool {
        engine.queue.manualRedirect?(tracks) == true
    }

    /// The catalogue cover a queued Discover song shows, so a Jam can share it.
    public func artworkURL(forTrackID id: UUID) -> URL? {
        context.first { $0.stableTrackID == id }?.artworkURL
    }

    /// A cover that arrived after the song was queued. Patches the online mirror too,
    /// or the next publish would paint the row blank again. `replacing` swaps a
    /// cover already there (a Jam shows the adder's).
    public func fillArtwork(_ data: Data, forTrackID id: UUID, replacing: Bool = false) {
        for i in contextDisplayTracks.indices
        where contextDisplayTracks[i].id == id && (replacing || contextDisplayTracks[i].artworkData == nil) {
            contextDisplayTracks[i].artworkData = data
        }
        engine.queue.fillArtwork(data, forTrackID: id, replacing: replacing)
    }

    /// "Add to Library" for a row the library doesn't hold (queue, history).
    /// Rebuilds the online form, preferring the live context's copy which already
    /// knows its source.
    public func addToLibrary(unsaved track: Track) async {
        // The mirror pairs with context by position; fall back to rebuilt id, then the rebuild.
        let mirrored = contextDisplayTracks.firstIndex { $0.id == track.id }
            .flatMap { context.indices.contains($0) ? context[$0] : nil }
        let form = Self.onlineForm(track)
        await addToLibrary(mirrored ?? context.first { $0.id == form.id } ?? form)
    }

    /// Sign-out: the online session belongs to the account that started it.
    public func endSession() {
        cancelPreparing()
        context              = []
        contextDisplayTracks = []
        contextLanes         = []
        contextIndex         = -1
        playingSlot          = -1
        nowPlayingID         = nil
    }

    /// Clears everything after the playing song from whichever list drives
    /// playback. In an online session that's the context, not the mirror.
    public func clearUpcomingQueue() {
        // Otherwise the suggestion service refills the context.
        engine.queue.pauseAutoQueue()
        guard hasActiveOnlineSession else {
            engine.queue.clearUpcoming()
            return
        }
        guard context.indices.contains(playingSlot) else {
            context              = []
            contextDisplayTracks = []
            contextLanes        = []
            contextIndex         = -1
            playingSlot          = -1
            engine.queue.clearUpcoming()
            return
        }
        contextLanes = alignedContextLanes()
        context.removeSubrange((playingSlot + 1)...)
        if contextDisplayTracks.count > playingSlot + 1 {
            contextDisplayTracks.removeSubrange((playingSlot + 1)...)
        }
        contextLanes.removeSubrange((playingSlot + 1)...)
        contextIndex = playingSlot
        publishDisplayQueue()
    }

    /// Clears only the manually queued rows. The playing list stays.
    public func clearManualQueue() {
        guard hasActiveOnlineSession else {
            engine.queue.clearManualQueue()
            return
        }
        contextLanes = alignedContextLanes()
        for slot in carryableManualSlotIndices().reversed() {
            context.remove(at: slot)
            contextLanes.remove(at: slot)
            if contextDisplayTracks.indices.contains(slot) { contextDisplayTracks.remove(at: slot) }
        }
        publishDisplayQueue()
    }

    /// Whether "Clear added songs" has anything to do.
    public var hasManualQueue: Bool {
        hasActiveOnlineSession ? !carryableManualSlotIndices().isEmpty
                               : engine.queue.hasManualQueue
    }

    private func carryableManualSlotIndices() -> [Int] {
        let start = max(playingSlot >= 0 ? playingSlot + 1 : contextIndex + 1, 0)
        guard start < context.count else { return [] }
        return (start..<context.count).filter {
            contextLanes.indices.contains($0) && contextLanes[$0] == .manual
        }
    }

    /// Removes one upcoming row. False if out of range or currently playing.
    @discardableResult
    public func removeFromQueue(at index: Int) -> Bool {
        guard hasActiveOnlineSession else {
            return engine.queue.remove(at: index)
        }
        guard context.indices.contains(index), index != playingSlot else { return false }
        contextLanes = alignedContextLanes()
        context.remove(at: index)
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks.remove(at: index)
        }
        contextLanes.remove(at: index)
        if index < playingSlot  { playingSlot  -= 1 }
        if index < contextIndex { contextIndex -= 1 }
        publishDisplayQueue()
        return true
    }

    /// Reorders a row (the queue panel's drag). `destination` follows
    /// QueueService.moveQueueItem semantics. In an online session the context,
    /// display tracks and lanes move together.
    public func moveInQueue(from source: Int, to destination: Int) {
        guard hasActiveOnlineSession else {
            engine.queue.moveQueueItem(from: source, to: destination)
            return
        }
        guard context.indices.contains(source) else { return }
        guard destination >= 0, destination <= context.count else { return }
        guard destination != source, destination != source + 1 else { return }

        contextLanes = alignedContextLanes()
        let target = destination > source ? destination - 1 : destination

        let result = context.remove(at: source)
        context.insert(result, at: target)
        if contextDisplayTracks.indices.contains(source) {
            let display = contextDisplayTracks.remove(at: source)
            contextDisplayTracks.insert(display, at: min(target, contextDisplayTracks.count))
        }
        contextLanes.remove(at: source)

        // Both indices follow the row they pointed at.
        playingSlot  = Self.shiftedIndex(playingSlot,  from: source, to: target)
        contextIndex = Self.shiftedIndex(contextIndex, from: source, to: target)

        // A row dropped into another lane joins it, like the local queue. The row
        // above decides; at the top of the upcoming list, the row below.
        let above = target - 1 > queueAnchor && contextLanes.indices.contains(target - 1)
                  ? contextLanes[target - 1] : nil
        let below = contextLanes.indices.contains(target) ? contextLanes[target] : nil
        contextLanes.insert(target > queueAnchor ? (above ?? below ?? .manual) : .context,
                            at: target)
        publishDisplayQueue()
    }

    /// Where an index lands after the row at `source` is moved to `target`.
    private static func shiftedIndex(_ index: Int, from source: Int, to target: Int) -> Int {
        guard index >= 0 else { return index }
        if index == source { return target }
        var moved = index
        if source < index { moved -= 1 }
        if target <= moved { moved += 1 }
        return moved
    }

    /// Splices `results` into the context in `lane`'s place and refreshes the
    /// mirror. Doesn't dedupe; callers that care filter first.
    private func insertIntoContext(contentsOf results: [OnlineTrack], lane: QueueOrigin,
                                   at index: Int? = nil) {
        guard !results.isEmpty else { return }
        if lane == .manual, sentToJam(results.map { $0.asTrack(deviceID: deviceID) }) { return }
        let at = index ?? contextInsertionIndex(for: lane)
        contextLanes = alignedContextLanes()
        context.insert(contentsOf: results, at: at)
        contextDisplayTracks.insert(contentsOf: results.map { $0.asTrack(deviceID: deviceID) },
                                    at: min(at, contextDisplayTracks.count))
        contextLanes.insert(contentsOf: results.map { _ in lane }, at: at)
        if at <= playingSlot  { playingSlot  += results.count }
        if at <= contextIndex { contextIndex += results.count }
        publishDisplayQueue()
        loadDisplayArtwork()
    }

    /// Fetches covers for rows appended to the local queue. Best-effort.
    private func fillQueueArtwork(for results: [OnlineTrack]) async {
        let deviceID = self.deviceID
        await withTaskGroup(of: (UUID, Data)?.self) { group in
            for result in results.prefix(60) {
                guard let url = result.artworkURL else { continue }
                let id = result.asTrack(deviceID: deviceID).id
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                    return (id, data)
                }
            }
            for await hit in group {
                guard let hit else { continue }
                engine.queue.fillArtwork(hit.1, forTrackID: hit.0)
            }
        }
    }

    /// Splices `result` into the context at `index` and refreshes the mirror.
    /// `prefetchNow` warms it immediately (Play Next).
    private func insertIntoContext(_ result: OnlineTrack, at index: Int,
                                   prefetchNow: Bool, lane: QueueOrigin = .manual) {
        if lane == .manual, sentToJam([result.asTrack(deviceID: deviceID)]) { return }
        let idx = max(0, min(index, context.count))
        contextLanes = alignedContextLanes()
        context.insert(result, at: idx)
        contextDisplayTracks.insert(result.asTrack(deviceID: deviceID),
                                    at: min(idx, contextDisplayTracks.count))
        // Mostly Play Next / Add to Queue; only top-ups use another lane.
        contextLanes.insert(lane, at: idx)
        // A row spliced in above them pushes both position markers down.
        if idx <= playingSlot  { playingSlot  += 1 }
        if idx <= contextIndex { contextIndex += 1 }
        // Through the guard, so a resolving slot doesn't repaint the bar.
        publishDisplayQueue()
        loadDisplayArtwork()
        // Queued, not browsed, so it ignores the browsing setting.
        if prefetchNow { preload(result) }
    }

    /// Shared body for playNext / addToQueue: insert the row first, then warm the
    /// file and fill the cover. Queued rows resolve when reached, so nothing waits
    /// on the warm.
    private func enqueue(_ result: OnlineTrack, _ enqueue: @escaping (Track) -> Void) async {
        let track = result.asTrack(deviceID: deviceID)
        enqueue(track)

        resolvingID = result.id
        defer { resolvingID = nil }

        // Cover art, patched into the row that is already on screen.
        if let url = result.artworkURL,
           let (data, _) = try? await URLSession.shared.data(from: url) {
            engine.queue.fillArtwork(data, forTrackID: track.id)
        }

        // Best-effort, no alert. The row resolves when reached and reports a real
        // failure then.
        _ = try? await resolveCachedFile(for: result)
    }

    // MARK: - Helpers

    /// Resolves `result` to a cached file: cache hit, in-flight prefetch, or a
    /// fresh download. Returns the file and its videoID.
    private func resolveCachedFile(for result: OnlineTrack) async throws -> (url: URL, videoID: String) {
        if let cached = cacheURL(for: result) {
            PlaybackCache.touch(cached)
            return (cached, videoIDIndex[result.id] ?? "")
        }
        let running = prefetchTasks[result.id]
            ?? makeDownloadTask(for: result,
                                pinnedVideoID: knownVideoID(forSourceRef: result.id))
        prefetchTasks[result.id] = running
        do {
            let res = try await running.value     // makeDownloadTask records the index
            prefetchTasks.removeValue(forKey: result.id)
            return (res.fileURL, res.videoID)
        } catch {
            prefetchTasks.removeValue(forKey: result.id)
            throw error
        }
    }

    /// True if the cached file is within ~20 s of the catalogue length, or if
    /// there's no length to compare.
    private static func cachedDurationMatches(_ url: URL, expected: TimeInterval) async -> Bool {
        guard expected > 0 else { return true }
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return true }
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite, secs > 0 else { return true }
        return abs(secs - expected) <= 20
    }

    // MARK: - Cache eviction (LRU)

    /// Pin window around the playhead, so eviction can't take what's playing or
    /// next. Larger ahead since playback moves forward.
    private static let cachePinWindowAhead  = 5
    private static let cachePinWindowBehind = 2

    /// Keeps the cache in budget, pinning files near the playhead. Runs after a download finishes.
    private func enforceCacheBudget() {
        // Timed as two spans: the pin scan and the eviction pass are slow for
        // different reasons.
        var pinned = Set<URL>()
        mixMainActivity("online/cache-budget ▸ pin-scan") {
            // Only a window around the playhead. readyURL does several stat calls per
            // track, so walking a 2000-song queue took over a second per download.
            let queue = engine.queue.queue
            if !queue.isEmpty {
                let centre = engine.queue.currentIndex < 0 ? 0 : min(engine.queue.currentIndex,
                                                                    queue.count - 1)
                let lower  = max(0, centre - Self.cachePinWindowBehind)
                let upper  = min(queue.count - 1, centre + Self.cachePinWindowAhead)
                for track in queue[lower...upper] {
                    if let url = AudioLocator.readyURL(for: track) { pinned.insert(url) }
                }
            }
            if let current = engine.queue.currentTrack,
               let url = AudioLocator.readyURL(for: current) {
                pinned.insert(url)
            }
            // Don't evict what was just prefetched for the next slot.
            if context.indices.contains(contextIndex + 1),
               let url = PlaybackCache.fileURL(forSourceRef: context[contextIndex + 1].id) {
                pinned.insert(url)
            }
        }
        PlaybackCache.pinnedURLs = pinned
        mixMainActivity("online/cache-budget ▸ evict") {
            PlaybackCache.enforceBudget()
        }
    }

    /// Generation counter so a stale auto-clear task can't wipe a newer message.
    private var errorGeneration = 0

    // MARK: - Preparing state

    private func beginPreparing(_ result: OnlineTrack) {
        // Scope the main-actor cost table to this play.
        MainThreadActivity.shared.resetCosts()
        preparing = PreparingTrack(id: result.id,
                                   title: result.title,
                                   artist: result.artistName,
                                   progress: ResolveProgress(phase: .searching, fraction: nil))
    }

    /// Ignores other songs, so a late cache fill doesn't repaint the bar.
    private func updatePreparing(_ trackID: String, _ step: ResolveProgress) {
        guard var current = preparing, current.id == trackID else { return }
        // Progress going backwards is yt-dlp retrying another client. Hold the bar.
        if case .downloading = step.phase,
           case .downloading = current.progress.phase,
           let new = step.fraction, let old = current.progress.fraction, new < old {
            return
        }
        current.progress = step
        preparing = current
    }

    /// Abandons the song being prepared. Bumping playToken makes each stage bail
    /// at its next check; the download is cancelled. Silent on purpose.
    public func cancelPreparing() {
        guard let current = preparing else { return }
        playToken &+= 1
        resolvingID = nil
        // Release the per-song claim too, or retries are dropped at the guard until
        // the stalled flow reaches its next check. Bump the run first so its defer
        // can't take the claim back from a retry.
        resolveRun &+= 1
        resolvingTrackID = nil
        prefetchTasks.removeValue(forKey: current.id)?.cancel()
        preparing = nil
    }

    private func endPreparing(_ trackID: String) {
        if preparing?.id == trackID { preparing = nil }
    }

    private func setError(_ message: String) {
        errorMessage = message
        errorGeneration &+= 1
        let generation = errorGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.errorGeneration == generation else { return }
            self.errorMessage = nil
        }
    }

    /// Surface a non-error status message.
    private func flashStatus(_ message: String) { onStatus?(message) }
}
