// OnlinePlaybackCoordinator.swift
// Mixtape
//
// Discover click→play: hover prefetches in the background, click reuses that Task
// (or starts one) and plays the file once it's downloaded.
//
// We download straight to disk rather than resolve a stream URL (-g): -g needs
// YouTube's nsig decryption (10–20s, throttles often), while a direct 128kbps m4a
// download lands in 3–6s and never stalls.
//
//   1. Cache hit?   → play immediately through the full PlaybackEngine.
//   2. Hover task?  → await the already-running download, then play.
//   3. Cold click?  → start download, await, play.
//   4. "Add to Library" promotes a cached file via ImportService.

import Foundation
import Combine
import AVFoundation

@MainActor
public final class OnlinePlaybackCoordinator: ObservableObject {

    /// ID of the OnlineTrack currently being resolved (drives per-row spinners).
    @Published public private(set) var resolvingID: String? = nil
    /// ID of the OnlineTrack currently playing through the engine (drives the
    /// now-playing indicator in the Discover UI). Nil when no online track plays.
    @Published public private(set) var nowPlayingID: String? = nil
    /// Non-nil briefly when a play attempt fails. Auto-clears after 4 s.
    @Published public private(set) var errorMessage: String? = nil
    /// Non-nil briefly to surface a non-error status (e.g. the result of a
    /// "wrong version" re-resolve). Auto-clears after a few seconds.
    @Published public private(set) var statusMessage: String? = nil

    /// The song the user is waiting on, and how far along it is.
    ///
    /// A cold online track is a search, a download and a conversion before a
    /// note is heard, and the only thing that ever said so was a spinner on the
    /// row — which says "something is happening" and nothing about whether it
    /// is nearly done. This is what the loading bar above the player reads.
    ///
    /// Only ever the song that was *asked for*: prefetches and cache fills run
    /// constantly and are nobody's business.
    @Published public private(set) var preparing: PreparingTrack? = nil


    /// What the loading bar shows. Carries its own title rather than an id the
    /// bar would have to look up, because by the time it matters the song might
    /// not be in any list on screen.
    public struct PreparingTrack: Equatable {
        public let id: String
        public let title: String
        public let artist: String
        public var progress: ResolveProgress

        /// "Searching", "Downloading", "Converting" — the verb the bar prints
        /// after the song's name.
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

    /// Whether there is a network to resolve against — supplied by
    /// `AppDependencies` rather than held, so this keeps no reference to the
    /// download manager. Everything below funnels through `beginSession`, which
    /// refuses rather than starting a resolve that can only end in a timeout.
    public var isOnline: () -> Bool = { true }

    /// Incremented on every play() call. A slow download checks this before
    /// starting playback and aborts if a newer click has superseded it —
    /// fixes the "click B while A loads, A plays" race.
    private var playToken = 0

    /// The song `playFromContext` is currently resolving, so a second tap on the
    /// same row doesn't start the whole resolve again. Distinct from `resolvingID`,
    /// which is published UI state for the row spinner.
    private var resolvingTrackID: String?
    /// Bumped every time `playFromContext` claims `resolvingTrackID`, so the
    /// claim can only ever be released by the run that made it. Without this a
    /// cancelled resolve, unwinding seconds later, would clear the claim a
    /// *retry* of the same song had since taken out — or, worse, its own stale
    /// claim would still be standing and the retry would be turned away at the
    /// guard. That was the "press stop, press skip, nothing happens" bug.
    private var resolveRun = 0

    /// Active download Tasks keyed by OnlineTrack.id.
    /// Inserted by prefetch(); reused or replaced by play(); removed on completion.
    /// Each yields the DownloadResult so the resolved videoID can be recorded.
    private var prefetchTasks: [String: Task<ResolvedAudio, Error>] = [:]

    /// Speculative downloads currently running (see `maxConcurrentPrefetches`).
    private var inFlightPrefetches = 0

    /// Songs already warmed on the resolver this session (see `warm`). Only ever
    /// grows while the app is up: the point of the set is that one warm per song
    /// is enough, and the server keeps the file long after we stop asking.
    private var warmedTrackIDs: Set<String> = []
    /// Warms currently in flight, capped alongside prefetches.
    private var inFlightWarms = 0

    /// Persistent map OnlineTrack.id → resolved YouTube videoID, so the cache is
    /// keyed by the *actual* video (an explicit upload and a clean one of the same
    /// song get distinct files). Loaded lazily from cacheDir/index.json.
    private var _videoIDIndex: [String: String]? = nil

    /// The list the current online track was played from (search results, an
    /// album's tracks, or an artist's popular list). Skip / auto-advance step
    /// through this. Empty when no online context is active.
    private var context: [OnlineTrack] = []
    /// One lane per `context` slot — see `QueueOrigin`.
    ///
    /// A Discover session is mostly context — the mix or the search result list
    /// it started from — with the user's own "Add to Queue" songs spliced in
    /// ahead of it and the app's own top-ups behind it. During a session the
    /// queue panel is a mirror of this list, so the lane has to travel with the
    /// slot, and this list has to keep them in the same order the local queue
    /// does: manual, then context, then recommendation, after the playing slot.
    /// Maintained by every mutation of `context`; `alignedContextLanes()` is the
    /// backstop.
    private var contextLanes: [QueueOrigin] = []
    /// Index of the currently playing track within `context`.
    private var contextIndex = 0
    /// Display mirror of `context` as `Track`s, so the Queue panel can show the
    /// online session's NOW PLAYING + NEXT UP. Built once when the context is set
    /// and reused as we navigate (the playing slot is swapped for the fully-built
    /// track so its artwork shows). Empty when no online context is active.
    private var contextDisplayTracks: [Track] = []
    /// Bumped whenever the display mirror is rebuilt, so a slow background artwork
    /// fetch for an old mirror can't clobber a newer one.
    private var displayArtworkToken = 0
    /// Artwork the UI handed us for the current play, reused when artwork for a
    /// neighbour isn't separately available.
    private var contextArtwork: Data?
    /// Which song `contextArtwork` is the cover *of*. Without it a session
    /// started with no artwork (the macOS search dropdown hands none over) drew
    /// whatever the previous session left behind — the wrong cover, confidently.
    private var contextArtworkID: String?
    /// Track details already fetched this launch, keyed by Deezer track id.
    private var trackDetails: [Int: (contributors: [String], coverURL: URL?)] = [:]
    /// Library tracks standing in for context slots, keyed by OnlineTrack.id.
    /// A context assembled from a mixed list (Home's "Jump back in", history) can
    /// contain songs the user already owns; those play from their own file
    /// instead of being re-resolved from the internet. Empty for a pure Discover
    /// session.
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

        // Look ahead whenever the queue changes. Waiting for the preload depth
        // to reach a song meant the warning arrived at the same moment as the
        // problem — the row was "next up" by the time it went red, which is no
        // warning at all.
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

    /// How far down the queue to look: the same preference that says how far
    /// ahead to fetch. Asking about a song and downloading it cost the same
    /// search, so "one ahead" means one of each — including songs the user
    /// queued by hand, which are simply the rows that come next.
    private var scanDepth: Int { PlaybackPrefetchSettings.shared.queueDepth.rawValue }

