// PlaybackEngine.swift
// Mixtape — Core/Services
//
// Drives audio playback via AVAudioEngine and the QueueService.
//
// Audio graph:   playerNode ──▶ eqNode (AVAudioUnitEQ) ──▶ mainMixerNode ──▶ output
//
// The EQ node is owned by AudioEqualizer and injected here so it sits in the
// signal path; gain changes apply live.
//
// Handles:
//   • Local file playback (AVAudioFile scheduled on an AVAudioPlayerNode)
//   • On-demand download for remote-only tracks (synced from another device)
//   • Lock-screen / Control Centre integration via MPNowPlayingInfoCenter
//   • Hardware/Bluetooth controls via MPRemoteCommandCenter
//
// Injected as @EnvironmentObject from MixtapeApp so every view can observe state.
//
// NOTE: This class is @MainActor. AVAudioEngine scheduling completion handlers
// run on a background thread, so they hop back via `Task { @MainActor in … }`.

import AVFoundation
import MediaPlayer
import Combine
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Playback State

public enum PlaybackState: Equatable {
    case stopped
    case loading
    case playing
    case paused
    case error(String)

    /// True when there is an active session (something loaded or playing).
    public var isActive: Bool {
        switch self {
        case .stopped: return false
        default: return true
        }
    }
    public var isPlaying: Bool { self == .playing }
}

// MARK: - Crossfade Mode

public enum CrossfadeMode: String, CaseIterable, Identifiable, Sendable {
    case off, gapless, crossfade
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off:       return "Off"
        case .gapless:   return "Gapless"
        case .crossfade: return "Crossfade"
        }
    }
}

// MARK: - Engine

@MainActor
public final class PlaybackEngine: NSObject, ObservableObject {

    // MARK: - Published State (UI observes these)

    @Published public private(set) var state:           PlaybackState = .stopped
    @Published public private(set) var currentTime:     TimeInterval  = 0
    @Published public private(set) var duration:        TimeInterval  = 0
    /// Tracks played this session, most recent first. Capped at 50.
    @Published public private(set) var recentlyPlayed:  [Track]       = []
    /// Non-nil when a playback error just occurred. Auto-clears after 4 seconds.
    @Published public private(set) var errorMessage:    String?       = nil
    /// Output volume 0.0 – 1.0. Observable and mutatable from any view.
    @Published public var volume: Float = 1.0 {
        didSet { applyVolume() }
    }

    /// Called whenever a track is prepended to `recentlyPlayed`.
    /// AppDependencies uses this to persist the entry via PlayHistoryRepository.
    public var onTrackAddedToHistory: ((Track) -> Void)?

    // MARK: - Online context routing (Discover)
    //
    // When the currently playing track is an online (Discover) stream, skip /
    // auto-advance can't use the local queue — each online track is downloaded
    // one at a time and only the playing one has a file on disk. The
    // OnlinePlaybackCoordinator installs these handlers so next / previous /
    // end-of-track route back to it, which downloads the neighbour in its
    // stored context and plays it. When a normal library track plays, the
    // engine clears these (see `play(track:in:)`) so the queue handles skips.

    /// Set by OnlinePlaybackCoordinator while an online context is active.
    /// Non-nil here means "the current track is an online stream".
    public var onlineNextHandler: (() async -> Void)?
    /// Companion to `onlineNextHandler` for backward skips.
    public var onlinePreviousHandler: (() async -> Void)?

    /// Routes an online track that has no playable local file (e.g. a song
    /// imported from a Spotify playlist, or replayed from history) through the
    /// OnlinePlaybackCoordinator, which resolves & streams it. Set by
    /// AppDependencies. Returns once routing has taken over. When nil, such a
    /// track falls through to the normal local-file path (and surfaces the
    /// "hasn't been uploaded yet" error).
    public var onlineRouter: ((Track, [Track]) async -> Void)?

    /// True when an online (Discover) context is driving playback, so skips
    /// must route to the coordinator instead of the local queue.
    public var hasOnlineContext: Bool { onlineNextHandler != nil }

    /// Clear the online routing handlers. Called when a library track takes
    /// over so the engine's normal queue handles next / previous again.
    public func clearOnlineContext() {
        onlineNextHandler = nil
        onlinePreviousHandler = nil
    }

    /// Current playback speed multiplier (0.5–2.0). 1.0 = normal. Persisted.
    @Published public private(set) var playbackRate: Float = 1.0
    /// Track-transition style. Persisted. `.off` keeps the original single-player
    /// path; `.gapless`/`.crossfade` overlap tracks via the dual-player graph.
    @Published public private(set) var crossfadeMode: CrossfadeMode = .off
    /// Crossfade overlap length in seconds (used when mode == .crossfade). 2–12.
    @Published public private(set) var crossfadeDuration: TimeInterval = 6
    /// Seconds left on the active sleep timer, or nil if none is running.
    @Published public private(set) var sleepTimerRemaining: TimeInterval? = nil

    // MARK: - Sub-services (observable by views)

    public let queue: QueueService

    /// The graphic equaliser whose AVAudioUnitEQ node sits in the audio graph.
    public let equalizer: AudioEqualizer

    // MARK: - Private

    private let fileStorage: SupabaseFileStorageService

