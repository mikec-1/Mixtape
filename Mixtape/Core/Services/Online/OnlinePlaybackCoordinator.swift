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

    private let ytdlp:         any TrackResolver
    private let engine:        PlaybackEngine
    private let importService: ImportService
    private let deviceID:      String

    /// Incremented on every play() call. A slow download checks this before
    /// starting playback and aborts if a newer click has superseded it —
    /// fixes the "click B while A loads, A plays" race.
    private var playToken = 0

    /// Active download Tasks keyed by OnlineTrack.id.
    /// Inserted by prefetch(); reused or replaced by play(); removed on completion.
    /// Each yields the DownloadResult so the resolved videoID can be recorded.
    private var prefetchTasks: [String: Task<ResolvedAudio, Error>] = [:]

    /// Persistent map OnlineTrack.id → resolved YouTube videoID, so the cache is
    /// keyed by the *actual* video (an explicit upload and a clean one of the same
    /// song get distinct files). Loaded lazily from cacheDir/index.json.
    private var _videoIDIndex: [String: String]? = nil

    /// The list the current online track was played from (search results, an
    /// album's tracks, or an artist's popular list). Skip / auto-advance step
    /// through this. Empty when no online context is active.
    private var context: [OnlineTrack] = []
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
    }

    // MARK: - Cache paths

    /// Library/Caches/OnlineCache — persists across launches but lives in the
    /// purgeable caches domain (not Documents), and is excluded from backups.
    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        var dir = base.appendingPathComponent("OnlineCache", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Don't let multi-GB of disposable audio bloat the user's backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// Total cache budget (bytes). When exceeded after a download, the
    /// least-recently-accessed unpinned files are evicted down under this.
    private static let cacheBudgetBytes: Int64 = 1_073_741_824 // 1 GB

    /// Cache file for a *resolved* videoID. The file may not exist yet.
    private func cacheURL(forVideoID videoID: String) -> URL {
        Self.cacheDir.appendingPathComponent("\(videoID).m4a")
    }

    /// The existing cached file for `result`, if its videoID is known and the
    /// file is on disk. Nil means "not cached yet — must download".
    func cacheURL(for result: OnlineTrack) -> URL? {
        guard let vid = videoIDIndex[result.id] else { return nil }
        let url = cacheURL(forVideoID: vid)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Path that SupabaseFileStorageService.localURL resolves to the cache file.
    /// The cache lives in Caches, not Documents, so we climb out with `..` —
    /// fileExists and AVURLAsset both resolve the `..` components.
    private func cacheRelativePath(forVideoID videoID: String) -> String {
        "../Library/Caches/OnlineCache/\(videoID).m4a"
    }

    // MARK: - VideoID index (persistent)

    private var indexFileURL: URL { Self.cacheDir.appendingPathComponent("index.json") }

    /// Lazily-loaded in-memory copy of the on-disk videoID index. A missing or
    /// corrupt file yields an empty index rather than crashing.
    private var videoIDIndex: [String: String] {
        get {
            if let cached = _videoIDIndex { return cached }
            let loaded = (try? Data(contentsOf: indexFileURL))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
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

    /// Record the resolved videoID for `trackID` and persist the index.
    private func recordVideoID(_ videoID: String, for trackID: String) {
        var idx = videoIDIndex
        idx[trackID] = videoID
        videoIDIndex = idx
    }

    /// Wipe every downloaded Discover file and the videoID index so everything
    /// re-fetches fresh. Cancels in-flight downloads first. Returns files removed.
    @discardableResult
    public func clearCache() -> Int {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()

        let fm = FileManager.default
        let dir = Self.cacheDir
        var removed = 0
        if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) {
            for url in urls where url.pathExtension == "m4a" {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }

        // Drop the persisted index so stale id → videoID mappings don't resurrect.
        try? fm.removeItem(at: indexFileURL)
        _videoIDIndex = [:]
        return removed
    }

    /// Forget one track's cached source (cancel its download, delete the .m4a, drop
    /// its videoID mapping) so the next play re-resolves it. Fixes a single song
    /// that landed on a wrong upload without nuking the whole cache. Returns true
    /// if a file was removed; safe to call when nothing was cached.
    @discardableResult
    public func clearCache(for result: OnlineTrack) -> Bool {
        prefetchTasks[result.id]?.cancel()
        prefetchTasks.removeValue(forKey: result.id)

        var removed = false
        if let url = cacheURL(for: result) {
            removed = (try? FileManager.default.removeItem(at: url)) != nil
        }

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
        clearCache(for: result)
        flashStatus("Finding a different source for “\(result.title)”…")

        if context.isEmpty {
            await play(result)
        } else {
            await play(result, context: context)
        }

        // The play path records the freshly-resolved videoID. Compare against the
        // one we just cleared to tell the user whether anything actually changed.
        let newVideoID = videoIDIndex[result.id]
        if let newVideoID, newVideoID != previousVideoID {
            flashStatus("Switched to a different version of “\(result.title)”.")
        } else if newVideoID != nil {
            flashStatus("That's the only version we could find for “\(result.title)”.")
        }
        // newVideoID == nil → the play attempt failed; setError already surfaced it.
    }

    // MARK: - Prefetch (hover)

    /// Begin downloading `result` in the background so play() is instant when
    /// the user clicks. Safe to call repeatedly — no-ops if already cached or
    /// a download is already running for this track.
    public func prefetch(_ result: OnlineTrack) {
        guard cacheURL(for: result) == nil else { return }   // already cached
        guard prefetchTasks[result.id] == nil else { return }
        prefetchTasks[result.id] = makeDownloadTask(for: result, priority: .background)
    }

    /// Build a download Task for `result`. On completion it records the resolved
    /// videoID in the persistent index and enforces the cache budget. The Task
    /// value is the full DownloadResult so callers can read the videoID.
    private func makeDownloadTask(for result: OnlineTrack,
                                  priority: TaskPriority = .userInitiated) -> Task<ResolvedAudio, Error> {
        let ytdlp = self.ytdlp
        let query = result.searchQuery
        let stem  = result.cacheStem
        let dir   = Self.cacheDir
        let dur   = result.duration
        let exp   = result.isExplicit
        let trackID = result.id
        return Task(priority: priority) { [weak self] in
            let res = try await ytdlp.download(query: query, name: stem, to: dir, expectedDuration: dur, preferExplicit: exp)
            await MainActor.run {
                self?.recordVideoID(res.videoID, for: trackID)
                self?.enforceCacheBudget()
            }
            return res
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
        self.contextArtwork = artworkData
        // Build the display mirror so the Queue panel shows the whole online
        // session (NOW PLAYING + everything queued after it), not just one song.
        self.contextDisplayTracks = self.context.map { $0.asTrack(deviceID: deviceID) }
        loadDisplayArtwork()
        await playFromContext(at: contextIndex, artworkData: artworkData)
    }

    /// Extend the active online session with similar-song suggestions so playback
    /// — and the Queue panel — keeps going when the original context runs low.
    /// New tracks join the navigation `context` (each downloaded on demand when
    /// reached) and the display mirror. No-op when no online session is active.
    /// Called by QueueSuggestionService.
    public func appendOnlineSuggestions(_ tracks: [OnlineTrack]) {
        guard !context.isEmpty else { return }
        let existing = Set(context.map { $0.id })
        let fresh = tracks.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        context.append(contentsOf: fresh)
        contextDisplayTracks.append(contentsOf: fresh.map { $0.asTrack(deviceID: deviceID) })
        engine.queue.setOnlineDisplayQueue(contextDisplayTracks, currentIndex: contextIndex)
        loadDisplayArtwork()
    }

    /// True while an online Discover session is active — lets the suggestion
    /// service decide whether to route similar songs here (vs the local queue).
    public var hasActiveOnlineSession: Bool { !context.isEmpty }

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
    public func playQueueTrack(_ track: Track) async -> Bool {
        guard !context.isEmpty,
              let index = contextDisplayTracks.firstIndex(where: { $0.id == track.id })
        else { return false }
        await playFromContext(at: index)
        return true
    }

    // MARK: - Standalone replay (history / recently-played / home)

    /// True when this Track is an online song (minted by OnlineTrack.asTrack, no
    /// remote object, no local file). Callers use it to route through
    /// playStandaloneOnline instead of the local-file path, which would otherwise
    /// claim the song "hasn't been uploaded yet".
    public func isStandaloneOnline(_ track: Track) -> Bool {
        track.isOnline
    }

    /// Play an online track that is not part of the active online context
    /// (e.g. replayed from history / recently-played / home). Rebuilds an
    /// OnlineTrack from the stored Track and plays it through the coordinator,
    /// so it resolves & streams correctly instead of hitting the local-file path.
    public func playStandaloneOnline(_ track: Track, context: [Track]) async {
        // Rebuild OnlineTracks so next/prev works like a fresh session. The minted
        // Track has no artworkURL/sourceID, so reconstruct from title/artist/album/
        // duration; artwork rides along from the already-loaded data.
        let onlineCtx: [OnlineTrack] = context.map { t in
            OnlineTrack(
                title: t.title,
                artistName: t.artistName,
                albumTitle: t.albumTitle,
                duration: t.duration
            )
        }
        let target = OnlineTrack(
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration
        )
        await play(target, context: onlineCtx, artworkData: track.artworkData)
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
                self.engine.queue.setOnlineDisplayQueue(self.contextDisplayTracks, currentIndex: self.contextIndex)
            }
        }
    }

    /// Step forward through the current online context, downloading the next
    /// track on demand. Installed on the engine as `onlineNextHandler`, so it
    /// fires for the next button, F9 / Cmd-Right, and end-of-track auto-advance.
    public func playNextInContext() async {
        guard contextIndex + 1 < context.count else {
            // End of context — hand control back to the engine and stop.
            engine.clearOnlineContext()
            engine.stopPlayback()
            nowPlayingID = nil
            return
        }
        await playFromContext(at: contextIndex + 1)
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
    private func playFromContext(at index: Int, artworkData: Data? = nil) async {
        guard context.indices.contains(index) else { return }
        let result = context[index]
        let artwork = artworkData ?? (index == contextIndex ? contextArtwork : nil)

        // Kick off lyrics resolution in parallel with the audio download so they're
        // cached by the time Now Playing opens. Best-effort — never blocks playback.
        LyricsService.shared.prefetch(for: result.asTrack(deviceID: deviceID))

        playToken &+= 1
        let token = playToken
        resolvingID = result.id
        defer { if token == playToken { resolvingID = nil } }

        // Cache hit — but validate duration first to catch a stale music-video pick.
        if let cached = cacheURL(for: result) {
            if await Self.cachedDurationMatches(cached, expected: result.duration) {
                guard token == playToken else { return }
                await startPlayback(result, index: index, artwork: artwork, token: token)
                prefetchTasks.removeValue(forKey: result.id)
                return
            } else {
                // Wrong version cached — delete and re-download.
                try? FileManager.default.removeItem(at: cached)
                prefetchTasks.removeValue(forKey: result.id)
            }
        }

        // Progressive streaming: for a cold track, ask the resolver for a stream URL
        // (server ensures the file exists, then range-serves it) so AVPlayer starts
        // on the first buffer instead of waiting for the whole download. We still
        // fill the on-disk cache in the background for replay / Add to Library.
        // Resolvers that can't stream (macOS) return nil and we fall through.
        if prefetchTasks[result.id] == nil,
           let stream = try? await ytdlp.resolveStream(query: result.searchQuery,
                                                        expectedDuration: result.duration,
                                                        preferExplicit: result.isExplicit) {
            guard token == playToken else { return }
            recordVideoID(stream.videoID, for: result.id)
            await startStreaming(result, stream: stream, index: index, artwork: artwork, token: token)
            // Cache the file in the background for next time (best-effort).
            if prefetchTasks[result.id] == nil {
                prefetchTasks[result.id] = makeDownloadTask(for: result, priority: .background)
            }
            return
        }

        // Reuse the hover-prefetch task if running, else start a fresh download.
        let downloadTask: Task<ResolvedAudio, Error>
        if let existing = prefetchTasks[result.id] {
            downloadTask = existing
        } else {
            downloadTask = makeDownloadTask(for: result)
            prefetchTasks[result.id] = downloadTask
        }

        do {
            _ = try await downloadTask.value
            guard token == playToken else {
                prefetchTasks.removeValue(forKey: result.id)
                return
            }
            await startPlayback(result, index: index, artwork: artwork, token: token)
        } catch {
            if token == playToken { setError(userFacingPlaybackMessage(for: error)) }
        }
        prefetchTasks.removeValue(forKey: result.id)
    }

    /// Play an already-downloaded context track, update the index, reinstall the
    /// skip handlers (engine.play clears them), and warm the next neighbour. If we
    /// have no artwork yet but the track has a URL, fetch it first so every track
    /// shows a cover; `token` is re-checked after that await so a newer click can't
    /// be clobbered by a stale fetch.
    private func startPlayback(_ result: OnlineTrack, index: Int, artwork: Data?, token: Int) async {
        var artwork = artwork
        if artwork == nil, let url = result.artworkURL {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                guard token == playToken else { return }
                artwork = data
            }
        }

        // The videoID is known here (we just played from / downloaded the cache).
        let videoID = videoIDIndex[result.id] ?? result.cacheStem
        let track = result.asTrack(
            artworkData: artwork,
            localPath: cacheRelativePath(forVideoID: videoID),
            deviceID: deviceID
        )
        contextIndex = index
        await engine.play(track: track, in: [track])

        // engine.play() reset the queue to this one track. Re-mirror the full
        // context (with the fully-built track in the playing slot) so the Queue
        // panel shows NOW PLAYING + NEXT UP.
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks[index] = track
            engine.queue.setOnlineDisplayQueue(contextDisplayTracks, currentIndex: index)
        }

        nowPlayingID = result.id

        // Route skip / auto-advance back here while this online track plays.
        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

        // Warm the next neighbour so the following skip-forward is near-instant.
        if context.indices.contains(index + 1) {
            prefetch(context[index + 1])
        }
    }

    /// Streaming version of startPlayback: progressive AVPlayer playback with no
    /// full download, but the same context wiring so it behaves like a cached
    /// track. The cache fill runs separately, so `localPath` points at where that
    /// file will land for later replay / Add to Library.
    private func startStreaming(_ result: OnlineTrack, stream: StreamResolution, index: Int, artwork: Data?, token: Int) async {
        var artwork = artwork
        if artwork == nil, let url = result.artworkURL {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                guard token == playToken else { return }
                artwork = data
            }
        }

        let track = result.asTrack(
            artworkData: artwork,
            localPath: cacheRelativePath(forVideoID: stream.videoID),
            deviceID: deviceID
        )
        contextIndex = index
        await engine.playOnlineStream(url: stream.url, headers: stream.headers, track: track)

        // engine cleared/reset the queue — re-mirror the full online context.
        if contextDisplayTracks.indices.contains(index) {
            contextDisplayTracks[index] = track
            engine.queue.setOnlineDisplayQueue(contextDisplayTracks, currentIndex: index)
        }

        nowPlayingID = result.id

        // Route skip / auto-advance back here while this online track streams.
        engine.onlineNextHandler     = { [weak self] in await self?.playNextInContext() }
        engine.onlinePreviousHandler = { [weak self] in await self?.playPreviousInContext() }

        // Warm the next neighbour so the following skip-forward is near-instant.
        if context.indices.contains(index + 1) {
            prefetch(context[index + 1])
        }
    }

    // MARK: - Add to Library

    /// Download (if needed) and import `result` as a permanent library track. We
    /// pass the OnlineTrack's metadata so it files correctly instead of landing
    /// under "Unknown Artist" parsed from the tag-less m4a, and Supabase sync fires.
    public func addToLibrary(_ result: OnlineTrack) async {
        resolvingID = result.id
        defer { resolvingID = nil }
        do {
            // importOnlineTrack copies the cached file into the library; the cache
            // copy stays put.
            let (fileURL, _) = try await resolveCachedFile(for: result)
            // A track replayed from Home/history has no artworkURL (rebuilt from a
            // snapshot) but already carries artwork on its display Track — pass it
            // through so the imported song keeps a cover.
            let loadedArtwork = contextDisplayTracks.first { $0.id == result.stableTrackID }?.artworkData
                ?? (result.id == nowPlayingID ? engine.queue.currentTrack?.artworkData : nil)
            _ = await importService.importOnlineTrack(
                from: fileURL,
                title: result.title,
                artistName: result.artistName,
                albumTitle: result.albumTitle,
                duration: result.duration,
                artworkURL: result.artworkURL,
                artworkData: loadedArtwork,
                isExplicit: result.isExplicit
            )
        } catch {
            setError(userFacingPlaybackMessage(for: error))
        }
    }

    // MARK: - Queue (Discover context menu)

    /// Download (if needed) and insert `result` immediately after the current
    /// track in the engine's queue. The track carries the cache relative path as
    /// its localPath, so it plays from disk without being imported to the library.
    public func playNext(_ result: OnlineTrack) async {
        await enqueue(result) { [weak self] track in
            self?.engine.queue.insertNext(track)
        }
    }

    /// Download (if needed) and append `result` to the end of the engine's queue.
    public func addToQueue(_ result: OnlineTrack) async {
        await enqueue(result) { [weak self] track in
            self?.engine.queue.append(track)
        }
    }

    /// Shared body for playNext / addToQueue: spinner, resolve the cached file,
    /// fetch artwork, build a Track, hand it to `enqueue`.
    private func enqueue(_ result: OnlineTrack, _ enqueue: @escaping (Track) -> Void) async {
        resolvingID = result.id
        defer { resolvingID = nil }
        do {
            let (_, videoID) = try await resolveCachedFile(for: result)

            // Lazily download cover art so the now-playing bar has it once this
            // queued track starts playing — mirrors startPlayback's approach.
            var artwork: Data? = nil
            if let url = result.artworkURL,
               let (data, _) = try? await URLSession.shared.data(from: url) {
                artwork = data
            }

            let track = result.asTrack(
                artworkData: artwork,
                localPath: cacheRelativePath(forVideoID: videoID),
                deviceID: deviceID
            )
            enqueue(track)
        } catch {
            setError(userFacingPlaybackMessage(for: error))
        }
    }

    // MARK: - Helpers

    /// Resolve `result` to an on-disk cache file, reusing work: cache hit returns
    /// immediately, an in-flight prefetch is awaited rather than restarted, else a
    /// fresh download. Shared by addToLibrary / playNext / addToQueue. Returns the
    /// file plus its resolved videoID.
    private func resolveCachedFile(for result: OnlineTrack) async throws -> (url: URL, videoID: String) {
        if let cached = cacheURL(for: result), let vid = videoIDIndex[result.id] {
            return (cached, vid)
        }
        let running = prefetchTasks[result.id] ?? makeDownloadTask(for: result)
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

    /// Keep the on-disk cache under `cacheBudgetBytes` by deleting the
    /// least-recently-accessed `.m4a` files. Files referenced by the live engine
    /// queue or the now-playing track are pinned and never evicted. Called after
    /// a download completes (never on the hot play path before playback).
    private func enforceCacheBudget() {
        let fm = FileManager.default
        let dir = Self.cacheDir
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }

        // Pin every cache file referenced by the live queue + now-playing track,
        // matched by filename (the localPath ends in "<videoID>.m4a").
        var pinned = Set<String>()
        for track in engine.queue.queue + [engine.queue.currentTrack].compactMap({ $0 }) {
            let lp = track.file.localPath
            if !lp.isEmpty { pinned.insert((lp as NSString).lastPathComponent) }
        }

        struct Entry { let url: URL; let size: Int64; let accessed: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in urls where url.pathExtension == "m4a" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(v?.fileSize ?? 0)
            let accessed = v?.contentAccessDate ?? v?.contentModificationDate ?? .distantPast
            total += size
            entries.append(Entry(url: url, size: size, accessed: accessed))
        }
        guard total > Self.cacheBudgetBytes else { return }

        // Oldest access first; remove until under budget, skipping pinned files.
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            if total <= Self.cacheBudgetBytes { break }
            guard !pinned.contains(entry.url.lastPathComponent) else { continue }
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.errorMessage = nil
        }
    }

    /// Briefly surface a non-error status message, then auto-clear it.
    private func flashStatus(_ message: String) {
        statusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.statusMessage = nil
        }
    }
}
