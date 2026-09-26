// Jam: several accounts listening together, Spotify-style. The host's device
// plays; guests join with a code, mirror it, add songs to its queue and (when
// the host allows) control it, over the private Realtime channel `jam:<id>`:
// presence = who's in, "state" from the host, "command" from guests to the
// host, "kick" and "end" from the host.
// A guest pauses continuity while in a Jam: one device can't mirror two players.
// Shares its protocol with mixtape-web src/lib/jam.ts, keep them in sync.

import Foundation
import Combine
import os
import Supabase

@MainActor
public final class JamService: ObservableObject {

    typealias TrackSummary = ContinuityService.TrackSummary

    /// One device in the Jam; presence is keyed by device id.
    nonisolated public struct Member: Codable, Hashable, Identifiable, Sendable {
        public let deviceID: String
        public let userID: String
        public let name: String
        public let host: Bool
        public var id: String { deviceID }
        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", userID = "user_id", name, host
        }
    }

    /// A row of the host's upcoming queue, as everyone sees it.
    nonisolated public struct Item: Codable, Sendable {
        var track: TrackSummary
        /// Who queued it; nil for the playlist or recommendations.
        public var addedBy: String?
        public var title: String { track.title }
        public var artist: String { track.artist }
        public var coverURL: URL? { track.coverURL.flatMap(URL.init(string:)) }
        enum CodingKeys: String, CodingKey { case track, addedBy = "added_by" }
    }

    nonisolated struct StateMessage: Codable, Sendable {
        var track: TrackSummary?
        var position: Double
        var duration: Double
        var playing: Bool
        var guestsControl: Bool
        var upNext: [Item]
        enum CodingKeys: String, CodingKey {
            case track, position, duration, playing
            case guestsControl = "guests_control", upNext = "up_next"
        }
    }

    /// Guest to host. `action`: add | play | pause | next | previous | seek.
    nonisolated struct Command: Codable, Sendable {
        var action: String
        var from: String
        var name: String
        var position: Double? = nil
        var tracks: [TrackSummary]? = nil
    }

    nonisolated struct Kick: Codable, Sendable {
        var userID: String
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: UUID
        public let code: String
        public let hostName: String
        public let isHost: Bool
        /// The account that joined; a different account never inherits it.
        let userID: UUID
        public var guestsControl: Bool = true
    }

    @Published public private(set) var session: Session? {
        didSet { persist() }
    }
    /// Everyone connected, this device included.
    @Published public private(set) var members: [Member] = []
    @Published public private(set) var upNext: [Item] = []
    @Published public private(set) var isBusy = false
    /// Drives the Jam sheet from anywhere (device picker, links).
    @Published public var isSheetPresented = false

    public var isGuest: Bool { session.map { !$0.isHost } ?? false }
    public var hostPresent: Bool { members.contains { $0.host } }
    public var link: URL? { session.map { Self.link(for: $0.code) } }

    /// Opens the Jam sheet a beat later, so a closing picker sheet doesn't swallow it.
    public func present() {
        Task { try? await Task.sleep(for: .milliseconds(350)); isSheetPresented = true }
    }

    public static func link(for code: String) -> URL {
        URL(string: "https://mixtaped.tech/jam?code=\(code)")!
    }

    private let client: SupabaseClient
    private let engine: PlaybackEngine
    private let continuity: ContinuityService
    private let deviceID: String
    private let currentUser: () -> AppUser?
    private let toast: (String) -> Void
    public weak var online: OnlinePlaybackCoordinator?

    private var channel: RealtimeChannelV2?
    private var channelTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var me: Member?
    private var presenceRefs: [String: Set<String>] = [:]
    /// Guest: the host's last state and when it arrived.
    private var last: (msg: StateMessage, at: TimeInterval)?
    /// Host: who queued each song, by track id.
    // ponytail: keyed by song, so the same song queued twice shows the latest name.
    private var addedBy: [UUID: String] = [:]
    /// Host: removed this session, ignored until their socket drops.
    private var kicked: Set<String> = []
    private var lastSent: (position: Double, at: TimeInterval, playing: Bool)?
    private var sendScheduled = false

    private static let storeKey = "jam.session"
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(client: SupabaseClient, engine: PlaybackEngine, continuity: ContinuityService,
                deviceID: String, currentUser: @escaping () -> AppUser?,
                toast: @escaping (String) -> Void) {
        self.client      = client
        self.engine      = engine
        self.continuity  = continuity
        self.deviceID    = deviceID
        self.currentUser = currentUser
        self.toast       = toast
        session = UserDefaults.standard.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        if isGuest { installGuestHooks() }

        engine.$state.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$currentIndex.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$queue.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
    }

    // MARK: - Starting, joining, leaving

    public func start() async {
        guard session == nil, let user = currentUser() else { return }
        isBusy = true
        defer { isBusy = false }
        struct Started: Decodable { let id: UUID; let code: String }
        do {
            let s: Started = try await client.rpc("start_jam").execute().value
            // The host has to be the device playing.
            if continuity.activeRemote != nil { continuity.play(on: nil) }
            begin(Session(id: s.id, code: s.code, hostName: user.displayName,
                          isHost: true, userID: user.id))
        } catch {
            MixLog.sync.error("[Jam] start failed: \(error)")
            toast("Couldn't start a Jam")
        }
    }

    public func join(code raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let user = currentUser() else { toast("Sign in to join a Jam"); return }
        if session?.code == code { isSheetPresented = true; return }
        isBusy = true
        defer { isBusy = false }
        struct Joined: Decodable {
            let id: UUID; let code: String; let host_name: String?
        }
        do {
            let j: Joined = try await client.rpc("join_jam", params: ["p_code": code]).execute().value
            if session != nil { leave() }
            // Joining your own Jam from a second device makes it a guest: one player.
            begin(Session(id: j.id, code: j.code, hostName: j.host_name ?? "Someone",
                          isHost: false, userID: user.id))
            isSheetPresented = true
        } catch {
            switch (error as? PostgrestError)?.code {
            case "P0002": toast("No Jam with that code")
            case "42501": toast("You were removed from that Jam")
            default:      toast("Couldn't join the Jam")
            }
        }
    }

    /// Guests leave; the host ends it for everyone.
    public func leave() {
        guard let s = session else { return }
        if s.isHost {
            Task { try? await client.rpc("end_jam", params: ["p_jam": s.id.uuidString]).execute() }
        }
        close(announceEnd: s.isHost, toast: nil)
    }

    /// Rejoins after the socket came back (sign-in, foreground, relaunch).
    public func resume() {
        guard let s = session else { return }
        guard s.userID == currentUser()?.id else { close(announceEnd: false, toast: nil); return }
        connect()
    }

    private func begin(_ s: Session) {
        session = s
        if !s.isHost {
            continuity.stop()
            installGuestHooks()
        }
        connect()
    }

    private func close(announceEnd: Bool, toast message: String?) {
        guard let s = session else { return }
        channelTask?.cancel()
        channelTask = nil
        tickTask?.cancel()
        tickTask = nil
        if let channel {
            self.channel = nil
            Task { [client] in
                if announceEnd { try? await channel.broadcast(event: "end", message: [String: String]()) }
                await channel.untrack()
                await client.removeChannel(channel)
            }
        }
        session = nil
        members = []
        upNext = []
        last = nil
        addedBy = [:]
        kicked = []
        presenceRefs = [:]
        lastSent = nil
        if !s.isHost {
            engine.queue.manualRedirect = nil
            engine.endMirroring()
            if let uid = currentUser()?.id { continuity.start(userID: uid) }
        }
        if let message { toast(message) }
    }

    private func persist() {
        let data = session.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    // MARK: - Host controls

    public func setGuestsControl(_ on: Bool) {
        guard session?.isHost == true, session?.guestsControl != on else { return }
        session?.guestsControl = on
        sendState()
    }

    public func remove(_ member: Member) {
        guard let s = session, s.isHost, member.userID != me?.userID else { return }
        kicked.insert(member.userID)
        send("kick", Kick(userID: member.userID))
        Task {
            try? await client.rpc("kick_jam_member",
                                  params: ["p_jam": s.id.uuidString, "p_user": member.userID]).execute()
        }
    }

    // MARK: - Channel

    private func connect() {
        guard let s = session, let user = currentUser() else { return }
        let topic = "jam:\(s.id.uuidString.lowercased())"
        if channel?.topic == "realtime:\(topic)", channel?.status == .subscribing { return }
        me = Member(deviceID: deviceID, userID: user.id.uuidString.lowercased(),
                    name: s.isHost ? s.hostName : user.displayName, host: s.isHost)
        let old = channel
        channel = nil
        channelTask?.cancel()
        let key = deviceID
        channelTask = Task { [weak self] in
            guard let self else { return }
            if let old { await client.removeChannel(old) }
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                await client.connectRealtimeSocket()
                let channel = client.channel(topic) {
                    $0.isPrivate = true
                    $0.presence.key = key
                }
                self.channel = channel
                let presence = channel.presenceChange()
                let states   = channel.broadcastStream(event: "state")
                let commands = channel.broadcastStream(event: "command")
                let kicks    = channel.broadcastStream(event: "kick")
                let ends     = channel.broadcastStream(event: "end")
                do {
                    try await client.joinWithDeadline(channel)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.channel = nil
                    await client.removeChannel(channel)
                    // Refused because the Jam is over, or just a dead socket?
                    let live: Bool = (try? await client.rpc("can_use_jam_topic",
                                                            params: ["p_topic": topic]).execute().value) ?? true
                    guard live else { close(announceEnd: false, toast: "This Jam has ended"); return }
                    MixLog.sync.error("[Jam] join failed, retrying in \(delay): \(error)")
                    await client.reconnectRealtimeSocket()
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
                    continue
                }
                members = []
                presenceRefs = [:]
                if let me { do { try await channel.track(me) } catch { MixLog.sync.error("[Jam] track failed: \(error)") } }
                sendState()
                await listen(presence: presence, states: states, commands: commands, kicks: kicks, ends: ends)
                return
            }
        }
        startTicker()
    }

    private func listen(presence: AsyncStream<any PresenceAction>, states: AsyncStream<JSONObject>,
                        commands: AsyncStream<JSONObject>, kicks: AsyncStream<JSONObject>,
                        ends: AsyncStream<JSONObject>) async {
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
                    guard let cmd = try? json["payload"]?.decode(as: Command.self) else { continue }
                    await self?.handle(cmd)
                }
            }
            group.addTask { [weak self] in
                for await json in kicks {
                    guard let kick = try? json["payload"]?.decode(as: Kick.self) else { continue }
                    await self?.handle(kick)
                }
            }
            group.addTask { [weak self] in
                for await _ in ends { await self?.hostEnded() }
            }
        }
    }

    private func handle(presence action: any PresenceAction) {
        for (key, p) in action.leaves {
            presenceRefs[key]?.remove(p.ref)
            guard presenceRefs[key]?.isEmpty ?? true else { continue }
            presenceRefs[key] = nil
            members.removeAll { $0.deviceID == key }
        }
        var joined = false
        for (key, p) in action.joins {
            guard let member = try? p.decodeState(as: Member.self) else { continue }
            presenceRefs[key, default: []].insert(p.ref)
            if let i = members.firstIndex(where: { $0.deviceID == key }) {
                if members[i] != member { members[i] = member }
                continue
            }
            if session?.isHost == true, member.userID != me?.userID,
               !members.contains(where: { $0.userID == member.userID }) {
                toast("\(member.name) joined the Jam")
            }
            members.append(member)
            joined = true
        }
        // A guest that just joined should see what's playing now.
        if joined { scheduleSend() }
    }

    private func handle(_ kick: Kick) {
        guard !(session?.isHost ?? true), kick.userID == me?.userID else { return }
        close(announceEnd: false, toast: "You were removed from the Jam")
    }

    private func hostEnded() {
        guard let s = session, !s.isHost else { return }
        close(announceEnd: false, toast: "\(s.hostName) ended the Jam")
    }

    private func send<T: Codable & Sendable>(_ event: String, _ message: T) {
        guard let channel, channel.status == .subscribed else { return }
        Task { try? await channel.broadcast(event: event, message: message) }
    }

    // MARK: - Guest

    /// While a guest, local plays and queue adds go to the host.
    private func installGuestHooks() {
        engine.queue.manualRedirect = { [weak self] in self?.add($0) ?? false }
        engine.remoteTransport = { [weak self] in self?.forward($0) }
        engine.remotePlayRedirect = { [weak self] track, _ in self?.add([track]) ?? false }
    }

    private func receive(_ msg: StateMessage) {
        guard let s = session, !s.isHost else { return }
        last = (msg, uptime)
        if s.guestsControl != msg.guestsControl { session?.guestsControl = msg.guestsControl }
        upNext = msg.upNext
        mirror()
    }

    private func mirror() {
        installGuestHooks()
        guard let last, let summary = last.msg.track else { return }
        engine.mirrorRemote(track: continuity.resolve(summary), position: extrapolated(last),
                            duration: last.msg.duration, isPlaying: last.msg.playing)
    }

    /// Queues songs on the host. True when it took them (always, while a guest).
    @discardableResult
    func add(_ tracks: [Track]) -> Bool {
        guard let s = session, !s.isHost, let me, let first = tracks.first else { return false }
        guard hostPresent else { toast("\(s.hostName) isn't connected right now"); return true }
        send("command", Command(action: "add", from: me.userID, name: me.name,
                                tracks: tracks.prefix(50).map(summary(of:))))
        toast(tracks.count == 1 ? "Added \u{201C}\(first.title)\u{201D} to the Jam"
                                : "Added \(tracks.count) songs to the Jam")
        return true
    }

    private func forward(_ action: PlaybackEngine.RemoteTransportAction) {
        guard let s = session, !s.isHost, let me else { return }
        guard s.guestsControl else { toast("Only \(s.hostName) can control playback"); return }
        var cmd = Command(action: "", from: me.userID, name: me.name)
        switch action {
        case .play:        cmd.action = "play"
        case .pause:       cmd.action = "pause"
        case .next:        cmd.action = "next"
        case .previous:    cmd.action = "previous"
        case .seek(let t): cmd.action = "seek"; cmd.position = t
        }
        send("command", cmd)
        // Show the press now; the host's next state confirms or corrects it.
        guard var l = last else { return }
        switch action {
        case .play, .pause:
            l.msg.position = extrapolated(l)
            l.msg.playing = action == .play
        case .seek(let t):
            l.msg.position = t
        default:
            return
        }
        l.at = uptime
        last = l
        mirror()
    }

    // MARK: - Host

    private func handle(_ cmd: Command) {
        guard let s = session, s.isHost, !kicked.contains(cmd.from) else { return }
        if cmd.action == "add" {
            hostAdd(cmd.tracks ?? [], by: cmd.name)
            return
        }
        // Enforced here, not just greyed out on the guest.
        guard s.guestsControl, engine.remoteTransport == nil else { return }
        switch cmd.action {
        case "play":     if !engine.state.isPlaying { engine.togglePlayPause() }
        case "pause":    engine.pause()
        case "next":     Task { await engine.playNext() }
        case "previous": Task { await engine.playPrevious() }
        case "seek":     if let p = cmd.position { engine.seek(to: p); scheduleSend() }
        default: break
        }
    }

    private func hostAdd(_ summaries: [TrackSummary], by name: String) {
        let tracks = summaries.prefix(50).map { s -> Track in
            let track = continuity.resolve(s)
            if let vid = s.videoID, let ref = track.sourceRef ?? s.sourceRef {
                online?.adoptVideoID(vid, forSourceRef: ref)
            }
            addedBy[track.id] = name
            return track
        }
        guard let first = tracks.first else { return }
        if engine.queue.currentTrack == nil {
            // Nothing playing yet: the first add starts the Jam.
            Task { await engine.play(track: first, in: tracks) }
        } else {
            online?.addToQueue(localTracks: tracks)
        }
        toast(tracks.count == 1 ? "\(name) added \u{201C}\(first.title)\u{201D}"
                                : "\(name) added \(tracks.count) songs")
        scheduleSend()
    }

    private func scheduleSend() {
        guard session?.isHost == true, !sendScheduled else { return }
        sendScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            sendScheduled = false
            sendState()
        }
    }

    private func sendState() {
        guard let s = session, s.isHost, let me else { return }
        let q = engine.queue
        upNext = q.upcomingRows.prefix(20).map { row in
            Item(track: summary(of: row.track),
                 addedBy: row.origin == .manual ? (addedBy[row.track.id] ?? me.name) : nil)
        }
        // Mirroring another of the host's own devices: nothing to say.
        guard engine.remoteTransport == nil else { return }
        let msg = StateMessage(track: q.currentTrack.map(summary(of:)),
                               position: engine.currentTime, duration: engine.duration,
                               playing: engine.state == .playing,
                               guestsControl: s.guestsControl, upNext: upNext)
        lastSent = (msg.position, uptime, msg.playing)
        send("state", msg)
    }

    /// Continuity's summary, plus a resolver key for local files so another
    /// account can find the song.
    private func summary(of track: Track) -> TrackSummary {
        var s = continuity.summary(of: track)
        if s.sourceRef == nil {
            s.sourceRef = OnlineTrack.key(title: track.identityTitle, artistName: track.artistName)
        }
        return s
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
        guard let s = session else { return }
        guard s.isHost else {
            if last?.msg.playing == true { mirror() }
            return
        }
        guard let sent = lastSent else { return }
        let now = uptime
        let expected = sent.playing ? sent.position + (now - sent.at) : sent.position
        // A seek, or the 5 s heartbeat that keeps guests honest.
        if abs(engine.currentTime - expected) > 2 || (sent.playing && now - sent.at >= 5) {
            sendState()
        }
    }

    private func extrapolated(_ last: (msg: StateMessage, at: TimeInterval)) -> TimeInterval {
        last.msg.playing ? last.msg.position + (uptime - last.at) : last.msg.position
    }
}
