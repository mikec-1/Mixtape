// Plays audio through AVAudioEngine and QueueService.
// Graph: players -> preMixer -> eq -> timePitch -> mainMixer -> output. The EQ node belongs to
// AudioEqualizer; gain changes apply live. Handles local files, on-demand download of remote-only
// tracks, the lock screen (MPNowPlayingInfoCenter) and hardware controls (MPRemoteCommandCenter).
// Engine completion handlers run off-main and hop back with `Task { @MainActor in ... }`.

import AVFoundation
import MediaPlayer
import Combine
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog
internal import Helpers

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

/// Listening that records nothing: no play log, recents or scrobble. An expiry rather than a flag so it
/// can't swallow history forever after being switched on once.
public enum PrivateSession {
    private static let key = "playback.privateSessionUntil"
    public static let window: TimeInterval = 6 * 3600

    public static var expiry: Date? { UserDefaults.standard.object(forKey: key) as? Date }
    public static var isActive: Bool { (expiry ?? .distantPast) > Date() }

    public static func set(_ on: Bool) {
        let defaults = UserDefaults.standard
        if on { defaults.set(Date().addingTimeInterval(window), forKey: key) }
        else  { defaults.removeObject(forKey: key) }
    }
}

@MainActor
public final class PlaybackEngine: NSObject, ObservableObject {

    // MARK: - Published State (UI observes these)

    @Published public private(set) var state:           PlaybackState = .stopped
    /// The position, on its own object (see `PlaybackClock`). Not `@Published`: it ticks five times a second
    /// and would redraw every view holding the engine. Views that show the position observe `clock`.
    public let clock = PlaybackClock()

    /// Position in seconds, stored on `clock`.
    public private(set) var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    @Published public private(set) var duration:        TimeInterval  = 0
    /// Tracks played this session, most recent first. Capped at 50.
    @Published public private(set) var recentlyPlayed:  [Track]       = []
    /// Non-nil when a playback error just occurred. Auto-clears after 4 seconds.
    @Published public private(set) var errorMessage:    String?       = nil
    /// Output volume 0.0-1.0. Observable and mutatable from any view.
    @Published public var volume: Float = 1.0 {
        didSet { applyVolume() }
    }

    /// Called when a track enters `recentlyPlayed`, with the listen time that crossed the threshold.
    /// AppDependencies persists it via PlayHistoryRepository.
    public var onTrackAddedToHistory: ((Track, TimeInterval, QueueSource) -> Void)?

    /// Final listen time for a logged play once the user leaves the track. AppDependencies corrects the row.
    public var onPlaySecondsFinalised: ((UUID, TimeInterval) -> Void)?

    /// The lock screen / CarPlay / Watch heart; AppDependencies answers since the engine doesn't know the library.
    public var isLiked:      ((Track) -> Bool)?
    public var onRemoteLike: ((Track) async -> Void)?

    // MARK: - Online context routing (Discover)
    // Online streams can't skip through the local queue: only the playing track has a file. The coordinator
    // installs these so next/previous/end-of-track go back to it. Cleared when a library track plays.

    /// Set by OnlinePlaybackCoordinator while an online context is active; non-nil means the current track streams.
    public var onlineNextHandler: (() async -> Void)?
    /// Companion to `onlineNextHandler` for backward skips.
    public var onlinePreviousHandler: (() async -> Void)?

    /// Routes a track with no playable local file (Spotify import, history replay, metadata-only sync) to the
    /// coordinator to resolve and stream. Set by AppDependencies; returns once routing takes over. When nil the
    /// track falls through to the local path and its "not uploaded yet" error.
    public var onlineRouter: ((Track, [Track]) async -> Void)?

    /// Renders an edit this device has no file for (made on another device) from its original, and returns
    /// the file. Set by AppDependencies.
    public var editRebuilder: ((Track) async throws -> URL)?

    /// Ids whose audio is being fetched (via `onlineRouter` or from the library's store). Stops a track the
    /// resolver couldn't give a file for from bouncing between the two. Published so clicked rows can show a
    /// spinner during the fetch.
    @Published public private(set) var routingTrackIDs: Set<UUID> = []

    /// True when `track` can only play by resolving online: nothing on disk and no `remoteKey`. Covers
    /// Discover/Spotify imports and rows whose source device never uploaded the audio.
    private func needsOnlineResolution(_ track: Track) -> Bool {
        // Rebuilt from the original, never searched for by its own title.
        if track.origin == .edit { return false }
        switch AudioLocator.locate(track) {
        case .ready, .remote:      return false
        case .resolvable:          return true
        case .unavailable(let reason):
            // Nothing here and nothing to fetch, but the resolver is still better than failing.
            return reason == .notUploadedYet || reason == .fileMissing
                || reason == .sharedFromAnotherLibrary
        }
    }

    /// True when the engine can play `track` itself (file on disk or a `remoteKey`). The coordinator uses it
    /// to avoid re-resolving owned songs.
    public func canPlayLocally(_ track: Track) -> Bool {
        !needsOnlineResolution(track)
    }

    /// An edit with no file here yet. Rebuilt when played, not on a launch restore.
    private func isMissingEdit(_ track: Track) -> Bool {
        track.origin == .edit && AudioPaths.durableURL(forLocalPath: track.file.localPath) == nil
    }

    /// Hands `track` to the coordinator. False when no router is wired or it's already routing, so callers can
    /// fall back to the local path.
    private func routeOnline(_ track: Track, context: [Track]) async -> Bool {
        guard let route = onlineRouter, !routingTrackIDs.contains(track.id) else { return false }
        routingTrackIDs.insert(track.id)
        defer { routingTrackIDs.remove(track.id) }
        await route(track, context)
        return true
    }

    /// True when an online context drives playback, so skips go to the coordinator.
    public var hasOnlineContext: Bool { onlineNextHandler != nil }

    /// Clears the online handlers so the queue handles skips again.
    public func clearOnlineContext() {
        onlineNextHandler = nil
        onlinePreviousHandler = nil
    }

    // MARK: - Continuity (showing another device's playback)

    public enum RemoteTransportAction: Equatable, Sendable {
        case play, pause, next, previous, seek(TimeInterval)
    }

    /// Installed by `ContinuityService` while mirroring another device. All transport paths (buttons, scrubber,
    /// media keys, lock screen) go through the methods below, so this redirects all of them. Cleared by any
    /// local play.
    public var remoteTransport: ((RemoteTransportAction) -> Void)?

    /// Also installed while mirroring: sends a song picked here to the playing device and returns true.
    /// Picking a song doesn't move playback; only the device picker (or the other device stopping) does.
    public var remotePlayRedirect: ((Track, [Track]) -> Bool)?

    /// Shows another device's song, position and state on every player surface without playing it. Stops
    /// local audio the first time, then only updates what changed, since each publish redraws.
    public func mirrorRemote(track: Track, position: TimeInterval, duration: TimeInterval,
                             isPlaying: Bool) {
        if audioFile != nil || playbackSource == .remote || queue.currentTrack?.id != track.id {
            // ponytail: an online resolve already in flight still takes over locally when it lands; cancel routes if that bites.
            loadGeneration &+= 1  // a local load in flight must not start audio underneath
            haltCurrentAudio()
            clearOnlineContext()
            queue.restoreSession(track: track)
            self.duration = duration
            currentTime = max(0, min(position, duration))
            updateNowPlayingInfo(track: track)
        } else if let art = track.artworkData, !art.isEmpty,
                  queue.currentTrack?.displayArtwork == nil {
            // Same song, but its cover just arrived (online rows have no store copy).
            queue.fillArtwork(art, forTrackID: track.id)
            objectWillChange.send()  // nothing @Published changed; the bar reads through us
            updateNowPlayingInfo(track: track)
        }
        if self.duration != duration { self.duration = duration }
        currentTime = max(0, min(position, duration))
        let next: PlaybackState = isPlaying ? .playing : .paused
        if state != next {
            state = next
            updateNowPlayingRate(isPlaying ? 1 : 0)
        }
    }

    /// The other device went away. Its song stays on screen, stopped at its last position, so play resumes it here.
    public func endMirroring() {
        remoteTransport = nil
        remotePlayRedirect = nil
        guard audioFile == nil, playbackSource == .engine, state != .stopped else { return }
        state = .stopped
        updateNowPlayingRate(0)
    }

    /// Current playback speed multiplier (0.5-2.0). 1.0 = normal. Persisted.
    @Published public private(set) var playbackRate: Float = 1.0
    /// Track transition style, persisted. `.off` is the single-player path; `.gapless`/`.crossfade` use both players.
    @Published public private(set) var crossfadeMode: CrossfadeMode = .off
    /// Crossfade overlap length in seconds (used when mode == .crossfade). 2-12.
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
    // All lazy: nodes are only built on first playback (see `configureGraphIfNeeded`), not at launch.
    private lazy var audioEngine = AVAudioEngine()
    /// Two players on separate preMixer buses so tracks can overlap. `playerNode` is the active one; `idlePlayer`
    /// is silent until a transition. With crossfade off `usingA` never flips.
    private lazy var playerA = AVAudioPlayerNode()
    private lazy var playerB = AVAudioPlayerNode()
    private var usingA  = true
    private var playerNode: AVAudioPlayerNode { usingA ? playerA : playerB }
    private var idlePlayer: AVAudioPlayerNode { usingA ? playerB : playerA }
    private var activeBus: AVAudioNodeBus { usingA ? 0 : 1 }
    private var idleBus:   AVAudioNodeBus { usingA ? 1 : 0 }