    /// Ask, ahead of time, which of the queued songs can actually be found.
    ///
    /// ponytail: one probe at a time, `scanDepth` rows deep. Each probe is a
    /// resolver search — a yt-dlp process on macOS, a request on iOS — so this
    /// deliberately trickles — at "whole queue" depth a long queue takes a
    /// while to work through. Batch it if that ever matters.
    private func scanQueueAvailability() {
        // Not cancel-and-restart. The queue republishes constantly during a
        // session — artwork landing, a top-up, the display mirror — and each
        // probe is a slow search, so restarting on every change meant the scan
        // was always back at row one and never finished a single answer. One
        // runner instead, with a flag saying "go round again when you're done".
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
        // The same preference that governs fetching ahead governs asking ahead:
        // both spend the network on songs nobody has pressed play on yet.
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
                // nil means this resolver can't stream, which says nothing about
                // the song. Only a thrown "no result" is an answer.
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

    /// The upcoming songs worth probing: the ones with no file of their own,
    /// from wherever playback currently is.
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

    /// Where a download is written while it's still arriving. The finished file
    /// is then handed to `PlaybackCache`, which is the only thing that decides
    /// where cached audio lives.
    static var cacheDir: URL { PlaybackCache.stagingDirectory }

    /// The cached file for `result`, or nil if this device doesn't have it.
    ///
    /// Keyed by the song, not by the video it resolved to. The old key was the
    /// videoID, which meant the lookup could only work if the index that maps
    /// song → video had survived — so clearing that index orphaned every file in
    /// the cache, and a fresh install re-downloaded songs already on disk.
    func cacheURL(for result: OnlineTrack) -> URL? {
        PlaybackCache.fileURL(forSourceRef: result.id)
    }

    // MARK: - VideoID index (persistent)

    /// Which upload each song resolved to. Now purely informational — it tells
    /// "wrong version" whether the resolver actually picked something different
    /// — and no longer stands between a cached file and the song it belongs to.
    private var indexFileURL: URL { PlaybackCache.directory.appendingPathComponent("online-index.json") }

    /// The pre-merge location, read once so existing mappings survive the move.
    private var legacyIndexFileURL: URL {
        PlaybackCache.legacyOnlineCacheDirectory.appendingPathComponent("index.json")
    }

    /// Lazily-loaded in-memory copy of the on-disk videoID index. A missing or
    /// corrupt file yields an empty index rather than crashing.
    private var videoIDIndex: [String: String] {
        get {
            dropPinsIfPreferenceFlipped()
            if let cached = _videoIDIndex { return cached }
            let loaded = decodeIndex(at: indexFileURL) ?? decodeIndex(at: legacyIndexFileURL) ?? [:]
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

    /// Uploads the user has rejected, per track.
    ///
    /// Persisted next to the videoID index and for the same reason: a judgement
    /// the user made by hand should not evaporate when the app restarts.
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
    }

    /// Start over for one track. Called when the exclusions have used up every
    /// upload there is: the alternative to forgetting is a song that can never
    /// be played again, which is worse than offering the first pick a second
    /// time.
    private func clearRejections(for trackID: String) {
        var all = rejectedVideoIDs
        guard all.removeValue(forKey: trackID) != nil else { return }
        rejectedVideoIDs = all
    }

    /// Throw away the pinned uploads when the censored-version preference is
    /// flipped.
    ///
    /// A pin skips the search entirely — that is the whole point of it — so
    /// without this the new setting would apply only to songs this device had
    /// never played, which is the opposite of what someone flipping it expects.
    /// The audio cache is keyed by video id, so a fresh pick simply fetches a
    /// fresh file and the old one ages out under the usual budget.
    private func dropPinsIfPreferenceFlipped() {
        let key = "mixtape.resolver.pinsPreferCensored"
        let want = ResolverPreferences.preferCensored
        guard UserDefaults.standard.bool(forKey: key) != want else { return }
        UserDefaults.standard.set(want, forKey: key)
        try? FileManager.default.removeItem(at: indexFileURL)
        _videoIDIndex = [:]
    }

    private func decodeIndex(at url: URL) -> [String: String]? {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    /// The upload this device settled on for a song, keyed by `sourceRef`.
    ///
    /// Public so continuity can hand it to the device taking over: knowing
    /// which video to fetch is the larger half of a cold resolve, and the
    /// device that was just playing already knows.
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
    private func recordVideoID(_ videoID: String, for trackID: String) {
        var idx = videoIDIndex
        idx[trackID] = videoID
        videoIDIndex = idx
    }

    /// Adopt whatever the old, separate Discover cache still holds, then forget
    /// it exists. Runs once at launch; a second run finds nothing and returns.
    private func migrateLegacyCache() {
        let index = videoIDIndex                    // reads the legacy file if that's all there is
        PlaybackCache.migrateLegacyOnlineCache(index: index)
        PlaybackCache.sweepStaging()
        if !index.isEmpty { videoIDIndex = index }   // re-persist at the new location

        // Nothing is playing yet, so nothing is pinned and eviction is free to
        // take the coldest files. Without this the only time the budget is ever
        // applied is after a download completes — so a cache left over budget by
        // a lowered limit, or by the migration above, stays over budget for as
        // long as the user doesn't play anything new.
        PlaybackCache.pinnedURLs = []
        PlaybackCache.enforceBudget()
    }

    /// Wipe every cached song and the videoID index so everything re-fetches
    /// fresh. Cancels in-flight downloads first. Returns files removed.
    @discardableResult
    public func clearCache() -> Int {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()

        let removed = PlaybackCache.clear()

        // Drop the persisted index so stale id → videoID mappings don't resurrect.
        try? FileManager.default.removeItem(at: indexFileURL)
        _videoIDIndex = [:]
        try? FileManager.default.removeItem(at: rejectedFileURL)
        _rejectedVideoIDs = [:]
        return removed
    }

    /// Forget one track's cached source (cancel its download, delete the file, drop
    /// its videoID mapping) so the next play re-resolves it. Fixes a single song
    /// that landed on a wrong upload without nuking the whole cache. Returns true
    /// if a file was removed; safe to call when nothing was cached.
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
        return removed
    }

    /// "Wrong version" action: forget the cached source then play through the
    /// normal flow so the resolver re-picks. Flashes whether it found a different
    /// upload or the same one was all it had.
    public func reResolveAndPlay(_ result: OnlineTrack, context: [OnlineTrack] = []) async {
        let previousVideoID = videoIDIndex[result.id]

        // Record the rejection before searching again, not after. Clearing the
        // cache is enough to make the *first* re-resolve find something new,
        // because the cache was the only thing pinning the answer. It is not
        // enough for the second: the search is deterministic, so without a
        // record of what was refused it hands back the upload just rejected,
        // and every further press returns that same one. The list is what makes
        // repeated presses walk through the alternatives.
        if let previousVideoID { reject(previousVideoID, for: result.id) }
        clearCache(for: result)

        let refused = exclusions(for: result.id)
        flashStatus(refused.count > 1
                    ? "Looking for another version of “\(result.title)” (\(refused.count) ruled out)…"
                    : "Finding a different source for “\(result.title)”…")

        await playRespectingRejections(result, context: context)

        // The play path records the freshly-resolved videoID. Compare against the
        // one we just cleared to tell the user whether anything actually changed.
        var newVideoID = videoIDIndex[result.id]

        // Nothing came back, and we are refusing uploads — so the refusals are
        // the likely reason. Forget them and try once more, otherwise a song
        // the user has re-resolved a few times becomes permanently unplayable.
        if newVideoID == nil, !refused.isEmpty {
            clearRejections(for: result.id)
            clearCache(for: result)
            await playRespectingRejections(result, context: context)
            newVideoID = videoIDIndex[result.id]
            if newVideoID != nil {
                flashStatus("That's every version we could find for “\(result.title)” — back to the first.")
                return
            }
        }

        if let newVideoID, newVideoID != previousVideoID {
            flashStatus("Switched to a different version of “\(result.title)”.")
        } else if newVideoID != nil {
            flashStatus("That's the only version we could find for “\(result.title)”.")
        }
        // newVideoID == nil → the play attempt failed; setError already surfaced it.
    }

    private func playRespectingRejections(_ result: OnlineTrack, context: [OnlineTrack]) async {
        if context.isEmpty {
            await play(result)
        } else {
            await play(result, context: context)
        }
    }

    // MARK: - Prefetch (hover)

    /// Begin downloading `result` in the background so play() is instant when
    /// the user clicks. Safe to call repeatedly — no-ops if already cached or
    /// a download is already running for this track.
    public func prefetch(_ result: OnlineTrack) {
        // Browsing-driven, so it answers to the browsing preference. The queue
        // preloader calls `preload` directly: songs already lined up to play
        // are not speculation in the same sense.
        guard PlaybackPrefetchSettings.shared.prefetchWhileBrowsing else { return }
        preload(result)
    }

    /// Prefetch regardless of the browsing preference — for songs the user has
    /// actually queued.
    private func preload(_ result: OnlineTrack) {
        guard cacheURL(for: result) == nil else { return }   // already cached
        guard prefetchTasks[result.id] == nil else { return }
        // Speculative work yields to the tap that actually happened. Every
        // prefetch is a yt-dlp + ffmpeg pair, and they are now started from
        // every album, artist and playlist page the user passes through — left
        // uncapped, browsing a few pages would put a dozen of them in flight
        // and starve the download the user is waiting on.
        guard speculativeInFlight < maxConcurrentPrefetches else { return }

        inFlightPrefetches += 1
        // Pinned when this device already knows which upload this song is. The
        // search is a third of a cold resolve and the answer is on disk — a
        // prefetch that searched again was paying for it twice.
        let task = makeDownloadTask(for: result,
                                    priority: .background,
                                    pinnedVideoID: knownVideoID(forSourceRef: result.id))
        prefetchTasks[result.id] = task
        // Release the slot on completion, whichever way it ends.
        //
        // A *successful* prefetch stays in `prefetchTasks`, so the play that
        // follows finds it and reuses the bytes. A failed one is evicted, and
        // that is the whole point of the distinction: `play` awaits whatever it
        // finds here, and an already-thrown task rethrows instantly. A hover
        // prefetch that quietly failed minutes ago therefore made the *first*
        // press on that song fail in a few hundred milliseconds with no search,
        // no download and nothing on screen but an error — and the second press,
        // after the catch had finally removed the entry, worked. That is exactly
        // the "pressed play and nothing happened, pressed again and it played"
        // report.
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                self?.prefetchTasks.removeValue(forKey: result.id)
                // Silent: nobody is waiting on this song yet. The point of
                // fetching ahead is that the queue can wear the warning long
                // before playback arrives at the row.
                if isSongNotFound(error) {
                    UnavailableTracks.shared.mark(title: result.title,
                                                  artist: result.artistName)
                }
            }
            self?.inFlightPrefetches -= 1
            // A slot just came free, so take the next song the user asked us to
            // get ahead on. `preload` refuses anything over the cap and does not
            // remember being refused, so without this the depth setting would
            // silently collapse to however many slots there were: asking for the
            // next five and getting one.
            self?.topUpQueuePrefetch()
        }
    }

    /// Start prefetching as far down the current queue as the depth preference
    /// asks for, as far as the concurrency budget allows right now.
    ///
    /// Idempotent and cheap: everything already cached, already running, or
    /// playable from the library is skipped, and the budget guard in `preload`
    /// stops the rest. Safe to call whenever a slot frees.
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

