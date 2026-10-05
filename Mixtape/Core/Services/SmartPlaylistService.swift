// CRUD and live resolution for smart playlists. Only the rule is stored
// (SmartPlaylistEntity); contents are resolved on demand. Context comes from
// `ModelStore`.

import Foundation
import SwiftData
import Combine
import OSLog

@MainActor
public final class SmartPlaylistService: ObservableObject {

    /// Published list of the user's smart playlists, sorted by creation date.
    @Published public private(set) var playlists: [SmartPlaylist] = []

    /// The open account's context. Never stored.
    private var context: ModelContext { ModelStore.shared.context }
    private let deviceID: String

    /// For covers, which get a `Playlist` and have no deps to ask.
    nonisolated(unsafe) public static weak var current: SmartPlaylistService?

    /// Rules belong to one account. Set by `AppDependencies` on sign-in/out.
    public var currentUserID: String? {
        didSet {
            guard oldValue != currentUserID else { return }
            claimUnownedRows()
            seedDefaultsIfNeeded()
            refresh()
            ensureMonthTapes(history: PlayHistoryRepository())
        }
    }

    public init(deviceID: String) {
        self.deviceID = deviceID
        Self.current = self
    }

    // MARK: - CRUD

    /// Re-reads all smart playlists from SwiftData into `playlists`.
    public func refresh() {
        guard let owner = currentUserID else { playlists = []; return }
        do {
            let desc = FetchDescriptor<SmartPlaylistEntity>(
                sortBy: [SortDescriptor(\.dateCreated)]
            )
            playlists = try context.fetch(desc).filter { $0.ownerID == owner }.map { entity in
                SmartPlaylist(
                    id:          entity.id,
                    name:        entity.name,
                    iconName:    entity.iconName,
                    rule:        SmartPlaylist.decodeRule(entity.ruleData),
                    dateCreated: entity.dateCreated,
                    inLibrary:   entity.inLibrary
                )
            }
        } catch {
            MixLog.library.error("[SmartPlaylistService] refresh failed: \(error)")
        }
    }

    /// User-created rules go straight into the library. Built-ins wait on Home.
    @discardableResult
    public func create(name: String, iconName: String, rule: SmartPlaylistRule) -> SmartPlaylist {
        let playlist = SmartPlaylist(name: name, iconName: iconName, rule: rule, inLibrary: true)
        let entity = SmartPlaylistEntity(
            id:          playlist.id,
            name:        playlist.name,
            iconName:    playlist.iconName,
            ruleData:    playlist.encodedRule(),
            dateCreated: playlist.dateCreated,
            ownerID:     currentUserID,
            inLibrary:   true
        )
        context.insert(entity)
        try? context.save()
        refresh()
        return playlist
    }

    public func update(_ playlist: SmartPlaylist) {
        let id = playlist.id
        let desc = FetchDescriptor<SmartPlaylistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try? context.fetch(desc).first else { return }
        entity.name     = playlist.name
        entity.iconName = playlist.iconName
        entity.ruleData = playlist.encodedRule()
        try? context.save()
        refresh()
    }

    /// Adds or removes a rule from the library. Built-ins go back to Home.
    public func setInLibrary(id: UUID, _ inLibrary: Bool) {
        let desc = FetchDescriptor<SmartPlaylistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try? context.fetch(desc).first else { return }
        entity.inLibrary = inLibrary
        try? context.save()
        refresh()
    }

    public func delete(id: UUID) {
        let desc = FetchDescriptor<SmartPlaylistEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let entity = try? context.fetch(desc).first {
            // Remembered, or `ensureMonthTapes` would make it again.
            if case .monthTape(let year, let month) = SmartPlaylist.decodeRule(entity.ruleData) {
                UserDefaults.standard.set(deletedTapes + ["\(year)-\(month)"], forKey: deletedTapesKey)
            }
            context.delete(entity)
            try? context.save()
        }
        refresh()
    }

    // MARK: - Resolution

