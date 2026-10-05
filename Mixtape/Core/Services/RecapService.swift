// Monthly recaps. Last month's snapshot is built once by the first device to get
// there, kept in `recap_snapshots` so every device shows the same one, and
// announced on the 1st at 10:00. Private until the owner shares it.

import Foundation
import Supabase
import UserNotifications
import OSLog
import Combine

@MainActor
public final class RecapService: NSObject, ObservableObject {

    /// One `recap_snapshots` row.
    public struct Recap: Codable, Sendable, Identifiable, Hashable {
        public var id: String { month }
        public let month: String
        public let payload: RecapSnapshot
        public var shared: Bool
        /// The token in its link; nil until the server has the row.
        public var shareID: String? = nil
        enum CodingKeys: String, CodingKey { case month, payload, shared, shareID = "share_id" }
    }

    private struct NewRow: Encodable, Sendable {
        let userID: UUID
        let month: String
        let payload: RecapSnapshot
        enum CodingKeys: String, CodingKey { case userID = "user_id", month, payload }
    }

    /// The account's recaps, newest first.
    @Published public private(set) var recaps: [Recap] = []
    /// Months watched or dismissed on this device.
    @Published private var seen: Set<String> = []
    /// The story on screen.
    @Published public var presented: Recap?
    /// Whose it is: nil for your own.
    public private(set) var presentedOwner: UserProfile?
    /// Opens on the summary card, as the profile shelf does.
    public private(set) var presentedAtCard = false
    /// A notification tapped before the recap was loaded.
    private var pendingOpen: String?

    public var currentUserID: UUID? {
        didSet { if currentUserID != oldValue { loadLocal() } }
    }

    private let clientProvider: () -> SupabaseClient
    private lazy var client: SupabaseClient = clientProvider()
    private let history: PlayHistoryRepository
    private let library: LibraryService
    private let snapshots: PlayedTrackSnapshotRepository
    private let deviceNames: () async -> [String: String]
    private var calendar: Calendar { .current }