    /// How many speculative downloads may run at once — a preference now, since
    /// how much bandwidth to spend ahead of time is the user's call. See
    /// `PlaybackPrefetchSettings`.
    ///
    /// On iOS it is not the user's call, because the limit is not this device's.
    /// Every resolve there goes through the hosted resolver, which serves two at
    /// a time and turns the third away instantly. Spending both slots on songs
    /// nobody has asked for leaves nothing for the song someone just tapped —
    /// which is precisely what happened: opening a large playlist started
    /// speculative resolves for its first unplayable rows, and the play press
    /// that followed was refused in a few hundred milliseconds. One slot for
    /// guessing, one always kept free for the tap.
    private var maxConcurrentPrefetches: Int {
        let preference = max(PlaybackPrefetchSettings.shared.concurrentPrefetches, 1)
        #if os(iOS)
        return min(preference, 1)
        #else
        return preference
        #endif
    }

    /// Speculative resolver work of every kind currently in flight.
    ///
    /// Prefetches and warms used to be counted separately against the same cap,
    /// so "two at a time" quietly meant four. They compete for one resource —
    /// the resolver — so they share one budget.
    private var speculativeInFlight: Int { inFlightPrefetches + inFlightWarms }

    /// Cancel speculative work so the resolver has a slot for the song the user
    /// is actually waiting on.
    ///
    /// Only on iOS, and only for *other* songs: the Mac resolves locally with no
    /// shared limit to free up, and a prefetch of this very song is the one
    /// piece of speculation that is about to become useful.
    private func standDownSpeculativeWork(except keepID: String) {
        #if os(iOS)
        for (id, task) in prefetchTasks where id != keepID {
            task.cancel()
            prefetchTasks.removeValue(forKey: id)
        }
        #endif
    }

