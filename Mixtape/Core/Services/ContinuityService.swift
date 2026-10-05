// Spotify Connect-style playback between one account's devices over the
// `playback:<user id>` Realtime channel: presence for open devices, "state"
// from whoever is playing, "command" aimed at one device. Idle devices mirror
// the player through PlaybackEngine.remoteTransport.
// Shares its protocol with mixtape-web src/lib/continuity.ts, keep them in sync.

import Foundation
import Combine
import Supabase
import OSLog

@MainActor
public final class ContinuityService: ObservableObject {

    nonisolated public struct Device: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let name: String
        /// "macOS" | "iOS" | "web"
        public let platform: String
        /// Nil on web.
        public var quality: String?
    }

    public struct DeviceStatus: Equatable, Sendable {
        /// "Song - Artist", nil when idle.
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
        /// Catalogue cover URL for Discover songs with no stored artwork.
        var coverURL: String?
        /// The sender's resolved upload, so the receiver can skip the search.
        var videoID: String?
        /// A signed link to the sender's own file, for imports a search can't find.
        var audioURL: String?
        /// Set for an edit, so the receiver renders it from their own copy of the original.
        var edit: SongEdit?
        enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration, edit
            case artworkKey = "artwork_key", sourceRef = "source_ref"
            case coverURL = "cover_url", videoID = "video_id", audioURL = "audio_url"
        }
    }

    nonisolated struct StateMessage: Codable, Sendable {
        var device: Device
        var track: TrackSummary?
        var position: Double
        var duration: Double
        var playing: Bool
        /// Sender's last start time in ms. Newest wins.
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
    /// Keyed by device id.
    @Published public private(set) var statuses: [String: DeviceStatus] = [:]
    /// This device. `quality` changes when the user changes it in Settings.
    @Published public private(set) var me: Device

    private let client: SupabaseClient
    private let engine: PlaybackEngine
    private let library: LibraryService
    private let toast: (Toast) -> Void

    /// Weak, only used for one lookup.
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

    /// Memoized cover lookups both ways. A nil value means nothing was found.
    private let catalogue = ITunesSearchClient()
    private var coverURLs: [UUID: String?] = [:]
    private var remoteCovers: [UUID: Data?] = [:]

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(client: SupabaseClient, engine: PlaybackEngine, library: LibraryService,
                deviceID: String, name: String, platform: String,
                toast: @escaping (Toast) -> Void) {
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

    public func start(userID: UUID) {
        let topic = "playback:\(userID.uuidString.lowercased())"
        // Don't tear down a join that's still in flight.
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
                // Open the socket ourselves, see connectRealtimeSocket().
                await client.connectRealtimeSocket()
                let channel = client.channel(topic) {
                    $0.isPrivate = true
                    $0.presence.key = key
                }
                // Stored first so a restart removes this channel.
                self.channel = channel
                let presence = channel.presenceChange()
                let states   = channel.broadcastStream(event: "state")
                let commands = channel.broadcastStream(event: "command")
                do {
                    try await client.joinWithDeadline(channel)
                } catch {
                    guard !Task.isCancelled else { return }
                    MixLog.sync.error("[Continuity] join failed, retrying in \(delay): \(error)")
                    self.channel = nil
                    await client.removeChannel(channel)
                    // Only fails on a dead socket, so replace it.
                    await client.reconnectRealtimeSocket()
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
                    continue
                }
                MixLog.sync.debug("[Continuity] joined \(topic) as \(me.name)")
                devices = []
                presenceRefs = [:]
                do { try await channel.track(me) } catch { MixLog.sync.error("[Continuity] track failed: \(error)") }
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

    /// No-op unless it changed.
    public func setQuality(_ quality: String) {
        guard me.quality != quality else { return }
        me.quality = quality
        guard let channel, channel.status == .subscribed else { return }
        Task { [me] in try? await channel.track(me) }
    }

    /// Polled because the engine's publishers fire in willSet.
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
            MixLog.sync.debug("[Continuity] device left: \(key)")
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
                MixLog.sync.debug("[Continuity] device joined: \(device.name) (\(device.platform))")
                devices.append(device)
                joined = true
            }
        }
        // Send state right away to newly joined devices.
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
        // Set before mirroring so we don't echo the remote song back.
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
        // Pin the sender's upload before playing.
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
            toast(.failed("Couldn't play “\(track.title)” on this device"))
            return
        }
        if position > 1 { engine.seek(to: position) }
        // ponytail: starts then pauses (brief blip); add a load-without-play if noticed.
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

    /// Only a device actually playing its own music broadcasts.
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

    func summary(of track: Track) -> TrackSummary {
        TrackSummary(id: track.id.uuidString.lowercased(), title: track.title,
                     artist: track.artistName, album: track.albumTitle, duration: track.duration,
                     artworkKey: track.artworkKey, sourceRef: track.sourceRef,
                     coverURL: coverURL(for: track),
                     videoID: track.sourceRef.flatMap { online?.knownVideoID(forSourceRef: $0) },
                     edit: track.edit)
    }

    /// Picking a song while mirroring plays it on the other device.
    private func sendToRemote(_ track: Track, context: [Track]) -> Bool {
        guard let remote = activeRemote else { return false }
        let state = StateMessage(
            device: me, track: summary(of: track), position: 0, duration: track.duration,
            playing: true, since: Date().timeIntervalSince1970 * 1000,
            queue: context.prefix(50).map { $0.id.uuidString.lowercased() })
        send(CommandMessage(target: remote.id, action: "transfer", state: state))
        toast(Toast("Playing on \(remote.name)", symbol: "hifispeaker.fill"))
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

    /// The library copy, or an online row the resolver can fetch.
    func resolve(_ s: TrackSummary) -> Track {
        let id = UUID(uuidString: s.id) ?? UUID()
        if var track = library.track(id: id) {
            // Use the sender's cover if ours is missing.
            if track.displayArtwork == nil {
                track.artworkData = remoteArtwork(for: id, summary: s)
            }
            return track
        }
        // Someone else's edit: rendered here from the original, never searched for by its own title.
        if let edit = s.edit {
            return Track(id: id, title: s.title, artistName: s.artist, albumTitle: s.album,
                         duration: s.duration, artworkData: remoteArtwork(for: id, summary: s),
                         artworkKey: s.artworkKey, sync: SyncMetadata(deviceID: ""),
                         file: .editPlaceholder, edit: edit)
        }
        // Our own copy under another id (an import, or another account's song), so it isn't fetched again.
        if let own = library.track(matching: s.title, artistName: s.artist, duration: s.duration) {
            return own
        }
        return Track(id: id, title: s.title, artistName: s.artist, albumTitle: s.album,
                     duration: s.duration, artworkData: remoteArtwork(for: id, summary: s),
                     artworkKey: s.artworkKey,
                     sync: SyncMetadata(deviceID: ""),
                     file: .onlinePlaceholder(sourceRef: s.sourceRef ?? ""))
    }

    // MARK: - Covers

    /// Returns the memo now and looks up in the background, re-sending when done.
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

    /// Cover for a remote song: the sender's stored cover, else its URL, else a catalogue lookup.
    private func remoteArtwork(for id: UUID, summary: TrackSummary) -> Data? {
        if let cached = remoteCovers[id] { return cached }
        remoteCovers[id] = Data?.none
        Task { [weak self, catalogue, client] in
            // The stored cover is only readable on the same account, but it's the real one.
            // The sender's URL is a catalogue guess, which drew a different cover for imported songs.
            var data: Data? = nil
            if let key = summary.artworkKey {
                data = try? await client.storage.from("artwork").download(path: key)
            }
            if data == nil {
                var url = summary.coverURL.flatMap(URL.init(string:))
                if url == nil {
                    let probe = Track(id: id, title: summary.title, artistName: summary.artist,
                                      albumTitle: summary.album, duration: summary.duration,
                                      sync: SyncMetadata(deviceID: ""),
                                      file: .onlinePlaceholder(sourceRef: summary.sourceRef ?? ""))
                    url = await LibraryService.catalogueArtworkURL(for: probe, catalogue: catalogue)
                }
                if let url { data = await LibraryService.fetchImage(url) }
            }
            guard let self, let data else { return }
            remoteCovers[id] = data
            // Jam adds are queued before their cover lands.
            online?.fillArtwork(data, forTrackID: id)
            if let remote = activeRemote { mirror(remote) }
        }
        return nil
    }
}
