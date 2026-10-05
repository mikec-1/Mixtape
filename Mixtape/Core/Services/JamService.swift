// Jam: several accounts listening together, Spotify-style. The host's device
// plays; guests join with a code, mirror it, add songs to its queue and (when
// the host allows) control it, over the private Realtime channel `jam:<id>`:
// presence = who's in, "state" from the host, "command" from guests to the
// host, "kick" and "end" from the host. Guests can edit the queue freely, but
// only the host can start playback again. A guest can listen on its own device
// too, following the host's song and position.
// A guest pauses continuity while in a Jam: one device can't mirror two players.
// If the host leaves, the Jam ends for everyone (Spotify's rule): the host's device
// renews a 90 s lease (touch_jam), so quitting or dropping off ends it like End does.
// However a device leaves (End, Leave, kicked, ended, disconnected) it pauses on the
// Jam's song and says why.
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
        /// The host's queue row, for remove and move. Nil from older hosts.
        public var row: UUID? = nil
        enum CodingKeys: String, CodingKey { case track, addedBy = "added_by", row }
    }

    nonisolated struct StateMessage: Codable, Sendable {
        var track: TrackSummary?
        var position: Double
        var duration: Double
        var playing: Bool
        var guestsControl: Bool
        var upNext: [Item]
        var shuffle: Bool? = nil
        /// RepeatMode raw value.
        var repeatMode: String? = nil
        enum CodingKeys: String, CodingKey {
            case track, position, duration, playing, shuffle
            case guestsControl = "guests_control", upNext = "up_next", repeatMode = "repeat"
        }
    }

    /// Guest to host. `action`: add | play | pause | next | previous | seek, and the
    /// queue edits remove | move (`row`, `to` counted in up-next) | shuffle (`on`) |
    /// repeat (`mode`) | reshuffle.
    nonisolated struct Command: Codable, Sendable {
        var action: String
        var from: String
        var name: String
        var position: Double? = nil
        var tracks: [TrackSummary]? = nil
        var row: String? = nil
        var to: Int? = nil
        var on: Bool? = nil
        var mode: String? = nil
    }

    nonisolated struct Kick: Codable, Sendable {
        var userID: String
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }

    /// Host to guests: the host queued songs itself.
    nonisolated struct Added: Codable, Sendable {
        var name: String
        var title: String
        var count: Int
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: UUID
        public let code: String
        public let hostName: String
        public let isHost: Bool
        /// The account that joined; a different account never inherits it.
        let userID: UUID
        public var guestsControl: Bool = true
        /// Host: accounts already greeted, so a reconnect or relaunch doesn't
        /// announce them again. Optional so older stored sessions still decode.
        var greeted: Set<String>? = nil
        /// Guest: plays the audio on this device instead of only the host's.
        var playsHere: Bool? = nil
        /// Host: advertised to people nearby. Nil is on.
        var nearby: Bool? = nil
    }

    @Published public private(set) var session: Session? {
        didSet { persist(); nearby.joined = session?.code }
    }
    /// Everyone connected, this device included.
    @Published public private(set) var members: [Member] = []
    @Published public private(set) var upNext: [Item] = []
    @Published public private(set) var shuffle = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var isBusy = false
    /// Drives the Jam sheet from anywhere (device picker, links).
    @Published public var isSheetPresented = false

    public var isGuest: Bool { session.map { !$0.isHost } ?? false }
    public var hostPresent: Bool { members.contains { $0.host } }
    public var playsHere: Bool { session?.playsHere == true }
    public var isDiscoverable: Bool { session?.nearby ?? true }
    public let nearby = JamNearby()
    public var link: URL? { session.map { Self.link(for: $0.code) } }

    /// Opens the Jam sheet a beat later, so a closing picker sheet doesn't swallow it.
    public func present() {
        Task { try? await Task.sleep(for: .milliseconds(350)); isSheetPresented = true }
    }

    public static func link(for code: String) -> URL {
        URL(string: "https://mixtaped.tech/jam/\(code)")!
    }

    private let client: SupabaseClient
    private let engine: PlaybackEngine
    private let continuity: ContinuityService
    private let deviceID: String
    private let currentUser: () -> AppUser?
    private let toast: (Toast) -> Void
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
    /// Signed links to imported songs' uploaded files, so other devices play
    /// the file itself instead of searching for the song.
    private var fileLinks: [UUID: String] = [:]
    /// Storage keys signed and links fetched, so neither happens twice.
    private var fileTried: Set<String> = []
    /// Songs whose shared file is still downloading.
    private var fetching: Set<UUID> = []
    /// Each song's cover as whoever queued it sees it: a signed link to their
    /// stored cover, or the catalogue picture. Every device draws this one.
    private var coverLinks: [UUID: String] = [:]
    /// Those covers, by link, once fetched.
    private var covers: [String: Data] = [:]
    private var lastSent: (position: Double, at: TimeInterval, playing: Bool)?
    /// Host: its own queued songs already seen, nil until the first state seeds it.
    private var seenOwnAdds: Set<UUID>?
    private var sendScheduled = false
    private var lastCheck: TimeInterval = -.infinity
    /// Checks in a row that got no answer; three is about the host's 90 s lease.
    private var missedChecks = 0
    /// Guest listening here: the host song loaded locally, and when it was last nudged into step.
    private var localTrackID: UUID?
    private var localLoading = false
    private var lastLocalSeek: TimeInterval = -.infinity

    private static let storeKey = "jam.session"
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(client: SupabaseClient, engine: PlaybackEngine, continuity: ContinuityService,
                deviceID: String, currentUser: @escaping () -> AppUser?,
                toast: @escaping (Toast) -> Void) {
        self.client      = client
        self.engine      = engine
        self.continuity  = continuity
        self.deviceID    = deviceID
        self.currentUser = currentUser
        self.toast       = toast
        session = UserDefaults.standard.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        nearby.joined = session?.code
        if isGuest { installGuestHooks() }

        engine.$state.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$currentIndex.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$queue.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$shuffleEnabled.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
        engine.queue.$repeatMode.sink { [weak self] _ in self?.scheduleSend() }.store(in: &cancellables)
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
            toast(.failed("Couldn't start a Jam", error))
        }
    }

    public func join(code raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let user = currentUser() else { toast(.failed("Sign in to join a Jam")); return }
        if session?.code == code { isSheetPresented = true; return }
        isBusy = true
        defer { isBusy = false }
        struct Joined: Decodable {
            let id: UUID; let code: String; let host_name: String?
        }
        do {
            let j: Joined = try await client.rpc("join_jam", params: ["p_code": code]).execute().value
            if session != nil { leave(quietly: true) }
            // Joining your own Jam from a second device makes it a guest: one player.
            begin(Session(id: j.id, code: j.code, hostName: j.host_name ?? "Someone",
                          isHost: false, userID: user.id))
            isSheetPresented = true
        } catch {
            switch (error as? PostgrestError)?.code {
            case "P0002": toast(.failed("No Jam with that code"))
            case "42501": toast(.failed("You were removed from that Jam"))
            default:      toast(.failed("Couldn't join the Jam", error))
            }
        }
    }

    /// The code of the Jam a friend is hosting, for their profile. Nil unless they've messaged you.
    public func profileJamCode(of userID: UUID) async -> String? {
        struct Found: Decodable { let code: String }
        let found: Found?? = try? await client.rpc("profile_jam", params: ["p_user": userID.uuidString])
            .execute().value
        return found??.code
    }

    /// Guests leave; the host ends it for everyone.
    public func leave(quietly: Bool = false) {
        guard let s = session else { return }
        if s.isHost {
            Task { try? await client.rpc("end_jam", params: ["p_jam": s.id.uuidString]).execute() }
        }
        close(announceEnd: s.isHost,
              toast: quietly ? nil : .done(s.isHost ? "You ended the Jam" : "You left the Jam"))
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

    private func close(announceEnd: Bool, toast message: Toast?) {
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
        shuffle = false
        repeatMode = .off
        localTrackID = nil
        nearby.stopAdvertising()
        last = nil
        addedBy = [:]
        kicked = []
        fileLinks = [:]
        fileTried = []
        coverLinks = [:]
        covers = [:]
        presenceRefs = [:]
        lastSent = nil
        seenOwnAdds = nil
        lastCheck = -.infinity
        missedChecks = 0
        if !s.isHost {
            engine.queue.manualRedirect = nil
            engine.endMirroring()
            if let uid = currentUser()?.id { continuity.start(userID: uid) }
        }
        // Everyone stays on the Jam's song, paused.
        engine.pause()
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

    public func setDiscoverable(_ on: Bool) {
        guard let s = session, s.isHost, isDiscoverable != on else { return }
        session?.nearby = on
        if on { nearby.advertise(code: s.code, host: s.hostName) } else { nearby.stopAdvertising() }
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
        if s.isHost, s.nearby ?? true { nearby.advertise(code: s.code, host: s.hostName) }
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
                let adds     = channel.broadcastStream(event: "added")
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
                await listen(presence: presence, states: states, commands: commands, kicks: kicks,
                             ends: ends, adds: adds)
                return
            }
        }
        startTicker()
    }

    private func listen(presence: AsyncStream<any PresenceAction>, states: AsyncStream<JSONObject>,
                        commands: AsyncStream<JSONObject>, kicks: AsyncStream<JSONObject>,
                        ends: AsyncStream<JSONObject>, adds: AsyncStream<JSONObject>) async {
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
            group.addTask { [weak self] in
                for await json in adds {
                    guard let added = try? json["payload"]?.decode(as: Added.self) else { continue }
                    await self?.hostQueued(added)
                }
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
               session?.greeted?.contains(member.userID) != true {
                session?.greeted = (session?.greeted ?? []).union([member.userID])
                toast(Toast("\(member.name) joined the Jam", symbol: "person.2.fill"))
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

    private func hostQueued(_ added: Added) {
        guard isGuest else { return }
        toast(Toast(added.count == 1 ? "\(added.name) added \u{201C}\(added.title)\u{201D}"
                                     : "\(added.name) added \(added.count) songs", symbol: "person.2.fill"))
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
        shuffle = msg.shuffle ?? false
        repeatMode = msg.repeatMode.flatMap(RepeatMode.init(rawValue:)) ?? .off
        mirror()
    }

    /// Guest: which device plays the audio. The host's device always plays too.
    public func setPlaysHere(_ on: Bool) {
        guard isGuest, playsHere != on else { return }
        session?.playsHere = on
        localTrackID = nil
        mirror()
    }

    private func mirror() {
        guard isGuest, !localLoading else { return }
        guard let last, let summary = last.msg.track else { installGuestHooks(); return }
        let track = resolve(summary)
        fetchCover(summary, for: track.id)
        if playsHere {
            prefetch(summary, as: track)
            upNext.forEach { prefetch($0.track) }
            // Its file is still downloading: show the host's playback until it lands.
            if !fetching.contains(track.id) { follow(track, last); return }
        }
        installGuestHooks()
        localTrackID = nil
        engine.mirrorRemote(track: track, position: extrapolated(last),
                            duration: last.msg.duration, isPlaying: last.msg.playing)
    }

    /// Listening here: plays the host's song on this device and keeps it in step.
    private func follow(_ track: Track, _ last: (msg: StateMessage, at: TimeInterval)) {
        let target = extrapolated(last)
        guard localTrackID == track.id else {
            // A new song while the host is paused: show it, load it once the host plays.
            guard last.msg.playing else {
                installGuestHooks()
                engine.mirrorRemote(track: track, position: target, duration: last.msg.duration, isPlaying: false)
                return
            }
            localTrackID = track.id
            localLoading = true
            engine.remoteTransport = nil
            Task {
                await engine.play(track: track, in: [track])
                localLoading = false
                // Left while it loaded.
                if session == nil { engine.pause() } else { mirror() }
            }
            return
        }
        // Local transport while nudging, then presses go back to the host.
        engine.remoteTransport = nil
        defer { installGuestHooks() }
        if last.msg.playing, engine.state == .paused { engine.resume() }
        if !last.msg.playing, engine.state == .playing { engine.pause() }
        guard engine.state == .playing || engine.state == .paused,
              abs(engine.currentTime - target) > 2, uptime - lastLocalSeek > 3 else { return }
        lastLocalSeek = uptime
        engine.seek(to: target)
    }

    /// Queues songs on the host. True when it took them (always, while a guest).
    @discardableResult
    func add(_ tracks: [Track]) -> Bool {
        guard let s = session, !s.isHost, let me, let first = tracks.first else { return false }
        guard hostPresent else { toast(.failed("\(s.hostName) isn't connected right now")); return true }
        let sent = Array(tracks.prefix(50))
        Task {
            // Imports carry a link to their file; the host can't find them by name.
            await sign(sent)
            send("command", Command(action: "add", from: me.userID, name: me.name,
                                    tracks: sent.map(summary(of:))))
        }
        toast(.done(tracks.count == 1 ? "Added \u{201C}\(first.title)\u{201D} to the Jam"
                                      : "Added \(tracks.count) songs to the Jam"))
        return true
    }

    private func forward(_ action: PlaybackEngine.RemoteTransportAction) {
        guard let s = session, !s.isHost, let me else { return }
        guard action != .play else { toast(.failed("Only the host can continue playback")); return }
        guard s.guestsControl else { toast(.failed("Only \(s.hostName) can control playback")); return }
        var cmd = Command(action: "", from: me.userID, name: me.name)
        switch action {
        case .play:        return
        case .pause:       cmd.action = "pause"
        case .next:        cmd.action = "next"
        case .previous:    cmd.action = "previous"
        case .seek(let t): cmd.action = "seek"; cmd.position = t
        }
        send("command", cmd)
        // Show the press now; the host's next state confirms or corrects it.
        guard var l = last else { return }
        switch action {
        case .pause:
            l.msg.position = extrapolated(l)
            l.msg.playing = false
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
        // Queue edits are open to everyone, like adding.
        if applyEdit(cmd) { return }
        // Enforced here, not just greyed out on the guest. Only the host resumes.
        guard s.guestsControl, engine.remoteTransport == nil else { return }
        switch cmd.action {
        case "pause":    engine.pause()
        case "next":     Task { await engine.playNext() }
        case "previous": Task { await engine.playPrevious() }
        case "seek":     if let p = cmd.position { engine.seek(to: p); scheduleSend() }
        default: break
        }
    }

    /// A queue edit from the Jam sheet, or false for anything else.
    private func applyEdit(_ cmd: Command) -> Bool {
        let q = engine.queue
        let row = cmd.row.flatMap(UUID.init(uuidString:)).flatMap { id in q.upcomingRows.first { $0.id == id } }
        switch cmd.action {
        case "remove":    if let row { online?.removeFromQueue(at: row.index) }
        case "move":      if let row, let to = cmd.to { online?.moveInQueue(from: row.index, to: q.currentIndex + 1 + to) }
        case "shuffle":   if let on = cmd.on { q.setShuffle(on) }
        case "repeat":    if let mode = cmd.mode.flatMap(RepeatMode.init(rawValue:)) { q.setRepeat(mode) }
        case "reshuffle": if q.shuffleEnabled { q.reshuffleContext() }
        default:          return false
        }
        scheduleSend()
        return true
    }

    // MARK: - Queue edits (the Jam sheet)

    public func removeUpNext(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where upNext.indices.contains(i) {
            guard let row = upNext[i].row else { continue }
            edit(Command(action: "remove", from: "", name: "", row: row.uuidString))
            if isGuest { upNext.remove(at: i) }
        }
    }

    public func moveUpNext(from source: IndexSet, to destination: Int) {
        guard let i = source.first, upNext.indices.contains(i), let row = upNext[i].row else { return }
        edit(Command(action: "move", from: "", name: "", row: row.uuidString, to: destination))
        if isGuest {
            let item = upNext.remove(at: i)
            upNext.insert(item, at: min(destination > i ? destination - 1 : destination, upNext.count))
        }
    }

    public func setShuffle(_ on: Bool) {
        edit(Command(action: "shuffle", from: "", name: "", on: on))
        if isGuest { shuffle = on }
    }

    public func cycleRepeat() {
        let mode = repeatMode.next
        edit(Command(action: "repeat", from: "", name: "", mode: mode.rawValue))
        if isGuest { repeatMode = mode }
    }

    public func reshuffle() {
        edit(Command(action: "reshuffle", from: "", name: ""))
    }

    /// The host applies an edit; a guest sends it and shows it now.
    private func edit(_ cmd: Command) {
        guard let s = session, let me else { return }
        var cmd = cmd
        cmd.from = me.userID
        cmd.name = me.name
        if s.isHost { _ = applyEdit(cmd); return }
        guard hostPresent else { toast(.failed("\(s.hostName) isn't connected right now")); return }
        send("command", cmd)
    }

    private func hostAdd(_ summaries: [TrackSummary], by name: String) {
        let summaries = Array(summaries.prefix(50))
        let tracks = summaries.map { s -> Track in
            let track = continuity.resolve(s)
            if let vid = s.videoID, let ref = track.sourceRef ?? s.sourceRef {
                online?.adoptVideoID(vid, forSourceRef: ref)
            }
            addedBy[track.id] = name
            // The adder's cover wins, here and for everyone else.
            if let link = s.coverURL { coverLinks[track.id] = link }
            return track
        }
        guard let first = tracks.first else { return }
        toast(Toast(tracks.count == 1 ? "\(name) added \u{201C}\(first.title)\u{201D}"
                                      : "\(name) added \(tracks.count) songs", symbol: "person.2.fill"))
        // A guest's imports: their files land first, so none of them gets searched for.
        // ponytail: a big add waits for every file; queue first and fetch behind if that drags.
        let fetches = zip(summaries, tracks).compactMap { prefetch($0, as: $1) }
            + zip(summaries, tracks).compactMap { fetchCover($0, for: $1.id) }
        Task {
            for f in fetches { await f.value }
            guard session?.isHost == true else { return }
            let tracks = zip(summaries, tracks).map { withCover($1, from: $0) }
            guard let first = tracks.first else { return }
            if engine.queue.currentTrack == nil {
                // Nothing playing yet: the first add starts the Jam.
                Task { await engine.play(track: first, in: tracks) }
            } else {
                online?.addToQueue(localTracks: tracks)
            }
            scheduleSend()
        }
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
        let rows = q.upcomingRows
        upNext = rows.prefix(20).map { row in
            Item(track: summary(of: row.track),
                 addedBy: row.origin == .manual ? (addedBy[row.track.id] ?? me.name) : nil,
                 row: row.id)
        }
        shuffle = q.shuffleEnabled
        repeatMode = q.repeatMode
        announceOwnAdds(in: rows)
        // The host's own imports, for guests listening on their device.
        let shown = [q.currentTrack].compactMap { $0 } + rows.prefix(20).map(\.track)
        Task { if await sign(shown) { scheduleSend() } }
        // Mirroring another of the host's own devices: nothing to say.
        guard engine.remoteTransport == nil else { return }
        let msg = StateMessage(track: q.currentTrack.map(summary(of:)),
                               position: engine.currentTime, duration: engine.duration,
                               playing: engine.state == .playing,
                               guestsControl: s.guestsControl, upNext: upNext,
                               shuffle: shuffle, repeatMode: repeatMode.rawValue)
        lastSent = (msg.position, uptime, msg.playing)
        send("state", msg)
    }

    /// Songs the host queued itself go through many paths, so they're spotted
    /// here as new manual rows no guest sent. Guest adds already toast.
    private func announceOwnAdds(in rows: [QueueService.Entry]) {
        guard let me else { return }
        let own = rows.filter { $0.origin == .manual && addedBy[$0.track.id] == nil }
        let ids = Set(own.map(\.track.id))
        defer { seenOwnAdds = ids }
        guard let seen = seenOwnAdds else { return }
        let fresh = own.filter { !seen.contains($0.track.id) }
        guard let first = fresh.first else { return }
        toast(.done(fresh.count == 1 ? "Added \u{201C}\(first.track.title)\u{201D} to the Jam"
                                     : "Added \(fresh.count) songs to the Jam"))
        send("added", Added(name: me.name, title: first.track.title, count: fresh.count))
    }

    /// Continuity's summary, plus a resolver key for local files so another
    /// account can find the song.
    private func summary(of track: Track) -> TrackSummary {
        var s = continuity.summary(of: track)
        // Not for an edit: its own title would find the original.
        if s.sourceRef == nil, track.edit == nil {
            s.sourceRef = OnlineTrack.key(title: track.identityTitle, artistName: track.artistName)
        }
        s.audioURL = fileLinks[track.id]
        s.coverURL = coverLinks[track.id] ?? online?.artworkURL(forTrackID: track.id)?.absoluteString ?? s.coverURL
        return s
    }

    /// The song with the sender's cover once it has landed, else this device's own.
    private func resolve(_ s: TrackSummary) -> Track {
        withCover(continuity.resolve(s), from: s)
    }

    private func withCover(_ track: Track, from s: TrackSummary) -> Track {
        guard let data = s.coverURL.flatMap({ covers[$0] }) else { return track }
        var track = track
        track.artworkData = data
        return track
    }

    /// Fetches the sender's cover once and swaps it into the queue. Nil when there's nothing to fetch.
    @discardableResult
    private func fetchCover(_ s: TrackSummary, for id: UUID) -> Task<Void, Never>? {
        guard let link = s.coverURL, let url = URL(string: link), fileTried.insert(link).inserted else { return nil }
        return Task {
            guard let data = await LibraryService.fetchImage(url), session != nil else { return }
            covers[link] = data
            online?.fillArtwork(data, forTrackID: id, replacing: true)
        }
    }

    // MARK: - Shared files

    /// Signs day-long links to these songs' uploaded files, in one call. True if any are new.
    /// ponytail: a Jam past a day hands out dead links; re-sign by age if they run that long.
    /// Covers too, so another account sees the stored cover instead of guessing one.
    @discardableResult
    private func sign(_ tracks: [Track]) async -> Bool {
        var files: [String: UUID] = [:]
        var art: [String: UUID] = [:]
        for t in tracks {
            if !t.isOnline, fileLinks[t.id] == nil, let key = t.file.remoteKey, !key.isEmpty,
               fileTried.insert(key).inserted { files[key] = t.id }
            if coverLinks[t.id] == nil, let key = t.artworkKey, !key.isEmpty,
               fileTried.insert("artwork/" + key).inserted { art[key] = t.id }
        }
        let newFiles = await signed(files, in: "audio")
        let newArt = await signed(art, in: "artwork")
        fileLinks.merge(newFiles) { old, _ in old }
        coverLinks.merge(newArt) { old, _ in old }
        return !newFiles.isEmpty || !newArt.isEmpty
    }

    private func signed(_ keys: [String: UUID], in bucket: String) async -> [UUID: String] {
        guard !keys.isEmpty,
              let results = try? await client.storage.from(bucket)
                  .createSignedURLs(paths: Array(keys.keys), expiresIn: 86_400) else { return [:] }
        var links: [UUID: String] = [:]
        for r in results {
            if let id = keys[r.path], let url = r.signedURL { links[id] = url.absoluteString }
        }
        return links
    }

    /// Downloads a shared file once, into the playback cache under the song's
    /// key, so it plays as it is. Nil when there's nothing to fetch.
    @discardableResult
    private func prefetch(_ s: TrackSummary, as resolved: Track? = nil) -> Task<Void, Never>? {
        guard let link = s.audioURL, let url = URL(string: link), fileTried.insert(link).inserted else { return nil }
        let track = resolved ?? continuity.resolve(s)
        // Our own copy plays already.
        guard track.isOnline, let ref = track.sourceRef else { return nil }
        fetching.insert(track.id)
        return Task {
            defer { fetching.remove(track.id) }
            do {
                let (tmp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    return
                }
                let named = PlaybackCache.stagingDirectory.appending(path: "\(UUID().uuidString).\(url.pathExtension)")
                try FileManager.default.moveItem(at: tmp, to: named)
                // A searched copy under the same key would win the lookup.
                while PlaybackCache.remove(forSourceRef: ref) {}
                _ = try PlaybackCache.adopt(named, forSourceRef: ref)
                fileLinks[track.id] = link
            } catch {
                MixLog.sync.error("[Jam] shared file fetch failed: \(error)")
            }
        }
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
        let now = uptime
        if now - lastCheck >= 30 { check(s) }
        guard s.isHost else {
            if last?.msg.playing == true || playsHere { mirror() }
            return
        }
        guard let sent = lastSent else { return }
        let expected = sent.playing ? sent.position + (now - sent.at) : sent.position
        // A seek, or the 5 s heartbeat that keeps guests honest.
        if abs(engine.currentTime - expected) > 2 || (sent.playing && now - sent.at >= 5) {
            sendState()
        }
    }

    /// The host renews the lease; guests ask whether it's still on. Catches an
    /// end whose broadcast was missed, and a host who left without pressing End.
    private func check(_ s: Session) {
        lastCheck = uptime
        Task {
            // Only a real false ends it: an error or a signed-out null isn't an answer.
            let live: Bool?
            if s.isHost {
                live = try? await client.rpc("touch_jam", params: ["p_jam": s.id.uuidString]).execute().value
            } else {
                live = try? await client.rpc("can_use_jam_topic",
                                             params: ["p_topic": "jam:\(s.id.uuidString.lowercased())"]).execute().value
            }
            guard session?.id == s.id else { return }
            guard let live else {
                missedChecks += 1
                if missedChecks >= 3 { close(announceEnd: s.isHost, toast: .failed("Lost connection to the Jam")) }
                return
            }
            missedChecks = 0
            guard !live else { return }
            close(announceEnd: s.isHost, toast: "This Jam has ended")
        }
    }

    private func extrapolated(_ last: (msg: StateMessage, at: TimeInterval)) -> TimeInterval {
        last.msg.playing ? last.msg.position + (uptime - last.at) : last.msg.position
    }
}