    /// Evaluates a rule against the live library. `history` is needed for
    /// play-count and last-played rules.
    public func resolve(
        _ playlist: SmartPlaylist,
        using library: LibraryService,
        history: PlayHistoryRepository?
    ) -> [Track] {
        let tracks = library.tracks
        switch playlist.rule {

        case .recentlyAdded(let limit):
            return tracks
                .sorted { $0.dateImported > $1.dateImported }
                .prefix(max(limit, 0))
                .map { $0 }

        case .mostPlayed(let limit):
            let counts = playCounts(history: history)
            return tracks
                .filter { (counts[$0.id] ?? 0) > 0 }
                .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
                .prefix(max(limit, 0))
                .map { $0 }

        case .onRepeat(let limit):
            // Recent window only; `mostPlayed` is the all-time list.
            let counts = playCounts(history: history, limit: 100)
            return tracks
                .filter { (counts[$0.id] ?? 0) > 1 }
                .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
                .prefix(max(limit, 0))
                .map { $0 }

        case .neverPlayed:
            let counts = playCounts(history: history)
            return dealt(tracks.filter { (counts[$0.id] ?? 0) == 0 }, for: playlist)

        case .forgottenFavourites(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: Date()) ?? .distantPast
            // recently played IDs (history is capped, so this is a best-effort window)
            let recentIDs = Set(recentlyPlayedIDs(history: history, since: cutoff))
            return dealt(tracks.filter { library.isFavourited(trackID: $0.id) && !recentIDs.contains($0.id) },
                         for: playlist)

        case .monthTape:
            guard let start = playlist.rule.tapeStart,
                  let month = Calendar.current.dateInterval(of: .month, for: start),
                  let ids = try? history?.fetchTrackIDs(in: month) else { return [] }
            return Array(ListeningTrends.tapeOrder(ids).lazy
                .compactMap { library.track(id: $0) }
                .prefix(SmartPlaylistRule.tapeLength))

        case .fieldContains(let field, let value):
            let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            return tracks
                .filter { matches(track: $0, field: field, needle: needle) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// Cap for open-ended rules, which can match most of an imported library.
    private static let openRuleCap = 100

    /// Built-ins with fewer songs than this aren't shown. User rules are exempt so
    /// they can still be edited.
    public static let minimumBuiltInSongs = 10

    /// Whether this playlist is worth putting on Home right now.
    public static func isWorthShowing(_ playlist: SmartPlaylist, count: Int) -> Bool {
        guard isBuiltIn(playlist) else { return count > 0 }
        return count >= minimumBuiltInSongs
    }

    /// A weekly deal from an open-ended pool, seeded by ISO week and rule:
    /// stable all week, same on every device. Ties break on the synced id so
    /// the order going into the shuffle matches too.
    private func dealt(_ pool: [Track], for playlist: SmartPlaylist) -> [Track] {
        let ordered = pool.sorted {
            $0.dateImported != $1.dateImported
                ? $0.dateImported > $1.dateImported
                : $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        guard playlist.rule.rotatesWeekly, ordered.count > Self.openRuleCap else {
            return Array(ordered.prefix(Self.openRuleCap))
        }
        return Array(WeeklyDeal.shuffled(ordered, key: playlist.rule.dealKey).prefix(Self.openRuleCap))
    }

    // MARK: - Resolution helpers

    /// Play counts over the whole retained history by default. `onRepeat` passes
    /// a small window.
    private func playCounts(history: PlayHistoryRepository?, limit: Int = 10_000) -> [UUID: Int] {
        guard let ids = try? history?.fetchRecentTrackIDs(limit: limit) else { return [:] }
        var counts: [UUID: Int] = [:]
        for id in ids { counts[id, default: 0] += 1 }
        return counts
    }

    /// IDs in the recent capped history window, used as a "played recently" proxy.
    private func recentlyPlayedIDs(history: PlayHistoryRepository?, since: Date) -> [UUID] {
        (try? history?.fetchRecentTrackIDs(limit: 50)) ?? []
    }

    private func matches(track: Track, field: SmartPlaylistRule.Field, needle: String) -> Bool {
        switch field {
        case .genre:
            return (track.genre ?? "").localizedCaseInsensitiveContains(needle)
        case .artist:
            return track.artistName.localizedCaseInsensitiveContains(needle)
        case .year:
            guard let year = track.year else { return false }
            return String(year).contains(needle)
        }
    }

    // MARK: - Defaults

    /// The shipped rules. `isBuiltIn` matches on these names, since entities
    /// don't record who made them.
    static let defaultRules: [(String, SmartPlaylistRule)] = [
        ("Recently Added",       .recentlyAdded(limit: 50)),
        ("On Repeat",            .onRepeat(limit: 30)),
        ("Most Played",          .mostPlayed(limit: 25)),
        ("Hidden Gems",          .neverPlayed),
        ("Forgotten Favourites", .forgottenFavourites(days: 90)),
    ]

    /// True for seeded rules. A renamed built-in counts as the user's.
    public static func isBuiltIn(_ playlist: SmartPlaylist) -> Bool {
        if case .monthTape = playlist.rule { return true }
        return defaultRules.contains { $0.0 == playlist.name }
    }

    // MARK: - Monthly tapes

    /// Tapes before last month's are the archive, not Home. Checked before resolving,
    /// since there's one per month.
    public static func isArchivedTape(_ playlist: SmartPlaylist, now: Date = Date()) -> Bool {
        guard let start = playlist.rule.tapeStart else { return false }
        return (Calendar.current.dateComponents([.month], from: start, to: now).month ?? 0) > 1
    }

    /// One month's tape, archived or not. Nil once it's been deleted.
    public func tape(year: Int, month: Int) -> SmartPlaylist? {
        playlists.first { $0.rule == .monthTape(year: year, month: month) }
    }

    private var deletedTapesKey: String { "smartPlaylists.deletedTapes.\(currentUserID ?? "")" }
    private var deletedTapes: [String] { UserDefaults.standard.stringArray(forKey: deletedTapesKey) ?? [] }

    /// A tape for every month since the oldest play, so history that syncs in later
    /// gets its months too. Existing and deleted months are left alone.
    public func ensureMonthTapes(history: PlayHistoryRepository) {
        guard let owner = currentUserID, let first = try? history.firstPlayDate() else { return }
        let have = Set(playlists.map(\.rule))
        let deleted = Set(deletedTapes)
        var added = false
        for (year, month) in ListeningTrends.months(from: first, to: Date(), calendar: .current) {
            let rule = SmartPlaylistRule.monthTape(year: year, month: month)
            guard !have.contains(rule), !deleted.contains("\(year)-\(month)"),
                  let start = rule.tapeStart else { continue }
            // Dated to its month, so tapes sort in calendar order.
            context.insert(SmartPlaylistEntity(
                id:          UUID(),
                name:        "\(start.formatted(.dateTime.month(.wide))) Tape",
                iconName:    rule.defaultIcon,
                ruleData:    SmartPlaylist(name: "", rule: rule).encodedRule(),
                dateCreated: start,
                ownerID:     owner
            ))
            added = true
        }
        guard added else { return }
        try? context.save()
        refresh()
    }

    /// Bump to seed newly added defaults on existing installs, once. Deleted ones stay deleted.
    private static let defaultsGeneration = 2
    private static let defaultsKey = "smartPlaylists.defaultsGeneration"

    /// Pre-ownership rows go to the first account signed in, with its seeding
    /// generation so deleted defaults stay deleted.
    private func claimUnownedRows() {
        guard let owner = currentUserID else { return }
        let unowned = ((try? context.fetch(FetchDescriptor<SmartPlaylistEntity>())) ?? [])
            .filter { $0.ownerID == nil }
        guard !unowned.isEmpty else { return }
        unowned.forEach { $0.ownerID = owner }
        try? context.save()
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.defaultsKey), forKey: "\(Self.defaultsKey).\(owner)")
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Seeds all built-ins the first time, then only ones added since the last generation.
    private func seedDefaultsIfNeeded() {
        guard let owner = currentUserID else { return }
        let key = "\(Self.defaultsKey).\(owner)"
        let existing = ((try? context.fetch(FetchDescriptor<SmartPlaylistEntity>())) ?? [])
            .filter { $0.ownerID == owner }
        let seeded = UserDefaults.standard.integer(forKey: key)
        guard existing.isEmpty || seeded < Self.defaultsGeneration else { return }
        let existingNames = Set(existing.map(\.name))

        let rules = Self.defaultRules
        let defaults = rules
            .filter { !existingNames.contains($0.0) }
            .map { SmartPlaylist(name: $0.0, iconName: $0.1.defaultIcon, rule: $0.1) }
        for p in defaults {
            context.insert(SmartPlaylistEntity(
                id:          p.id,
                name:        p.name,
                iconName:    p.iconName,
                ruleData:    p.encodedRule(),
                dateCreated: p.dateCreated,
                ownerID:     owner
            ))
        }
        try? context.save()
        UserDefaults.standard.set(Self.defaultsGeneration, forKey: key)
    }
}