    // Crossfade transition state
    private var crossfadeTask: Task<Void, Never>?
    private var outgoingPlayer: AVAudioPlayerNode?
    private var isTransitioning = false

    // MARK: - Play/pause fade state
    // Pause fade rides the main mixer output, not the per-player volumes crossfade owns, so pausing
    // mid-crossfade fades the whole blend and the two ramps never fight over one value.
    private enum FadePhase { case idle, fadingOut, fadingIn }
    private var fadePhase: FadePhase = .idle
    private var fadeTask: Task<Void, Never>?
    /// Bumped on every fade start/cancel so a stale ramp step can't write after a newer one took over.
    private var fadeGeneration = 0
    /// 0...1 multiplier on top of the user's `volume`. Separate so a volume change mid-ramp doesn't break the
    /// fade and the fade can't exceed the user's volume.
    private var fadeGain: Float = 1

    /// Fade-out is longer than fade-in: a slow release sounds settled, a slow attack sounds laggy.
    private static let pauseFadeDuration:  TimeInterval = 0.35
    private static let resumeFadeDuration: TimeInterval = 0.20
    /// ~60 steps/sec. Finer is inaudible and only burns main-actor hops.
    private static let fadeStepInterval:   TimeInterval = 1.0 / 60.0
    /// Presses closer than this are someone spamming play/pause. At full length each ramp is reversed before
    /// it gets anywhere, so the presses cancel out and nothing audible happens.
    private static let rapidToggleWindow:  Duration     = .milliseconds(500)
    /// Ramp used while spamming: short enough that every press is heard, long enough not to click.
    private static let rapidFadeDuration:  TimeInterval = 0.10
    private var lastToggleAt: ContinuousClock.Instant?
    /// How long the engine keeps running after a pause, so a quick resume doesn't wait on the output
    /// device restarting (slow, blocks the main actor, and Bluetooth drops the first moments).
    private static let engineIdleGrace:    Duration     = .seconds(2)
    private var engineIdleTask: Task<Void, Never>?
    /// Mixer right after the players that converts every file to one canonical format, so the EQ and
    /// TimePitch units never see a format change (TimePitch rejects it with -10868 and crashes on `connect`).
    private lazy var preMixerNode = AVAudioMixerNode()
    /// The EQ node, owned by `equalizer`.
    private var eqNode: AVAudioUnitEQ { equalizer.node }
    /// Varispeed/pitch node for playback-speed control. Sits eq -> timePitch -> mixer.
    private lazy var timePitchNode = AVAudioUnitTimePitch()
    private var graphConfigured = false

    /// The fixed format the effect chain runs at; the preMixer converts into it.
    private let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    // Sleep timer
    private var sleepTimerTask: Task<Void, Never>?

    // Last.fm: when the track started and whether it crossed the scrobble threshold.
    private var scrobbleStartedAt: Date?
    private var didScrobbleCurrent = false
    /// True once the current track crossed the minimum listen and was recorded. Reset per track.
    private var didRecordHistoryCurrent = false
    /// The logged play and how far the user got. Tracked on the tick because `currentTime` is already 0 when
    /// the next track starts.
    private var loggedPlayTrackID: UUID?
    private var loggedPlaySeconds: TimeInterval = 0

    // Last track a lyrics prefetch ran for, so it isn't repeated.
    private var lastLyricsPrefetchID: Track.ID?

    // UserDefaults keys for persisted playback state.
    private enum DefaultsKey {
        static let playbackRate      = "playback.rate"
        static let lastTrackID       = "playback.lastTrackID"
        static let lastPosition      = "playback.lastPosition"
        static let crossfadeMode     = "playback.crossfadeMode"
        static let crossfadeDuration = "playback.crossfadeDuration"
        static let crossfadeOnSkip   = "playback.crossfadeOnSkip"
        static let trimPadding       = "playback.trimPadding"
        static let normalizeVolume   = "playback.normalizeVolume"
        static let queueSnapshot     = "playback.queueSnapshot"
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
    /// Position last written to defaults, for the throttle.
    private var lastPersistedPosition: TimeInterval = 0
    private var terminationObservers: Set<AnyCancellable> = []
    /// Bumped on every load. A stale `loadAndPlay` checks it before anything irreversible. Exposed as
    /// `playbackGeneration` for long resolves (see OnlinePlaybackCoordinator.playFromContext).
    private var loadGeneration = 0

    /// Set when the user pauses while a requested song is still fetching, so the fetch finishing doesn't
    /// start it anyway. Cleared by the next play or resume.
    private var pausedWhileLoading = false

    /// Bumped by every load. Copy it before a long await; a different value after means something else took over.
    public var playbackGeneration: Int { loadGeneration }

    // MARK: Padded-source trimming
    // Online sources often have trailing silence (a 2:40 song in a 5:00 file). When the source overshoots the
    // catalogue length by more than slack, play to the catalogue length and treat that as the end.

    /// The catalogue's length for whatever is loaded, 0 when unknown.
    private var canonicalDuration: TimeInterval = 0
    /// Set once the capped end has been acted on, so a stream can't advance twice.
    private var didReachCappedEnd = false

    /// Slack for normal differences (count-in, fade, other master); the bad case is minutes, not seconds.
    private static let paddingSlack: TimeInterval = 20

    /// `seconds` trimmed to the catalogue length when the source overruns, keeping a couple of seconds so
    /// long endings aren't clipped.
    private static func trimmed(_ seconds: TimeInterval, canonical: TimeInterval) -> TimeInterval {
        // Opt-out, since a wrong catalogue length would cut the song short. On by default.
        guard UserDefaults.standard.object(forKey: DefaultsKey.trimPadding) as? Bool ?? true else { return seconds }
        guard canonical > 30, seconds > canonical + paddingSlack else { return seconds }
        return canonical + 2
    }

    /// The frame-count form, for the local file path.
    private static func trimmedFrames(_ frames: AVAudioFramePosition,
                                      sampleRate: Double,
                                      canonical: TimeInterval) -> AVAudioFramePosition {
        guard sampleRate > 0, frames > 0 else { return frames }
        let seconds = Double(frames) / sampleRate
        let capped  = trimmed(seconds, canonical: canonical)
        guard capped < seconds else { return frames }
        return AVAudioFramePosition((capped * sampleRate).rounded())
    }

    // MARK: - Remote streaming (Discover / online playback)

    /// What drives playback: `.engine` (AVAudioEngine, local files) or `.remote` (AVPlayer streaming a
    /// URL). Public controls branch on this so the player bar works the same for both.
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
        mixMainActivity("engine/init ▸ prefs") { restorePlaybackPreferences() }
        LaunchTimeline.mark("engine/prefs")
        observeAppTermination()
        // Spanned: the only thing here that creates `audioEngine` (it observes its config changes).
        mixMainActivity("engine/init ▸ observers") { observeAudioSessionEvents() }
        LaunchTimeline.mark("engine/observers")
    }

    // MARK: - Audio Graph Setup