    // Audio graph
    private let audioEngine = AVAudioEngine()
    /// Two player nodes feeding the preMixer on distinct buses so tracks can
    /// overlap for crossfade / gapless. `playerNode` is whichever is currently
    /// active; the other (`idlePlayer`) is silent until a transition. When
    /// crossfade is OFF, `usingA` never flips so behaviour matches the original
    /// single-player path exactly.
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private var usingA  = true
    private var playerNode: AVAudioPlayerNode { usingA ? playerA : playerB }
    private var idlePlayer: AVAudioPlayerNode { usingA ? playerB : playerA }
    private var activeBus: AVAudioNodeBus { usingA ? 0 : 1 }
    private var idleBus:   AVAudioNodeBus { usingA ? 1 : 0 }

    // Crossfade transition state
    private var crossfadeTask: Task<Void, Never>?
    private var outgoingPlayer: AVAudioPlayerNode?
    private var isTransitioning = false
    /// Plain mixer placed directly after the player. It absorbs per-file format
    /// changes (channel count / sample rate) and converts to one canonical format,
    /// so the downstream AU effects (EQ, TimePitch) always run at a fixed format.
    /// Without this, reconnecting the serial AU chain per file makes the TimePitch
    /// unit reject the format (err -10868) and crash on `connect`.
    private let preMixerNode = AVAudioMixerNode()
    /// The EQ node — provided by `equalizer`. Inserted between player and mixer.
    private var eqNode: AVAudioUnitEQ { equalizer.node }
    /// Varispeed/pitch node for playback-speed control. Sits eq → timePitch → mixer.
    private let timePitchNode = AVAudioUnitTimePitch()
    private var graphConfigured = false

    /// The fixed format the effect chain (preMixer output → eq → timePitch → mixer)
    /// always runs at. The preMixer converts any file format into this.
    private let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    // Sleep timer
    private var sleepTimerTask: Task<Void, Never>?

    // Last.fm scrobbling: when the current track started, and whether it has
    // already crossed the scrobble threshold this play-through.
    private var scrobbleStartedAt: Date?
    private var didScrobbleCurrent = false
    /// True once the current track has crossed the minimum-listen threshold and
    /// been recorded to history. Reset whenever a new track starts.
    private var didRecordHistoryCurrent = false

    // Lyrics prefetch: id of the track we last kicked off a background lyrics
    // resolve for, so the same track isn't prefetched twice in a row.
    private var lastLyricsPrefetchID: Track.ID?

    // UserDefaults keys for persisted playback state.
    private enum DefaultsKey {
        static let playbackRate      = "playback.rate"
        static let lastTrackID       = "playback.lastTrackID"
        static let lastPosition      = "playback.lastPosition"
        static let crossfadeMode     = "playback.crossfadeMode"
        static let crossfadeDuration = "playback.crossfadeDuration"
    }

    /// The file currently scheduled on the player node.
    private var audioFile: AVAudioFile?
    /// Sample rate of the currently loaded file (for time/sample conversion).
    private var fileSampleRate: Double = 44_100
    /// Total frames in the currently loaded file.
    private var fileLengthFrames: AVAudioFramePosition = 0
    /// Sample offset of the segment currently scheduled (seek base).
    private var seekFrameOffset: AVAudioFramePosition = 0
    /// Whether the player node is logically playing (engine running + node playing).
    private var isNodePlaying = false

    private var progressTimer: AnyCancellable?
    /// Incremented each time a new load is requested. A stale `loadAndPlay` call
    /// checks this before doing anything irreversible and aborts if superseded.
    private var loadGeneration = 0

    // MARK: - Remote streaming (Discover / online playback)

    /// Which backend is currently driving playback. `.engine` is the AVAudioEngine
    /// graph (local files); `.remote` is an AVPlayer streaming a yt-dlp URL. The
    /// public controls (toggle/pause/resume/seek/volume) branch on this so the
    /// existing player bar works unchanged for online tracks.
    private enum PlaybackSource { case engine, remote }
    private var playbackSource: PlaybackSource = .engine
    private var remotePlayer: AVPlayer?
    private var remoteTimeObserver: Any?
    private var remoteEndObserver: NSObjectProtocol?

    // MARK: - Init

    public init(queue: QueueService, fileStorage: SupabaseFileStorageService, equalizer: AudioEqualizer) {
        self.queue       = queue
        self.fileStorage = fileStorage
        self.equalizer   = equalizer
        super.init()
        configureGraph()
        setupRemoteCommands()
    }

    // MARK: - Audio Graph Setup

    /// Build the node graph once: player -> eq -> mainMixer. Idempotent.
    private func configureGraph() {
        guard !graphConfigured else { return }

        audioEngine.attach(playerA)
        audioEngine.attach(playerB)
        audioEngine.attach(preMixerNode)
        audioEngine.attach(eqNode)
        audioEngine.attach(timePitchNode)

        // Both players → preMixer on separate buses. Each player→preMixer link is
        // reconnected per file (connectPlayer). Everything from the preMixer onward
        // stays pinned to the canonical format, so the AU effects never see a live
        // format change. The idle player is silent (nothing scheduled) until a
        // crossfade transition.
        audioEngine.connect(playerA, to: preMixerNode, fromBus: 0, toBus: 0, format: canonicalFormat)
        audioEngine.connect(playerB, to: preMixerNode, fromBus: 0, toBus: 1, format: canonicalFormat)
        audioEngine.connect(preMixerNode, to: eqNode, format: canonicalFormat)
        audioEngine.connect(eqNode, to: timePitchNode, format: canonicalFormat)
        audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: canonicalFormat)