    init(client: @autoclosure @escaping () -> SupabaseClient, history: PlayHistoryRepository,
         library: LibraryService, snapshots: PlayedTrackSnapshotRepository,
         deviceNames: @escaping () async -> [String: String]) {
        self.clientProvider = client
        self.history = history
        self.library = library
        self.snapshots = snapshots
        self.deviceNames = deviceNames
        super.init()

        // Recaps are built from history, so a history wipe takes them with it.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let reset = UserDataReset.from(note)
                guard reset.clearedHistory, !reset.isAccountSwitch, let self else { return }
                self.wipe()
            }
        }
        // The 1st can arrive while the app is open.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    // MARK: - Home

    /// Last month's recap while it's still unwatched.
    public var fresh: Recap? {
        guard let first = recaps.first, first.month == Self.key(for: lastMonth.start),
              !seen.contains(first.month) else { return nil }
        return first
    }

    public func watch(_ recap: Recap) {
        markSeen(recap.month)
        open(recap)
    }

    public func open(_ recap: Recap, owner: UserProfile? = nil, atCard: Bool = false) {
        presentedOwner = owner
        presentedAtCard = atCard
        presented = recap
    }

    public func dismiss(_ recap: Recap) { markSeen(recap.month) }

    /// Every song played in `month`, most played first. What the story's clips draw from.
    public func songs(in month: String) -> [UUID] {
        guard let start = calendar.date(from: DateComponents(year: Int(month.prefix(4)), month: Int(month.suffix(2)))),
              let interval = calendar.dateInterval(of: .month, for: start),
              let ids = try? history.fetchTrackIDs(in: interval) else { return [] }
        return ListeningTrends.tapeOrder(ids)
    }

    /// Every song you've played, most played first.
    public func songsByPlays() -> [UUID] {
        ListeningTrends.tapeOrder((try? history.fetchRecentTrackIDs(limit: 10_000)) ?? [])
    }

    /// Developer tool: this month so far. Never stored, so the real build on the 1st still happens.
    /// Returns the play count when there aren't enough plays yet.
    public func previewThisMonth() async -> Int? {
        let month = calendar.dateInterval(of: .month, for: Date())!
        let key = Self.key(for: month.start)
        guard let snapshot = await build(month, key: key) else {
            return (try? history.fetchTrackIDs(in: month))?.count ?? 0
        }
        open(Recap(month: key, payload: snapshot, shared: false))
        return nil
    }

    /// Opens a hand-crafted recap that triggers every slide, for showing the UI
    /// to someone without any listening data.
    public func demoRecap() {
        let snapshot = RecapSnapshot.demo
        open(Recap(month: snapshot.month, payload: snapshot, shared: false))
    }

    // MARK: - Refresh

    /// After sign-in sync and on the way back to the foreground: adopts the server's
    /// list, builds last month if nobody has, and lines up the notifications.
    public func refresh() async {
        guard let userID = currentUserID else { return }
        if let mine = await fetchRecaps(userID: userID), currentUserID == userID {
            recaps = mine
            saveLocal()
        }
        let last = lastMonth
        let key = Self.key(for: last.start)
        if !recaps.contains(where: { $0.month == key }), let snapshot = await build(last, key: key) {
            do {
                // The first device to build a month wins; later builds are dropped.
                try await client.from("recap_snapshots")
                    .upsert(NewRow(userID: userID, month: key, payload: snapshot),
                            onConflict: "user_id,month", returning: .minimal, ignoreDuplicates: true)
                    .execute()
                if let mine = await fetchRecaps(userID: userID) { recaps = mine }
            } catch {
                MixLog.library.error("[Recap] insert: \(error.localizedDescription)")
                // Offline: show this device's build until the server has one.
                recaps.insert(Recap(month: key, payload: snapshot, shared: false), at: 0)
            }
            saveLocal()
        }
        if let recap = recaps.first(where: { $0.month == key }) { await announce(recap) }
        await prescheduleThisMonth()
        openPending()
    }

    private func build(_ month: DateInterval, key: String) async -> RecapSnapshot? {
        guard let before = calendar.date(byAdding: .month, value: -1, to: month.start),
              let all = try? history.fetchAllPlays(since: before),
              let known = try? history.fetchTrackIDs(before: month.start) else { return nil }
        func row(_ p: PlayHistoryRepository.PlayRecord) -> RecapMath.Play {
            .init(trackID: p.trackID, playedAt: p.playedAt, seconds: p.secondsPlayed, deviceID: p.deviceID)
        }
        // Spotify plays count as their library song when there is one, otherwise under
        // the id Discover would give them.
        guard let spotify = await spotifyListening(from: before, to: month.end, month: key) else { return nil }
        let index = spotify.plays.isEmpty ? nil : LibraryTrackIndex(tracks: library.tracks)
        var spotifyMeta: [UUID: RecapMath.Meta] = [:]
        func spotifyRow(_ p: SpotifyPlay) -> RecapMath.Play {
            let duration = TimeInterval(p.durationMs) / 1000
            let artists = ImportService.creditedArtists(from: p.artist)
            let id: UUID
            if let owned = index?.match(title: p.title, artistName: p.artist, duration: duration) {
                id = owned.id
            } else {
                id = Self.discoverID(title: p.title, artist: p.artist)
                if spotifyMeta[id] == nil {
                    spotifyMeta[id] = .init(title: p.title, artist: p.artist, artists: artists, genre: nil,
                                            duration: duration, inLibrary: false)
                }
            }
            return .init(trackID: id, playedAt: p.playedAt, seconds: 0, deviceID: Self.spotifyDevice)
        }
        let spotifyRows = spotify.plays.map(spotifyRow)

        let plays = (all.filter { $0.playedAt >= month.start && $0.playedAt < month.end }.map(row)
                     + spotifyRows.filter { $0.playedAt >= month.start })
            .sorted { $0.playedAt > $1.playedAt }
        guard plays.count >= RecapMath.minimumPlays else { return nil }
        let previousSpotify = spotifyRows.filter { $0.playedAt < month.start }
        let previous = (all.filter { $0.playedAt < month.start }.map(row) + previousSpotify)
            .sorted { $0.playedAt > $1.playedAt }

        let names = await deviceNames()
        let snapshotMap = (try? snapshots.fetchAll()) ?? [:]
        let spotifyOnly = spotifyMeta
        var snapshot = RecapMath.build(
            key: key, plays: plays, previous: previous,
            knownBefore: known.union(previousSpotify.map(\.trackID)),
            meta: { [library] id in
                let owned = library.track(id: id)
                guard let track = owned ?? snapshotMap[id] else { return spotifyOnly[id] }
                let genre = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(title: track.displayTitle, artist: track.artistName,
                             artists: ImportService.creditedArtists(from: track.artistName),
                             genre: genre?.isEmpty == false ? genre : nil,
                             duration: track.duration, inLibrary: owned != nil)
            },
            deviceName: { id in
                if id == Self.spotifyDevice { return "Spotify" }
                return id == AppDependencies.deviceID ? SupabaseSyncService.deviceName : names[id] ?? "another device"
            },
            calendar: calendar)
        snapshot?.spotifyTop = spotify.top
        if snapshot != nil { snapshot?.social = await social(month) }
        return snapshot
    }

    /// Jams and shared songs in the month. Nil when they couldn't be read, which only
    /// leaves their slide out.
    private func social(_ month: DateInterval) async -> RecapSnapshot.Social? {
        struct Params: Encodable { let p_from: String; let p_to: String }
        let iso = ISO8601DateFormatter()
        do {
            return try await client.rpc("recap_social", params: Params(p_from: iso.string(from: month.start),
                                                                      p_to: iso.string(from: month.end)))
                .execute().value
        } catch {
            MixLog.library.error("[Recap] social: \(error.localizedDescription)")
            return nil
        }
    }

    /// The id Discover gives a song you don't have.
    nonisolated static func discoverID(title: String, artist: String) -> UUID {
        OnlineTrack.stableID(for: OnlineTrack.key(title: ImportService.bareTitle(title),
                                                  artistName: ImportService.creditedArtists(from: artist).first ?? artist))
    }

    /// Stands in for a device id on plays that happened in Spotify.
    private static let spotifyDevice = "spotify"

    /// A `spotify_plays` row, copied from Spotify by the spotify_history job.
    private struct SpotifyPlay: Decodable, Sendable {
        let playedAt: Date
        let title: String
        let artist: String
        let durationMs: Int
        enum CodingKeys: String, CodingKey {
            case playedAt = "played_at", title, artist, durationMs = "duration_ms"
        }
    }

    /// Spotify plays in the range and the month's top list when the account adds them to
    /// recaps, nothing when it doesn't, nil when that couldn't be read, so a month is
    /// never stored without them.
    private func spotifyListening(from start: Date, to end: Date, month key: String) async
        -> (plays: [SpotifyPlay], top: RecapSnapshot.SpotifyTop?)? {
        guard let userID = currentUserID else { return ([], nil) }
        struct Setting: Decodable { let history_sync: Bool }
        let iso = ISO8601DateFormatter()
        do {
            let setting: [Setting] = try await client.from("spotify_connections")
                .select("history_sync").eq("user_id", value: userID).execute().value
            guard setting.first?.history_sync == true else { return ([], nil) }
            let top: [RecapSnapshot.SpotifyTop] = try await client.from("spotify_top")
                .select("songs,artists").eq("user_id", value: userID).eq("month", value: key)
                .execute().value
            var rows: [SpotifyPlay] = []
            let pageSize = 1000
            while true {
                let page: [SpotifyPlay] = try await client.from("spotify_plays")
                    .select("played_at,title,artist,duration_ms")
                    .eq("user_id", value: userID)
                    .gte("played_at", value: iso.string(from: start))
                    .lt("played_at", value: iso.string(from: end))
                    .order("played_at")
                    .range(from: rows.count, to: rows.count + pageSize - 1)
                    .execute().value
                rows += page
                if page.count < pageSize { return (rows, top.first.flatMap { $0.songs.isEmpty ? nil : $0 }) }
            }
        } catch {
            MixLog.library.error("[Recap] Spotify listening: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Remote

    /// Every recap for your own id, only shared ones for anyone else (RLS decides).
    public func fetchRecaps(userID: UUID) async -> [Recap]? {
        do {
            return try await client.from("recap_snapshots")
                .select("month,payload,shared,share_id")
                .eq("user_id", value: userID)
                .order("month", ascending: false)
                .execute().value
        } catch {
            MixLog.library.error("[Recap] fetch: \(error.localizedDescription)")
            return nil
        }
    }

    /// A recap from its link and whose it is. Nil when it's gone or its owner hasn't shown it.
    public func recap(shareID: String) async -> (Recap, UUID)? {
        struct Row: Decodable { let user_id: UUID }
        guard let row: Row = try? await client.from("recap_snapshots")
                .select("user_id").eq("share_id", value: shareID).single().execute().value,
              let recap = await fetchRecaps(userID: row.user_id)?.first(where: { $0.shareID == shareID })
        else { return nil }
        return (recap, row.user_id)
    }

    public func setShared(_ shared: Bool, month: String) {
        guard let userID = currentUserID, let i = recaps.firstIndex(where: { $0.month == month }) else { return }
        recaps[i].shared = shared
        if presented?.month == month { presented?.shared = shared }
        saveLocal()
        Task {
            do {
                try await client.from("recap_snapshots")
                    .update(["shared": shared], returning: .minimal)
                    .eq("user_id", value: userID).eq("month", value: month)
                    .execute()
            } catch {
                MixLog.library.error("[Recap] share: \(error.localizedDescription)")
            }
        }
    }

    private func wipe() {
        guard let userID = currentUserID else { return }
        recaps = []
        presented = nil
        seen = []
        saveLocal()
        removeNotifications()
        RecapClipStore.removeAll()
        Task {
            _ = try? await client.from("recap_snapshots").delete().eq("user_id", value: userID).execute()
        }
    }

    // MARK: - Local

    private var cacheKey: String? { currentUserID.map { "recap.snapshots.\($0.uuidString)" } }
    private var seenKey: String? { currentUserID.map { "recap.seen.\($0.uuidString)" } }
    private var announcedKey: String? { currentUserID.map { "recap.announced.\($0.uuidString)" } }

    private func loadLocal() {
        presented = nil
        recaps = cacheKey.flatMap { UserDefaults.standard.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([Recap].self, from: $0) } ?? []
        seen = Set(seenKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? [])
        openPending()
    }

    private func saveLocal() {
        guard let cacheKey, let data = try? JSONEncoder().encode(recaps) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        if let seenKey { UserDefaults.standard.set(Array(seen), forKey: seenKey) }
    }

    private func markSeen(_ month: String) {
        seen.insert(month)
        saveLocal()
    }

    public func signedOut() {
        removeNotifications()
        RecapClipStore.removeAll()
        currentUserID = nil
    }

    // MARK: - Notifications

    private var lastMonth: DateInterval {
        let now = calendar.dateInterval(of: .month, for: Date())!
        return calendar.dateInterval(of: .month, for: now.start.addingTimeInterval(-1))!
    }

    static func key(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return RecapMath.key(year: c.year!, month: c.month!)
    }

    /// 10:00 on the 1st of the month after `month`.
    private func fireDate(after monthStart: Date) -> DateComponents {
        let next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        var c = calendar.dateComponents([.year, .month, .day], from: next)
        c.hour = 10
        return c
    }

    private var announced: Set<String> {
        get { Set(announcedKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []) }
        set { if let announcedKey { UserDefaults.standard.set(Array(newValue), forKey: announcedKey) } }
    }

    /// Before 10:00 on the 1st this swaps the placeholder for the real numbers;
    /// after it, posts straight away unless a notification already went out.
    private func announce(_ recap: Recap) async {
        guard !seen.contains(recap.month) else { return }
        let r = recap.payload
        let fire = fireDate(after: calendar.date(from: DateComponents(year: r.year, month: r.monthNumber))!)
        let early = calendar.date(from: fire).map { Date() < $0 } ?? false
        guard early || !announced.contains(recap.month) else { return }

        var body = "\(Self.hours(r.minutes)), \(r.songs.formatted()) songs"
        if let rep = r.onRepeat { body += ", and one you played \(rep.count) times in a single day" }
        await post(month: recap.month, body: body + ". Tap to watch your recap.",
                   at: early ? fire : nil)
    }

    /// A placeholder for this month once it has enough plays to get a recap, so
    /// the 1st still gets a notification if the app isn't opened that day.
    private func prescheduleThisMonth() async {
        let month = calendar.dateInterval(of: .month, for: Date())!
        let key = Self.key(for: month.start)
        guard !announced.contains(key),
              let ids = try? history.fetchTrackIDs(in: month), ids.count >= RecapMath.minimumPlays else { return }
        await post(month: key, body: "Tap to watch your recap.", at: fireDate(after: month.start))
    }

    private func post(month: String, body: String, at fire: DateComponents?) async {
        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus
        guard InviteNotifier.isEnabled, status == .authorized || status == .provisional,
              let m = Int(month.suffix(2)) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your \(calendar.monthSymbols[m - 1]) on Mixtape is ready"
        content.body = body
        content.sound = .default
        let trigger = fire.map { UNCalendarNotificationTrigger(dateMatching: $0, repeats: false) }
        // Same id, so the real numbers replace the placeholder.
        try? await centre.add(UNNotificationRequest(identifier: "recap-\(month)", content: content, trigger: trigger))
        announced.insert(month)
    }

    private func removeNotifications() {
        let centre = UNUserNotificationCenter.current()
        Task {
            let ids = await centre.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("recap-") }
            centre.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// "80 hours", "45 minutes".
    static func hours(_ minutes: Int) -> String {
        minutes >= 120 ? "\((minutes / 60).formatted()) hours" : "\(minutes) minutes"
    }

    private func openPending() {
        guard let month = pendingOpen, let recap = recaps.first(where: { $0.month == month }) else { return }
        pendingOpen = nil
        watch(recap)
    }
}

// MARK: - Tapping the notification

extension RecapService {
    /// A tapped `recap-YYYY-MM` banner. Held until the recaps load on a cold launch.
    func open(month: String) {
        pendingOpen = month
        openPending()
    }
}
