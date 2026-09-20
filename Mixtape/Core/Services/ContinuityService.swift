// ContinuityService.swift
// Mixtape — Core/Services
//
// Spotify Connect-style playback across one account's open apps. Every signed-in
// device joins a private Realtime channel, `playback:<user id>`:
//
//   presence   which devices are open (keyed by device id)
//   "state"    what a device is playing — sent only by a device playing itself
//   "command"  play / pause / next / previous / seek / transfer, aimed at one device
//
// A device that isn't playing mirrors the one that is: the engine shows the
// remote song and hands its transport here (`PlaybackEngine.remoteTransport`),
// so the player bar, mini player, Now Playing, media keys and lock screen all
// drive the other device without knowing about it.
//
// The web player speaks the same protocol (mixtape-web src/lib/continuity.ts).
// The wire shapes below are that contract — change both or neither.

import Foundation
import Combine
import Supabase

@MainActor
public final class ContinuityService: ObservableObject {

    nonisolated public struct Device: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let name: String
        /// "macOS" | "iOS" | "web"
        public let platform: String
        /// The device's audio quality — "High" / "Normal" / "Low". Optional
        /// because the web player has no download quality to report.
        public var quality: String?
    }

    /// What a device is doing, for the picker. Derived from its last `state`
    /// broadcast; for this device, from the engine.
    public struct DeviceStatus: Equatable, Sendable {
        /// "Song — Artist", or nil when that device isn't playing anything.
        public var line: String?
        public var isPlaying: Bool
    }

    nonisolated struct TrackSummary: Codable, Sendable {
        var id: String            // lowercase uuid, same id on every client
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var artworkKey: String?
        var sourceRef: String?
        /// A catalogue cover address, for songs with no stored blob and no
        /// storage key — everything played straight out of Discover. Without it
        /// the other device has nothing at all to draw: it can't reach into this
        /// one's memory, and there is no row in the database to sign.
        var coverURL: String?
        /// The upload the sending device resolved this song to.
        ///
        /// Finding it is the larger half of a cold resolve — the transcode is
        /// the rest — and the device that was just playing already knows. Sent
        /// so the one taking over can skip straight to the download instead of
        /// searching again, which is the 5–10 s of silence on a handoff.
        var videoID: String?
        enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration
            case artworkKey = "artwork_key", sourceRef = "source_ref"
            case coverURL = "cover_url", videoID = "video_id"
        }
    }

    nonisolated struct StateMessage: Codable, Sendable {
        var device: Device
        var track: TrackSummary?
        var position: Double
        var duration: Double
        var playing: Bool
        /// ms since epoch of the sender's last start. A new value is "someone
        /// pressed play over there"; the newest start wins.
        var since: Double
        /// Current + upcoming track ids, so a transfer keeps the queue going.
        var queue: [String]
    }

    nonisolated struct CommandMessage: Codable, Sendable {
        var target: String
        var action: String
        var position: Double? = nil
        var state: StateMessage? = nil
    }

    /// The user's other open devices.
    @Published public private(set) var devices: [Device] = []
    /// The device this one is showing and controlling; nil while playback is local.
    @Published public private(set) var activeRemote: Device?
    /// What each device is playing, keyed by device id. Published so the picker
    /// follows a remote device's song without polling it.
    @Published public private(set) var statuses: [String: DeviceStatus] = [:]
    /// This device. `quality` changes when the user changes it in Settings.
    @Published public private(set) var me: Device

    private let client: SupabaseClient
    private let engine: PlaybackEngine
    private let library: LibraryService
    private let toast: (String) -> Void

    /// Owner of the resolved-upload index. Installed by `AppDependencies`;
    /// weak because the coordinator holds the whole online session and this
    /// only ever borrows one lookup from it.
    public weak var online: OnlinePlaybackCoordinator?

    private var channel: RealtimeChannelV2?
    private var channelTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var since: Double = 0
    private var handledSince: [String: Double] = [:]
    private var lastStates: [String: (msg: StateMessage, at: TimeInterval)] = [:]
    private var lastSent: (position: Double, at: TimeInterval, playing: Bool)?
    private var presenceRefs: [String: Set<String>] = [:]
    private var sendScheduled = false

    /// Catalogue cover lookups, both directions, memoized per track: the address
    /// to advertise for what we're playing, and the bytes for what a remote
    /// device is playing. `nil` value = looked and found nothing, so we don't
    /// ask again every 500 ms tick.
    private let catalogue = ITunesSearchClient()
    private var coverURLs: [UUID: String?] = [:]
    private var remoteCovers: [UUID: Data?] = [:]

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(client: SupabaseClient, engine: PlaybackEngine, library: LibraryService,
                deviceID: String, name: String, platform: String,
                toast: @escaping (String) -> Void) {
        self.client  = client
        self.engine  = engine
        self.library = library
        self.toast   = toast
        self.me      = Device(id: deviceID, name: name, platform: platform, quality: nil)

        // `$state` fires in willSet: `engine.state` is still the old value here.
        engine.$state
            .sink { [weak self] next in
                guard let self else { return }
                if next == .playing, engine.state != .playing, engine.remoteTransport == nil {
                    since = Date().timeIntervalSince1970 * 1000
                }
                scheduleSend()
            }
            .store(in: &cancellables)
        engine.queue.$currentIndex
            .sink { [weak self] _ in self?.scheduleSend() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Called once Realtime has credentials — sign-in and every foreground.
    public func start(userID: UUID) {
        let topic = "playback:\(userID.uuidString.lowercased())"
        // Sign-in and the first foreground arrive within the same second. Tearing
        // down a join still in flight is what left this channel dead for good.
        if channel?.topic == "realtime:\(topic)", channel?.status == .subscribing { return }
        let old = channel
        channel = nil
        channelTask?.cancel()
        let key = me.id
        channelTask = Task { [weak self] in
            guard let self else { return }
            if let old { await client.removeChannel(old) }
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                // Never let `subscribe()` be the one to open the socket — see
                // `connectRealtimeSocket()` for the 70 s of silence that causes.
                await client.connectRealtimeSocket()
                let channel = client.channel(topic) {
                    $0.isPrivate = true
                    $0.presence.key = key
                }
                // Stored before subscribing, so a restart mid-join removes this
                // channel rather than being handed it back from the client's cache.
                self.channel = channel
                let presence = channel.presenceChange()
                let states   = channel.broadcastStream(event: "state")
                let commands = channel.broadcastStream(event: "command")
                do {
                    try await client.joinWithDeadline(channel)
                } catch {
                    guard !Task.isCancelled else { return }
                    print("[Continuity] join failed, retrying in \(delay): \(error)")
                    self.channel = nil
                    await client.removeChannel(channel)
                    // A join only ever fails here because the socket is dead —
                    // and a dead socket stays dead until it is replaced.
                    await client.reconnectRealtimeSocket()
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
                    continue
                }
                print("[Continuity] joined \(topic) as \(me.name)")
                devices = []
                presenceRefs = [:]
                do { try await channel.track(me) } catch { print("[Continuity] track failed: \(error)") }
                sendState()
                await listen(presence: presence, states: states, commands: commands)
                return
            }
        }
        startTicker()
    }

    private func listen(presence: AsyncStream<any PresenceAction>,
                        states: AsyncStream<JSONObject>,
                        commands: AsyncStream<JSONObject>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await action in presence { await self?.handle(presence: action) }
            }
            group.addTask { [weak self] in
                for await json in states {
                    guard let msg = try? json["payload"]?.decode(as: StateMessage.self) else { continue }
                    await self?.receive(msg)
                }
            }
            group.addTask { [weak self] in
                for await json in commands {
                    guard let cmd = try? json["payload"]?.decode(as: CommandMessage.self) else { continue }
                    await self?.handle(cmd)
                }
            }
        }
    }

    public func stop() {
        channelTask?.cancel()
        channelTask = nil
        tickTask?.cancel()
        tickTask = nil
        if let channel {
            self.channel = nil
            Task { [client] in
                await channel.untrack()
                await client.removeChannel(channel)
            }
        }
        if activeRemote != nil {
            activeRemote = nil
            engine.endMirroring()
        }
        devices = []
        presenceRefs = [:]
        lastStates = [:]
        statuses = [:]
        handledSince = [:]
        since = 0
        lastSent = nil
    }

    // MARK: - Status

    public func status(of device: Device) -> DeviceStatus {
        statuses[device.id] ?? DeviceStatus(line: nil, isPlaying: false)
    }

    /// The audio quality this device is set to, re-announced to the others.
    /// Cheap to call repeatedly — a no-op unless the value actually changed.
    public func setQuality(_ quality: String) {
        guard me.quality != quality else { return }
        me.quality = quality
        guard let channel, channel.status == .subscribed else { return }
        Task { [me] in try? await channel.track(me) }
    }

    /// Recomputed on the ticker rather than from the engine's publishers: those
    /// fire in `willSet`, so the queue's current track is still the old one there.
    private func refreshMyStatus() {
        let next: DeviceStatus
        if engine.remoteTransport == nil, let track = engine.queue.currentTrack {
            next = DeviceStatus(line: "\(track.title) — \(track.artistName)",
                                isPlaying: engine.state == .playing)
        } else {
            next = DeviceStatus(line: nil, isPlaying: false)
        }
        if statuses[me.id] != next { statuses[me.id] = next }
    }

    // MARK: - Choosing a device

    /// Moves playback to `device`, or to this device when nil.
    public func play(on device: Device?) {
        guard let device else {
            guard let remote = activeRemote, let last = lastStates[remote.id] else { return }
            send(CommandMessage(target: remote.id, action: "pause"))
            let position = extrapolated(last)
            Task { await takeOver(last.msg, position: position) }
            return
        }
        guard device.id != me.id, device.id != activeRemote?.id else { return }
        var state: StateMessage
        if let remote = activeRemote, let last = lastStates[remote.id] {
            state = last.msg
            state.position = extrapolated(last)
            send(CommandMessage(target: remote.id, action: "pause"))
        } else {
            guard engine.queue.currentTrack != nil else { return }
            state = currentState()
            engine.pause()
        }
        send(CommandMessage(target: device.id, action: "transfer", state: state))
    }

    // MARK: - Presence

    private func handle(presence action: any PresenceAction) {
        for (key, p) in action.leaves where key != me.id {
            presenceRefs[key]?.remove(p.ref)
            guard presenceRefs[key]?.isEmpty ?? true else { continue }
            presenceRefs[key] = nil
            print("[Continuity] device left: \(key)")
            devices.removeAll { $0.id == key }
            lastStates[key] = nil
            statuses[key] = nil
            // A device that comes straight back (a foreground rejoin) is mirrored again.
            handledSince[key] = nil
            if activeRemote?.id == key {
                activeRemote = nil
                engine.endMirroring()
            }
        }
        var joined = false
        for (key, p) in action.joins where key != me.id {
            guard let device = try? p.decodeState(as: Device.self) else { continue }
            presenceRefs[key, default: []].insert(p.ref)
            if let i = devices.firstIndex(where: { $0.id == key }) {
                if devices[i] != device { devices[i] = device }
            } else {
                print("[Continuity] device joined: \(device.name) (\(device.platform))")
                devices.append(device)
                joined = true
            }
        }
        // A device that just opened should see what's playing without waiting
        // for the next heartbeat.
        if joined { scheduleSend() }
    }

    // MARK: - Receiving

    private func receive(_ msg: StateMessage) {
        let id = msg.device.id
        guard id != me.id else { return }
        lastStates[id] = (msg, uptime)
        statuses[id] = DeviceStatus(line: msg.track.map { "\($0.title) — \($0.artist)" },
                                    isPlaying: msg.playing)
        let fresh = msg.playing && handledSince[id] != msg.since
        handledSince[id] = msg.since

        if activeRemote != nil, engine.remoteTransport == nil { activeRemote = nil }
        if activeRemote?.id == id { mirror(msg.device); return }
        guard fresh else { return }
        // Both playing: the newest start keeps the music.
        if activeRemote == nil, engine.state.isPlaying, since > msg.since { return }
        mirror(msg.device)
    }

    private func mirror(_ device: Device) {
        guard let last = lastStates[device.id], let summary = last.msg.track else {
            activeRemote = nil
            engine.endMirroring()
            return
        }
        if activeRemote != device { activeRemote = device }
        // Before `mirrorRemote`, so the state sink already sees a mirror and
        // doesn't broadcast the remote song back as ours.
        engine.remoteTransport = { [weak self] in self?.forward($0) }
        engine.remotePlayRedirect = { [weak self] track, context in
            self?.sendToRemote(track, context: context) ?? false
        }
        engine.mirrorRemote(track: resolve(summary), position: extrapolated(last),
                            duration: last.msg.duration, isPlaying: last.msg.playing)
    }

    private func handle(_ cmd: CommandMessage) {
        guard cmd.target == me.id else { return }
        if cmd.action == "transfer" {
            if let state = cmd.state { Task { await takeOver(state, position: state.position) } }
            return
        }
        // A mirror has nothing to pause; the device actually playing does.
        guard engine.remoteTransport == nil else { return }
        switch cmd.action {
        case "play":     if !engine.state.isPlaying { engine.togglePlayPause() }
        case "pause":    engine.pause()
        case "next":     Task { await engine.playNext() }
        case "previous": Task { await engine.playPrevious() }
        case "seek":
            if let p = cmd.position { engine.seek(to: p); scheduleSend() }
        default: break
        }
    }

    private func takeOver(_ state: StateMessage, position: TimeInterval) async {
        guard let summary = state.track else { return }
        let track = resolve(summary)
        // Before the play: an online song resolves through the pinned index, so
        // the sender's pick has to be in it by the time the resolve starts.
        if let vid = summary.videoID, let ref = track.sourceRef ?? summary.sourceRef {
            online?.adoptVideoID(vid, forSourceRef: ref)
        }
        let queued = state.queue.compactMap(UUID.init(uuidString:)).compactMap(library.track(id:))
        let context = queued.contains { $0.id == track.id } ? queued : [track]
        activeRemote = nil
        await engine.play(track: track, in: context,
                          startIndex: context.firstIndex { $0.id == track.id })
        await engine.waitUntilPlaying(timeout: 20)
        guard engine.queue.currentTrack?.id == track.id else { return }
        guard engine.state == .playing else {
            toast("Couldn't play “\(track.title)” on this device")
            return
        }
        if position > 1 { engine.seek(to: position) }
        // ponytail: a paused session starts then pauses (a blip of audio);
        // load-without-playing in the engine if anyone notices.
        if !state.playing { engine.pause() }
    }

    // MARK: - Sending

    private func forward(_ action: PlaybackEngine.RemoteTransportAction) {
        guard let remote = activeRemote else { return }
        var cmd = CommandMessage(target: remote.id, action: "")
        switch action {
        case .play:         cmd.action = "play"
        case .pause:        cmd.action = "pause"
        case .next:         cmd.action = "next"
        case .previous:     cmd.action = "previous"
        case .seek(let t):  cmd.action = "seek"; cmd.position = t
        }
        send(cmd)
        // Show the press now; the device's own state confirms or corrects it.
        guard var last = lastStates[remote.id] else { return }
        switch action {
        case .play, .pause:
            last.msg.position = extrapolated(last)
            last.msg.playing = action == .play
        case .seek(let t):
            last.msg.position = t
        default:
            return
        }
        last.at = uptime
        lastStates[remote.id] = last
        mirror(remote)
    }

    private func send(_ cmd: CommandMessage) {
        guard let channel, channel.status == .subscribed else { return }
        Task { try? await channel.broadcast(event: "command", message: cmd) }
    }

    private func scheduleSend() {
        guard !sendScheduled else { return }
        sendScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            sendScheduled = false
            if activeRemote != nil, engine.remoteTransport == nil { activeRemote = nil }
            sendState()
        }
    }

    /// Only a device playing its own music speaks, and only once it has
    /// played this session — a restored, untouched session is not "playing here".
    private func sendState() {
        guard engine.remoteTransport == nil, since > 0,
              let channel, channel.status == .subscribed else { return }
        let msg = currentState()
        lastSent = (msg.position, uptime, msg.playing)
        Task { try? await channel.broadcast(event: "state", message: msg) }
    }

    private func currentState() -> StateMessage {
        let q = engine.queue
        let upcoming = q.queue.indices.contains(q.currentIndex)
            ? q.queue[q.currentIndex...].prefix(50).map { $0.id.uuidString.lowercased() }
            : []
        return StateMessage(
            device: me,
            track: q.currentTrack.map { summary(of: $0) },
            position: engine.currentTime, duration: engine.duration,
            playing: engine.state == .playing, since: since, queue: upcoming)
    }

    private func summary(of track: Track) -> TrackSummary {
        TrackSummary(id: track.id.uuidString.lowercased(), title: track.title,
                     artist: track.artistName, album: track.albumTitle, duration: track.duration,
                     artworkKey: track.artworkKey, sourceRef: track.sourceRef,
                     coverURL: coverURL(for: track),
                     videoID: track.sourceRef.flatMap { online?.knownVideoID(forSourceRef: $0) })
    }

    /// The user picked a song while this device was mirroring another one.
    ///
    /// It plays *there*. Which device is the player is a choice the user makes
    /// in the picker — not something a tap on a song quietly changes — so this
    /// device stays a mirror and follows the song it just sent.
    private func sendToRemote(_ track: Track, context: [Track]) -> Bool {
        guard let remote = activeRemote else { return false }
        let state = StateMessage(
            device: me, track: summary(of: track), position: 0, duration: track.duration,
            playing: true, since: Date().timeIntervalSince1970 * 1000,
            queue: context.prefix(50).map { $0.id.uuidString.lowercased() })
        send(CommandMessage(target: remote.id, action: "transfer", state: state))
        toast("Playing on \(remote.name)")
        return true
    }

    // MARK: - Clock

    private func startTicker() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                tick()
            }
        }
    }

    private func tick() {
        refreshMyStatus()
        if let remote = activeRemote {
            if engine.remoteTransport == nil { activeRemote = nil; return }
            if lastStates[remote.id]?.msg.playing == true { mirror(remote) }
            return
        }
        guard since > 0, engine.remoteTransport == nil, let sent = lastSent else { return }
        let now = uptime
        let expected = sent.playing ? sent.position + (now - sent.at) : sent.position
        // A seek, a new song, or the 5 s heartbeat that keeps mirrors honest.
        if abs(engine.currentTime - expected) > 2 || (sent.playing && now - sent.at >= 5) {
            sendState()
        }
    }

    private func extrapolated(_ last: (msg: StateMessage, at: TimeInterval)) -> TimeInterval {
        last.msg.playing ? last.msg.position + (uptime - last.at) : last.msg.position
    }

    /// The library's copy when it has one; otherwise an online row the resolver
    /// can fetch by title and artist.
    private func resolve(_ s: TrackSummary) -> Track {
        let id = UUID(uuidString: s.id) ?? UUID()
        if var track = library.track(id: id) {
            // A library row with no cover of its own draws a grey square; the
            // sender already found one, so take that rather than nothing.
            if track.displayArtwork == nil {
                track.artworkData = remoteArtwork(for: id, summary: s)
            }
            return track
        }
        return Track(id: id, title: s.title, artistName: s.artist, albumTitle: s.album,
                     duration: s.duration, artworkData: remoteArtwork(for: id, summary: s),
                     artworkKey: s.artworkKey,
                     sync: SyncMetadata(deviceID: ""),
                     file: .onlinePlaceholder(sourceRef: s.sourceRef ?? ""))
    }

    // MARK: - Covers

    /// The cover address to advertise for the song this device is playing.
    ///
    /// Answers from the memo immediately and looks the song up in the
    /// background: state goes out every half second, and a broadcast must never
    /// wait on the network. The lookup finishing re-sends, so the cover lands on
    /// the other devices a moment later.
    private func coverURL(for track: Track) -> String? {
        if let cached = coverURLs[track.id] { return cached }
        coverURLs[track.id] = String?.none          // claim it, so the tick doesn't re-ask
        Task { [weak self, catalogue] in
            let url = await LibraryService.catalogueArtworkURL(for: track, catalogue: catalogue)
            guard let self, let url else { return }
            coverURLs[track.id] = url.absoluteString
            sendState()
        }
        return nil
    }

    /// Cover bytes for a song playing on another device.
    ///
    /// The address the sender gave us when it had one; the catalogue by title
    /// and artist when it didn't, which is what keeps an older client's songs
    /// from showing up as grey squares. Re-mirrors when the bytes arrive so the
    /// placeholder picks them up.
    private func remoteArtwork(for id: UUID, summary: TrackSummary) -> Data? {
        if let cached = remoteCovers[id] { return cached }
        remoteCovers[id] = Data?.none
        Task { [weak self, catalogue] in
            var url = summary.coverURL.flatMap(URL.init(string:))
            if url == nil {
                let probe = Track(id: id, title: summary.title, artistName: summary.artist,
                                  albumTitle: summary.album, duration: summary.duration,
                                  sync: SyncMetadata(deviceID: ""),
                                  file: .onlinePlaceholder(sourceRef: summary.sourceRef ?? ""))
                url = await LibraryService.catalogueArtworkURL(for: probe, catalogue: catalogue)
            }
            guard let self, let url, let data = await LibraryService.fetchImage(url) else { return }
            remoteCovers[id] = data
            if let remote = activeRemote { mirror(remote) }
        }
        return nil
    }
}