    /// The cheap `UserDefaults` part of setup, kept in `init` because the UI binds to rate and crossfade
    /// settings before anything plays.
    private func restorePlaybackPreferences() {
        let savedRate = UserDefaults.standard.float(forKey: DefaultsKey.playbackRate)
        if savedRate >= 0.5 && savedRate <= 2.0 {
            playbackRate = savedRate
        }

        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.crossfadeMode),
           let mode = CrossfadeMode(rawValue: raw) {
            crossfadeMode = mode
        }
        let savedFade = UserDefaults.standard.double(forKey: DefaultsKey.crossfadeDuration)
        if savedFade >= 2 && savedFade <= 12 { crossfadeDuration = savedFade }
    }

    /// Builds the graph: players -> preMixer -> eq -> timePitch -> mainMixer. Idempotent, not called from
    /// `init`: touching `mainMixerNode` builds the whole output chain, and most launches never play.
    private func configureGraphIfNeeded() {
        guard !graphConfigured else { return }

        audioEngine.attach(playerA)
        audioEngine.attach(playerB)
        audioEngine.attach(preMixerNode)
        audioEngine.attach(eqNode)
        audioEngine.attach(timePitchNode)

        // Players connect per file (`connectPlayer`). Everything after the preMixer stays at the canonical
        // format. The idle player has nothing scheduled until a transition.
        audioEngine.connect(playerA, to: preMixerNode, fromBus: 0, toBus: 0, format: canonicalFormat)
        audioEngine.connect(playerB, to: preMixerNode, fromBus: 0, toBus: 1, format: canonicalFormat)
        audioEngine.connect(preMixerNode, to: eqNode, format: canonicalFormat)
        audioEngine.connect(eqNode, to: timePitchNode, format: canonicalFormat)
        audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: canonicalFormat)

        playerA.volume = 1
        playerB.volume = 1
        timePitchNode.rate = playbackRate

        audioEngine.prepare()
        graphConfigured = true
        // Apply the volume set before the graph existed.
        applyVolume()
    }

    /// Reconnects the active player for the loaded file's format. Called before scheduling a new file.
    private func connectGraph(for format: AVAudioFormat) {
        configureGraphIfNeeded()
        connectPlayer(playerNode, bus: activeBus, format: format)
    }

    /// Reconnects one player's preMixer bus for `format`; the preMixer converts it so the effects never renegotiate.
    private func connectPlayer(_ player: AVAudioPlayerNode, bus: AVAudioNodeBus, format: AVAudioFormat) {
        configureGraphIfNeeded()
        audioEngine.connect(player, to: preMixerNode, fromBus: 0, toBus: bus, format: format)
    }

    /// Start the engine if it isn't already running. Returns true on success.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        configureGraphIfNeeded()
        guard !audioEngine.isRunning else { return true }
        do {
            try audioEngine.start()
            return true
        } catch {
            MixLog.playback.error("[PlaybackEngine] Failed to start AVAudioEngine: \(error)")
            return false
        }
    }

    /// The one place output level is written: user `volume` times `fadeGain`, so neither overwrites the other.
    private func applyVolume() {
        let level = volume * fadeGain * normalizationGain
        // Naming `mainMixerNode` would build the graph; `configureGraphIfNeeded` calls this again once it exists.
        if graphConfigured {
            audioEngine.mainMixerNode.outputVolume = level
        }
        // Mirror to the remote player so the volume slider also works while streaming.
        remotePlayer?.volume = level
    }

    // MARK: - Volume normalization

    /// Per-song level correction, linear, never above 1. Combined in `applyVolume`.
    private var normalizationGain: Float = 1

    private static var normalizesVolume: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.normalizeVolume) as? Bool ?? true
    }

    /// ponytail: attenuation only, since both volumes cap at 1 and quiet songs stay quiet. Boosting needs a
    /// limiter; most rips are louder than the target anyway.
    private static func attenuation(_ db: Float) -> Float { db >= 0 ? 1 : pow(10, db / 20) }

    /// Points the output at `url`'s measured level. Unmeasured files and streams start at the library's typical
    /// correction and get measured in the background.
    private func normalize(to url: URL?) {
        guard Self.normalizesVolume else {
            normalizationGain = 1
            applyVolume()
            return
        }
        if let url, let db = LoudnessAnalyzer.cachedGainDB(for: url) {
            normalizationGain = Self.attenuation(db)
            applyVolume()
            return
        }
        normalizationGain = Self.attenuation(LoudnessAnalyzer.typicalGainDB)
        applyVolume()
        guard let url else { return }
        let generation = loadGeneration
        Task { [weak self] in
            guard let db = await LoudnessAnalyzer.measureGainDB(for: url) else { return }
            guard let self, self.loadGeneration == generation else { return }
            self.normalizationGain = Self.attenuation(db)
            self.applyVolume()
        }
    }

    /// Re-reads the setting for the current song so the Settings switch applies immediately.
    public func reapplyNormalization() {
        normalize(to: playbackSource == .engine ? audioFile?.url : nil)
    }

    // MARK: - Public Controls

    /// Loads a new queue starting at `track` and plays it.
    /// `startIndex` is for callers pointing at a row (Queue panel click), since a song can be queued twice.
    /// `resolved` marks the coordinator handing back a resolved song. That call arrives while the id is still
    /// in `routingTrackIDs`, and without the flag the re-entry guards would drop it as a duplicate click.
    /// `source` names the list for the queue's "Next up: <name>" header. Passed in because `QueueService.play`
    /// resets it, and setting it later races a fetch.
    public func play(track: Track, in tracks: [Track], startIndex: Int? = nil,
                     resolved: Bool = false, source: QueueSource = .none) async {
        // A user play outranks an earlier pause. Not the resolver handoff, which may have been paused since.
        if !resolved { pausedWhileLoading = false }
        // Feeds the Library's Recents order.
        if !resolved {
            switch source {
            case .playlist(let id, _): PlaylistMetadataService.shared.markPlayed(playlistID: id)
            case .named(let name) where name == track.albumTitle:
                PlaylistMetadataService.shared.markAlbumPlayed(title: name, artistName: track.artistName)
            default: break
            }
        }
        if !resolved, remoteTransport != nil,
           remotePlayRedirect?(track, tracks) == true { return }
        remoteTransport = nil
        // No local file and no remoteKey: resolve and stream via the coordinator. It plays the resolved file
        // back through here with `localPath` set.
        if needsOnlineResolution(track), !resolved {
            // Already resolving; a second tap would hit the local path and show "no audio" for a downloading song.
            if routingTrackIDs.contains(track.id) { return }
            if await routeOnline(track, context: tracks) { return }
        }
        // Same for a song downloading from the library store. Not for the resolver's handoff, which is the download arriving.
        if !resolved, routingTrackIDs.contains(track.id) {
            // Logged because this click produces nothing visible.
            MixLog.playback.debug("[PlaybackEngine] Ignored play of \"\(track.title)\", already routing")
            return
        }
        // A direct play takes over the local queue. The coordinator reinstalls its handlers right after if it's
        // driving an online track.
        clearOnlineContext()
        // Resolve lyrics now so they're cached by the time Now Playing opens.
        LyricsService.shared.prefetch(for: track)
        // The queue goes to the load instead of being written now: the player bar reads it, so writing it early
        // shows the new song while the old one is still playing. See `handOver`.
        await loadAndPlay(track: track, publishing: tracks, startIndex: startIndex,
                          resolved: resolved, source: source)
    }

    /// Through `pause()`/`resume()` so there's one path into each fade.
    public func togglePlayPause() {
        if let remoteTransport { remoteTransport(state == .playing ? .pause : .play); return }
        switch state {
        case .playing: pause()
        case .paused:  resume()
        default:
            // Stopped with songs queued ("Add to Queue" doesn't start playback), so play starts the queue.
            // `play(track:in:)` routes a row with no file through the coordinator.
            guard let first = queue.currentTrack ?? queue.queue.first else { break }
            // Stopped part-way (another device handed back), so start from there.
            let resumeAt = currentTime
            Task {
                await play(track: first, in: queue.queue)
                guard resumeAt > 1 else { return }
                await waitUntilPlaying(timeout: 20)
                if queue.currentTrack?.id == first.id { seek(to: resumeAt) }
            }
        }
    }

    /// If `trackID` is loaded, stops and clears the queue so the player shows nothing. Call before deleting a track.
    public func stopIfPlaying(trackID: Track.ID) {
        guard queue.currentTrack?.id == trackID else { return }
        stopPlayback()
        queue.clearCurrentTrack()
    }

    public func pause() {
        if let remoteTransport { remoteTransport(.pause); return }
        guard state == .playing else { return }
        // A song is loading behind this; remember the pause so the handover respects it.
        if !routingTrackIDs.isEmpty { pausedWhileLoading = true }
        // Update state now so the button feels instant; the audio takes ~0.35s to fade.
        state = .paused
        updateNowPlayingRate(0)
        // Save the session on pause; a crash or force quit never reaches the termination hook.
        persistQueueSnapshot()
        // Remote streams use the AVPlayer observer, not this timer. Stopping it also keeps
        // `maybeStartCrossfade()` from starting during the fade.
        if playbackSource != .remote { stopProgressTimer() }
        // The player runs until the ramp hits zero, see `haltAfterPauseFade`.
        startFade(to: 0, over: toggleFadeDuration(Self.pauseFadeDuration), phase: .fadingOut)
    }

    /// Waits until audio is playing or `timeout` elapses, for speculative work (cache fills, warming the next
    /// track) that shouldn't compete with the buffer. Returns on timeout. Polled at 100ms: observing
    /// `$state` emits nothing during a stall, the case that matters.
    public func waitUntilPlaying(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .playing { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// How a stream handed to `playOnlineStream` turned out.
    public enum StreamStart: Sendable {
        /// Audio is advancing.
        case playing
        /// AVPlayer gave up on the item (403, unsupported format, refused connection).
        case failed
        /// Neither before the deadline; to the listener, the same as `failed`.
        case timedOut
    }

    /// Seconds of the stream AVPlayer has loaded, or nil when nothing streams. The only progress measure on
    /// the streaming path.
    public var remoteBufferedSeconds: TimeInterval? {
        guard let item = remotePlayer?.currentItem else { return nil }
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return nil }
        let loaded = range.start.seconds + range.duration.seconds
        return loaded.isFinite ? max(0, loaded) : nil
    }

    /// Waits until a new remote stream plays or fails. Unlike `waitUntilPlaying`, `failed` arrives fast for a
    /// rejected URL, so the fallback starts right away instead of at the deadline.
    public func awaitStreamStart(timeout: TimeInterval) async -> StreamStart {
        /// A stream held at 0:00 by a mid-fetch pause counts as started, or the caller would time out and download
        /// a copy nobody is listening to.
        func started() -> Bool {
            state == .playing || (state == .paused && pausedWhileLoading)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if started() { return .playing }
            if remotePlayer?.currentItem?.status == .failed { return .failed }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return started() ? .playing : .timedOut
    }

    public func resume() {
        if let remoteTransport { remoteTransport(.play); return }
        guard state == .paused else { return }
        pausedWhileLoading = false
        state = .playing
        updateNowPlayingRate(playbackRate)
        // A song that arrived paused (launch restore, mid-fetch pause) was never announced; scrobble from now.
        if scrobbleStartedAt == nil, let track = queue.currentTrack {
            scrobbleStartedAt = Date()
            Task { await LastFmScrobbler.shared.updateNowPlaying(track: track) }
        }

        if fadePhase == .fadingOut {
            // The pause fade hadn't reached silence, so the player never stopped. Reverse the ramp; restarting would stutter.
        } else {
            // Fully halted: come up from silence so the restart isn't a click.
            fadeGain = 0
            applyVolume()
            #if os(iOS)
            activateAudioSession()
            #endif
            if playbackSource == .remote { resumeRemoteAtRate() } else { resumePlayback() }
        }
        if playbackSource != .remote { startProgressTimer() }
        startFade(to: 1, over: toggleFadeDuration(Self.resumeFadeDuration), phase: .fadingIn)
    }

    #if os(iOS)
    /// A non-mixable session stops other apps' audio, so only activate when something is about to play.
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            MixLog.playback.error("[PlaybackEngine] Audio session error: \(error)")
        }
    }
    #endif

    /// Seeks to `time` seconds, playing or paused, by rescheduling the file from that frame.
    public func seek(to time: TimeInterval) {
        if let remoteTransport {
            currentTime = max(0, min(time, duration))   // the scrubber lands now, not on the echo
            remoteTransport(.seek(time))
            return
        }
        // Nothing loaded (the queue ran out) but the UI still shows the track, so reload it and start there.
        if state == .stopped, audioFile == nil, playbackSource == .engine,
           let track = queue.currentTrack {
            Task { @MainActor in
                await loadAndPlay(track: track)
                // Only if it loaded, or a failed reload retries forever.
                if audioFile != nil { seek(to: time) }
            }
            return
        }
        if playbackSource == .remote {
            guard let player = remotePlayer, duration > 0 else { return }
            let clamped = max(0, min(time, duration))
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
            // Scrubbing back out of a trimmed ending re-arms it.
            if clamped < duration { didReachCappedEnd = false }
            currentTime = clamped
            updateNowPlayingTime()
            return
        }
        guard let file = audioFile, fileLengthFrames > 0 else { return }
        cancelCrossfade()
        // Just short of the end: seeking to exactly `duration` schedules zero frames and never completes.
        let clamped = max(0, min(time, duration - 0.05))
        let targetFrame = AVAudioFramePosition(clamped * fileSampleRate)

        let wasPlaying = (state == .playing)

        // Bump generation so the old segment's completion doesn't auto-advance.
        loadGeneration &+= 1
        let generation = loadGeneration

        playerNode.stop()           // fires the old completion handler (now stale)
        isNodePlaying = false

        scheduleSegment(of: file, startingAtFrame: targetFrame, generation: generation)

        currentTime = clamped

        if wasPlaying, startEngineIfNeeded() {
            playerNode.play()
            isNodePlaying = true
        }
        updateNowPlayingTime()
        persistPlaybackPosition()
    }

    public func playNext() async {
        if let remoteTransport { remoteTransport(.next); return }
        // Natural endings also land here, so only a jump with over 5s left counts as a skip.
        if let track = queue.currentTrack, duration > 0, currentTime < duration - 5 {
            Analytics.track("skip", [
                "track_id": .string(track.id.uuidString.lowercased()),
                "title":    .string(track.title),
                "artist":   .string(track.artistName),
                "seconds":  .double(currentTime.rounded()),
                "duration": .double(duration.rounded()),
                "source":   .string(queue.source.historyRef?.kind ?? "none")
            ])
            if currentTime < 30 { SkipHistory.noteEarlySkip(title: track.identityTitle, artist: track.artistName) }
        }
        // Online context: advance through the coordinator, which downloads the next track.
        if let handler = onlineNextHandler {
            await handler()
            return
        }
        if beginSkipCrossfade() { return }
        // Skip songs already known to be unfindable. Bounded: with repeat on, `advance()` never returns nil.
        for _ in 0..<queue.queue.count {
            guard let next = queue.advance() else { break }
            if UnavailableTracks.shared.contains(next), !canPlayLocally(next) {
                UnavailableTracks.shared.mark(title: next.identityTitle,
                                              artist: next.artistName, announce: true)
                continue
            }
            await loadAndPlay(track: next)
            return
        }
        stopPlayback()
    }

    public func playPrevious() async {
        if let remoteTransport { remoteTransport(.previous); return }
        // Within the first 3 seconds: restart current track instead of going back.
        if currentTime > 3, queue.currentTrack != nil {
            seek(to: 0)
            if state == .paused { resume() }
            return
        }
        // Online context active -> step back through the Discover context.
        if let handler = onlinePreviousHandler {
            await handler()
            return
        }
        if let prev = queue.previous() {
            await loadAndPlay(track: prev)
        }
    }

    // MARK: - Playback Speed

    /// Sets the speed, clamped to 0.5...2.0. Applied live via the time-pitch node (pitch kept) and persisted.
    public func setRate(_ rate: Float) {
        let clamped = max(0.5, min(rate, 2.0))
        playbackRate = clamped
        timePitchNode.rate = clamped
        // Streams use the AVPlayer rate; pitch is kept by `audioTimePitchAlgorithm` set at load.
        if playbackSource == .remote, state == .playing { remotePlayer?.rate = clamped }
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.playbackRate)
        // Lock-screen rate reflects whether we're actively playing, scaled by speed.
        updateNowPlayingRate(state == .playing ? clamped : 0)
    }

    /// Resumes the AVPlayer at the chosen speed; setting `rate` both starts it and applies it.
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
            lastPersistedPosition = currentTime
        }
    }

    /// Saves the whole queue, not just the song, so a relaunch restores what comes next. Not on the position
    /// tick: a queue the size of All Songs is thousands of rows.
    private func persistQueueSnapshot() {
        let defaults = UserDefaults.standard
        guard queue.currentTrack != nil,
              let data = try? JSONEncoder().encode(queue.snapshot) else {
            defaults.removeObject(forKey: DefaultsKey.queueSnapshot)
            return
        }
        defaults.set(data, forKey: DefaultsKey.queueSnapshot)
    }

    /// The same save, at most every few seconds, from the 0.2s tick. At most three seconds are lost on quit.
    private func persistPlaybackPositionThrottled() {
        guard state == .playing else { return }
        guard abs(currentTime - lastPersistedPosition) >= 3 else { return }
        persistPlaybackPosition()
    }

    // MARK: - Interruptions & Route Changes
    // Interruptions, route changes and configuration changes. Common on iOS, rare on the Mac:
    // 1. Interruption (call, alarm, Siri) stops the engine. On end, reactivate the session and resume if allowed.
    // 2. Route change that removed the output (headphones out) must pause.
    // 3. Configuration change tore down the graph's connections; remake them before restarting.

    /// True when the system stopped playback, so the interruption's end knows whether to resume.
    private var wasPlayingBeforeInterruption = false

    private func observeAudioSessionEvents() {
        let center = NotificationCenter.default

        #if os(iOS)
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &terminationObservers)

        center.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleRouteChange(note) }
            .store(in: &terminationObservers)
        #endif

        center.publisher(for: .AVAudioEngineConfigurationChange, object: audioEngine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleEngineConfigurationChange() }
            .store(in: &terminationObservers)
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = (state == .playing)
            MixLog.playback.debug("[PlaybackEngine] Audio interrupted (was playing: \(self.wasPlayingBeforeInterruption))")
            // Through `pause()` so the UI, lock screen and fade match the silence.
            if state == .playing { pause() }

        case .ended:
            let options: AVAudioSession.InterruptionOptions = {
                guard let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return [] }
                return AVAudioSession.InterruptionOptions(rawValue: raw)
            }()
            MixLog.playback.debug("[PlaybackEngine] Interruption ended (shouldResume: \(options.contains(.shouldResume)))")
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else {
                wasPlayingBeforeInterruption = false
                return
            }
            wasPlayingBeforeInterruption = false
            // The session was deactivated; `resume()` can't make sound without reactivating it.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                MixLog.playback.error("[PlaybackEngine] Could not reactivate session after interruption: \(error)")
                return
            }
            resume()

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Only losing the device we were playing to matters; the system handles the rest.
        guard reason == .oldDeviceUnavailable else { return }
        MixLog.playback.debug("[PlaybackEngine] Output device went away, pausing")
        if state == .playing { pause() }
    }
    #endif

    /// The graph was rebuilt. Reconnect it and restart if a song was playing.
    private func handleEngineConfigurationChange() {
        MixLog.playback.debug("[PlaybackEngine] Audio engine reconfigured, rebuilding the graph")
        // Nothing to reconnect if nothing was ever connected.
        guard graphConfigured else { return }
        // Nodes are still attached, only the connections are gone, so reconnect rather than rebuild.
        audioEngine.connect(playerA, to: preMixerNode, fromBus: 0, toBus: 0, format: canonicalFormat)
        audioEngine.connect(playerB, to: preMixerNode, fromBus: 0, toBus: 1, format: canonicalFormat)
        audioEngine.connect(preMixerNode, to: eqNode, format: canonicalFormat)
        audioEngine.connect(eqNode, to: timePitchNode, format: canonicalFormat)
        audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: canonicalFormat)
        if let format = audioFile?.processingFormat {
            connectPlayer(playerNode, bus: activeBus, format: format)
        }
        applyVolume()
        audioEngine.prepare()

        guard playbackSource == .engine, state == .playing else { return }
        startEngineIfNeeded()
        if !isNodePlaying {
            playerNode.play()
            isNodePlaying = true
        }
    }

    /// Save on quit, logout or shutdown: the position the user will see next.
    private func observeAppTermination() {
        let center = NotificationCenter.default
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.willTerminateNotification,
                                          NSApplication.willResignActiveNotification]
        #else
        // iOS can kill a suspended app without warning, so background/resign is the last safe point.
        let names: [Notification.Name] = [UIApplication.willTerminateNotification,
                                          UIApplication.didEnterBackgroundNotification]
        #endif
        for name in names {
            center.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Read the clock; up to 0.2s played since the last tick.
                    if self.state == .playing { self.currentTime = self.currentPlaybackTime() }
                    self.persistPlaybackPosition()
                    self.persistQueueSnapshot()
                }
                .store(in: &self.terminationObservers)
        }
    }

    /// Sign-out and account switch: stop, empty the queue and clear the saved song, position and queue so the
    /// next account doesn't inherit them.
    public func forgetLastSession() {
        stopPlayback()
        clearOnlineContext()
        queue.clearCurrentTrack()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.lastTrackID)
        defaults.removeObject(forKey: DefaultsKey.lastPosition)
        defaults.removeObject(forKey: DefaultsKey.queueSnapshot)
    }

    /// Restores the last session paused at its saved position. Call once at launch after the library loads.
    public func restoreLastSession(allTracks: [Track]) {
        guard state == .stopped else { return }
        let defaults = UserDefaults.standard
        guard
            let idString = defaults.string(forKey: DefaultsKey.lastTrackID),
            let uuid = UUID(uuidString: idString),
            let track = allTracks.first(where: { $0.id == uuid })
        else { return }
        let position = defaults.double(forKey: DefaultsKey.lastPosition)
        // The saved queue first. The saved track still decides what's loaded, since the snapshot may have lost it.
        var restoredQueue = false
        if let data = defaults.data(forKey: DefaultsKey.queueSnapshot),
           let snapshot = try? JSONDecoder().decode(QueueService.Snapshot.self, from: data) {
            let byID = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            restoredQueue = queue.restore(snapshot, from: byID) != nil
        }
        Task { @MainActor in
            await loadButPause(track: track, at: position, keepingQueue: restoredQueue)
        }
    }

    /// Reloads the current song from whatever copy `AudioLocator` finds, keeping the queue. Used by "Wrong version".
    public func reloadCurrent() async {
        guard let track = queue.currentTrack else { return }
        await loadAndPlay(track: track)
    }

    /// Tape decks: puts a parked queue back, paused at `position` or playing on. Nil empties the player.
    public func loadDeck(_ snapshot: QueueService.Snapshot?, at position: TimeInterval,
                         from tracks: [UUID: Track], play: Bool) async {
        stopPlayback()
        clearOnlineContext()
        guard let snapshot, let track = queue.restore(snapshot, from: tracks) else {
            forgetLastSession()
            return
        }
        await loadButPause(track: track, at: position, keepingQueue: true)
        persistPlaybackPosition()
        persistQueueSnapshot()
        if play { togglePlayPause() }
    }

    /// Load `track` and leave it paused at `position` seconds (resume-on-launch path).
    private func loadButPause(track: Track, at position: TimeInterval,
                              keepingQueue: Bool = false) async {
        // A restored queue already holds this song; the one-track queue is for sessions without a snapshot.
        if !(keepingQueue && queue.currentTrack?.id == track.id) {
            queue.restoreSession(track: track)
        }
        // Tracks with no cached file aren't resolved at launch. Restore the UI and stay stopped; play() routes it when tapped.
        if needsOnlineResolution(track) || isMissingEdit(track) {
            state = .stopped
            return
        }
        // Load suspended so a restore doesn't start the song, scrobble and then pause. Cleared after in case
        // the load never consumed it.
        pausedWhileLoading = true
        await loadAndPlay(track: track)
        pausedWhileLoading = false
        if duration > 0 {
            seek(to: min(position, duration))
        }
        pausePlayback()
        state = .paused
        stopProgressTimer()
        updateNowPlayingRate(0)
    }

    // MARK: - Private: Load & Play

    /// Stops what's playing and puts `track` in its place: audio, transport state and (if this load owns
    /// one) the queue, in the same turn so they can't disagree. This is when the bar shows the new song.
    private func handOver(to track: Track, publishing context: [Track]?, startIndex: Int? = nil,
                          source: QueueSource = .none) {
        mixMainActivity("engine/hand-over") {
            handOverBody(to: track, publishing: context, startIndex: startIndex, source: source)
        }
    }

    private func handOverBody(to track: Track, publishing context: [Track]?, startIndex: Int? = nil,
                              source: QueueSource = .none) {
        // Spanned separately: `haltCurrentAudio` may create the first node, and `queue.play` publishes the whole context.
        remoteTransport = nil
        mixMainActivity("engine/hand-over ▸ halt") { haltCurrentAudio() }
        state = .loading
        if let context {
            mixMainActivity("engine/hand-over ▸ publish-queue") {
                queue.play(track: track, in: context, startIndex: startIndex)
                // Same turn as the queue, since `queue.play` clears the source.
                queue.setSource(source)
            }
        }
    }

    /// Stops the outgoing song and clears what the next one would inherit.
    private func haltCurrentAudio() {
        // A local load replaces any remote stream; hand control back to the engine.
        if playbackSource == .remote {
            teardownRemotePlayer()
            playbackSource = .engine
        }
        // Cancel any crossfade or pause fade, or the new track starts at the ramp's gain.
        cancelCrossfade()
        resetFade()
        // Before the graph exists nothing has played, and naming `playerNode` would build it (costly, e.g.
        // during the launch restore).
        if graphConfigured { playerNode.stop() }
        isNodePlaying = false
        audioFile = nil
        stopProgressTimer()
        currentTime = 0
        seekFrameOffset = 0
    }

    /// Loads `track` and plays it. `publishing` is the queue this load owns, non-nil only from
    /// `play(track:in:)`, so the queue lands with the audio (see `handOver`).
    private func loadAndPlay(track: Track, publishing pending: [Track]? = nil,
                             startIndex: Int? = nil, resolved: Bool = false,
                             source: QueueSource = .none) async {
        // Supersede any in-flight load or segment.
        loadGeneration &+= 1
        let generation = loadGeneration

        // 1. Find the audio. `AudioLocator` decides which copy wins.
        var fileURL: URL
        let location = AudioLocator.locate(track)

        // A file on disk swaps now. A song that still has to be fetched keeps the old one playing and named until
        // it arrives, like the online path. Only when this call owns the queue: skips and auto-advance already
        // moved it, so for them cutting now keeps things in step.
        let waitsForAudio: Bool = {
            guard pending != nil else { return false }
            if case .ready = location { return false }
            return true
        }()
        if !waitsForAudio { handOver(to: track, publishing: pending, startIndex: startIndex, source: source) }

        switch location {
        case .ready(let url, _):
            fileURL = url

        case .remote:
            // Published so the clicked row shows a spinner during the download.
            routingTrackIDs.insert(track.id)
            do {
                fileURL = try await fileStorage.download(track: track, accessToken: "")
                routingTrackIDs.remove(track.id)
            } catch {
                routingTrackIDs.remove(track.id)
                // Only surface the error if we're still the active load request.
                guard loadGeneration == generation else { return }
                if waitsForAudio { haltCurrentAudio() }
                setError("Couldn't download \"\(track.title)\". Check your connection and try again.")
                MixLog.playback.error("[PlaybackEngine] Download failed for \"\(track.title)\": \(error)")
                return
            }
            guard loadGeneration == generation else { return }
            handOver(to: track, publishing: pending, startIndex: startIndex, source: source)

        case .unavailable where track.origin == .edit:
            // Made on another device: render it here from this library's copy of the original.
            routingTrackIDs.insert(track.id)
            var rebuilt: URL?
            do { rebuilt = try await editRebuilder?(track) } catch {
                MixLog.playback.error("[PlaybackEngine] Couldn't rebuild edit \"\(track.title)\": \(error)")
            }
            routingTrackIDs.remove(track.id)
            guard loadGeneration == generation else { return }
            guard let rebuilt else {
                if waitsForAudio { haltCurrentAudio() }
                setError("Couldn't make \"\(track.title)\" on this device. The song it was made from isn't available.")
                return
            }
            fileURL = rebuilt
            handOver(to: track, publishing: pending, startIndex: startIndex, source: source)

        case .resolvable, .unavailable:
            guard loadGeneration == generation else { return }
            // Paths that came through play(track:in:) already tried the resolver; queue-driven ones (auto-advance,
            // skip, crossfade, launch resume) get one try, with the live queue as context so the rest of it survives
            // the handoff. `.unavailable` rows that might be findable (never uploaded, shared) are tried too: a
            // failed search beats refusing to look.
            let worthResolving: Bool = {
                if case .resolvable = location { return true }
                if case .unavailable(let reason) = location {
                    return reason == .notUploadedYet || reason == .fileMissing
                        || reason == .sharedFromAnotherLibrary
                }
                return false
            }()
            // Not for the resolver's handoff, which would bounce.
            if worthResolving, !resolved, await routeOnline(track, context: queue.queue) { return }
            guard loadGeneration == generation else { return }
            // Still in flight from an earlier tap, so don't report "can't play" yet. The handoff is the exception:
            // it holds its own id, and silence would leave the spinner up.
            if !resolved, routingTrackIDs.contains(track.id) {
                MixLog.playback.debug("[PlaybackEngine] No audio yet for \"\(track.title)\", still routing")
                return
            }

            // Nothing will play, so stop the outgoing song that kept running during all of the above.
            if waitsForAudio { haltCurrentAudio() }
            if case .unavailable(let reason) = location {
                setError(reason.message(for: track.title))
            } else {
                setError(UnavailableReason.needsInternet.message(for: track.title))
            }
            MixLog.playback.error("[PlaybackEngine] No playable audio for \"\(track.title)\" (\(String(describing: location)))")
            return
        }

        // Abort if a newer play() call has already taken over.
        guard loadGeneration == generation else { return }

        // 2. Claim the audio session, unless this load starts paused.
        #if os(iOS)
        if !pausedWhileLoading { activateAudioSession() }
        #endif

        // 3. Open the file, reconnect the graph for its format, schedule and play. Throws so the caller can
        // self-heal once.
        func openAndPlay(_ url: URL) throws {
            let startSuspended = pausedWhileLoading
            pausedWhileLoading = false
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat

            audioFile        = file
            fileSampleRate   = processingFormat.sampleRate
            // Trimmed: duration, the scheduled segment and auto-advance all measure from this.
            fileLengthFrames = Self.trimmedFrames(file.length,
                                                  sampleRate: processingFormat.sampleRate,
                                                  canonical: track.duration)
            canonicalDuration = track.duration
            seekFrameOffset  = 0
            duration         = fileLengthFrames > 0 ? Double(fileLengthFrames) / fileSampleRate : 0
            currentTime      = 0

            // TimePitch rejects a format change while running (-10868 on skip), so stop the engine before
            // reconnecting; startEngineIfNeeded() restarts it.
            if audioEngine.isRunning { audioEngine.stop() }
            connectGraph(for: processingFormat)

            scheduleSegment(of: file, startingAtFrame: 0, generation: generation)
            normalize(to: url)

            // A paused load leaves the engine off; `resume()` starts it.
            if !startSuspended, !startEngineIfNeeded() {
                throw NSError(domain: "PlaybackEngine", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "audio engine wouldn't start"])
            }
            clearError()
            if startSuspended {
                // Loaded, scheduled and silent at 0:00; `resume()` starts the segment already on the node.
                state = .paused
                updateNowPlayingRate(0)
            } else {
                playerNode.play()
                isNodePlaying = true
                state = .playing
            }
            ResolveTrace.shared.end("first audible (file)")
            Self.reportPlayStartCost()

            // Reset scrobble tracking for the new track and announce "now playing".
            scrobbleStartedAt = startSuspended ? nil : Date()
            didScrobbleCurrent = false
            rotateHistoryTracking()
            if !startSuspended {
                let nowPlayingTrack = track
                Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }
                startProgressTimer()
            }
            updateNowPlayingInfo(track: track)

            // Warm the lyrics cache in the background for the new current track.
            prefetchLyrics(for: track)
        }

        do {
            try openAndPlay(fileURL)
        } catch {
            guard loadGeneration == generation else { return }
            MixLog.playback.error("[PlaybackEngine] First open failed for \"\(track.title)\": \(error), attempting self-heal")

            // Self-heal: a corrupt cache copy (bad ID3-on-m4a, truncated fetch) throws kAudioFileInvalidFileError,
            // so delete it and fetch again. Only cache copies, never the user's exported files.
            if case .ready(_, let kind) = location, kind == .cached {
                try? FileManager.default.removeItem(at: fileURL)
            }

            var healedURL: URL? = AudioLocator.readyURL(for: track)
            // If the only copy left was the deleted one, download a fresh copy.
            if (healedURL == nil || healedURL == fileURL), track.file.remoteKey != nil {
                healedURL = try? await fileStorage.download(track: track, accessToken: "")
            }

            guard loadGeneration == generation else { return }

            if let healedURL, healedURL != fileURL {
                do {
                    fileURL = healedURL
                    try openAndPlay(healedURL)
                    MixLog.playback.debug("[PlaybackEngine] Self-heal succeeded for \"\(track.title)\"")
                    return
                } catch {
                    guard loadGeneration == generation else { return }
                    MixLog.playback.error("[PlaybackEngine] Self-heal retry failed for \"\(track.title)\": \(error)")
                }
            }

            setError("Couldn't play \"\(track.title)\" right now. Please try again.")
            MixLog.playback.error("[PlaybackEngine] Playback failed for \"\(track.title)\": \(error)")
        }
    }

    /// Schedules `file` from `startingAtFrame` to its end. The completion auto-advances, guarded by the
    /// generation so it never fires after a stop, seek or new load.
    private func scheduleSegment(of file: AVAudioFile, startingAtFrame startFrame: AVAudioFramePosition, generation: Int) {
        seekFrameOffset = startFrame
        let framesToPlay = AVAudioFrameCount(max(0, fileLengthFrames - startFrame))
        guard framesToPlay > 0 else {
            // Nothing left to play (seek at the end), so treat it as finished.
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

    /// Streams an online track with AVPlayer instead of waiting for a full download. `headers` carries the
    /// hosted resolver's bearer auth (trusted host only, see RemoteResolverService). The coordinator installs
    /// the next/previous handlers after this returns; end-of-stream reads `onlineNextHandler` live.
    public func playOnlineStream(url: URL, headers: [String: String], track: Track) async {
        // A streaming load takes over the queue and supersedes any engine playback.
        clearOnlineContext()
        // Warm lyrics in parallel with buffering (coalesces with the tap-time prefetch).
        prefetchLyrics(for: track)
        // Surface the new track in the queue/player bar.
        queue.play(track: track, in: [track])
        await startRemoteStream(url: url, headers: headers, track: track)
    }

    /// Configures and starts the AVPlayer. The caller has already updated the queue and history.
    private func startRemoteStream(url: URL, headers: [String: String], track: Track) async {
        remoteTransport = nil
        // Supersede any engine playback.
        cancelCrossfade()
        resetFade()
        loadGeneration &+= 1
        playerNode.stop()
        isNodePlaying = false
        audioFile = nil
        stopProgressTimer()
        if audioEngine.isRunning { audioEngine.pause() }

        // Reset and switch to the remote backend.
        teardownRemotePlayer()
        playbackSource = .remote
        // No file to measure, so use the typical correction or a Discover song stands out.
        normalize(to: nil)
        currentTime = 0
        duration    = track.duration       // provisional; refined once the item loads
        canonicalDuration  = track.duration
        didReachCappedEnd  = false
        state       = .loading

        #if os(iOS)
        if !pausedWhileLoading { activateAudioSession() }
        #endif

        // Inject auth headers (bearer) so the hosted resolver authorises the stream.
        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset  = AVURLAsset(url: url, options: options)
        let item   = AVPlayerItem(asset: asset)
        // Preserve pitch when the user changes playback speed.
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        remotePlayer = player
        // Through applyVolume() so the stream opens at the same composed level.
        applyVolume()

        // Drive currentTime/duration/state from the player's clock.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        remoteTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.playbackSource == .remote else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : self.currentTime
                // The remote clock doesn't run the progress timer, so it calls the throttle itself.
                self.persistPlaybackPositionThrottled()
                if let d = self.remotePlayer?.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    self.duration = Self.trimmed(d.seconds, canonical: self.canonicalDuration)
                }
                // A trimmed stream never hits its own end notification, so advance here.
                if self.duration > 0, self.currentTime >= self.duration,
                   !self.didReachCappedEnd,
                   self.remotePlayer.map({ player in
                       (player.currentItem?.duration.seconds ?? 0) > self.duration + 0.5
                   }) == true {
                    self.didReachCappedEnd = true
                    if let handler = self.onlineNextHandler {
                        await handler()
                    } else {
                        self.stopPlayback()
                    }
                    return
                }
                if self.remotePlayer?.timeControlStatus == .playing {
                    switch self.state {
                    case .loading, .error:
                        // Clear a premature "no audio" error; the song is playing.
                        self.clearError()
                        self.state = .playing
                        // First audible audio: the end of "user pressed play".
                        ResolveTrace.shared.end("first audible (stream)")
                        Self.reportPlayStartCost()
                    default:
                        break
                    }
                }
                self.checkHistoryThreshold()
                // Streams scrobble too.
                self.checkScrobbleThreshold()
                self.updateNowPlayingTime()
            }
        }

        // At end of stream, advance through the online context if one is active, otherwise stop.
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

        // The user paused while this resolved, so it arrives loaded and silent at 0:00; `resume()` starts it.
        if pausedWhileLoading {
            // Left set: if the stream is dead and the coordinator falls back to a download, that handover must
            // respect the same pause. Only `resume()` and `play(track:in:)` clear it.
            player.rate = 0
            state = .paused
            // Don't carry the previous song's scrobble state; `resume()` starts this one's.
            scrobbleStartedAt  = nil
            didScrobbleCurrent = false
            updateNowPlayingRate(0)
            updateNowPlayingInfo(track: track)
            return
        }

        // Start at the user's chosen speed (rate > 0 begins playback).
        player.rate = playbackRate
        // Stay `.loading` until the time observer sees `.playing`, so the coordinator's watchdog can catch a
        // stalled stream and fall back to a download.
        scrobbleStartedAt  = Date()
        didScrobbleCurrent = false
        rotateHistoryTracking()
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
        // Finish any crossfade first so the outgoing player isn't left paused but scheduled.
        cancelCrossfade()
        playerNode.pause()
        isNodePlaying = false
        engineIdleTask?.cancel()
        engineIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.engineIdleGrace)
            guard !Task.isCancelled, let self, !self.isNodePlaying, self.audioEngine.isRunning else { return }
            self.audioEngine.pause()
        }
    }

    private func resumePlayback() {
        // play() on a stopped engine raises an ObjC exception.
        guard audioFile != nil, startEngineIfNeeded() else { return }
        playerNode.play()
        isNodePlaying = true
    }

    // MARK: - Play/Pause Fade
    // Pause and resume ramp the output to and from silence instead of cutting mid-waveform (which clicks).

    /// Equal-power curve, like `beginCrossfade`: a linear amplitude ramp sounds like it drops off at the end.
    /// Returns 0->1 progress so the caller can interpolate between any two gains.
    private static func fadeCurve(_ t: Float, fadingOut: Bool) -> Float {
        fadingOut ? 1 - cos(t * .pi / 2) : sin(t * .pi / 2)
    }

    /// `normal` for a lone press, the short ramp when this press follows the last one within the window.
    private func toggleFadeDuration(_ normal: TimeInterval) -> TimeInterval {
        let now = ContinuousClock.now
        defer { lastToggleAt = now }
        guard let last = lastToggleAt, now - last < Self.rapidToggleWindow else { return normal }
        return Self.rapidFadeDuration
    }

    /// Ramps `fadeGain` to `target`, cancelling any ramp in flight. Starts from the current gain, so quick
    /// pause/play/pause reverses smoothly and can't strand the gain.
    private func startFade(to target: Float, over duration: TimeInterval, phase: FadePhase) {
        cancelFade()                     // bumps fadeGeneration
        let generation = fadeGeneration
        fadePhase = phase

        let start = fadeGain
        let delta = target - start
        let steps = max(1, Int((duration / Self.fadeStepInterval).rounded()))
        guard duration > 0, abs(delta) > 0.0001 else {
            finishFade(at: target)
            return
        }
        let fadingOut = delta < 0

        fadeTask = Task { @MainActor [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(Self.fadeStepInterval))
                guard !Task.isCancelled, let self, self.fadeGeneration == generation else { return }
                let t = Float(i) / Float(steps)
                self.fadeGain = start + delta * Self.fadeCurve(t, fadingOut: fadingOut)
                self.applyVolume()
            }
            guard !Task.isCancelled, let self, self.fadeGeneration == generation else { return }
            self.finishFade(at: target)
        }
    }

    /// Land the ramp exactly on `target` and, if it was a pause, do the actual stop.
    private func finishFade(at target: Float) {
        fadeTask  = nil
        fadeGain  = target
        applyVolume()
        let completed = fadePhase
        fadePhase = .idle
        if completed == .fadingOut { haltAfterPauseFade() }
    }

    /// Drops the ramp, leaving `fadeGain` as is. The generation bump stops a task already past its
    /// `Task.isCancelled` check.
    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeGeneration &+= 1
        fadePhase = .idle
    }

    /// Cancels any ramp and restores full output. Called by every path that starts or tears down audio, or a
    /// track change mid-fade would play at the ramp's gain.
    private func resetFade() {
        cancelFade()
        fadeGain = 1
        applyVolume()
    }

    /// The end of a pause: output is silent, so the hard stop is inaudible. Only reached when nothing
    /// superseded the fade.
    private func haltAfterPauseFade() {
        guard state == .paused else { return }
        if playbackSource == .remote {
            remotePlayer?.pause()
            return
        }
        // Read the clock while the node still renders; the fade tail is real playback.
        currentTime = currentPlaybackTime()
        pausePlayback()
        persistPlaybackPosition()
    }

    // Plays aren't logged at start, only once past the minimum listen (`checkHistoryThreshold`).

    /// Records the current track as a play: prepends to `recentlyPlayed` and persists via the callback.
    /// Skips a duplicate at the top. Online tracks have stable ids, so repeats aggregate.
    private func recordCurrentPlay() {
        guard let track = queue.currentTrack else {
            MixLog.playback.debug("[history] recordCurrentPlay: no currentTrack, skipped")
            return
        }
        if recentlyPlayed.first?.id == track.id {
            MixLog.playback.debug("[history] recordCurrentPlay: '\(track.title)' already at top, skipped")
            return
        }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > 50 { recentlyPlayed.removeLast() }
        MixLog.playback.debug("[history] RECORDED '\(track.title)' id=\(track.id) online=\(track.isOnline) recentlyPlayed.count=\(self.recentlyPlayed.count)")
        SkipHistory.forgive(title: track.identityTitle, artist: track.artistName)
        onTrackAddedToHistory?(track, loggedPlaySeconds, queue.source)
    }

    /// Records the current track after 30s (or ~90% of a shorter song). Once per track.
    private func checkHistoryThreshold() {
        guard !PrivateSession.isActive else { return }
        guard let track = queue.currentTrack else { return }
        // Already logged: just keep the listen time current for the flush.
        if didRecordHistoryCurrent {
            loggedPlaySeconds = max(loggedPlaySeconds, currentTime)
            return
        }
        let target = duration > 0 ? min(30, duration * 0.9) : 30
        guard currentTime >= target else { return }
        MixLog.playback.debug("[history] threshold reached: currentTime=\(self.currentTime) target=\(target) duration=\(self.duration)")
        didRecordHistoryCurrent = true
        loggedPlayTrackID = track.id
        loggedPlaySeconds = currentTime
        recordCurrentPlay()
    }

    /// Closes the play row for the track being left and arms the log for the next. Every start path calls
    /// this so none forgets the flush.
    private func rotateHistoryTracking() {
        if let id = loggedPlayTrackID, loggedPlaySeconds > 0 {
            onPlaySecondsFinalised?(id, loggedPlaySeconds)
        }
        loggedPlayTrackID = nil
        loggedPlaySeconds = 0
        didRecordHistoryCurrent = false
    }

    /// Seeds `recentlyPlayed` from storage at launch, after AppDependencies loads history.
    public func restoreHistory(_ tracks: [Track]) {
        recentlyPlayed = Array(tracks.prefix(50))
    }

    /// Removes songs from recently played. The list never consults the library, so deletes must reach in here.
    public func forgetFromRecentlyPlayed(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let kept = recentlyPlayed.filter { !ids.contains($0.id) }
        guard kept.count != recentlyPlayed.count else { return }
        recentlyPlayed = kept
    }

    /// Clears the in-memory recently-played list. After the play log is deleted this is the only copy left,
    /// and it feeds Home, recent artists and the Recent panel.
    public func clearRecentlyPlayed() {
        recentlyPlayed = []
    }

    /// Incremented per setError so a stale auto-clear task can't wipe a newer message.
    private var errorGeneration = 0

    /// Clears the current error now. Bumps the generation so `setError`'s pending auto-clear can't wipe a
    /// newer message. Leaves `state` alone; callers set it.
    private func clearError() {
        guard errorMessage != nil else { return }
        errorGeneration &+= 1
        errorMessage = nil
    }

    /// Sets the error state and toast message, auto-clearing both after 5s.
    private func setError(_ message: String) {
        state        = .error(message)
        errorMessage = message
        errorGeneration &+= 1
        let generation = errorGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.errorGeneration == generation else { return }
            if case .error = self.state { self.state = .stopped }
            self.errorMessage = nil
        }
    }

    public func stopPlayback() {
        cancelCrossfade()
        // Stop is immediate (track deleted, queue done); kill any fade so it can't pause a new player later.
        resetFade()
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
            // 0.2s keeps the seek bar and synced lyrics smooth.
            .publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.currentTime = self.currentPlaybackTime()
                self.persistPlaybackPositionThrottled()
                self.checkScrobbleThreshold()
                self.checkHistoryThreshold()
                self.maybeStartCrossfade()
            }
    }

    /// Scrobbles once the track passes Last.fm's threshold: half its length or 4 minutes, for tracks over 30s.
    /// The scrobbler no-ops when Last.fm is off.
    private func checkScrobbleThreshold() {
        guard !didScrobbleCurrent, duration > 30, let startedAt = scrobbleStartedAt else { return }
        let threshold = min(duration / 2, 240)
        guard currentTime >= threshold, let track = queue.currentTrack else { return }
        didScrobbleCurrent = true
        Task { await LastFmScrobbler.shared.scrobble(track: track, startedAt: startedAt) }
    }

    /// Warms the lyrics cache for `track` in the background, once per track. Silent on failure.
    private func prefetchLyrics(for track: Track) {
        guard lastLyricsPrefetchID != track.id else { return }
        lastLyricsPrefetchID = track.id
        Task { await LyricsService.shared.resolve(for: track) }
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    /// Position from the node's sample clock plus the seek offset, or the last `currentTime` when not rendering.
    private func currentPlaybackTime() -> TimeInterval {
        // A stream never attaches the (lazy) nodes, and asking an unattached node for its time throws an ObjC
        // exception (the crash when swiping the app away mid-stream).
        guard fileSampleRate > 0, playbackSource == .engine, graphConfigured else { return currentTime }
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

    /// Prints the main-actor cost table 3s after audio starts, since the stall happens after first audio.
    /// Scoped to this play by the reset in `beginPreparing`.
    private static func reportPlayStartCost() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            MainThreadActivity.shared.logReport("play start")
        }
    }

    private var artworkRetries = 0
    private var artworkRetryID: UUID?

    private func updateNowPlayingInfo(track: Track) {
        mixMainActivity("now-playing/info") { updateNowPlayingInfoBody(track: track) }
    }

    private func updateNowPlayingInfoBody(track: Track) {
        // Remote commands are registered the first time a song starts. Spanned three ways because the first call
        // is slow once (registration, cold artwork decode, info-centre XPC) and the total can't tell which.
        mixMainActivity("now-playing/remote-commands") {
            setupRemoteCommandsIfNeeded()
            syncRemoteCommandState()
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:                        track.title,
            MPMediaItemPropertyArtist:                       track.artistName,
            MPMediaItemPropertyAlbumTitle:                   track.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:     currentTime,
            MPMediaItemPropertyPlaybackDuration:             duration,
            MPNowPlayingInfoPropertyPlaybackRate:            playbackRate,
        ]

        mixMainActivity("now-playing/artwork-decode") {
            #if os(iOS)
            if let data = track.displayArtwork, let img = UIImage(data: data) {
                info[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            #elseif os(macOS)
            if let data = track.displayArtwork, let img = NSImage(data: data) {
                info[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            #endif
        }

        mixMainActivity("now-playing/publish") {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        // Covers load lazily (online ones after the song starts), so retry or the lock screen keeps the placeholder.
        // ponytail: a few timed retries, observe the artwork store if this falls short.
        if artworkRetryID != track.id { artworkRetryID = track.id; artworkRetries = 0 }
        if info[MPMediaItemPropertyArtwork] == nil, artworkRetries < 5 {
            artworkRetries += 1
            let id = track.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let cur = self.queue.currentTrack, cur.id == id else { return }
                self.updateNowPlayingInfo(track: cur)
            }
        }
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

    /// Set the crossfade overlap length (seconds). Clamped to 2...12. Persisted.
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

    /// A manual Next with an overlap instead of a hard cut, using the end-of-track fade machinery. Opt-in
    /// (Settings > Playback > Crossfade on Skip), `.crossfade` mode only. Returns false to fall back to the
    /// normal advance.
    private func beginSkipCrossfade() -> Bool {
        guard crossfadeMode == .crossfade, UserDefaults.standard.bool(forKey: DefaultsKey.crossfadeOnSkip),
              !isTransitioning, state == .playing else { return false }
        guard let next = queue.peekNext() else { return false }
        // Leave unfindable songs to the walk below, which badges and explains them.
        if UnavailableTracks.shared.contains(next), !canPlayLocally(next) { return false }
        guard let url = fileStorage.localURL(for: next) else { return false }
        beginCrossfade(to: next, url: url, fade: effectiveFade)
        return true
    }

    /// From the progress timer: near the end of the track, with a local next track, start the overlap.
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
        // Only when the next file is local; never stall a transition on a download.
        guard let url = fileStorage.localURL(for: next) else { return }
        beginCrossfade(to: next, url: url, fade: max(fade, 0.2))
    }

    /// Overlaps the active track with `next`: schedule it on the idle player, flip the active player now (so
    /// progress and now-playing show the new track), then ramp volumes over `fade` seconds.
    private func beginCrossfade(to next: Track, url: URL, fade: TimeInterval) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { return }  // bad file: let the normal completion handler advance

        isTransitioning = true
        let outgoing = playerNode
        let incoming = idlePlayer
        let incomingBus = idleBus
        let fmt = file.processingFormat
        let lenFrames = Self.trimmedFrames(file.length,
                                           sampleRate: fmt.sampleRate,
                                           canonical: next.duration)

        // Schedule the incoming track on the idle bus; the engine keeps running and the chain stays canonical.
        connectPlayer(incoming, bus: incomingBus, format: fmt)
        incoming.volume = 0

        loadGeneration &+= 1
        let generation = loadGeneration
        scheduleFullFile(file, on: incoming, length: lenFrames, generation: generation)
        startEngineIfNeeded()
        incoming.play()

        // `playerNode` is now the incoming player, so the clock and seek follow the new track.
        usingA.toggle()
        outgoingPlayer = outgoing

        // Advance the queue to the incoming track.
        _ = queue.advance()

        // Adopt the incoming file as the current file/state.
        audioFile        = file
        fileSampleRate   = fmt.sampleRate
        fileLengthFrames = lenFrames
        canonicalDuration = next.duration
        seekFrameOffset  = 0
        duration         = lenFrames > 0 ? Double(lenFrames) / fmt.sampleRate : 0
        currentTime      = 0
        isNodePlaying    = true
        scrobbleStartedAt  = Date()
        didScrobbleCurrent = false
        rotateHistoryTracking()
        updateNowPlayingInfo(track: next)
        let nowPlayingTrack = next
        Task { await LastFmScrobbler.shared.updateNowPlaying(track: nowPlayingTrack) }

        // Warm the lyrics cache in the background for the incoming track.
        prefetchLyrics(for: next)

        // Equal-power ramp. Level correction is one output gain, so it ramps from this song's to the next one's.
        let fromGain = normalizationGain
        let toGain = Self.normalizesVolume
            ? Self.attenuation(LoudnessAnalyzer.cachedGainDB(for: url) ?? LoudnessAnalyzer.typicalGainDB)
            : 1
        crossfadeTask?.cancel()
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = max(1, Int(fade / 0.03))
            for i in 1...steps {
                if Task.isCancelled { return }
                let t = Float(i) / Float(steps)
                outgoing.volume = cos(t * .pi / 2)
                self.playerNode.volume = sin(t * .pi / 2)
                self.normalizationGain = fromGain + (toGain - fromGain) * t
                self.applyVolume()
                try? await Task.sleep(for: .seconds(0.03))
            }
            if Task.isCancelled { return }
            outgoing.stop()
            outgoing.volume = 1
            self.playerNode.volume = 1
            self.outgoingPlayer = nil
            self.isTransitioning = false
            // Measures the incoming file if the ramp above had to guess at it.
            self.reapplyNormalization()
        }
    }

    /// Schedules a whole file on `player` with a generation-guarded auto-advance (like `scheduleSegment`).
    /// `length` is the trimmed length, not `file.length`, so padding doesn't play past a crossfade.
    private func scheduleFullFile(_ file: AVAudioFile, on player: AVAudioPlayerNode,
                                  length: AVAudioFramePosition, generation: Int) {
        let frames = AVAudioFrameCount(max(0, min(file.length, length)))
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

    /// Stops any crossfade's outgoing player and restores both volumes. Safe when not transitioning.
    private func cancelCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        if let out = outgoingPlayer {
            out.stop()
            out.volume = 1
            outgoingPlayer = nil
        }
        // As in `haltCurrentAudio`: touching players before the graph exists creates them. They start at volume 1.
        if graphConfigured {
            playerA.volume = 1
            playerB.volume = 1
        }
        isTransitioning = false
    }

    // MARK: - Remote Command Center

    /// Registers lock screen, Control Centre, headphone and Bluetooth controls once, off the main thread.
    /// Called from `updateNowPlayingInfo` rather than `init`: `MPRemoteCommandCenter.shared()` and the first
    /// `addTarget` are an XPC round trip that froze launch. Only the handlers need the main actor and they hop
    /// to it. The guard flips before the hop so it can't register twice.
    func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        Task { await Self.registerRemoteCommands(for: self) }
        // Shuffle and repeat changed in-app: CarPlay and the Watch read them from the commands. Deferred a turn
        // because @Published fires in willSet.
        remoteStateObserver = queue.$shuffleEnabled.map { _ in () }
            .merge(with: queue.$repeatMode.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncRemoteCommandState() }
    }

    private var remoteCommandsConfigured = false
    private var remoteStateObserver: AnyCancellable?

    /// Takes the play/pause keys while something else owns the audio, like the recap story.
    /// True means play, false pause, nil toggle.
    var remotePlayPause: ((Bool?) -> Void)?

    private func remote(_ play: Bool?) {
        if let remotePlayPause { return remotePlayPause(play) }
        switch play {
        case true?: resume()
        case false?: pause()
        case nil: togglePlayPause()
        }
    }

    /// Pushes shuffle, repeat and liked state to the remote commands.
    /// ponytail: a like that skips `deps.toggleFavourite` (multi-select) shows at the next song; observe the
    /// library's favourites if that lag matters.
    func syncRemoteCommandState() {
        guard remoteCommandsConfigured else { return }
        let shuffle: MPShuffleType = queue.shuffleEnabled ? .items : .off
        let repeatType: MPRepeatType = switch queue.repeatMode {
            case .off: .off
            case .all: .all
            case .one: .one
        }
        let liked = queue.currentTrack.map { isLiked?($0) ?? false } ?? false
        // Off the main actor for the same reason as the registration below.
        Task { await Self.applyRemoteCommandState(shuffle: shuffle, repeatType: repeatType, liked: liked) }
    }

    private nonisolated static func applyRemoteCommandState(shuffle: MPShuffleType, repeatType: MPRepeatType,
                                                            liked: Bool) async {
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.currentShuffleType = shuffle
        c.changeRepeatModeCommand.currentRepeatType   = repeatType
        c.likeCommand.isActive = liked
    }

    /// `nonisolated async` runs on the global executor even when awaited from the main actor (SE-0338).
    /// `Task.detached` wouldn't: the closure inherits this type's isolation.
    private nonisolated static func registerRemoteCommands(for engine: PlaybackEngine) async {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget            { [weak engine] _ in
            Task { @MainActor [weak engine] in engine?.remote(true) };      return .success
        }
        c.pauseCommand.addTarget           { [weak engine] _ in
            Task { @MainActor [weak engine] in engine?.remote(false) };     return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak engine] _ in
            Task { @MainActor [weak engine] in engine?.remote(nil) };       return .success
        }

        c.nextTrackCommand.addTarget { [weak engine] _ in
            guard let engine else { return .commandFailed }
            Task { @MainActor in await engine.playNext() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak engine] _ in
            guard let engine else { return .commandFailed }
            Task { @MainActor in await engine.playPrevious() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak engine] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor [weak engine] in engine?.seek(to: e.positionTime) }
            }
            return .success
        }

        // No skipForward/Backward: they replace next/previous on the lock screen. No dislike until 4.3 uses it.
        c.changeShuffleModeCommand.addTarget { [weak engine] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = e.shuffleType != .off
            Task { @MainActor [weak engine] in engine?.queue.setShuffle(on) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak engine] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let type = e.repeatType
            Task { @MainActor [weak engine] in
                engine?.queue.setRepeat(type == .one ? .one : type == .all ? .all : .off)
            }
            return .success
        }
        c.likeCommand.localizedTitle      = "Add to Liked Songs"
        c.likeCommand.localizedShortTitle = "Like"
        c.likeCommand.addTarget { [weak engine] _ in
            Task { @MainActor [weak engine] in
                guard let engine, let track = engine.queue.currentTrack else { return }
                await engine.onRemoteLike?(track)
                engine.syncRemoteCommandState()
            }
            return .success
        }
    }
}
