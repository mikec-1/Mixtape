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
    }

    // MARK: - Public Controls

    /// Load a new queue starting at `track` and begin playback.
    public func play(track: Track, in tracks: [Track]) async {
        // Capture the previous track BEFORE queue.play() overwrites currentTrack.
        addToHistory(queue.currentTrack, skippingIfSameAs: track)
        queue.play(track: track, in: tracks)
        await loadAndPlay(track: track)
    }

    public func togglePlayPause() {
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
        guard state == .playing else { return }
        pausePlayback()
        state = .paused
        stopProgressTimer()
        updateNowPlayingRate(0)
        persistPlaybackPosition()
    }

    public func resume() {
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
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.playbackRate)
        // Lock-screen rate reflects whether we're actively playing, scaled by speed.
        updateNowPlayingRate(state == .playing ? clamped : 0)
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
        let fileURL: URL

        if let local = fileStorage.localURL(for: track) {
            fileURL = local
        } else if track.file.remoteKey != nil {
            do {
                fileURL = try await fileStorage.download(track: track, accessToken: "")
            } catch {
                // Only surface the error if we're still the active load request.
                guard loadGeneration == generation else { return }
                setError("Couldn't download \"\(track.title)\" — \(error.localizedDescription)")
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
        do {
            let file = try AVAudioFile(forReading: fileURL)
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
                setError("Couldn't start the audio engine for \"\(track.title)\".")
                return
            }
            playerNode.play()
            isNodePlaying = true
            state = .playing

            // Reset scrobble tracking for the new track and announce "now playing".
            scrobbleStartedAt = Date()
            didScrobbleCurrent = false
            let nowPlayingTrack = track
            Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }

            startProgressTimer()
            updateNowPlayingInfo(track: track)
        } catch {
            guard loadGeneration == generation else { return }
            setError("Playback failed for \"\(track.title)\" — \(error.localizedDescription)")
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
    private func addToHistory(_ track: Track?, skippingIfSameAs arriving: Track?) {
        guard let track else { return }
        if let arriving, arriving.id == track.id { return }
        // Don't duplicate the top of the list.
        if recentlyPlayed.first?.id == track.id { return }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > 50 { recentlyPlayed.removeLast() }
        // Notify AppDependencies to persist this entry
        onTrackAddedToHistory?(track)
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
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if case .error = self.state { self.state = .stopped }
            self.errorMessage = nil
        }
    }

    public func stopPlayback() {
        cancelCrossfade()
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
        updateNowPlayingInfo(track: next)
        let nowPlayingTrack = next
        Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }

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
