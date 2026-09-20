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
    /// The playback position, published on its own object — see `PlaybackClock`.
    ///
    /// Deliberately *not* `@Published`. It changes five times a second, and an
    /// `ObservableObject` has one `objectWillChange` for all of its state: while
    /// this lived here, every view holding the engine — the Mac root view, the
    /// sidebar, the songs table, every detail page — re-evaluated its body on
    /// each tick, whether or not it drew a clock. Views that show the position
    /// observe `clock` instead; everything else now hears from the engine only
    /// when the track, the play state or the queue moves.
    public let clock = PlaybackClock()

    /// Where playback is, in seconds. Stored on `clock`; this is the engine's
    /// own way in and out, so the rest of this file reads as it always did.
    public private(set) var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    @Published public private(set) var duration:        TimeInterval  = 0
    /// Tracks played this session, most recent first. Capped at 50.
    @Published public private(set) var recentlyPlayed:  [Track]       = []
    /// Non-nil when a playback error just occurred. Auto-clears after 4 seconds.
    @Published public private(set) var errorMessage:    String?       = nil
    /// Output volume 0.0 – 1.0. Observable and mutatable from any view.
    @Published public var volume: Float = 1.0 {
        didSet { applyVolume() }
    }

    /// Called whenever a track is prepended to `recentlyPlayed`, with the
    /// listen time that crossed the threshold.
    /// AppDependencies uses this to persist the entry via PlayHistoryRepository.
    public var onTrackAddedToHistory: ((Track, TimeInterval) -> Void)?

    /// Final listen time for a play already in the history table, once the user
    /// leaves the track. AppDependencies corrects the stored row with it.
    public var onPlaySecondsFinalised: ((UUID, TimeInterval) -> Void)?

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

    /// Routes a track that has no playable local file (e.g. a song imported from
    /// a Spotify playlist, replayed from history, or synced here as metadata-only
    /// from another device) through the OnlinePlaybackCoordinator, which resolves
    /// & streams it. Set by AppDependencies. Returns once routing has taken over.
    /// When nil, such a track falls through to the normal local-file path (and
    /// surfaces the "hasn't been uploaded yet" error).
    public var onlineRouter: ((Track, [Track]) async -> Void)?

    /// Ids whose audio is being fetched right now — handed to `onlineRouter`, or
    /// downloading from the library's own store. The coordinator plays the
    /// resolved track back through `play(track:in:)`, so without this a track the
    /// resolver couldn't give a local file for would bounce between the two
    /// forever.
    ///
    /// Published because it is also the only honest answer to "is anything
    /// happening?" for a row that was just clicked. Fetching a song can take
    /// several seconds — search, then download — during which nothing on screen
    /// used to move, so the song looked ignored and people clicked it again.
    /// Track rows watch this to draw a spinner over the cover; both kinds of
    /// fetch are in here because from the row's side they are the same wait.
    @Published public private(set) var routingTrackIDs: Set<UUID> = []

    /// True when `track` can *only* be played by resolving it online: nothing on
    /// disk and no `remoteKey` to download from. That covers Discover / Spotify
    /// imports (`isOnline`) and also library rows that arrived here as metadata
    /// while the source device never uploaded the audio — for those the local
    /// path has nowhere to go but the "hasn't been uploaded yet" dead end, so
    /// asking the resolver is strictly better than failing.
    private func needsOnlineResolution(_ track: Track) -> Bool {
        switch AudioLocator.locate(track) {
        case .ready, .remote:      return false
        case .resolvable:          return true
        case .unavailable(let reason):
            // Nothing here and nothing to fetch — but a row stranded by a device
            // that never uploaded is still worth asking the resolver about,
            // which is strictly better than failing outright.
            return reason == .notUploadedYet || reason == .fileMissing
                || reason == .sharedFromAnotherLibrary
        }
    }

    /// Inverse of `needsOnlineResolution`, for callers outside the engine: true
    /// when this track has audio the engine can play on its own (a file on disk,
    /// or a `remoteKey` to download it from). OnlinePlaybackCoordinator uses it to
    /// avoid re-resolving songs the user already owns.
    public func canPlayLocally(_ track: Track) -> Bool {
        !needsOnlineResolution(track)
    }

    /// Hand `track` to the online coordinator. Returns false when there's no
    /// router wired, or when this track is already mid-route, so callers can fall
    /// back to the local path.
    private func routeOnline(_ track: Track, context: [Track]) async -> Bool {
        guard let route = onlineRouter, !routingTrackIDs.contains(track.id) else { return false }
        routingTrackIDs.insert(track.id)
        defer { routingTrackIDs.remove(track.id) }
        await route(track, context)
        return true
    }

    /// True when an online (Discover) context is driving playback, so skips
    /// must route to the coordinator instead of the local queue.
    public var hasOnlineContext: Bool { onlineNextHandler != nil }

    /// Clear the online routing handlers. Called when a library track takes
    /// over so the engine's normal queue handles next / previous again.
    public func clearOnlineContext() {
        onlineNextHandler = nil
        onlinePreviousHandler = nil
    }

    // MARK: - Continuity (showing another device's playback)

    public enum RemoteTransportAction: Equatable, Sendable {
        case play, pause, next, previous, seek(TimeInterval)
    }

    /// Installed by `ContinuityService` while this device shows a song playing
    /// somewhere else. Every transport path — the buttons, the scrubber, media
    /// keys, the lock screen — already comes through the six methods below, so
    /// intercepting there is what makes all of them control the other device.
    /// Cleared by any local play: choosing a song here takes playback back.
    public var remoteTransport: ((RemoteTransportAction) -> Void)?

    /// Also installed by `ContinuityService` while mirroring: hands a song the
    /// user picked *here* to the device that is actually playing, and returns
    /// true when it did. Picking a song is not a request to move the music —
    /// the player only changes when the user says so in the device picker, or
    /// when the playing device closes or stops.
    public var remotePlayRedirect: ((Track, [Track]) -> Bool)?

    /// Put another device's song, position and play state where every player
    /// surface reads them, without making a sound. Stops local audio the first
    /// time; after that it only moves the values that changed, since each
    /// publish redraws every view holding the engine.
    public func mirrorRemote(track: Track, position: TimeInterval, duration: TimeInterval,
                             isPlaying: Bool) {
        if audioFile != nil || playbackSource == .remote || queue.currentTrack?.id != track.id {
            // ponytail: an online resolve already in flight still hands its song
            // over when it lands (a local takeover); cancel routes if that bites.
            loadGeneration &+= 1        // a local load in flight must not start audio underneath
            haltCurrentAudio()
            clearOnlineContext()
            queue.restoreSession(track: track)
            self.duration = duration
            currentTime = max(0, min(position, duration))
            updateNowPlayingInfo(track: track)
        } else if let art = track.artworkData, !art.isEmpty,
                  queue.currentTrack?.displayArtwork == nil {
            // Same song, but the sender's cover only just arrived (an online
            // row has no store copy to fall back on, so this is the only path).
            queue.fillArtwork(art, forTrackID: track.id)
            objectWillChange.send()     // nothing @Published moved; the bar reads through us
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

    /// The other device went away. What it was playing stays on screen,
    /// stopped at its last position, so play picks it up here.
    public func endMirroring() {
        remoteTransport = nil
        remotePlayRedirect = nil
        guard audioFile == nil, playbackSource == .engine, state != .stopped else { return }
        state = .stopped
        updateNowPlayingRate(0)
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
    // Lazy, all five of them. Building the graph was already deferred to first
    // playback — see `configureGraphIfNeeded` — but the *nodes* were still
    // constructed eagerly in `init`, which meant every launch paid to
    // instantiate audio units nothing was going to use. `engine/prefs` measured
    // 1165 ms between the equalizer and the end of this initialiser, and three
    // UserDefaults reads cannot account for that; an `AVAudioUnitTimePitch` is
    // an AudioComponent lookup and load, and a mixer node is another.
    //
    // Every access below is on a playback or settings path, never on the launch
    // path, so the first one to arrive pays — by which point the user has asked
    // for audio and the cost is expected.
    private lazy var audioEngine = AVAudioEngine()
    /// Two player nodes feeding the preMixer on distinct buses so tracks can
    /// overlap for crossfade / gapless. `playerNode` is whichever is currently
    /// active; the other (`idlePlayer`) is silent until a transition. When
    /// crossfade is OFF, `usingA` never flips so behaviour matches the original
    /// single-player path exactly.
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
    //
    // Deliberately on a different knob from the crossfade ramp. Crossfade owns the
    // *per-node* volumes (playerA/playerB) and cancelCrossfade() slams both back to
    // 1; if the pause fade shared those it would either be wiped by a transition or
    // wipe one. The pause fade instead rides the main mixer's output, downstream of
    // both players, so pausing mid-crossfade fades the whole blend and the two ramps
    // never argue about the same value.
    private enum FadePhase { case idle, fadingOut, fadingIn }
    private var fadePhase: FadePhase = .idle
    private var fadeTask: Task<Void, Never>?
    /// Bumped on every fade start/cancel. A ramp task that got past its
    /// `Task.isCancelled` check before being superseded still bails on this, so a
    /// stale step can never write a volume after a newer transition took over.
    private var fadeGeneration = 0
    /// 0…1 multiplier layered on top of the user's `volume`, never replacing it.
    /// Kept separate so a volume change mid-ramp re-applies through applyVolume()
    /// without stomping the fade, the fade can't push output past the ceiling the
    /// user chose, and the ramp's final write is a gain — not a remembered volume
    /// that may since have gone stale.
    private var fadeGain: Float = 1

    /// Fade-out is longer than fade-in on purpose: a slow release reads as
    /// "settling", a slow attack just reads as laggy.
    private static let pauseFadeDuration:  TimeInterval = 0.35
    private static let resumeFadeDuration: TimeInterval = 0.20
    /// ~60 steps/sec. Finer is inaudible and only burns main-actor hops.
    private static let fadeStepInterval:   TimeInterval = 1.0 / 60.0
    /// Plain mixer placed directly after the player. It absorbs per-file format
    /// changes (channel count / sample rate) and converts to one canonical format,
    /// so the downstream AU effects (EQ, TimePitch) always run at a fixed format.
    /// Without this, reconnecting the serial AU chain per file makes the TimePitch
    /// unit reject the format (err -10868) and crash on `connect`.
    private lazy var preMixerNode = AVAudioMixerNode()
    /// The EQ node — provided by `equalizer`. Inserted between player and mixer.
    private var eqNode: AVAudioUnitEQ { equalizer.node }
    /// Varispeed/pitch node for playback-speed control. Sits eq → timePitch → mixer.
    private lazy var timePitchNode = AVAudioUnitTimePitch()
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
    /// The logged play's track and how far into it the user has got. Kept on the
    /// progress tick because `currentTime` is already back to 0 by the time a
    /// new track's start path runs — there'd be nothing left to report.
    private var loggedPlayTrackID: UUID?
    private var loggedPlaySeconds: TimeInterval = 0

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
    /// Position last written to defaults, so the throttle knows how much
    /// playback has gone by unsaved.
    private var lastPersistedPosition: TimeInterval = 0
    private var terminationObservers: Set<AnyCancellable> = []
    /// Incremented each time a new load is requested. A stale `loadAndPlay` call
    /// checks this before doing anything irreversible and aborts if superseded.
    ///
    /// Readable from outside as `playbackGeneration` so a resolve that takes
    /// seconds can tell whether anything else claimed the player while it was
    /// running — see OnlinePlaybackCoordinator.playFromContext.
    private var loadGeneration = 0

    /// Set when the user pauses while a song they asked for is still being
    /// fetched. The old song is what's audible during that wait, so `pause()`
    /// reads as "stop the music" — and the fetch finishing several seconds
    /// later must not override it by starting the new song anyway. Cleared by
    /// the next thing the user does: a fresh play, or a resume.
    private var pausedWhileLoading = false

    /// Bumped by every load. Take a copy before a long await and compare after:
    /// a different value means some other play took the engine over.
    public var playbackGeneration: Int { loadGeneration }

    // MARK: Padded-source trimming
    //
    // A resolved online source is whatever upload the search picked, and uploads
    // lie about their length in one specific way: the song ends and the file
    // doesn't. Two minutes of silence after a 2:40 track is common enough that
    // it reads as a bug in Mixtape — the transport shows 5:00, the scrubber puts
    // the song in the first half of its own bar, and the queue sits there not
    // advancing. The canonical length from the catalogue is the honest number,
    // so when a source overshoots it by more than a rounding difference we play
    // to the catalogue length and treat that as the end of the track.

    /// The catalogue's length for whatever is loaded, 0 when unknown.
    private var canonicalDuration: TimeInterval = 0
    /// Set once the capped end has been acted on, so a stream can't advance twice.
    private var didReachCappedEnd = false

    /// Only worth trimming when the source is meaningfully longer than the
    /// catalogue says. The slack absorbs the ordinary disagreements — a count-in,
    /// a fade, a different master — and leaves the pathological case, which is
    /// minutes rather than seconds.
    private static let paddingSlack: TimeInterval = 20

    /// `seconds` trimmed to the catalogue length when the source overruns it,
    /// otherwise unchanged. Keeps a couple of seconds of the overrun so a track
    /// whose real ending runs slightly long isn't clipped mid-note.
    private static func trimmed(_ seconds: TimeInterval, canonical: TimeInterval) -> TimeInterval {
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
        mixMainActivity("engine/init ▸ prefs") { restorePlaybackPreferences() }
        LaunchTimeline.mark("engine/prefs")
        observeAppTermination()
        // Spanned because this is the one thing here that forces `audioEngine`
        // into existence — it subscribes to that object's configuration-change
        // notification — so it is now the launch's whole audio cost, and the
        // next log should say whether that alone is worth deferring too.
        mixMainActivity("engine/init ▸ observers") { observeAudioSessionEvents() }
        LaunchTimeline.mark("engine/observers")
    }

    // MARK: - Audio Graph Setup

    /// The parts of the old `configureGraph` that are just `UserDefaults` reads.
    ///
    /// Kept in `init` because the UI binds to `playbackRate` and the crossfade
    /// settings whether or not anything has played yet, and because they cost
    /// nothing. Everything expensive moved to `configureGraphIfNeeded`.
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

    /// Build the node graph: players -> preMixer -> eq -> timePitch -> mainMixer.
    /// Idempotent, and deliberately NOT called from `init`.
    ///
    /// This was 1432 ms of a cold iOS launch and 204 ms on the Mac, spent before
    /// the first window existed. Touching `mainMixerNode` is what costs it:
    /// AVAudioEngine builds its output unit lazily, so the first mention of the
    /// main mixer instantiates the whole HAL chain (the `HALC_ShellObject`
    /// complaints in the Mac log are it happening). None of that is needed until
    /// something plays, and most launches never play anything.
    private func configureGraphIfNeeded() {
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

        playerA.volume = 1
        playerB.volume = 1
        timePitchNode.rate = playbackRate

        audioEngine.prepare()
        graphConfigured = true
        // Now that there is a mixer to write to, the volume the user set while
        // the graph did not exist takes effect.
        applyVolume()
    }

    /// Reconnect playerNode -> eqNode using the loaded file's processing format so
    /// channel count / sample rate match. Called before scheduling a new file.
    private func connectGraph(for format: AVAudioFormat) {
        configureGraphIfNeeded()
        connectPlayer(playerNode, bus: activeBus, format: format)
    }

    /// Reconnect a specific player → preMixer input bus for `format`. The preMixer
    /// converts it to the canonical format the rest of the chain expects, so the
    /// AU effects never have to re-negotiate (which is what crashed with -10868).
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
            print("[PlaybackEngine] ❌ Failed to start AVAudioEngine: \(error)")
            return false
        }
    }

    /// Single place that writes an output level. Everything the user controls
    /// (`volume`) and everything the pause/resume ramp controls (`fadeGain`) meets
    /// here, so neither can clobber the other: a mid-fade volume change re-applies
    /// at the ramp's current gain, and a ramp step re-applies at the user's current
    /// ceiling.
    private func applyVolume() {
        let level = volume * fadeGain
        // Before the graph exists, naming `mainMixerNode` would build it — which
        // is the launch cost this lazy path is here to avoid. The value is not
        // lost: `configureGraphIfNeeded` calls this again once there is a mixer.
        if graphConfigured {
            audioEngine.mainMixerNode.outputVolume = level
        }
        // Mirror to the remote player so the volume slider also works while streaming.
        remotePlayer?.volume = level
    }

    // MARK: - Public Controls

    /// Load a new queue starting at `track` and begin playback.
    ///
    /// `startIndex` is for callers pointing at a *row* rather than naming a song
    /// — a click in the Queue panel. Without it the queue starts at the first
    /// copy of that song, which is the wrong one as soon as a song appears in
    /// the queue twice.
    ///
    /// `resolved` is the way back *in*. OnlinePlaybackCoordinator finishes a
    /// resolve by calling this method with the downloaded song — and that call
    /// arrives while the original track id is still in `routingTrackIDs`,
    /// because the coordinator is running inside `routeOnline`, which only
    /// clears the id when it returns. The re-entry guards below then read the
    /// handoff as "the user clicked a song that is already downloading" and
    /// dropped it: the bar ran to "done", the spinner stayed, and nothing
    /// played until the song was clicked a second time — by which point the
    /// cache was warm and it started instantly. A minted online Track hashes to
    /// the same id as the library row it came from, so this is not a corner
    /// case; it is every cold play of a song that has to be found online.
    /// `source` names the list being played so the queue can head its section
    /// "Next up: <name>". It rides along with the play rather than being set
    /// afterwards because `QueueService.play` *resets* the source — a caller
    /// that marks it after the fact races the load and loses the name whenever
    /// the song has to be fetched first.
    public func play(track: Track, in tracks: [Track], startIndex: Int? = nil,
                     resolved: Bool = false, source: QueueSource = .none) async {
        // A play the user asked for outranks any pause that came before it.
        // Not the resolver's handoff (`resolved`), which is the tail of a play
        // that may well have been paused since.
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
        // A track with no local file and no remoteKey can't be played from disk —
        // resolve & stream it through the coordinator instead. The coordinator
        // plays the *resolved* file back through this method with its cache
        // `localPath` populated, so `localURL(for:)` is non-nil on the way back in.
        if needsOnlineResolution(track), !resolved {
            // Already resolving. Tapping a song that is taking a few seconds used
            // to fall through to the local path, which has nowhere to go for a
            // track with no file — so the second tap answered with "no audio on
            // this device" about a song that was, at that moment, downloading, and
            // which then started playing underneath the error.
            if routingTrackIDs.contains(track.id) { return }
            if await routeOnline(track, context: tracks) { return }
        }
        // The same guard for a song being downloaded from the library's own
        // store: it is already on its way, and a second click should be a
        // no-op rather than a second download of the same bytes. It does not
        // apply to the resolver's own handoff — that call *is* the download
        // arriving.
        if !resolved, routingTrackIDs.contains(track.id) {
            // Logged because this is a click that produces nothing at all: no
            // audio, no error, no visible change. When it is wrong it is
            // invisible, and it was wrong for years.
            print("[PlaybackEngine] ⏳ Ignored play of \"\(track.title)\" — already routing")
            return
        }
        // A direct play() takes over the local queue. Drop any online routing so
        // skips use the queue again. OnlinePlaybackCoordinator re-installs its
        // handlers immediately after this call when it's driving an online track.
        clearOnlineContext()
        // Start resolving lyrics the moment a song is chosen so they're cached by
        // the time Now Playing opens. Best-effort — never blocks playback.
        LyricsService.shared.prefetch(for: track)
        // The queue is handed to the load rather than written now: everything the
        // player bar shows is read from it, so writing it here is what put the new
        // song's title, artist and cover on screen while the previous song was
        // still the one coming out of the speakers. `loadAndPlay` publishes it at
        // the moment it takes the audio over. See `handOver`.
        await loadAndPlay(track: track, publishing: tracks, startIndex: startIndex,
                          resolved: resolved, source: source)
    }

    /// Routed through `pause()` / `resume()` rather than duplicating their bodies —
    /// the fade bookkeeping only stays consistent if there is exactly one path into
    /// each transition.
    public func togglePlayPause() {
        if let remoteTransport { remoteTransport(state == .playing ? .pause : .play); return }
        switch state {
        case .playing: pause()
        case .paused:  resume()
        default:
            // Stopped with songs waiting. "Add to Queue" fills the queue without
            // starting anything — that's the point of it — so the first press of
            // play is what has to start it. Without this the whole transport was
            // inert next to a queue full of songs, which is what "the button
            // does nothing" looked like. `play(track:in:)` handles a row with no
            // local file by routing it through the coordinator, so a queued
            // Discover song starts here exactly as it would from its own page.
            guard let first = queue.currentTrack ?? queue.queue.first else { break }
            // Left stopped part-way through — by another device handing
            // playback back — so start where it was, not from the top.
            let resumeAt = currentTime
            Task {
                await play(track: first, in: queue.queue)
                guard resumeAt > 1 else { return }
                await waitUntilPlaying(timeout: 20)
                if queue.currentTrack?.id == first.id { seek(to: resumeAt) }
            }
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
        if let remoteTransport { remoteTransport(.pause); return }
        guard state == .playing else { return }
        // Something is on its way in behind this. Remember the pause so the
        // handover honours it instead of starting the new song.
        if !routingTrackIDs.isEmpty { pausedWhileLoading = true }
        // Flip the visible state (and the lock screen) straight away — the button
        // has to feel instant even though the audio takes ~0.35s to reach silence.
        state = .paused
        updateNowPlayingRate(0)
        // A pause is the other moment the session is worth writing down — a
        // crash or a force-quit never reaches the termination hook.
        persistQueueSnapshot()
        // The remote path's clock is the AVPlayer's periodic observer, not this
        // timer, so only the engine path has one to stop. Stopping it now also
        // keeps maybeStartCrossfade() from opening a transition during the fade.
        if playbackSource != .remote { stopProgressTimer() }
        // The node/player keeps running until the ramp reaches zero — that silence
        // before the hard stop is the whole point (see haltAfterPauseFade).
        startFade(to: 0, over: Self.pauseFadeDuration, phase: .fadingOut)
    }

    /// Suspends until audio is actually coming out, or `timeout` elapses.
    ///
    /// For callers with speculative work to start — cache fills, warming the
    /// next track — that must not compete with the buffer the listener is
    /// waiting on. Returns on timeout rather than throwing: a stream that never
    /// reaches `.playing` is a reason to give up waiting, not a reason to skip
    /// the warm-up entirely.
    ///
    /// Polled deliberately. The caller only needs "has it started yet", and
    /// 100ms granularity is far finer than anything it gates; observing
    /// `$state` would mean racing a publisher that emits nothing at all in the
    /// case that matters most — a stall.
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
        /// AVPlayer gave up on the item — a 403 on the URL, a format it can't
        /// open, the host refusing the connection.
        case failed
        /// Neither, within the deadline. A stall, and from where the listener
        /// sits there's no difference between this and `failed`.
        case timedOut
    }

    /// Seconds of the streaming item AVPlayer has actually pulled down, or nil
    /// when nothing is streaming and there is nothing honest to report.
    ///
    /// This is the only byte count that exists on the streaming path: the
    /// resolver hands over a URL and steps out, so from then on AVPlayer is the
    /// one moving the file and its loaded range is the progress.
    public var remoteBufferedSeconds: TimeInterval? {
        guard let item = remotePlayer?.currentItem else { return nil }
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return nil }
        let loaded = range.start.seconds + range.duration.seconds
        return loaded.isFinite ? max(0, loaded) : nil
    }

    /// Suspends until a freshly started remote stream either plays or proves it
    /// won't. The other half of `waitUntilPlaying`, for the caller that has to
    /// *decide* something rather than schedule around it.
    ///
    /// `failed` is what makes this worth having over a plain timeout: a rejected
    /// URL is knowable in a few hundred milliseconds, so the fallback can start
    /// then instead of at the end of a deadline long enough to also cover a slow
    /// buffer on a bad connection.
    public func awaitStreamStart(timeout: TimeInterval) async -> StreamStart {
        /// A stream held at 0:00 because the user paused mid-fetch has started
        /// as far as this is concerned: the item is attached and ready. Waiting
        /// for `.playing` would time out and send the caller off to download a
        /// copy of a song nobody is listening to.
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

        if fadePhase == .fadingOut {
            // Caught the pause fade before it reached silence, so the node/player
            // never stopped. Just reverse the ramp from wherever it got to —
            // re-starting playback here would stutter and reset the sample clock.
        } else {
            // Fully halted: come up from silence so the restart isn't a click.
            fadeGain = 0
            applyVolume()
            if playbackSource == .remote { resumeRemoteAtRate() } else { resumePlayback() }
        }
        if playbackSource != .remote { startProgressTimer() }
        startFade(to: 1, over: Self.resumeFadeDuration, phase: .fadingIn)
    }

    /// Seek to `time` seconds. Works while paused or playing.
    /// Implemented by stopping the player node and re-scheduling the file from
    /// the target sample offset.
    public func seek(to time: TimeInterval) {
        if let remoteTransport {
            currentTime = max(0, min(time, duration))   // the scrubber lands now, not on the echo
            remoteTransport(.seek(time))
            return
        }
        // Nothing loaded: the queue ran out and `stopPlayback()` tore the file
        // down, so every seek below returns early and a click on a lyric does
        // nothing. The instruction is still meaningful — "play from here" — and
        // the UI is still showing the track, so load it again and start there.
        if state == .stopped, audioFile == nil, playbackSource == .engine,
           let track = queue.currentTrack {
            Task { @MainActor in
                await loadAndPlay(track: track)
                seek(to: time)
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
        if let remoteTransport { remoteTransport(.next); return }
        // Online context active → advance through the Discover context (downloads
        // the neighbour on demand) instead of the single-track local queue.
        if let handler = onlineNextHandler {
            await handler()
            return
        }
        // Walk past anything already known to be unfindable. Stopping on a song
        // no resolver has ever produced is the "queue died in the middle" case:
        // the row is badged in the queue for exactly this reason, and reaching
        // it should cost a line of explanation, not the rest of the session.
        while let next = queue.advance() {
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
        // Online context active → step back through the Discover context.
        if let handler = onlinePreviousHandler {
            await handler()
            return
        }
        if let prev = queue.previous() {
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
            lastPersistedPosition = currentTime
        }
    }

    /// Write the whole queue, not just the song.
    ///
    /// Only the current track used to survive a quit, so relaunching restored
    /// one song with nothing after it — "next" was empty however long the list
    /// had been. Deliberately *not* on the 3-second position tick: this encodes
    /// every row, and a queue the size of All Songs is a few thousand of them.
    private func persistQueueSnapshot() {
        let defaults = UserDefaults.standard
        guard queue.currentTrack != nil,
              let data = try? JSONEncoder().encode(queue.snapshot) else {
            defaults.removeObject(forKey: DefaultsKey.queueSnapshot)
            return
        }
        defaults.set(data, forKey: DefaultsKey.queueSnapshot)
    }

    /// The same write, but at most every few seconds — called from the 0.2s
    /// progress tick.
    ///
    /// Without this the position was only ever written on a seek or a pause, so
    /// quitting mid-song restored to wherever the last seek happened to be:
    /// leave at 2:16 having last scrubbed to 1:01 and 1:01 is what came back.
    /// Three seconds is the most that can now be lost, which is under the
    /// resolution anyone notices resuming a song.
    private func persistPlaybackPositionThrottled() {
        guard state == .playing else { return }
        guard abs(currentTime - lastPersistedPosition) >= 3 else { return }
        persistPlaybackPosition()
    }

    // MARK: - Interruptions & Route Changes
    //
    // Three things can take the audio out from under a running engine, and all
    // three are everyday events on iOS and rare-to-impossible on the Mac. That
    // asymmetry is why none of this existed: playback on iPhone simply died —
    // after a phone call, after Siri, after a pair of AirPods connected — and
    // stayed dead until the app was force-quit, because nothing ever restarted
    // the engine.
    //
    //   1. An *interruption* (call, alarm, Siri) deactivates our session and
    //      stops the engine. When it ends the system tells us whether we may
    //      resume; the session has to be re-activated before we can.
    //   2. A *route change* that removed the current output (headphones pulled)
    //      must pause. iOS expects this; not doing it is what makes a phone
    //      suddenly play out loud in someone's pocket.
    //   3. A *configuration change* means the engine's graph was torn down
    //      underneath us (a new sample rate from a route change). The nodes are
    //      still attached but the connections are gone, so they have to be
    //      remade before the engine can start again.

    /// True when playback was stopped by the system rather than by the user, so
    /// the end of the interruption knows whether there is anything to resume.
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
            print("[PlaybackEngine] Audio interrupted (was playing: \(wasPlayingBeforeInterruption))")
            // Go through `pause()` so the UI, the lock screen and the fade all
            // agree with the silence the system has already imposed.
            if state == .playing { pause() }

        case .ended:
            let options: AVAudioSession.InterruptionOptions = {
                guard let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return [] }
                return AVAudioSession.InterruptionOptions(rawValue: raw)
            }()
            print("[PlaybackEngine] Interruption ended (shouldResume: \(options.contains(.shouldResume)))")
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else {
                wasPlayingBeforeInterruption = false
                return
            }
            wasPlayingBeforeInterruption = false
            // Our session was deactivated by the interruption; `resume()` will
            // start the engine but cannot make it audible without this.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[PlaybackEngine] ❌ Could not reactivate session after interruption: \(error)")
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
        // Only the disappearance of the device we were playing to is our
        // business. Everything else (a new device arriving, a category change)
        // the system handles on its own.
        guard reason == .oldDeviceUnavailable else { return }
        print("[PlaybackEngine] Output device went away — pausing")
        if state == .playing { pause() }
    }
    #endif

    /// The graph was rebuilt under us. Reconnect it and, if the user still
    /// thinks a song is playing, get it going again.
    private func handleEngineConfigurationChange() {
        print("[PlaybackEngine] Audio engine reconfigured — rebuilding the graph")
        // Nothing to reconnect if nothing was ever connected.
        guard graphConfigured else { return }
        // The connections are gone but the nodes are still attached, so this is
        // a reconnect, not a rebuild: clearing the flag would re-attach nodes
        // that are already there.
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

    /// Persist on the way out. A quit, a logout, or the machine shutting down
    /// gives us this and nothing else — and it is the exact moment the saved
    /// position matters most, because it is the one the user will see next.
    private func observeAppTermination() {
        let center = NotificationCenter.default
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.willTerminateNotification,
                                          NSApplication.willResignActiveNotification]
        #else
        // iOS may be killed while suspended without any further warning, so
        // background/resign is the last reliable point to write.
        let names: [Notification.Name] = [UIApplication.willTerminateNotification,
                                          UIApplication.didEnterBackgroundNotification]
        #endif
        for name in names {
            center.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Read the clock rather than trusting the last tick: up to
                    // 0.2s of playback happened after it.
                    if self.state == .playing { self.currentTime = self.currentPlaybackTime() }
                    self.persistPlaybackPosition()
                    self.persistQueueSnapshot()
                }
                .store(in: &self.terminationObservers)
        }
    }

    /// Sign-out and account switch: stop, empty the queue, and drop the saved
    /// song, position and queue so the next launch has nothing to bring back.
    /// `persistPlaybackPosition` never clears the keys itself, so without this
    /// the last account's song reappeared paused under the next one.
    public func forgetLastSession() {
        stopPlayback()
        clearOnlineContext()
        queue.clearCurrentTrack()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.lastTrackID)
        defaults.removeObject(forKey: DefaultsKey.lastPosition)
        defaults.removeObject(forKey: DefaultsKey.queueSnapshot)
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
        // The saved queue first, so what comes back is the list that was
        // playing rather than one song on its own. The track from the keys
        // above still decides what is loaded: it is the one the position
        // belongs to, and the snapshot may have lost it to a deletion.
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

    /// Load `track` and leave it paused at `position` seconds (resume-on-launch path).
    private func loadButPause(track: Track, at position: TimeInterval,
                              keepingQueue: Bool = false) async {
        // A restored queue already holds this song in its place; the one-track
        // fallback is for a session with no snapshot to rebuild from.
        if !(keepingQueue && queue.currentTrack?.id == track.id) {
            queue.restoreSession(track: track)
        }
        // Tracks with no cached file would need resolving/streaming, which we
        // don't do automatically on launch. Restore the session for the UI and
        // stay stopped — play() routes it through the coordinator when tapped.
        if needsOnlineResolution(track) {
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

    /// Cut whatever is playing and put `track` in its place — the audio, the
    /// transport state and (when this load owns one) the queue the player bar
    /// reads, all in the same turn so the three can't describe different songs.
    ///
    /// This is the moment the bar's title, artist and cover become the new
    /// song's. Not the click: a click on a song that still has to be fetched is
    /// several seconds away from this.
    private func handOver(to track: Track, publishing context: [Track]?, startIndex: Int? = nil,
                          source: QueueSource = .none) {
        mixMainActivity("engine/hand-over") {
            handOverBody(to: track, publishing: context, startIndex: startIndex, source: source)
        }
    }

    private func handOverBody(to track: Track, publishing context: [Track]?, startIndex: Int? = nil,
                              source: QueueSource = .none) {
        // Split because this went from 0 ms to 1804 ms when the audio nodes were
        // made lazy, and two unrelated things in here could account for that:
        // `haltCurrentAudio` touches `playerNode`, which is now the first thing
        // to force a node into existence, and `queue.play` publishes the whole
        // context, which on All Songs is a couple of thousand rows. The total
        // cannot say which, and the fix is different for each.
        remoteTransport = nil
        mixMainActivity("engine/hand-over ▸ halt") { haltCurrentAudio() }
        state = .loading
        if let context {
            mixMainActivity("engine/hand-over ▸ publish-queue") {
                queue.play(track: track, in: context, startIndex: startIndex)
                // Same turn as the queue it names: `queue.play` clears the source,
                // so naming it anywhere else is a window where the section header
                // reads "Next up" with nothing after it.
                queue.setSource(source)
            }
        }
    }

    /// Stop the outgoing song and clear everything the next one would inherit.
    /// Called on the way into a handover, and on the way out of a load that
    /// turned out to have nothing to play.
    private func haltCurrentAudio() {
        // A local load supersedes any active remote stream — tear it down and
        // hand control back to the AVAudioEngine graph.
        if playbackSource == .remote {
            teardownRemotePlayer()
            playbackSource = .engine
        }
        // Manual load supersedes any in-flight crossfade: stop the outgoing
        // player and reset volumes before taking over. Likewise a pause fade —
        // otherwise the new track starts at whatever gain the ramp had reached.
        cancelCrossfade()
        resetFade()
        // Naming `playerNode` builds a lazy `AVAudioPlayerNode`, and the first
        // one drags in the whole AVAudioEngine/AudioUnit first-use handshake —
        // measured at 1643 ms on the main actor, once per launch. Before the
        // graph is configured no node has ever produced sound, so there is
        // nothing to stop: skipping it is a no-op that saves the whole bill.
        // The launch-time restore of the previous song is exactly this case.
        if graphConfigured { playerNode.stop() }
        isNodePlaying = false
        audioFile = nil
        stopProgressTimer()
        currentTime = 0
        seekFrameOffset = 0
    }

    /// Loads `track` and plays it.
    ///
    /// `publishing` is the queue this load owns — non-nil only from
    /// `play(track:in:)`, where the caller is choosing a song rather than moving
    /// through a queue that has already moved. Handed down rather than written by
    /// the caller so the queue lands in the same turn as the audio: see
    /// `handOver`.
    private func loadAndPlay(track: Track, publishing pending: [Track]? = nil,
                             startIndex: Int? = nil, resolved: Bool = false,
                             source: QueueSource = .none) async {
        // Bump generation so any previously in-flight load/segment knows it has
        // been superseded.
        loadGeneration &+= 1
        let generation = loadGeneration

        // 1. Find the audio. `AudioLocator` is the only thing that decides which
        //    copy wins and what has to happen when there isn't one.
        var fileURL: URL
        let location = AudioLocator.locate(track)

        // Whether the outgoing song gets cut at the click depends on whether the
        // incoming one is actually here.
        //
        // A copy on disk swaps instantly, so the handover happens now and there
        // is never a moment where the bar and the speakers disagree. A song that
        // still has to be fetched is a different thing: cutting the audio at the
        // click buys silence, and — because everything the player bar shows is
        // read from the queue — a bar naming a song nobody can hear yet. So the
        // fetch runs with the previous song still playing and still named, which
        // is exactly what the online path has always done, and the swap happens
        // when there is something to swap to.
        //
        // Only when this call owns the queue. Skip and auto-advance have already
        // moved the queue on before they get here, so for them cutting now is
        // what keeps the two in step.
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
            // Published, so the row the user clicked can put a spinner over its
            // cover for as long as this takes — the same one an online resolve
            // gets. Without it a download from the library's own store is several
            // seconds in which nothing anywhere moves.
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
                print("[PlaybackEngine] ❌ Download failed for \"\(track.title)\": \(error)")
                return
            }
            guard loadGeneration == generation else { return }
            handOver(to: track, publishing: pending, startIndex: startIndex, source: source)

        case .resolvable, .unavailable:
            guard loadGeneration == generation else { return }
            // Callers that come through play(track:in:) already tried the
            // resolver; the queue-driven paths (auto-advance, skip, crossfade,
            // resume-on-launch) haven't, so give it one shot before failing.
            // Context is just this track — an online session shouldn't swallow
            // the rest of a local queue.
            //
            // `.unavailable` gets a shot too when the row *might* be findable:
            // a track whose audio never left another device is better served by
            // a search than by a dead end. Shared rows are in that set now — the
            // only ones that reach here are the ones with no title to search on,
            // and a search that finds nothing is a better answer than a refusal
            // to look.
            let worthResolving: Bool = {
                if case .resolvable = location { return true }
                if case .unavailable(let reason) = location {
                    return reason == .notUploadedYet || reason == .fileMissing
                        || reason == .sharedFromAnotherLibrary
                }
                return false
            }()
            // Not for the resolver's own handoff: it has just been down this
            // road, and sending it back would be the bounce this guard exists
            // to prevent.
            if worthResolving, !resolved, await routeOnline(track, context: [track]) { return }
            guard loadGeneration == generation else { return }
            // Still in flight from an earlier tap. The answer to "can this be
            // played?" isn't known yet, and "no" is the one answer that is
            // definitely wrong — this is what used to put an error on screen
            // while the song was still on its way to playing. The handoff is
            // the exception: it holds its own id here, and staying silent would
            // leave the spinner up forever.
            if !resolved, routingTrackIDs.contains(track.id) {
                print("[PlaybackEngine] ⏳ No audio yet for \"\(track.title)\" — still routing")
                return
            }

            // Nothing is going to play, so the outgoing song — which has been
            // left running while all of the above was tried — stops here.
            if waitsForAudio { haltCurrentAudio() }
            if case .unavailable(let reason) = location {
                setError(reason.message(for: track.title))
            } else {
                setError(UnavailableReason.needsInternet.message(for: track.title))
            }
            print("[PlaybackEngine] ❌ No playable audio for \"\(track.title)\" (\(location))")
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
            let startSuspended = pausedWhileLoading
            pausedWhileLoading = false
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat

            audioFile        = file
            fileSampleRate   = processingFormat.sampleRate
            // Trimmed, not raw: everything downstream — the reported duration,
            // the segment that gets scheduled, and so the auto-advance at its
            // end — measures from this, so a padded source simply ends where the
            // song does.
            fileLengthFrames = Self.trimmedFrames(file.length,
                                                  sampleRate: processingFormat.sampleRate,
                                                  canonical: track.duration)
            canonicalDuration = track.duration
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
            clearError()
            if startSuspended {
                // Loaded, scheduled, and silent at 0:00. `resume()` starts the
                // segment that is already sitting on the node, so pressing play
                // begins this song from the top rather than re-loading it.
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
            print("[PlaybackEngine] ⚠️ First open failed for \"\(track.title)\": \(error) — attempting self-heal")

            // Self-heal: a corrupt cached copy (e.g. a legacy bad ID3-on-m4a
            // download, or a truncated fetch) makes AVAudioFile throw
            // kAudioFileInvalidFileError. Throw that copy away and fetch again.
            //
            // Only a *cache* copy. This used to delete the user's exported file
            // — a real file in their own Music folder, which the app doesn't own
            // and can't recreate — as its first move on any playback failure.
            if case .ready(_, let kind) = location, kind == .cached {
                try? FileManager.default.removeItem(at: fileURL)
            }

            var healedURL: URL? = AudioLocator.readyURL(for: track)
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
        // Surface the new track in the queue/player bar.
        queue.play(track: track, in: [track])
        await startRemoteStream(url: url, headers: headers, track: track)
    }

    /// Configures and starts the AVPlayer for a remote stream. Assumes the queue /
    /// history have already been updated by the caller.
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
        currentTime = 0
        duration    = track.duration       // provisional; refined once the item loads
        canonicalDuration  = track.duration
        didReachCappedEnd  = false
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
        remotePlayer = player
        // Via applyVolume() rather than assigning `volume` directly, so the stream
        // opens at the same composed level everything else uses.
        applyVolume()

        // Drive currentTime/duration/state from the player's clock.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        remoteTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.playbackSource == .remote else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : self.currentTime
                // The remote player has its own clock and never runs the
                // progress timer, so it needs its own call to the same throttle.
                self.persistPlaybackPositionThrottled()
                if let d = self.remotePlayer?.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    self.duration = Self.trimmed(d.seconds, canonical: self.canonicalDuration)
                }
                // A trimmed stream never reaches its own end-of-item notification,
                // so the end of the song has to be the thing that advances it.
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
                        // `.error` is here for the tail of the sequence this whole
                        // change is about: a premature "no audio on this device"
                        // used to sit on screen for its full five seconds while the
                        // song it was about played underneath it — and, worse, the
                        // old `state == .loading` test meant an errored state never
                        // flipped to .playing at all, so the transport stayed wrong
                        // until the next track.
                        self.clearError()
                        self.state = .playing
                        // First audio actually advancing — the only honest end of
                        // "user pressed play".
                        ResolveTrace.shared.end("first audible (stream)")
                        Self.reportPlayStartCost()
                    default:
                        break
                    }
                }
                self.checkHistoryThreshold()
                // Streamed tracks scrobble too — without this the remote path
                // sent "now playing" but never crossed the scrobble threshold.
                self.checkScrobbleThreshold()
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

        // The user pressed pause while this stream was still being resolved.
        // It arrives loaded and silent at 0:00 instead of overriding them; the
        // item is attached, so `resume()` starts it from the top.
        if pausedWhileLoading {
            // Deliberately left set: if the stream turns out to be dead and the
            // coordinator falls back to a full download, that handover has to
            // honour the same pause. Only the user clears it — see `resume()`
            // and `play(track:in:)`.
            player.rate = 0
            state = .paused
            updateNowPlayingRate(0)
            updateNowPlayingInfo(track: track)
            return
        }

        // Start at the user's chosen speed (rate > 0 begins playback).
        player.rate = playbackRate
        // Stay in .loading until the time observer confirms audio is actually
        // advancing (timeControlStatus == .playing). This lets the coordinator's
        // watchdog detect a stalled/failed stream and fall back to a download.
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

    // MARK: - Play/Pause Fade
    //
    // Pause used to cut the graph dead mid-waveform, which clicks. Both backends now
    // ramp the output level to silence first and only then stop, and come back up
    // from silence on resume.

    /// Equal-power shaping, the same curve `beginCrossfade` settled on. A linear
    /// ramp on raw amplitude sounds like it falls off a cliff at the end because
    /// perceived loudness is roughly logarithmic; cos/sin keeps the drop even.
    /// Returns 0→1 progress along the curve, so the caller can interpolate between
    /// any two gains (which is what makes an interrupted ramp resume smoothly).
    private static func fadeCurve(_ t: Float, fadingOut: Bool) -> Float {
        fadingOut ? 1 - cos(t * .pi / 2) : sin(t * .pi / 2)
    }

    /// Ramp `fadeGain` to `target`, cancelling whatever ramp was in flight. Always
    /// starts from the *current* gain, so a pause→play→pause inside 100ms reverses
    /// mid-flight instead of jumping, and can never strand the gain at 0 or halfway:
    /// each transition owns the ramp until the next one takes it.
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

    /// Drop any in-flight ramp, leaving `fadeGain` where it stands. The generation
    /// bump matters as much as the cancel: a task already awake past its
    /// `Task.isCancelled` check would otherwise still get one stale write in.
    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeGeneration &+= 1
        fadePhase = .idle
    }

    /// Cancel any ramp *and* restore full output. Every path that starts fresh audio
    /// or tears playback down calls this — without it a pause fade caught mid-flight
    /// by a track change would leave the next track playing at whatever gain the
    /// ramp had reached (often silence).
    private func resetFade() {
        cancelFade()
        fadeGain = 1
        applyVolume()
    }

    /// The tail of a pause: output is already silent, so the hard stop is inaudible.
    /// Only reached when nothing superseded the fade — resume/stop/load all cancel
    /// the ramp, so this can never pause a player something else just started.
    private func haltAfterPauseFade() {
        guard state == .paused else { return }
        if playbackSource == .remote {
            remotePlayer?.pause()
            return
        }
        // Read the clock while the node is still rendering: the fade tail is real
        // playback, so the position we persist has to include it.
        currentTime = currentPlaybackTime()
        pausePlayback()
        persistPlaybackPosition()
    }

    // NOTE: start-time history logging is intentionally absent — a play is only
    // recorded once it crosses the minimum-listen threshold (see
    // `checkHistoryThreshold`), so skips and brief samples don't pollute
    // "Recently played" or listening stats.

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
        onTrackAddedToHistory?(track, loggedPlaySeconds)
    }

    /// Records the current track once it's been listened to for at least 30s (or
    /// ~90% of a sub-30s song), so only meaningful listens count toward Home and
    /// stats. Fires once per track; the flag resets when a new track loads.
    private func checkHistoryThreshold() {
        guard let track = queue.currentTrack else { return }
        // Already logged: just keep the listen time current for the flush.
        if didRecordHistoryCurrent {
            loggedPlaySeconds = max(loggedPlaySeconds, currentTime)
            return
        }
        let target = duration > 0 ? min(30, duration * 0.9) : 30
        guard currentTime >= target else { return }
        print("[history] threshold reached: currentTime=\(currentTime) target=\(target) duration=\(duration)")
        didRecordHistoryCurrent = true
        loggedPlayTrackID = track.id
        loggedPlaySeconds = currentTime
        recordCurrentPlay()
    }

    /// Close out the play row for the track being left, then arm the log for the
    /// next one. Every start path calls this instead of clearing
    /// `didRecordHistoryCurrent` itself, so a new one can't forget the flush.
    private func rotateHistoryTracking() {
        if let id = loggedPlayTrackID, loggedPlaySeconds > 0 {
            onPlaySecondsFinalised?(id, loggedPlaySeconds)
        }
        loggedPlayTrackID = nil
        loggedPlaySeconds = 0
        didRecordHistoryCurrent = false
    }

    /// Seeds `recentlyPlayed` from persistent storage on app launch.
    /// Call this once after AppDependencies has loaded history from SwiftData.
    public func restoreHistory(_ tracks: [Track]) {
        recentlyPlayed = Array(tracks.prefix(50))
    }

    /// Drop songs from the recently-played list.
    ///
    /// The list is a snapshot of what was played, kept in memory and seeded from
    /// the play log — nothing about it consults the library, so a song deleted
    /// from the library carried on sitting on the Home shelf, playable, with no
    /// row behind it. Deleting is the one edit that has to reach in here.
    public func forgetFromRecentlyPlayed(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let kept = recentlyPlayed.filter { !ids.contains($0.id) }
        guard kept.count != recentlyPlayed.count else { return }
        recentlyPlayed = kept
    }

    /// Wipe the in-memory recently-played list.
    ///
    /// It is seeded from the play log at launch and appended to as songs play,
    /// so after the log is deleted this is the only copy still standing — and it
    /// feeds the Home shelf, the recent-artists row and the Recent panel, all of
    /// which kept showing a history that had just been erased.
    public func clearRecentlyPlayed() {
        recentlyPlayed = []
    }

    /// Incremented per setError so a stale auto-clear task can't wipe a newer message.
    private var errorGeneration = 0

    /// Drops the current error without waiting out its five seconds.
    ///
    /// Bumps the generation so the pending auto-clear from `setError` can't fire
    /// afterwards and wipe a *newer* message. Deliberately leaves `state` alone —
    /// every caller is on its way to setting one.
    private func clearError() {
        guard errorMessage != nil else { return }
        errorGeneration &+= 1
        errorMessage = nil
    }

    /// Sets the error state AND the error toast message, then auto-clears both after 5 s.
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
        // Stop is immediate by contract (track deleted, queue exhausted) — kill any
        // pending fade so it can't reach in afterwards and pause a fresh player.
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
            // 0.2s tick keeps the seek bar smooth and synced-lyric highlighting
            // snappy (the old 0.5s tick added up to half a second of lag).
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

    /// Print the main-actor cost table a moment after the song is audible.
    ///
    /// The stall being chased happens *after* first audio, so a report taken at
    /// the same instant would miss it entirely. Three seconds is the window the
    /// user describes as "laggy for a few seconds after pressing play", and the
    /// table is scoped to this play by the reset in `beginPreparing`.
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
        // The first thing that happens when a song starts, and the only place a
        // remote command could ever have something to act on.
        // Split three ways because this costs 1114 ms exactly once — on the
        // launch that restores the previous song — and 0 ms every time after.
        // That shape fits all three of these and the total can't say which:
        // the remote-command registration only happens on the first call, the
        // artwork decode is only cold once, and the info-centre setter is an
        // XPC hop to mediaserverd that may be waiting for it to start up.
        mixMainActivity("now-playing/remote-commands") { setupRemoteCommandsIfNeeded() }
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

        // Covers load lazily (and online ones arrive after the song starts), so
        // the lock screen / Dynamic Island would keep the grey placeholder.
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
        let lenFrames = Self.trimmedFrames(file.length,
                                           sampleRate: fmt.sampleRate,
                                           canonical: next.duration)

        // Wire + schedule the incoming track on the idle player/bus (engine keeps
        // running; downstream chain stays canonical so the AU effects don't renegotiate).
        connectPlayer(incoming, bus: incomingBus, format: fmt)
        incoming.volume = 0

        loadGeneration &+= 1
        let generation = loadGeneration
        scheduleFullFile(file, on: incoming, length: lenFrames, generation: generation)
        startEngineIfNeeded()
        incoming.play()

        // Flip logical active player → `incoming`. `playerNode` now == incoming, so
        // the progress clock and seek operate on the new track.
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
    /// `length` is the trimmed length the caller computed for this file, not
    /// `file.length` — playing to the raw end is what would put a padded
    /// source's silence on the far side of a crossfade.
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
        // Same reason as in `haltCurrentAudio`: touching the players before the
        // graph exists instantiates them. They are born at volume 1 anyway.
        if graphConfigured {
            playerA.volume = 1
            playerB.volume = 1
        }
        isTransitioning = false
    }

    // MARK: - Remote Command Center

    /// Lock screen, Control Centre, headphone and Bluetooth controls.
    ///
    /// Deliberately not called from `init`: `MPRemoteCommandCenter.shared()` was
    /// 376 ms of a cold iOS launch, spent wiring up controls for a player that
    /// had nothing to play. Called instead from `updateNowPlayingInfo`, which
    /// runs as a song starts — before there is any way for one of these commands
    /// to arrive.
    /// Register the lock-screen and headphone controls, once, off the main thread.
    ///
    /// Measured at **1771 ms on the main actor**, on the first call and only the
    /// first: `MPRemoteCommandCenter.shared()` and the first `addTarget` are an
    /// XPC round trip to `mediaremoted`, and it happens during launch — while
    /// the first sync is contending for everything — because restoring the
    /// previous song publishes now-playing info. That was the launch freeze.
    ///
    /// None of that work needs the main actor. Only the *handlers* do, and they
    /// hop to it themselves. The registration is fire-and-forget: the guard flips
    /// before the hop so a second call can't register twice, and the worst case
    /// of the couple of hundred milliseconds before it lands is a lock screen
    /// whose buttons aren't wired yet — during app launch, before there is
    /// anything to control.
    private func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        Task { await Self.registerRemoteCommands(for: self) }
    }

    private var remoteCommandsConfigured = false

    /// `nonisolated` + `async` is what actually gets this off the main actor: a
    /// non-isolated async function runs on the global executor even when an
    /// actor-isolated caller awaits it (SE-0338). `Task.detached` would not have
    /// worked — the closure literal would inherit this type's isolation, which
    /// is the trap that made a previous "background" rescan run on main.
    private nonisolated static func registerRemoteCommands(for engine: PlaybackEngine) async {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget            { [weak engine] _ in
            Task { @MainActor in engine?.resume() };          return .success
        }
        c.pauseCommand.addTarget           { [weak engine] _ in
            Task { @MainActor in engine?.pause() };           return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak engine] _ in
            Task { @MainActor in engine?.togglePlayPause() }; return .success
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
                Task { @MainActor in engine?.seek(to: e.positionTime) }
            }
            return .success
        }
    }
}