        audioEngine.mainMixerNode.outputVolume = volume
        playerA.volume = 1
        playerB.volume = 1

        // Restore persisted playback rate.
        let savedRate = UserDefaults.standard.float(forKey: DefaultsKey.playbackRate)
        if savedRate >= 0.5 && savedRate <= 2.0 {
            playbackRate = savedRate
        }
        timePitchNode.rate = playbackRate

        // Restore persisted crossfade preferences.
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.crossfadeMode),
           let mode = CrossfadeMode(rawValue: raw) {
            crossfadeMode = mode
        }
        let savedFade = UserDefaults.standard.double(forKey: DefaultsKey.crossfadeDuration)
        if savedFade >= 2 && savedFade <= 12 { crossfadeDuration = savedFade }

        audioEngine.prepare()
        graphConfigured = true
    }

    /// Reconnect playerNode -> eqNode using the loaded file's processing format so
    /// channel count / sample rate match. Called before scheduling a new file.
    private func connectGraph(for format: AVAudioFormat) {
        connectPlayer(playerNode, bus: activeBus, format: format)
    }

    /// Reconnect a specific player → preMixer input bus for `format`. The preMixer
    /// converts it to the canonical format the rest of the chain expects, so the
    /// AU effects never have to re-negotiate (which is what crashed with -10868).
    private func connectPlayer(_ player: AVAudioPlayerNode, bus: AVAudioNodeBus, format: AVAudioFormat) {
        audioEngine.connect(player, to: preMixerNode, fromBus: 0, toBus: bus, format: format)
    }

    /// Start the engine if it isn't already running. Returns true on success.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard !audioEngine.isRunning else { return true }
        do {
            try audioEngine.start()
            return true
        } catch {
            print("[PlaybackEngine] ❌ Failed to start AVAudioEngine: \(error)")
            return false
        }
    }

    private func applyVolume() {
        // Apply to the main mixer so it affects the full graph output.
        audioEngine.mainMixerNode.outputVolume = volume
        // Mirror to the remote player so the volume slider also works while streaming.
        remotePlayer?.volume = volume
    }

    // MARK: - Public Controls

    /// Load a new queue starting at `track` and begin playback.
    public func play(track: Track, in tracks: [Track]) async {
        // An online track with no playable local file yet (imported from Spotify,
        // replayed from history) must resolve & stream through the coordinator
        // rather than the local-file path. The coordinator plays the *resolved*
        // file back through this method with its cache `localPath` populated, so
        // `localURL(for:)` is non-nil by then — no recursion.
        if track.isOnline, fileStorage.localURL(for: track) == nil, let route = onlineRouter {
            await route(track, tracks)
            return
        }
        // A direct play() takes over the local queue. Drop any online routing so
        // skips use the queue again. OnlinePlaybackCoordinator re-installs its
        // handlers immediately after this call when it's driving an online track.
        clearOnlineContext()
        // Start resolving lyrics the moment a song is chosen so they're cached by
        // the time Now Playing opens. Best-effort — never blocks playback.
        LyricsService.shared.prefetch(for: track)
        // Capture the previous track BEFORE queue.play() overwrites currentTrack.
        addToHistory(queue.currentTrack, skippingIfSameAs: track)
        queue.play(track: track, in: tracks)
        await loadAndPlay(track: track)
    }

    public func togglePlayPause() {
        if playbackSource == .remote {
            switch state {
            case .playing: remotePlayer?.pause(); state = .paused; updateNowPlayingRate(0)
            case .paused:  resumeRemoteAtRate(); state = .playing; updateNowPlayingRate(playbackRate)
            default: break
            }
            return
        }
        switch state {
        case .playing:
            pausePlayback()
            state = .paused
            stopProgressTimer()
            updateNowPlayingRate(0)
            persistPlaybackPosition()
        case .paused:
            resumePlayback()
            state = .playing
            startProgressTimer()
            updateNowPlayingRate(1)
        default:
            break
        }
    }

    /// If `trackID` is the currently loaded track, stop playback and clear the queue
    /// entirely so the mini-player returns to a "Nothing playing" state.
    /// Call this before deleting a track from the library.
    public func stopIfPlaying(trackID: Track.ID) {
        guard queue.currentTrack?.id == trackID else { return }
        stopPlayback()
        queue.clearCurrentTrack()
    }

    public func pause() {
        if playbackSource == .remote {
            guard state == .playing else { return }
            remotePlayer?.pause(); state = .paused; updateNowPlayingRate(0)
            return
        }
        guard state == .playing else { return }
        pausePlayback()
        state = .paused
        stopProgressTimer()
        updateNowPlayingRate(0)
        persistPlaybackPosition()
    }

    public func resume() {
        if playbackSource == .remote {
            guard state == .paused else { return }
            resumeRemoteAtRate(); state = .playing; updateNowPlayingRate(playbackRate)
            return
        }
        guard state == .paused else { return }
        resumePlayback()
        state = .playing
        startProgressTimer()
        updateNowPlayingRate(1)
    }

    /// Seek to `time` seconds. Works while paused or playing.
    /// Implemented by stopping the player node and re-scheduling the file from
    /// the target sample offset.
    public func seek(to time: TimeInterval) {
        if playbackSource == .remote {
            guard let player = remotePlayer, duration > 0 else { return }
            let clamped = max(0, min(time, duration))
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
            currentTime = clamped
            updateNowPlayingTime()
            return
        }
        guard let file = audioFile, fileLengthFrames > 0 else { return }
        cancelCrossfade()
        let clamped = max(0, min(time, duration))
        let targetFrame = AVAudioFramePosition(clamped * fileSampleRate)

        let wasPlaying = (state == .playing)

        // Bump generation so the in-flight completion handler for the old segment
        // doesn't auto-advance when we stop it here.
        loadGeneration &+= 1
        let generation = loadGeneration

        playerNode.stop()           // fires the old completion handler (now stale)
        isNodePlaying = false

        scheduleSegment(of: file, startingAtFrame: targetFrame, generation: generation)

        currentTime = clamped

        if wasPlaying {
            startEngineIfNeeded()
            playerNode.play()
            isNodePlaying = true
        }
        updateNowPlayingTime()
        persistPlaybackPosition()
    }

    public func playNext() async {
        // Online context active → advance through the Discover context (downloads
        // the neighbour on demand) instead of the single-track local queue.
        if let handler = onlineNextHandler {
            await handler()
            return
        }
        let current = queue.currentTrack
        if let next = queue.advance() {
            addToHistory(current, skippingIfSameAs: next)
            await loadAndPlay(track: next)
        } else {
            // End of queue — log the last track before stopping.
            if let current { addToHistory(current, skippingIfSameAs: nil) }
            stopPlayback()
        }
    }

    public func playPrevious() async {
        // Within the first 3 seconds: restart current track instead of going back.
        if currentTime > 3, queue.currentTrack != nil {
            seek(to: 0)
            if state == .paused { resume() }
            return
        }
        // Online context active → step back through the Discover context.
        if let handler = onlinePreviousHandler {
            await handler()
            return
        }
        let current = queue.currentTrack
        if let prev = queue.previous() {
            addToHistory(current, skippingIfSameAs: prev)
            await loadAndPlay(track: prev)
        }
    }

    // MARK: - Playback Speed

    /// Set the playback speed multiplier. Clamped to 0.5…2.0. Applied live to the
    /// graph's time-pitch node (preserves pitch) and persisted to UserDefaults.
    public func setRate(_ rate: Float) {
        let clamped = max(0.5, min(rate, 2.0))
        playbackRate = clamped
        timePitchNode.rate = clamped
        // Remote (AVPlayer) streams apply speed via the player's rate; pitch is
        // preserved by the item's audioTimePitchAlgorithm set at load time.
        if playbackSource == .remote, state == .playing { remotePlayer?.rate = clamped }
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.playbackRate)
        // Lock-screen rate reflects whether we're actively playing, scaled by speed.
        updateNowPlayingRate(state == .playing ? clamped : 0)
    }

    /// Resume the remote AVPlayer at the user's chosen speed. Setting `rate`
    /// directly both starts playback and applies the multiplier in one step.
    private func resumeRemoteAtRate() {
        remotePlayer?.rate = playbackRate
    }

    // MARK: - Sleep Timer

    /// Start (or restart) a sleep timer. After `duration` seconds, playback pauses.
    public func setSleepTimer(_ duration: TimeInterval) {
        cancelSleepTimer()
        guard duration > 0 else { return }
        sleepTimerRemaining = duration
        sleepTimerTask = Task { @MainActor [weak self] in
            while let remaining = self?.sleepTimerRemaining, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                guard let current = self.sleepTimerRemaining else { return }
                let next = current - 1
                if next <= 0 {
                    self.sleepTimerRemaining = nil
                    self.sleepTimerTask = nil
                    if self.state == .playing { self.pause() }
                    return
                } else {
                    self.sleepTimerRemaining = next
                }
            }
        }
    }

    /// Cancel any running sleep timer.
    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = nil
    }

    // MARK: - Resume On Launch

    /// Persist the current track id + position so playback can be restored next launch.
    private func persistPlaybackPosition() {
        let defaults = UserDefaults.standard
        if let id = queue.currentTrack?.id {
            defaults.set(id.uuidString, forKey: DefaultsKey.lastTrackID)
            defaults.set(currentTime, forKey: DefaultsKey.lastPosition)
        }
    }

    /// Restore the last session PAUSED at its saved position. Does NOT auto-play.
    /// Call once on launch after the library has loaded.
    public func restoreLastSession(allTracks: [Track]) {
        guard state == .stopped else { return }
        let defaults = UserDefaults.standard
        guard
            let idString = defaults.string(forKey: DefaultsKey.lastTrackID),
            let uuid = UUID(uuidString: idString),
            let track = allTracks.first(where: { $0.id == uuid })
        else { return }
        let position = defaults.double(forKey: DefaultsKey.lastPosition)
        Task { @MainActor in
            await loadButPause(track: track, at: position)
        }
    }

    /// Load `track` and leave it paused at `position` seconds (resume-on-launch path).
    private func loadButPause(track: Track, at position: TimeInterval) async {
        queue.restoreSession(track: track)
        // Online tracks with no cached file would need resolving/streaming, which
        // we don't do automatically on launch. Restore the session for the UI and
        // stay stopped — play() routes it through the coordinator when tapped.
        if track.isOnline, fileStorage.localURL(for: track) == nil {
            state = .stopped
            return
        }
        await loadAndPlay(track: track)
        // loadAndPlay starts playback; immediately pause and seek to saved position.
        if duration > 0 {
            seek(to: min(position, duration))
        }
        pausePlayback()
        state = .paused
        stopProgressTimer()
        updateNowPlayingRate(0)
    }

    // MARK: - Private: Load & Play

    private func loadAndPlay(track: Track) async {
        // A local load supersedes any active remote stream — tear it down and
        // hand control back to the AVAudioEngine graph.
        if playbackSource == .remote {
            teardownRemotePlayer()
            playbackSource = .engine
        }
        // Manual load supersedes any in-flight crossfade: stop the outgoing
        // player and reset volumes before taking over.
        cancelCrossfade()
        // Bump generation so any previously in-flight load/segment knows it has
        // been superseded.
        loadGeneration &+= 1
        let generation = loadGeneration

        // Stop the current playback IMMEDIATELY — never leave old audio running
        // while we resolve/download the next track.
        playerNode.stop()
        isNodePlaying = false
        audioFile = nil
        stopProgressTimer()
        currentTime = 0
        seekFrameOffset = 0
        state = .loading

        // 1. Resolve a local URL — use cached file, or download on demand.
        var fileURL: URL

        if let local = fileStorage.localURL(for: track) {
            fileURL = local
        } else if track.file.remoteKey != nil {
            do {
                fileURL = try await fileStorage.download(track: track, accessToken: "")
            } catch {
                // Only surface the error if we're still the active load request.
                guard loadGeneration == generation else { return }
                setError("Couldn't download \"\(track.title)\". Check your connection and try again.")
                print("[PlaybackEngine] ❌ Download failed for \"\(track.title)\": \(error)")
                return
            }
        } else {
            guard loadGeneration == generation else { return }
            setError("\"\(track.title)\" hasn't been uploaded yet. Open Mixtape on your Mac to sync.")
            print("[PlaybackEngine] ❌ No remoteKey for \"\(track.title)\" — upload pending on source device")
            return
        }

        // Abort if a newer play() call has already taken over.
        guard loadGeneration == generation else { return }

        // 2. Configure audio session (iOS only).
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlaybackEngine] Audio session error: \(error)")
        }
        #endif

        // 3. Open the file, reconnect the graph for its format, schedule & play.
        //    Opens AVAudioFile, configures the graph and begins playback; throws on
        //    any failure so the caller can attempt a one-time self-heal.
        func openAndPlay(_ url: URL) throws {
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat

            audioFile        = file
            fileSampleRate   = processingFormat.sampleRate
            fileLengthFrames = file.length
            seekFrameOffset  = 0
            duration         = fileLengthFrames > 0 ? Double(fileLengthFrames) / fileSampleRate : 0
            currentTime      = 0

            // Match the graph to the file's format (channel count / sample rate).
            // The AVAudioUnitTimePitch node rejects a live format change while the
            // engine is running (err -10868 on skip), so stop the engine before
            // reconnecting; startEngineIfNeeded() below brings it back up.
            if audioEngine.isRunning { audioEngine.stop() }
            connectGraph(for: processingFormat)

            scheduleSegment(of: file, startingAtFrame: 0, generation: generation)

            guard startEngineIfNeeded() else {
                throw NSError(domain: "PlaybackEngine", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "audio engine wouldn't start"])
            }
            playerNode.play()
            isNodePlaying = true
            state = .playing

            // Reset scrobble tracking for the new track and announce "now playing".
            scrobbleStartedAt = Date()
            didScrobbleCurrent = false
        didRecordHistoryCurrent = false
            let nowPlayingTrack = track
            Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }

            startProgressTimer()
            updateNowPlayingInfo(track: track)

            // Warm the lyrics cache in the background for the new current track.
            prefetchLyrics(for: track)
        }

        do {
            try openAndPlay(fileURL)
        } catch {
            guard loadGeneration == generation else { return }
            print("[PlaybackEngine] ⚠️ First open failed for \"\(track.title)\": \(error) — attempting self-heal")

            // Self-heal: a corrupt exported/cached copy (e.g. a legacy bad ID3-on-m4a
            // download) makes AVAudioFile throw kAudioFileInvalidFileError. Drop the
            // bad exported copy and re-resolve from cache/remote, then retry once.
            ExportManager.shared.deleteExportedFile(for: track)

            var healedURL: URL? = fileStorage.localURL(for: track)
            // If the only copy left was the one we just deleted (or it's the same
            // corrupt cache file), re-download a fresh copy from the remote.
            if (healedURL == nil || healedURL == fileURL), track.file.remoteKey != nil {
                healedURL = try? await fileStorage.download(track: track, accessToken: "")
            }

            guard loadGeneration == generation else { return }

            if let healedURL, healedURL != fileURL {
                do {
                    fileURL = healedURL
                    try openAndPlay(healedURL)
                    print("[PlaybackEngine] ✅ Self-heal succeeded for \"\(track.title)\"")
                    return
                } catch {
                    guard loadGeneration == generation else { return }
                    print("[PlaybackEngine] ❌ Self-heal retry failed for \"\(track.title)\": \(error)")
                }
            }

            setError("Couldn't play \"\(track.title)\" right now. Please try again.")
            print("[PlaybackEngine] ❌ Playback failed for \"\(track.title)\": \(error)")
        }
    }

    /// Schedule `file` to play from `startingAtFrame` to its end on the player node.
    /// The completion handler auto-advances to the next track, guarded by the
    /// generation counter so it never fires after a manual stop/seek/new-load.
    private func scheduleSegment(of file: AVAudioFile, startingAtFrame startFrame: AVAudioFramePosition, generation: Int) {
        seekFrameOffset = startFrame
        let framesToPlay = AVAudioFrameCount(max(0, fileLengthFrames - startFrame))
        guard framesToPlay > 0 else {
            // Nothing left to play (seek to/at end) — treat as finished.
            return
        }

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: framesToPlay,
            at: nil
        ) { [weak self] in
            // Runs OFF the main actor when playback of the segment completes.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore stale completions (manual stop, seek, or a newer load).
                guard self.loadGeneration == generation else { return }
                guard self.isNodePlaying else { return }
                self.isNodePlaying = false
                await self.playNext()
            }
        }
    }

    // MARK: - Remote Streaming (progressive online playback)

    /// Play an online track by **streaming** `url` via AVPlayer (progressive —
    /// audio starts as soon as enough has buffered) instead of waiting for the
    /// whole file to download. `headers` carries the bearer auth for the hosted
    /// resolver (only set for the trusted host — see RemoteResolverService).
    ///
    /// The caller (OnlinePlaybackCoordinator) installs the online next/previous
    /// handlers AFTER this returns; end-of-stream reads `onlineNextHandler` live,
    /// so auto-advance flows through the Discover context just like the local
    /// path. Speed control, scrubbing and lyrics all run off the AVPlayer clock.
    public func playOnlineStream(url: URL, headers: [String: String], track: Track) async {
        // A streaming load takes over the queue and supersedes any engine playback.
        clearOnlineContext()
        // Warm lyrics in parallel with buffering (coalesces with the tap-time prefetch).
        prefetchLyrics(for: track)
        // Log the outgoing track and surface the new one in the queue/player bar.
        addToHistory(queue.currentTrack, skippingIfSameAs: track)
        queue.play(track: track, in: [track])
        await startRemoteStream(url: url, headers: headers, track: track)
    }

    /// Configures and starts the AVPlayer for a remote stream. Assumes the queue /
    /// history have already been updated by the caller.
    private func startRemoteStream(url: URL, headers: [String: String], track: Track) async {
        // Supersede any engine playback.
        cancelCrossfade()
        loadGeneration &+= 1
        playerNode.stop()
        isNodePlaying = false
        audioFile = nil
        stopProgressTimer()
        if audioEngine.isRunning { audioEngine.pause() }

        // Reset and switch to the remote backend.
        teardownRemotePlayer()
        playbackSource = .remote
        currentTime = 0
        duration    = track.duration       // provisional; refined once the item loads
        state       = .loading

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Inject auth headers (bearer) so the hosted resolver authorises the stream.
        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset  = AVURLAsset(url: url, options: options)
        let item   = AVPlayerItem(asset: asset)
        // Preserve pitch when the user changes playback speed.
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        remotePlayer = player

        // Drive currentTime/duration/state from the player's clock.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        remoteTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.playbackSource == .remote else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : self.currentTime
                if let d = self.remotePlayer?.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    self.duration = d.seconds
                }
                if self.state == .loading, self.remotePlayer?.timeControlStatus == .playing {
                    self.state = .playing
                }
                self.checkHistoryThreshold()
                self.updateNowPlayingTime()
            }
        }

        // At end of stream, auto-advance through the online context if one is
        // active (handler installed by the coordinator after this returns),
        // otherwise stop.
        remoteEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let handler = self.onlineNextHandler {
                    await handler()
                } else {
                    self.stopPlayback()
                }
            }
        }

        // Start at the user's chosen speed (rate > 0 begins playback).
        player.rate = playbackRate
        // Stay in .loading until the time observer confirms audio is actually
        // advancing (timeControlStatus == .playing). This lets the coordinator's
        // watchdog detect a stalled/failed stream and fall back to a download.
        scrobbleStartedAt  = Date()
        didScrobbleCurrent = false
        didRecordHistoryCurrent = false
        updateNowPlayingInfo(track: track)
        let nowPlayingTrack = track
        Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }
    }

    /// Tear down the AVPlayer and its observers. Safe to call when none exists.
    private func teardownRemotePlayer() {
        if let obs = remoteTimeObserver {
            remotePlayer?.removeTimeObserver(obs)
            remoteTimeObserver = nil
        }
        if let end = remoteEndObserver {
            NotificationCenter.default.removeObserver(end)
            remoteEndObserver = nil
        }
        remotePlayer?.pause()
        remotePlayer = nil
    }

    // MARK: - Pause / Resume primitives

    private func pausePlayback() {
        // Finalise any in-flight crossfade before pausing so we don't leave the
        // outgoing player paused-but-scheduled.
        cancelCrossfade()
        playerNode.pause()
        audioEngine.pause()
        isNodePlaying = false
    }

    private func resumePlayback() {
        guard audioFile != nil else { return }
        startEngineIfNeeded()
        playerNode.play()
        isNodePlaying = true
    }

    /// Prepend `track` to recentlyPlayed unless it's nil or identical to `arriving`.
    /// Pass `nil` for `arriving` when stopping playback (no incoming track).
    /// Start-time history logging is intentionally a no-op: a play is only
    /// recorded once it crosses the minimum-listen threshold (see
    /// `checkHistoryThreshold`), so skips and brief samples don't pollute
    /// "Recently played" or listening stats. Kept so existing call sites compile.
    private func addToHistory(_ track: Track?, skippingIfSameAs arriving: Track?) {}

    /// Record the *current* track as a play: prepend to `recentlyPlayed` (Home
    /// screen) and persist via the callback (history table → stats). Skips a
    /// duplicate already at the top of the list. Online tracks have a stable id,
    /// so repeated plays aggregate rather than pile up as unique entries.
    private func recordCurrentPlay() {
        guard let track = queue.currentTrack else {
            print("[history] recordCurrentPlay: no currentTrack — skipped")
            return
        }
        if recentlyPlayed.first?.id == track.id {
            print("[history] recordCurrentPlay: '\(track.title)' already at top — skipped")
            return
        }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > 50 { recentlyPlayed.removeLast() }
        print("[history] RECORDED '\(track.title)' id=\(track.id) online=\(track.isOnline) recentlyPlayed.count=\(recentlyPlayed.count)")
        onTrackAddedToHistory?(track)
    }

    /// Records the current track once it's been listened to for at least 30s (or
    /// ~90% of a sub-30s song), so only meaningful listens count toward Home and
    /// stats. Fires once per track; the flag resets when a new track loads.
    private func checkHistoryThreshold() {
        guard !didRecordHistoryCurrent, queue.currentTrack != nil else { return }
        let target = duration > 0 ? min(30, duration * 0.9) : 30
        guard currentTime >= target else { return }
        print("[history] threshold reached: currentTime=\(currentTime) target=\(target) duration=\(duration)")
        didRecordHistoryCurrent = true
        recordCurrentPlay()
    }

    /// Seeds `recentlyPlayed` from persistent storage on app launch.
    /// Call this once after AppDependencies has loaded history from SwiftData.
    public func restoreHistory(_ tracks: [Track]) {
        recentlyPlayed = Array(tracks.prefix(50))
    }

    /// Sets the error state AND the error toast message, then auto-clears both after 4 s.
    private func setError(_ message: String) {
        state        = .error(message)
        errorMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if case .error = self.state { self.state = .stopped }
            self.errorMessage = nil
        }
    }

    public func stopPlayback() {
        cancelCrossfade()
        teardownRemotePlayer()
        playbackSource = .engine
        // Bump generation so the segment completion handler won't auto-advance.
        loadGeneration &+= 1
        playerNode.stop()
        isNodePlaying = false
        audioFile = nil
        // Pause (not stop) the engine so the graph stays configured & ready.
        if audioEngine.isRunning { audioEngine.pause() }
        stopProgressTimer()
        currentTime = 0
        duration    = 0
        seekFrameOffset = 0
        state       = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        progressTimer = Timer
            // 0.2s tick keeps the seek bar smooth and synced-lyric highlighting
            // snappy (the old 0.5s tick added up to half a second of lag).
            .publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.currentTime = self.currentPlaybackTime()
                self.checkScrobbleThreshold()
                self.checkHistoryThreshold()
                self.maybeStartCrossfade()
            }
    }

    /// Scrobble the current track once it crosses Last.fm's threshold: played for
    /// at least half its duration OR 4 minutes (whichever first), for tracks >30s.
    /// No-ops when Last.fm is disabled/unconfigured (the scrobbler guards that).
    private func checkScrobbleThreshold() {
        guard !didScrobbleCurrent, duration > 30, let startedAt = scrobbleStartedAt else { return }
        let threshold = min(duration / 2, 240)
        guard currentTime >= threshold, let track = queue.currentTrack else { return }
        didScrobbleCurrent = true
        Task { await LastFmScrobbler.shared.scrobble(track: track, startedAt: startedAt) }
    }

    /// Fire-and-forget: warm the lyrics cache for `track` in the background so
    /// they're already resolved when the user opens the lyrics view. No-ops if we
    /// already kicked off a prefetch for this same track. Silent on failure and
    /// never blocks playback.
    private func prefetchLyrics(for track: Track) {
        guard lastLyricsPrefetchID != track.id else { return }
        lastLyricsPrefetchID = track.id
        Task { await LyricsService.shared.resolve(for: track) }
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    /// Compute the current playback position from the player node's sample clock
    /// plus the seek offset. Falls back to the last known `currentTime` if the
    /// node isn't currently rendering (e.g. paused).
    private func currentPlaybackTime() -> TimeInterval {
        guard fileSampleRate > 0 else { return currentTime }
        guard
            let nodeTime   = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return currentTime
        }
        let elapsedFrames = Double(seekFrameOffset) + Double(playerTime.sampleTime)
        let t = elapsedFrames / fileSampleRate
        // Clamp to [0, duration]; sampleTime can briefly overshoot at the tail.
        return max(0, min(t, duration))
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo(track: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:                        track.title,
            MPMediaItemPropertyArtist:                       track.artistName,
            MPMediaItemPropertyAlbumTitle:                   track.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:     currentTime,
            MPMediaItemPropertyPlaybackDuration:             duration,
            MPNowPlayingInfoPropertyPlaybackRate:            playbackRate,
        ]

        #if os(iOS)
        if let data = track.artworkData, let img = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        #elseif os(macOS)
        if let data = track.artworkData, let img = NSImage(data: data) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingRate(_ rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Crossfade / Gapless

    /// Set the transition style. Persisted. `.off` restores single-player behaviour.
    public func setCrossfadeMode(_ mode: CrossfadeMode) {
        crossfadeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.crossfadeMode)
        if mode == .off { cancelCrossfade() }
    }

    /// Set the crossfade overlap length (seconds). Clamped to 2…12. Persisted.
    public func setCrossfadeDuration(_ seconds: TimeInterval) {
        let clamped = max(2, min(seconds, 12))
        crossfadeDuration = clamped
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.crossfadeDuration)
    }

    /// The overlap length actually used for the active mode.
    private var effectiveFade: TimeInterval {
        switch crossfadeMode {
        case .off:       return 0
        case .gapless:   return 0.4          // short equal-power fade to hide the load gap
        case .crossfade: return crossfadeDuration
        }
    }

    /// Called from the progress timer. When the active track is within the fade
    /// window of its end and a local next track exists, begin overlapping it.
    private func maybeStartCrossfade() {
        guard crossfadeMode != .off, !isTransitioning, state == .playing else { return }
        guard audioFile != nil, duration > 0 else { return }
        let fade = effectiveFade
        // Don't crossfade tracks too short to absorb the overlap.
        guard duration > fade + 1 else { return }
        let remaining = duration - currentTime
        // 0.55s slop covers the 0.5s timer resolution so we never miss the window.
        guard remaining > 0, remaining <= fade + 0.55 else { return }
        guard let next = queue.peekNext() else { return }
        // Crossfade only when the next file is already local — never stall the
        // transition on a network download; fall back to the normal advance.
        guard let url = fileStorage.localURL(for: next) else { return }
        beginCrossfade(to: next, url: url, fade: max(fade, 0.2))
    }

    /// Overlap the active track with `next`: schedule it on the idle player, flip
    /// the logical "active" player immediately (so progress/now-playing reflect the
    /// new track), then equal-power ramp the volumes over `fade` seconds.
    private func beginCrossfade(to next: Track, url: URL, fade: TimeInterval) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { return }   // bad file — let the normal completion handler advance

        isTransitioning = true
        let outgoing = playerNode
        let incoming = idlePlayer
        let incomingBus = idleBus
        let fmt = file.processingFormat
        let lenFrames = file.length

        // Wire + schedule the incoming track on the idle player/bus (engine keeps
        // running; downstream chain stays canonical so the AU effects don't renegotiate).
        connectPlayer(incoming, bus: incomingBus, format: fmt)
        incoming.volume = 0

        loadGeneration &+= 1
        let generation = loadGeneration
        scheduleFullFile(file, on: incoming, generation: generation)
        startEngineIfNeeded()
        incoming.play()

        // Flip logical active player → `incoming`. `playerNode` now == incoming, so
        // the progress clock and seek operate on the new track.
        usingA.toggle()
        outgoingPlayer = outgoing

        // Advance queue + log history for the outgoing track.
        let outgoingTrack = queue.currentTrack
        _ = queue.advance()
        addToHistory(outgoingTrack, skippingIfSameAs: next)

        // Adopt the incoming file as the current file/state.
        audioFile        = file
        fileSampleRate   = fmt.sampleRate
        fileLengthFrames = lenFrames
        seekFrameOffset  = 0
        duration         = lenFrames > 0 ? Double(lenFrames) / fmt.sampleRate : 0
        currentTime      = 0
        isNodePlaying    = true
        scrobbleStartedAt  = Date()
        didScrobbleCurrent = false
        didRecordHistoryCurrent = false
        updateNowPlayingInfo(track: next)
        let nowPlayingTrack = next
        Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }

        // Warm the lyrics cache in the background for the incoming track.
        prefetchLyrics(for: next)

        // Equal-power volume ramp.
        crossfadeTask?.cancel()
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = max(1, Int(fade / 0.03))
            for i in 1...steps {
                if Task.isCancelled { return }
                let t = Float(i) / Float(steps)
                outgoing.volume = cos(t * .pi / 2)
                self.playerNode.volume = sin(t * .pi / 2)
                try? await Task.sleep(for: .seconds(0.03))
            }
            if Task.isCancelled { return }
            outgoing.stop()
            outgoing.volume = 1
            self.playerNode.volume = 1
            self.outgoingPlayer = nil
            self.isTransitioning = false
        }
    }

    /// Schedule a whole file on a given player with a generation-guarded
    /// auto-advance completion handler (mirrors `scheduleSegment`).
    private func scheduleFullFile(_ file: AVAudioFile, on player: AVAudioPlayerNode, generation: Int) {
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return }
        player.scheduleSegment(file, startingFrame: 0, frameCount: frames, at: nil) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.loadGeneration == generation else { return }
                guard self.isNodePlaying else { return }
                self.isNodePlaying = false
                await self.playNext()
            }
        }
    }

    /// Tear down any in-flight crossfade: stop the outgoing player and restore
    /// both players to full volume. Safe to call when not transitioning.
    private func cancelCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        if let out = outgoingPlayer {
            out.stop()
            out.volume = 1
            outgoingPlayer = nil
        }
        playerA.volume = 1
        playerB.volume = 1
        isTransitioning = false
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget             { [weak self] _ in self?.resume();           return .success }
        c.pauseCommand.addTarget            { [weak self] _ in self?.pause();            return .success }
        c.togglePlayPauseCommand.addTarget  { [weak self] _ in self?.togglePlayPause();  return .success }

        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.playNext() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.playPrevious() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
    }
}