    /// Warm `result` on the resolver without pulling a byte of its audio onto
    /// this device.
    ///
    /// The two platforms pay for a cold song in completely different places, and
    /// that difference is the whole of the iOS-vs-Mac gap. macOS runs yt-dlp
    /// locally: one search, then `-g` hands back a direct CDN URL and AVPlayer
    /// streams from it. iOS has no `Process`, so it asks the resolver server —
    /// and that server's `/resolve` runs the search *and downloads the entire
    /// track* before it answers anything at all. Only then does the phone start
    /// buffering. A couple of seconds on the Mac becomes a full server-side
    /// download plus a transfer on the phone.
    ///
    /// Asking for a stream URL and throwing it away leaves the finished file in
    /// the server's own cache, so the resolve behind the tap that follows is
    /// just the search again — the expensive half is already paid for, off the
    /// clock, while the user is still reading the results.
    ///
    /// Deliberately not `prefetch`. That downloads the bytes *here*, which on a
    /// phone means spending cellular data on a song nobody has asked for yet.
    /// This spends one HTTP request.
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
                    // A warm that failed must not poison the song for the rest of
                    // the session — the tap that follows should be free to try
                    // the whole thing again rather than inherit a dead answer.
                    self.warmedTrackIDs.remove(trackID)
                }
            }
        }
    }

    /// Warm the cache for library rows that can only be played by resolving them
    /// online — the shape a joined collaborative playlist arrives in.
    ///
    /// This is the difference the person who joined a shared playlist is feeling.
    /// Discover has always prefetched on hover, so by the time a song there is
    /// clicked the file is usually already on disk; a shared playlist did nothing
    /// until the tap, and then did all of it — search, resolve, download — with
    /// the user watching. Same work, just moved to while they're reading the
    /// tracklist.
    ///
    /// Deliberately only the first few. A hundred-song playlist is a hundred
    /// downloads nobody asked for, on a phone, against a 1 GB cache budget that
    /// would then evict the songs they actually played.
    public func prefetchResolvable(_ tracks: [Track], limit: Int? = nil) {
        guard PlaybackPrefetchSettings.shared.prefetchWhileBrowsing else { return }
        // Opening a page is a weaker signal than queueing, so the depth setting
        // caps this too — someone who asked for the whole queue is asking for
        // this as well, and someone who turned preloading off meant it.
        let limit = limit ?? max(PlaybackPrefetchSettings.shared.queueDepth.rawValue, 1)
        var started = 0
        for track in tracks where started < limit {
            // Skip anything with its own audio: `canPlayLocally` covers both a
            // file on disk and a remoteKey to download it from, neither of which
            // needs the resolver.
            guard !engine.canPlayLocally(track), !track.title.isEmpty else { continue }
            prefetch(Self.onlineForm(track))
            started += 1
        }
    }

    /// Build a download Task for `result`. The resolver writes into staging; the
    /// finished file is moved into the shared playback cache under the song's own
    /// key, the resolved videoID is recorded, and the budget is re-checked. The
    /// Task value carries the *adopted* URL, so callers never hold a path that's
    /// about to be moved out from under them.
    ///
    /// `pinnedVideoID` skips the search pass. Pass it when the video is already
    /// known — after a stream resolve, that both saves the round trip and
    /// guarantees the cached copy is the same upload the user is hearing.
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
            // Every download narrates itself, prefetches included. A hover
            // prefetch that the user then clicks is the *common* cold play, and
            // when only explicitly-awaited downloads reported, that click
            // inherited a bar with no number in it — the download was already
            // running and simply had nobody listening. `updatePreparing` drops
            // anything that isn't the song on screen, so the quiet cases stay
            // quiet.
            let report: @Sendable (ResolveProgress) -> Void = { step in
                // The resolver reports from whatever thread it runs its child
                // process (or URLSession) on; the bar reads this on the main actor.
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
            // `Task` inside a @MainActor type inherits that actor, so this is
            // main-thread code however it reads — `adopt` moves a file and the
            // block below walks the queue and the cache directory.
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

    /// Play `result` as a standalone track (no skip context). Thin wrapper kept
    /// for backward-compat — forwards to the context-aware form with a one-item
    /// context, so skip-forward/back simply have nowhere to go.
    public func play(_ result: OnlineTrack, artworkData: Data? = nil) async {
        await play(result, context: [result], artworkData: artworkData)
    }

    /// Play `result` within `context` — the list it was selected from (search
    /// results, an album's tracks, an artist's popular list). Skipping
    /// forward/back and auto-advance then step through `context`, downloading
    /// each neighbour on demand. `artworkData` is the card image already loaded
    /// by the UI, passed through to the now-playing bar.
    public func play(_ result: OnlineTrack, context: [OnlineTrack], artworkData: Data? = nil) async {
        await beginSession(result, context: context, artworkData: artworkData, localSubstitutes: [:])
    }

    /// Shared body of `play(_:context:artworkData:)`. `localSubstitutes` maps
    /// OnlineTrack.id → a library track that should play from its own file rather
    /// than being resolved online (see `playStandaloneOnline`).
    private func beginSession(
        _ result: OnlineTrack,
        context: [OnlineTrack],
        artworkData: Data?,
        localSubstitutes: [String: Track]
    ) async {
        // No network and nothing on the disk: say so now. The resolve would
        // otherwise run its full search/download path against a dead network,
        // leaving the previous song playing behind a bar that never finishes.
        // A cached file or a library substitute still plays — that is the whole
        // point of downloading.
        if !isOnline(), localSubstitutes[result.id] == nil, cacheURL(for: result) == nil {
            setError("“\(result.title)” isn't downloaded — you're offline.")
            return
        }
        // Mirroring another device: the song goes there instead, and none of
        // the work below (resolve, download, stream) is ours to do. Checked
        // here rather than in the engine because the engine only hears about an
        // online song once it has already been fetched.
        if engine.remoteTransport != nil,
           engine.remotePlayRedirect?(result.asTrack(deviceID: deviceID),
                                      context.map { $0.asTrack(deviceID: deviceID) }) == true {
            return
        }
        // What the user queued by hand outlives the session it was queued in:
        // pressing play on another playlist replaces the list, not the requests.
        // Captured before `localSubstitutes` is replaced, because a carried row
        // backed by a library file has to keep its substitute entry too.
        let carriedManual = carryableManualSlots()
        let carriedSubs   = carriedManual.reduce(into: [String: Track]()) { subs, slot in
            subs[slot.online.id] = self.localSubstitutes[slot.online.id]
        }
        self.localSubstitutes = localSubstitutes.merging(carriedSubs.compactMapValues { $0 }) { _, new in new }
        // Remember the context so the engine's skip handlers can navigate it.
        // Fall back to a one-item context if the caller passed an empty list.
        let ctx = context.isEmpty ? [result] : context
        // If `result` isn't actually in `ctx`, prepend it rather than silently
        // playing ctx[0] — guarantees the requested track is the one that plays.
        if let idx = ctx.firstIndex(of: result) {
            self.context      = ctx
            self.contextIndex = idx
        } else {
            self.context      = [result] + ctx
            self.contextIndex = 0
        }
        // A fresh session is all context — apart from the songs carried over,
        // which are spliced back in right after the one now playing.
        self.contextLanes = Array(repeating: .context, count: self.context.count)
        if !carriedManual.isEmpty {
            let at = min(self.contextIndex + 1, self.context.count)
            self.context.insert(contentsOf: carriedManual.map(\.online), at: at)
            self.contextLanes.insert(contentsOf: carriedManual.map { _ in QueueOrigin.manual }, at: at)
        }
        self.contextArtwork = artworkData
        self.contextArtworkID = artworkData == nil ? nil : result.id
        // Nothing from this list is playing yet, and the slot left over from the
        // previous session indexes a song that has nothing to do with this one.
        self.playingSlot = -1
        self.awaitingHandoff = true
        // Build the display mirror so the Queue panel shows the whole online
        // session (NOW PLAYING + everything queued after it), not just one song.
        // Slots backed by a library track show that track, artwork and all.
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

    /// The manual-lane rows still ahead of playback, with their display form —
    /// what `beginSession` carries into the next session.
    private func carryableManualSlots() -> [(online: OnlineTrack, display: Track?)] {
        carryableManualSlotIndices().map { i in
            (context[i], contextDisplayTracks.indices.contains(i) ? contextDisplayTracks[i] : nil)
        }
    }

    /// Extend the active online session with similar-song suggestions so playback
    /// — and the Queue panel — keeps going when the original context runs low.
    /// New tracks join the navigation `context` (each downloaded on demand when
    /// reached) and the display mirror. No-op when no online session is active.
    /// Called by QueueSuggestionService.
    public func appendOnlineSuggestions(_ tracks: [OnlineTrack]) {
        guard !context.isEmpty else { return }
        // Deliberately deduped, unlike a queue action: nobody asked for these,
        // and a suggestion the session already contains is just a repeat.
        let existing = Set(context.map { $0.id })
        insertIntoContext(contentsOf: tracks.filter { !existing.contains($0.id) },
                          lane: .recommendation)
    }

    /// How many context plays are in flight. Read by `hasActiveOnlineSession`
    /// so the gap between the engine dropping its online handlers (any `play()`
    /// clears them) and this coordinator re-installing them doesn't read as
    /// "the session ended".
    private var startingCount = 0

    /// The context slot whose audio is actually coming out of the speakers, or
    /// -1 when nothing from this session is playing yet.
    ///
    /// Not `contextIndex`: that moves the moment a song is *clicked*, and stays
    /// pointed at it for the seconds it takes to resolve and download, while the
    /// previous song is still playing. And not a search for `nowPlayingID`
    /// either — a slot backed by a library file the user already owns plays with
    /// no online id at all. Set at each handoff, next to the audio it describes.
    private var playingSlot: Int = -1

    /// Set while a newly-chosen session's list has been built but its first song
    /// hasn't taken over the speakers yet.
    ///
    /// The mirror is pushed for all sorts of reasons that aren't a handoff —
    /// cover art arriving, a song added to the queue — and the list it pushes is
    /// the *new* session's while the *old* session's song is still playing. The
    /// slot index went with it, and an index is only meaningful against the list
    /// it was measured in: slot 5 of the search the user just left is slot 5 of
    /// the search they just typed, which is some unrelated song. That is what
    /// repainted the player bar with a random result seconds before the song
    /// they picked had finished downloading.
    ///
    /// So the whole push waits for the handoff. Until then the player queue
    /// keeps naming the song actually coming out of the speakers, which is the
    /// only thing it should ever name. Nothing needs to clear this on failure —
    /// it only holds while something is playing, so a session that never starts
    /// stops holding as soon as the old song ends.
    private var awaitingHandoff = false

    /// Push the display mirror to the player's queue.
    ///
    /// The *list* goes out on every call — a song added to the queue has to
    /// appear in the Queue panel the instant it is added, whether or not
    /// anything is playing and whether or not a resolve is in flight. What is
    /// held back is the position: `currentIndex` names the slot actually
    /// playing, because everything the player bar shows comes from
    /// `queue.currentTrack`, and pointing it at a song that is still resolving
    /// paints that title, artist and cover over the *previous* song's audio and
    /// still-advancing timeline.
    ///
    /// -1 (nothing from this session playing) is passed through as-is; the Queue
    /// panel then lists every row as upcoming, which is exactly right for a
    /// queue that has been filled but not started.
    private func publishDisplayQueue() {
        // Only while this coordinator is the one playing. Every push here
        // overwrites the whole player queue, so a push from a session that no
        // longer owns the audio paints its songs over the live one — and the
        // player bar reads `queue.currentTrack`, so what the user sees is the
        // *previous* song's title and cover sitting over the song they just
        // started. The way in was always asynchronous: cover art fetched for a
        // session lands seconds later (`loadDisplayArtwork`), long after a tap
        // on a local song — Recently played, a library row — took playback
        // over. Every other mutator here already refuses to touch a dead
        // session; the guard belongs on the push itself, which is the only
        // thing that can reach the queue.
        guard hasActiveOnlineSession else { return }
        // See `awaitingHandoff`: a session that hasn't started yet must not
        // repaint the bar over the song that is still playing.
        guard !awaitingHandoff || engine.queue.currentTrack == nil else { return }
        let slot = context.indices.contains(playingSlot) ? playingSlot : -1
        mixMainActivity("queue/publish-online") {
            engine.queue.setOnlineDisplayQueue(contextDisplayTracks,
                                               currentIndex: slot,
                                               lanes: alignedContextLanes(),
                                               source: .named("Discover"))
        }
    }

    /// `contextLanes`, repaired if it has drifted out of step with `context` —
    /// a mismatch would mislabel every slot after the gap.
    private func alignedContextLanes() -> [QueueOrigin] {
        guard contextLanes.count != context.count else { return contextLanes }
        var lanes = Array(contextLanes.prefix(context.count))
        while lanes.count < context.count { lanes.append(.context) }
        return lanes
    }

    /// The slot after which newly queued songs go: the one actually playing, or
    /// the one being resolved when nothing has taken over the speakers yet.
    private var queueAnchor: Int { max(playingSlot, contextIndex) }

    /// Where a new row of `lane` belongs, keeping this list in the same lane
    /// order the local queue keeps: the user's own queued songs first, then the
    /// rest of the session, then the app's top-ups.
    ///
    /// This is what stops "Add to Queue" during a Discover session landing
    /// behind the whole mix — the same bug the local queue had.
    private func contextInsertionIndex(for lane: QueueOrigin) -> Int {
        let lanes = alignedContextLanes()
        var i = min(max(queueAnchor + 1, 0), context.count)
        while i < context.count, lanes[i] <= lane { i += 1 }
        return i
    }

    /// True while an online Discover session is actually driving playback — lets
    /// the suggestion service, and every "Add to Queue", decide whether to route
    /// songs into the context or into the real local queue.
    ///
    /// `context` alone is not the answer: it is never emptied, so it still holds
    /// the last Discover session hours after the user went back to their library.
    /// Anything routed into it from there is spliced into a dead list and then
    /// *published over the live queue* by the next mirror push — which is exactly
    /// how adding a mix to the queue used to fill it with a previous session's
    /// songs. The engine's handlers are the honest signal: every local `play()`
    /// drops them, and the coordinator re-installs them only while it is the one
    /// playing. `startingCount` covers the moment in between, when the
    /// coordinator has cleared them itself and is about to put them back.
    public var hasActiveOnlineSession: Bool {
        !context.isEmpty && (engine.hasOnlineContext || startingCount > 0)
    }

    /// The online track currently loaded in the player, if any — lets UI outside
    /// Discover (e.g. the player bar) offer Add to Library / queue actions for it.
    public var currentOnlineTrack: OnlineTrack? {
        guard let id = nowPlayingID else { return nil }
        return context.first { $0.id == id }
    }

    /// Jump straight to a track the user clicked in the Queue panel during an
    /// online session. Resolves it through the normal context flow (cache hit /
    /// in-flight prefetch / fresh download) so it shows the standard spinner and
    /// plays once on disk — exactly like clicking it in Discover. Matched by the
    /// display-mirror Track id. Returns false when there's no online session or
    /// the track isn't part of it, so the caller can fall back to local playback.
    @discardableResult
    public func playQueueTrack(at index: Int, track: Track) async -> Bool {
        // `hasActiveOnlineSession`, not `!context.isEmpty`: a finished session's
        // context lingers, and matching a queue row against it would drag the
        // dead session back — republishing its songs over the live queue.
        guard hasActiveOnlineSession else { return false }
        // The queue is a mirror of `contextDisplayTracks` during a session, so
        // the row's position *is* the context position — and a position is what
        // this needs, since the same song can sit in the queue more than once
        // and searching by id would always find the first of them. The id check
        // is a sanity guard for a mirror that has drifted; falling back to a
        // search there is better than playing the wrong song.
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

    /// True when this Track can *only* be played by resolving it online. Callers
    /// use it to route through `playStandaloneOnline` instead of the local-file
    /// path, which would otherwise claim the song "hasn't been uploaded yet".
    ///
    /// Both halves matter. `isOnline` is a stored fact about where the song came
    /// from and stays true forever — a Discover song downloaded for offline
    /// listening is still `.online`. Routing on that alone sent songs whose audio
    /// was sitting on this disk back out to the resolver to be found, downloaded
    /// and decoded again, which is why replaying one from Home took as long as
    /// hearing it the first time. What decides the route is whether there are
    /// bytes to play, not where they originally came from.
    public func isStandaloneOnline(_ track: Track) -> Bool {
        track.isOnline && !engine.canPlayLocally(track)
    }

    /// Play an online track that is not part of the active online context
    /// (e.g. replayed from history / recently-played / home). Rebuilds an
    /// OnlineTrack from the stored Track and plays it through the coordinator,
    /// so it resolves & streams correctly instead of hitting the local-file path.
    public func playStandaloneOnline(_ track: Track, context: [Track]) async {
        // Rebuild OnlineTracks so next/prev works like a fresh session. The minted
        // Track has no artworkURL/sourceID, so reconstruct from title/artist/album/
        // duration; artwork rides along from the already-loaded data.
        let onlineCtx: [OnlineTrack] = mixMainActivity("online/context-form") {
            context.map(Self.onlineForm)
        }
        let target = Self.onlineForm(track)
        // A context like Home's "Jump back in" mixes Discover songs with library
        // songs the user already owns. Keep the ordering intact, but remember
        // which slots have their own audio so we play the user's file instead of
        // re-resolving the song from the internet.
        //
        // Only the tapped song is decided here. Working the whole context out up
        // front is what made pressing play on Favourites take a second and a
        // half before the resolver was even asked: `canPlayLocally` is
        // `AudioLocator.locate`, which is several filesystem probes per track,
        // and it ran two thousand times on the main actor between the press and
        // the first line of work that leads to sound. Nothing needs the other
        // slots yet — they are consulted when playback reaches them, which is
        // minutes away — so the rest is filled in behind the resolve.
        //
        // Normally the tapped track is not a substitute — callers route here when
        // it has no audio of its own. Checked rather than assumed: a caller that
        // decides on origin instead of capability would otherwise have this
        // re-download a song already on this disk, and the check costs nothing.
        var substitutes: [String: Track] = [:]
        substitutes[target.id] = engine.canPlayLocally(track) ? track : nil
        // Started before `beginSession`, and safe to be: the pass suspends on its
        // first line, while `beginSession` runs synchronously as far as its own
        // `await`, so the assignment of `localSubstitutes` always lands first and
        // the pass merges into it rather than being overwritten by it.
        fillLocalSubstitutes(for: onlineCtx, originals: context)
        await beginSession(target, context: onlineCtx,
                           artworkData: track.artworkData,
                           localSubstitutes: substitutes)
    }

    /// Works out which of the remaining context slots the user already owns, in
    /// chunks, off the press path.
    ///
    /// Deliberately still on the main actor — `AudioLocator` and the caches it
    /// consults are — but yielding every hundred tracks, so the pass shows up as
    /// a series of short slices the run loop can draw between instead of one
    /// long block. It starts before `beginSession` and runs alongside a resolve
    /// that takes seconds, so it has finished long before the session can reach
    /// a slot it decides.
    ///
    /// Merged rather than assigned: `beginSession` writes the tapped song's own
    /// entry, and the display mirror is republished once at the end so any slot
    /// that turned out to be a library track shows that track's own artwork.
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

    /// The `OnlineTrack` form of a library/history `Track` — what the resolver
    /// needs to look the song up again.
    private static func onlineForm(_ track: Track) -> OnlineTrack {
        // `identityTitle`, so the rebuilt `OnlineTrack` lands on the same id,
        // the same `cacheStem` and the same search query the song was saved
        // under. Handing it `track.title` split every feature-credited song in
        // two: the copy already on disk was filed under one key and looked for
        // under another.
        OnlineTrack(
            title: track.identityTitle,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration,
            // Carried, not defaulted. Dropping it here is what made every play
            // from the library resolve as if the song were clean, whatever the
            // catalogue said when it was saved.
            isExplicit: track.isExplicit
        )
    }

    /// Fetch cover art for the queue-display mirror in the background, so the
    /// Queue panel shows album covers for upcoming online tracks (`asTrack()`
    /// builds them artwork-less). Results are merged and the mirror re-pushed once.
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
                // Covers usually land while the clicked song is still resolving,
                // which is exactly when this must not reach the player bar.
                self.publishDisplayQueue()
            }
        }
    }

    /// Step forward through the current online context, downloading the next
    /// track on demand. Installed on the engine as `onlineNextHandler`, so it
    /// fires for the next button, F9 / Cmd-Right, and end-of-track auto-advance.
    public func playNextInContext() async {
        // Repeat is a property of the queue, not of where its songs came from —
        // an online session used to walk straight off the end of a context the
        // user had set to loop, because only the local queue consulted it.
        if engine.queue.repeatMode == .one, context.indices.contains(contextIndex) {
            await playFromContext(at: contextIndex)
            return
        }
        // The repeating group can end before the context does: rows dragged
        // below the boundary are queued for after repeat is switched off, so the
        // loop turns around at the boundary rather than at the last row.
        // Mirror positions are context positions, so the index carries over.
        let lastLooping = engine.queue.repeatBoundaryIndex ?? context.count - 1
        if engine.queue.repeatMode == .all, !context.isEmpty, contextIndex >= lastLooping {
            await playFromContext(at: 0)
            return
        }
        guard contextIndex + 1 < context.count else {
            // End of context — hand control back to the engine and stop.
            engine.clearOnlineContext()
            engine.stopPlayback()
            nowPlayingID = nil
            playingSlot  = -1
            return
        }
        await playFromContext(at: contextIndex + 1)
    }

    /// Move past a song that isn't out there, without punishing the song that
    /// is currently making noise.
    ///
    /// The old path went through `playNextInContext()`, which stops playback at
    /// the end of the context — correct when a queue has genuinely finished,
    /// wrong here. Pressing play on an unfindable song in a one-song context
    /// therefore killed whatever was playing and rewound it to 0:00: the user
    /// asked for a song that doesn't exist and lost the one that does. With
    /// nowhere to go, the session simply lets go and leaves the audio alone.
    private func skipUnfindable(from index: Int) async {
        guard index + 1 < context.count else {
            engine.clearOnlineContext()
            nowPlayingID = nil
            playingSlot  = -1
            return
        }
        await playFromContext(at: index + 1)
    }

    /// The song with its guests and its cover filled in from Deezer's track
    /// record, when the listing it came from carried neither.
    ///
    /// The type-ahead dropdown is the case that needs it: its rows are built to
    /// be shown, not played, so a song tapped straight out of it arrives with an
    /// empty credit and, when its thumbnail URL misses, nothing to draw. The id
    /// is derived from title|artist and neither of those changes here, so the
    /// enriched copy is the same song to every key in the session.
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
    public func playPreviousInContext() async {
        guard contextIndex - 1 >= 0 else { return }
        await playFromContext(at: contextIndex - 1)
    }

    /// Resolve (cache hit / in-flight prefetch / fresh download) the track at
    /// `index` in the current context and play it through the engine, honouring
    /// the playToken race guard so rapid skips don't fight each other. Once
    /// playing, installs the skip handlers on the engine and prefetches the next
    /// neighbour so the following skip-forward is fast.
    /// `skippingUnfindable` is false when the user pressed this exact row: a
    /// song the app failed to find an hour ago is still worth one more search if
    /// someone asks for it by hand. Reaching it by playing through the queue is
    /// the case that skips.
    private func playFromContext(at index: Int, artworkData: Data? = nil,
                                 skippingUnfindable: Bool = true) async {
        guard context.indices.contains(index) else { return }
        startingCount += 1
        defer { startingCount -= 1 }
        // Fill in the credit and the cover the listing this came from didn't
        // carry, before anything is built out of it. `enriched` keeps the id
        // (title|artist), so the slot, its lane and any substitute still match.
        let result = await enriched(context[index])
        guard context.indices.contains(index) else { return }
        context[index] = result

        // Already known to be nowhere: don't spend seconds proving it again with
        // the music stopped. Say which song was dropped and move on — silence
        // with no explanation is what this whole path exists to avoid.
        if skippingUnfindable, localSubstitutes[result.id] == nil,
           UnavailableTracks.shared.contains(title: result.title, artist: result.artistName) {
            UnavailableTracks.shared.mark(title: result.title, artist: result.artistName,
                                          announce: true)
            contextIndex = index
            await skipUnfindable(from: index)
            return
        }
        let artwork = artworkData ?? (contextArtworkID == result.id ? contextArtwork : nil)

        // What the engine was playing when this resolve started. Finding a song
        // online takes seconds, and in those seconds the user can play
        // something else — a library row, a song from Recently played. The play
        // token only knows about clicks *inside* this coordinator, so without
        // this a resolve that started first would still hand its song to the
        // engine at the end, cutting off whatever the user actually chose and
        // publishing its own queue over the live one. `engine.playbackGeneration`
        // moves on every load from anywhere, so a change means someone else owns
        // the player now and this resolve's only remaining job is to leave the
        // downloaded file in the cache.
        var entryGeneration = engine.playbackGeneration
        func takenOver() -> Bool { engine.playbackGeneration != entryGeneration }

        // One resolve per song at a time. A Discover row plays on a single click
        // of its artwork and on a double click of the row, so double-clicking the
        // artwork delivers both and this ran twice — two searches, two stream
        // extractions, ~660ms of extra wall clock, and one whole result thrown
        // away by the play token. The token makes the duplicate harmless, not
        // free: the second yt-dlp pair still runs to completion, competing for
        // bandwidth with the buffer the user is waiting on.
        //
        // Keyed on the song, not a flag, so clicking a *different* row still
        // supersedes normally — that's what playToken is for.
        guard resolvingTrackID != result.id else { return }
        resolveRun &+= 1
        let run = resolveRun
        resolvingTrackID = result.id
        defer { if resolveRun == run { resolvingTrackID = nil } }

        ResolveTrace.shared.begin(result.searchQuery)

        // This slot is a song the user already owns — play their file and skip
        // resolution entirely. Re-checked here (not just when the session was
        // built) because the file could have gone away since.
        if let local = localSubstitutes[result.id] {
            if engine.canPlayLocally(local) {
                guard !takenOver() else { return }
                playToken &+= 1
                await startLocalPlayback(local, index: index, token: playToken)
                return
            }
            // File vanished — fall through and resolve it online like any other.
            localSubstitutes[result.id] = nil
        }

        // Kick off lyrics resolution in parallel with the audio download so they're
        // cached by the time Now Playing opens. Best-effort — never blocks playback.
        LyricsService.shared.prefetch(for: result.asTrack(deviceID: deviceID))

        playToken &+= 1
        let token = playToken
        resolvingID = result.id
        defer { if token == playToken { resolvingID = nil } }

        // Down on every exit from here — the song started, it failed, or a newer
        // click took over. A bar left standing over a song that is already
        // playing is worse than no bar at all.
        defer { if token == playToken { endPreparing(result.id) } }

        // Cache hit — but validate duration first to catch a stale music-video pick.
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
                // Wrong version cached — delete and re-download.
                PlaybackCache.remove(forSourceRef: result.id)
                prefetchTasks.removeValue(forKey: result.id)
            }
        }

        // Progressive streaming: for a cold track, ask the resolver for a stream URL
        // (server ensures the file exists, then range-serves it) so AVPlayer starts
        // on the first buffer instead of waiting for the whole download. We still
        // fill the on-disk cache in the background for replay / Add to Library.
        // A resolver that can't stream returns nil and we fall through.
        //
        // A prefetch already running for this track used to veto this whole
        // branch, on the theory that work in flight is work worth waiting for.
        // Measured, it is the opposite: reaching this line means the cache probe
        // above missed, so the download is *unfinished*, and waiting out its last
        // byte cost 6285ms where streaming the same song took 3652ms.
        //
        // So stream instead — but resolve first and only then stand the prefetch
        // down, because a stream resolve can come back empty and a prefetch
        // cancelled before we knew that is progress thrown away for nothing.
        // Set when a stream was resolved but never produced audio: the video is
        // known, so the fallback download below skips the search pass.
        var deadStreamVideoID: String?

        // Past this line the song is genuinely cold: nothing on disk, and every
        // route from here takes seconds the user is going to sit through.
        //
        // Which makes this the moment guessing has to give way. Anything still
        // being fetched on spec is holding a resolver slot the tap needs more,
        // and `warmAfterPlayback` starts the queue filling again as soon as this
        // song is audible — so nothing is lost but a few seconds of a download
        // that was never asked for.
        standDownSpeculativeWork(except: result.id)
        beginPreparing(result)

        // The video this song resolved to last time, if it has ever resolved.
        // `recordVideoID` has been writing this index down all along — on every
        // stream, every warm and every completed download — and nothing was
        // reading it back on the path where it would save the most: the search
        // is the larger half of a cold resolve. Withheld when the user has
        // rejected that video, or "wrong version" would stop being fixable.
        let known = videoIDIndex[result.id]
        let pinned = known.flatMap { exclusions(for: result.id).contains($0) ? nil : $0 }

        if let stream = try? await ytdlp.resolveStream(query: result.searchQuery,
                                                       expectedDuration: result.duration,
                                                       preferExplicit: result.isExplicit,
                                                       excluding: exclusions(for: result.id),
                                                       pinnedVideoID: pinned) {
            guard token == playToken else { return }
            ResolveTrace.shared.mark("stream resolve TOTAL")
            // Cancelling now genuinely stops the yt-dlp child, so it stops
            // competing for bandwidth with the buffer we're about to fill.
            // `warmAfterPlayback` restarts it as a cache fill — pinned to the
            // video actually playing — once the audio is audible.
            if let inFlight = prefetchTasks.removeValue(forKey: result.id) {
                inFlight.cancel()
                ResolveTrace.shared.mark("prefetch stood down for stream")
            }
            recordVideoID(stream.videoID, for: result.id)
            // The search is over and bytes are moving, even though AVPlayer is
            // the one moving them and won't say how many. The bar stops saying
            // "finding audio" for a song that has already been found.
            updatePreparing(result.id, ResolveProgress(phase: .downloading, fraction: nil))
            guard !takenOver() else { return }
            await startStreaming(result, stream: stream, index: index, artwork: artwork, token: token)
            // Our own handoff moved the generation on; re-baseline, or the
            // download fallback below would read this as somebody else's play.
            entryGeneration = engine.playbackGeneration
            ResolveTrace.shared.mark("engine handoff (stream)")

            // Handing the URL to AVPlayer is not the same as playing it, and
            // until now nothing here knew the difference. A resolve that came
            // back fine could still be a 403 — the resolver never fetches the
            // URL, AVPlayer does — and when that happened the engine simply sat
            // in `.loading` forever: a spinner over a song that was never going
            // to start, with no error and no retry.
            //
            // What eventually produced audio was an accident. `warmAfterPlayback`
            // gave up waiting after 8s and started its *cache fill*, which
            // downloaded the song at background priority and put it on disk
            // without ever playing it — so the track only played when the user
            // gave up, skipped away, and came back to a warm cache. Sixteen
            // seconds of nothing, then instant on the second try.
            //
            // So wait for the stream to prove itself, and fall through to the
            // download if it doesn't.
            // AVPlayer is now the thing moving bytes, and it does say how many:
            // the loaded range of the item is literally how much of the song is
            // on the device. Poll it while we wait, so the bar on a streaming
            // play fills like a download instead of sweeping like a spinner.
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
                // The resolver picked the source; it's the only thing that can
                // stop picking it. Without this the same client is asked again
                // on the very next line, and again on the next play.
                await ytdlp.noteStreamUnplayable(videoID: stream.videoID)
                deadStreamVideoID = stream.videoID
            }
        }

        // Reuse the hover-prefetch task if running, else start a fresh download.
        //
        // Except after a dead stream, which supersedes any prefetch: that
        // prefetch was cancelled when the stream resolved, and it searched for
        // the video this path already knows the id of.
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
            // Same known-video shortcut the stream resolve above takes: this
            // path also ran the full search to arrive at an id already on disk.
            downloadTask = makeDownloadTask(for: result, pinnedVideoID: pinned)
            prefetchTasks[result.id] = downloadTask
            reusedPrefetch = false
        }

        // Both of these are already mid-flight or skip the search, so the bar
        // would otherwise still be showing whatever step it was on. Say
        // "downloading" now; the reporter attached to the task overwrites this
        // with a real percentage on its next line.
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
            // A press must never inherit a speculative task's failure. The
            // prefetch may have failed long before the user asked for anything,
            // or been cancelled by something that has nothing to do with this
            // tap — and either way the honest answer to "play this" is to go and
            // fetch it, not to report an error about work the user never
            // requested. The eviction above makes this rare; this makes it
            // impossible, including for the races it cannot cover.
            //
            // Only for a reused task, and only once: a fresh download that fails
            // has genuinely failed, and retrying it in a loop is how a dead song
            // becomes a hang.
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
                        // Straight on to the next song. Stopping dead on a song
                        // that does not exist is the failure the badge is
                        // warning about; having warned, don't then do it.
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
                if token == playToken, !takenOver() { await skipUnfindable(from: index) }
            } else if token == playToken {
                setError(userFacingPlaybackMessage(for: error, title: result.title))
            }
            ResolveTrace.shared.end("FAILED — \(error.localizedDescription)")
        }
        prefetchTasks.removeValue(forKey: result.id)
    }

    /// Play a context slot that's backed by a library track the user already owns.
    /// Same wiring as `startPlayback` — engine plays it from its own file, then we
    /// re-mirror the queue and reinstall the skip handlers so next/previous keep
    /// walking this context — but nothing is resolved or downloaded.
    private func startLocalPlayback(_ local: Track, index: Int, token: Int) async {
        contextIndex = index
        await engine.play(track: local, in: [local], resolved: true)
        guard token == playToken else { return }

        // engine.play() reset the queue to this one track — re-mirror the context.
        playingSlot = index
        awaitingHandoff = false
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks[index] = local
        }
        publishDisplayQueue()

        // No *online* track is playing, so Discover shows nothing as current and
        // the player bar doesn't offer "Add to Library" for a song already in it.
        nowPlayingID = nil

        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

        // Warm the next neighbour unless it's another local file (nothing to warm).
        if context.indices.contains(index + 1) {
            let next = context[index + 1]
            if localSubstitutes[next.id] == nil { prefetch(next) }
        }
    }

    /// Play an already-downloaded context track, update the index, reinstall the
    /// skip handlers (engine.play clears them), and warm the next neighbour. If we
    /// have no artwork yet but the track has a URL, fetch it first so every track
    /// shows a cover; `token` is re-checked after that await so a newer click can't
    /// be clobbered by a stale fetch.
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

        // No localPath: the file behind this song is a cache entry, and a cache
        // entry is not where a library row should point. Storing that path is
        // what made a saved Discover song "lose" its audio the moment the budget
        // evicted it — the row still named a file that wasn't there any more.
        // `AudioLocator` finds the cached copy from the song's own key instead.
        let track = result.asTrack(artworkData: artwork, deviceID: deviceID)
        contextIndex = index
        // `resolved:` — this call is the end of a resolve the engine itself
        // started, so it must not be turned away by the guard that stops a
        // second click on a song already downloading.
        await engine.play(track: track, in: [track], resolved: true)

        // engine.play() reset the queue to this one track. Re-mirror the full
        // context (with the fully-built track in the playing slot) so the Queue
        // panel shows NOW PLAYING + NEXT UP.
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

        // Warm the next neighbour so the following skip-forward is near-instant.
        // Slots backed by a library file have nothing to download.
        if context.indices.contains(index + 1) {
            let next = context[index + 1]
            if localSubstitutes[next.id] == nil { prefetch(next) }
        }
    }

    /// Streaming version of startPlayback: progressive AVPlayer playback with no
    /// full download, but the same context wiring so it behaves like a cached
    /// track. The cache fill runs separately and the row doesn't name it — see
    /// `startPlayback` for why a cache path never belongs in `localPath`.
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

        // engine cleared/reset the queue — re-mirror the full online context.
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

        // The next-neighbour warm that used to live here is deferred with the
        // rest of the speculative work — see warmAfterPlayback.
    }

    /// Speculative work that follows a stream: filling the on-disk cache from
    /// the video now playing, and warming the next track in the context. Held
    /// back until this song is actually audible.
    ///
    /// Both are downloads, and starting them the moment the URL reached
    /// AVPlayer meant three transfers pulling at once during the exact window
    /// the first buffer had to land in. A trace showed 2103ms from handoff to
    /// audio where the network alone needed ~350ms, with a whole competing
    /// search for the *next* song running inside that gap. Neither job is
    /// urgent — the next track isn't needed for another three minutes, and the
    /// cache copy only matters on a replay. The buffer is the only urgent
    /// thing, and it was the one being starved.
    private func warmAfterPlayback(cacheFillFor result: OnlineTrack,
                                   pinnedVideoID: String,
                                   token: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.engine.waitUntilPlaying(timeout: Self.warmupDeadline)
            // A skip while we waited: that song's own warm-up now owns the
            // bandwidth, and this one's next-neighbour is no longer next.
            guard token == self.playToken else { return }

            if self.prefetchTasks[result.id] == nil, self.cacheURL(for: result) == nil {
                let fill = self.makeDownloadTask(for: result,
                                                 priority: .background,
                                                 pinnedVideoID: pinnedVideoID)
                self.prefetchTasks[result.id] = fill
                // Evicted if it fails, for the same reason as `preload`: a task
                // left here having already thrown is a failure waiting to be
                // handed to the next press on this song.
                Task { [weak self] in
                    do { _ = try await fill.value }
                    catch { self?.prefetchTasks.removeValue(forKey: result.id) }
                }
            }
            // As many of the songs after this one as the user asked for. The
            // depth is a ceiling rather than a promise: `preload` still refuses
            // anything already cached and still respects the concurrency cap,
            // so a deep queue fills in order rather than all at once — each
            // finishing prefetch pulling in the next.
            self.topUpQueuePrefetch()
        }
    }

    /// How long to hold speculative work waiting for audio. Past this the
    /// stream is stalled or dead, and the cache fill is the better bet anyway —
    /// it's what the fallback download would have produced.
    private static let warmupDeadline: TimeInterval = 8

    /// How long a stream gets to start before the download takes over.
    ///
    /// Only reached by a stream that is stalling rather than refusing — a
    /// rejected URL reports itself in a few hundred milliseconds and doesn't
    /// wait this out. So it's set against the slowest *honest* start measured
    /// (2103ms from handoff to audio, on a first buffer competing with two other
    /// transfers) with room on top, rather than against a 403.
    private static let streamStartDeadline: TimeInterval = 5

    // MARK: - Add to Library

    /// Save `result` to the library as a placeholder: metadata, artwork, album
    /// and artist, and the key needed to resolve the audio again. No file is
    /// copied and nothing is uploaded.
    ///
    /// This is what "add to library" means everywhere else and what the user
    /// asked for here. It used to download the song, copy it into the imports
    /// directory as though the user had imported it themselves, and then upload
    /// that copy to Supabase — so saving a song took as long as downloading it,
    /// spent the user's storage quota on audio the resolver can produce again in
    /// seconds, and left a row that claimed to be a permanent local file. The
    /// permanent copy is a separate, deliberate action: Download for offline
    /// listening, which is the only thing that should cost disk.
    ///
    /// Because the row carries only metadata, it syncs, so the song appears in
    /// the library on the user's other devices and resolves there too.
    public func addToLibrary(_ result: OnlineTrack, albumOnly: Bool = false) async {
        if albumOnly {
            SavedAlbumsService.shared.markAlbumOnly(result.stableTrackID, title: result.albumTitle, artistName: result.artistName)
        } else {
            SavedAlbumsService.shared.promote(result.stableTrackID)
        }
        defer { if !albumOnly { importService.libraryService.saveToLibrary(trackID: result.stableTrackID) } }
        resolvingID = result.id
        defer { resolvingID = nil }

        // A track replayed from Home/history has no artworkURL (rebuilt from a
        // snapshot) but already carries artwork on its display Track — pass it
        // through so the saved song keeps a cover.
        let loadedArtwork = contextDisplayTracks.first { $0.id == result.stableTrackID }?.artworkData
            ?? (result.id == nowPlayingID ? engine.queue.currentTrack?.artworkData : nil)

        _ = await importService.saveOnlineTrack(
            sourceRef: result.id,
            // Same identity the display track has been using all along, so
            // "already in my library?" keeps answering correctly after the save.
            id: result.stableTrackID,
            // The reconstructed title, so the library row is called what the
            // record is called — see `OnlineTrack.displayTitle`.
            title: result.displayTitle,
            artistName: result.artistName,
            albumTitle: result.albumTitle,
            duration: result.duration,
            artworkURL: result.artworkURL,
            artworkData: loadedArtwork,
            isExplicit: result.isExplicit
        )
    }

    // MARK: - Queue (Discover context menu)

    /// Insert `result` immediately after the current track.
    ///
    /// During an online session the engine's queue is only a display mirror —
    /// navigation walks `context` — so inserting into the queue there would be
    /// wiped by the next re-mirror and never play. Instead the track joins the
    /// context itself (downloaded on demand when reached, like any neighbour).
    /// Outside an online session, download and insert into the real local queue.
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

    /// Append `result` to the end of the queue (online context or local queue —
    /// same routing rationale as `playNext(_:)`).
    ///
    /// `manual` is false for the queue's own top-ups, which arrive here after a
    /// download: those belong in the recommendation lane, below both the user's
    /// own queued songs and the rest of the session.
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

    /// Append a whole mix or playlist of online songs to the queue.
    ///
    /// Not `addToQueue(_:)` in a loop, for two reasons. The single-song path
    /// warms the cache before it appends, so a 24-song mix meant 24 serial
    /// downloads before the last row appeared — the menu item looked like it had
    /// done nothing at all for minutes. And each song published the queue
    /// separately, rebuilding the Queue panel once per track. Here the rows land
    /// immediately (a queued row carries no file path either way — it is
    /// resolved when the queue reaches it) and the covers are filled in behind
    /// them.
    ///
    /// `lane` is `.manual` for the menu item and `.recommendation` for the
    /// queue's own top-ups, which come here as one batch for the same reason a
    /// mix does: appended one at a time, each landing rewrote the queue again.
    public func addToQueue(_ results: [OnlineTrack], lane: QueueOrigin = .manual) async {
        guard !results.isEmpty else { return }
        if hasActiveOnlineSession {
            insertIntoContext(contentsOf: results, lane: lane)
            return
        }
        // Songs already in the queue are appended again rather than skipped.
        // Queue rows carry their own identity, so a song can appear as many
        // times as it was asked for and each row is independently playable.
        engine.queue.append(contentsOf: results.map { $0.asTrack(deviceID: deviceID) }, lane: lane)
        await fillQueueArtwork(for: results)
    }

    /// "Add to Queue" for library songs — a playlist page, or a selection in one.
    ///
    /// Outside an online session this is just an append. Inside one the engine's
    /// queue is only a display mirror, so an append there would be wiped by the
    /// next push; the songs join the context instead, each registered as its own
    /// local substitute so it plays from the file the user already has rather
    /// than being resolved from the internet again.
    public func addToQueue(localTracks tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard hasActiveOnlineSession else {
            engine.queue.append(contentsOf: tracks)
            return
        }
        var additions: [OnlineTrack] = []
        var subs: [String: Track] = [:]
        for track in tracks {
            let online = Self.onlineForm(track)
            if engine.canPlayLocally(track) { subs[online.id] = track }
            additions.append(online)
        }
        localSubstitutes.merge(subs) { _, new in new }
        // At the end of the user's own queued run, not the end of the list —
        // songs added by hand play before the rest of the session.
        let at = contextInsertionIndex(for: .manual)
        contextLanes = alignedContextLanes()
        context.insert(contentsOf: additions, at: at)
        contextDisplayTracks.insert(contentsOf: tracks, at: min(at, contextDisplayTracks.count))
        contextLanes.insert(contentsOf: additions.map { _ in .manual }, at: at)
        if at <= playingSlot  { playingSlot  += additions.count }
        if at <= contextIndex { contextIndex += additions.count }
        publishDisplayQueue()
    }

    /// "Add to Library" for a row the library doesn't hold — a queue row, a
    /// history row, anything that is a display mirror of a Discover song rather
    /// than a saved one. There's no library id to flag, so the online form is
    /// rebuilt and saved; the live context's own copy wins when it has one, so
    /// the already-resolved source id rides along instead of being searched for
    /// again.
    public func addToLibrary(unsaved track: Track) async {
        // `contextDisplayTracks` pairs with `context` by position, so a queue
        // row taken from the live session finds its own online track — the one
        // that already knows its source id and artwork URL. Failing that, by
        // rebuilt id, and failing that the rebuild itself.
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

    /// "Clear queue" — drop everything after the song playing, from whichever
    /// list is really driving playback.
    ///
    /// During an online session the engine's queue is only a mirror of the
    /// context, so truncating it there would last exactly until the next push;
    /// the context itself is what has to shrink.
    public func clearUpcomingQueue() {
        // Same for the online path: without this the suggestion service refills
        // the context it just emptied.
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

    /// "Clear added songs" — drop only the rows the user queued by hand, from
    /// whichever list is driving playback. The list they are playing from stays.
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

    /// Remove one upcoming row from whichever list is driving playback. Returns
    /// false when the row can't be removed (out of range, or it's the song
    /// currently playing).
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

    /// Reorder one row of whichever list is driving playback — the queue panel's
    /// drag. `destination` uses the same insertion-index-before-removal
    /// semantics as `QueueService.moveQueueItem(from:to:)`.
    ///
    /// During an online session the engine's queue is only a mirror, so a move
    /// applied there would be wiped by the next push: the context, its display
    /// tracks and its manual flags all move together here instead.
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

        // The audible slot and the browsing index both name positions, so both
        // follow the row they were pointing at across the move.
        playingSlot  = Self.shiftedIndex(playingSlot,  from: source, to: target)
        contextIndex = Self.shiftedIndex(contextIndex, from: source, to: target)

        // A row dropped into another lane joins it — the same rule the local
        // queue uses, and for the same reason: a "Next in queue" row sitting
        // inside the "Next up: …" section is a list contradicting its own
        // headings. The row above decides (a drop lands after what it was
        // dropped onto); at the very top of the upcoming list the row below does.
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

    /// Splice `results` into the live context in `lane`'s place, and refresh the
    /// display mirror — the bulk form of `insertIntoContext(_:at:prefetchNow:lane:)`.
    /// Takes what it is given: a song asked for twice is queued twice, and
    /// callers that don't want that (suggestions) filter first.
    private func insertIntoContext(contentsOf results: [OnlineTrack], lane: QueueOrigin) {
        guard !results.isEmpty else { return }
        let at = contextInsertionIndex(for: lane)
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

    /// Download cover art for rows appended straight to the local queue and
    /// patch it in as it arrives. Best-effort and unordered: a missing cover is
    /// a grey square, never a reason for the song not to be queued.
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

    /// Splice `result` into the active online context at `index` and refresh the
    /// display mirror. `prefetchNow` warms the cache immediately (used for
    /// "Play Next", where the track is about to be reached).
    private func insertIntoContext(_ result: OnlineTrack, at index: Int,
                                   prefetchNow: Bool, lane: QueueOrigin = .manual) {
        let idx = max(0, min(index, context.count))
        contextLanes = alignedContextLanes()
        context.insert(result, at: idx)
        contextDisplayTracks.insert(result.asTrack(deviceID: deviceID),
                                    at: min(idx, contextDisplayTracks.count))
        // Almost everything that reaches here is a Play Next / Add to Queue on
        // one song; only the queue's own top-ups arrive in another lane.
        contextLanes.insert(lane, at: idx)
        // A row spliced in above them pushes both position markers down.
        if idx <= playingSlot  { playingSlot  += 1 }
        if idx <= contextIndex { contextIndex += 1 }
        // Through the guard, not around it: an unguarded push here painted a
        // still-resolving slot's title and cover over the song actually playing.
        publishDisplayQueue()
        loadDisplayArtwork()
        // "Play next" is a queued song, not a browsed one — it doesn't answer
        // to the browsing preference.
        if prefetchNow { preload(result) }
    }

    /// Shared body for playNext / addToQueue: put the row in the queue, then warm
    /// the cached file and fill the cover in behind it.
    ///
    /// The row goes in *first*, before any network work. Warming first meant a
    /// song queued from search took as long to appear in the Queue panel as it
    /// took to download — several seconds of a menu item that looked like it had
    /// done nothing, and queueing the same song three times showed one row, then
    /// two, then three, minutes apart. Nothing depends on the warm having
    /// finished: a queued row carries no file path either way (see
    /// `startPlayback`), so it resolves when the queue reaches it.
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

        // Warming is best-effort, and a failure here is explicitly not an error
        // to show. This used to raise an alert, which is where "couldn't find
        // song" came from *while a different song was playing perfectly well*:
        // the user queued something, kept listening, and a background resolve
        // for a song they hadn't reached yet interrupted them — naming neither
        // the song nor anything they could act on.
        //
        // Nothing is lost by continuing. The queued row carries no file path
        // either way (see `startPlayback`), so it is resolved when the queue
        // actually reaches it — and that is the path that gets to report a
        // real failure, about the song then playing.
        _ = try? await resolveCachedFile(for: result)
    }

    // MARK: - Helpers

    /// Resolve `result` to an on-disk cache file, reusing work: cache hit returns
    /// immediately, an in-flight prefetch is awaited rather than restarted, else a
    /// fresh download. Shared by addToLibrary / playNext / addToQueue. Returns the
    /// file plus its resolved videoID.
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

    /// True if the cached file's runtime is within ~20 s of the canonical iTunes
    /// length (or if we have no canonical length, trust the cache).
    private static func cachedDurationMatches(_ url: URL, expected: TimeInterval) async -> Bool {
        guard expected > 0 else { return true }
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return true }
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite, secs > 0 else { return true }
        return abs(secs - expected) <= 20
    }

    // MARK: - Cache eviction (LRU)

    /// Keep the cache inside the user's budget, pinning whatever is playing now
    /// and whatever plays next so eviction can never take the file out from
    /// under the player. Called after a download completes (never on the hot
    /// play path before playback).
    ///
    /// The budget itself and the eviction order live in `PlaybackCache` — this
    /// only supplies the one thing the cache can't know, which is what the
    /// player is currently holding on to.
    /// How far either side of the playhead the pin window reaches. Ahead is
    /// larger because that is the direction playback actually moves; behind
    /// exists only so an immediate skip-back doesn't re-download.
    private static let cachePinWindowAhead  = 5
    private static let cachePinWindowBehind = 2

    private func enforceCacheBudget() {
        // Split in two because the halves are slow for unrelated reasons and a
        // single number could never say which: the pin scan asks the filesystem
        // a question per queued song, and the eviction pass stats every file in
        // the cache directory. Both run here, on the main actor, every time a
        // download finishes.
        var pinned = Set<URL>()
        mixMainActivity("online/cache-budget ▸ pin-scan") {
            // A window around the playhead, not the whole queue. This used to
            // walk every queued song, and `readyURL` asks the filesystem up to
            // six questions per track — on a 2,000-song context that is twelve
            // thousand `stat` calls on the main actor, measured at 1.3 seconds,
            // once per completed download. It was the post-play stall.
            //
            // The window is the honest size of the question. Pinning only
            // protects a file from the cache's LRU eviction, and the only files
            // that can plausibly be evicted before they're wanted are the ones
            // about to be played — the current song and its immediate
            // neighbours. A song four hundred rows away losing its cached copy
            // costs a re-download it was going to need anyway, and it was never
            // safe to rely on the pin: the budget can evict it the moment the
            // window moves on, seconds later. Behind as well as ahead, because
            // skip-back is a normal thing to do.
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
            // The next context slot is about to be fetched; don't evict what we
            // just prefetched for it.
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

    /// Generation counters so a stale auto-clear task can't wipe a newer message.
    private var errorGeneration = 0
    private var statusGeneration = 0

    // MARK: - Preparing state

    private func beginPreparing(_ result: OnlineTrack) {
        // Scope the main-actor cost table to this one play, so the report printed
        // a few seconds after the song is audible describes the press the user
        // just made and nothing before it.
        MainThreadActivity.shared.resetCosts()
        preparing = PreparingTrack(id: result.id,
                                   title: result.title,
                                   artist: result.artistName,
                                   progress: ResolveProgress(phase: .searching, fraction: nil))
    }

    /// Ignores anything that isn't about the song on screen — a cache fill that
    /// finishes late must not repaint the bar for the track playing now.
    private func updatePreparing(_ trackID: String, _ step: ResolveProgress) {
        guard var current = preparing, current.id == trackID else { return }
        // Progress that goes backwards is yt-dlp starting a second attempt with
        // a different client; the bar staying put reads better than it resetting.
        if case .downloading = step.phase,
           case .downloading = current.progress.phase,
           let new = step.fraction, let old = current.progress.fraction, new < old {
            return
        }
        current.progress = step
        preparing = current
    }

    /// Abandon the song currently being prepared.
    ///
    /// Bumping `playToken` is what actually stops the work: every stage of the
    /// resolve re-checks it and returns, so the flow unwinds at its next
    /// checkpoint rather than running to completion and playing a song the user
    /// has already said they don't want. The in-flight download is cancelled
    /// outright — nothing else is waiting on it once the play is abandoned.
    ///
    /// Deliberately silent. The user asked for this one, and a card that
    /// vanishes has already said everything an error banner would.
    public func cancelPreparing() {
        guard let current = preparing else { return }
        playToken &+= 1
        resolvingID = nil
        // Release the one-resolve-per-song claim as well. The abandoned flow
        // holds it until it reaches its next token check, which for a stalled
        // yt-dlp search can be a long way off — and until then every attempt to
        // play this song again was silently dropped at the guard above, which
        // is what left the user stuck on it. Bumping the run first means that
        // flow's own `defer` can no longer take the claim back off a retry.
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

    /// Briefly surface a non-error status message, then auto-clear it.
    private func flashStatus(_ message: String) {
        statusMessage = message
        statusGeneration &+= 1
        let generation = statusGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.statusGeneration == generation else { return }
            self.statusMessage = nil
        }
    }
}
