// SmartPlaylistService.swift
// Mixtape — Core/Services
//
// CRUD + live resolution for SmartPlaylists. Smart playlists are local-only:
// they persist their *rule* (via SwiftData SmartPlaylistEntity) but never their
// contents, which are resolved on demand against the current library, play
// history and favourites.
//
// ModelContext is obtained the same way the repositories get theirs — passed in
// from whichever account's store is open. See `ModelStore`.
//
// Minimum deployment: iOS 17 / macOS 14

import Foundation
import SwiftData
import Combine

@MainActor
public final class SmartPlaylistService: ObservableObject {

    /// Published list of the user's smart playlists, sorted by creation date.
    @Published public private(set) var playlists: [SmartPlaylist] = []

    /// Never stored: the context belongs to whichever account's store is open
    /// right now. See `ModelStore`.
    private var context: ModelContext { ModelStore.shared.context }
    private let deviceID: String

    /// For covers, which get a `Playlist` and have no deps to ask.
    nonisolated(unsafe) public static weak var current: SmartPlaylistService?

    /// Rules are local, but they belong to one account: nobody signed in sees
    /// none, and a second account on this device never sees the first one's.
    /// Set by `AppDependencies` on sign-in and sign-out.
    public var currentUserID: String? {
        didSet {
            guard oldValue != currentUserID else { return }
            claimUnownedRows()
            seedDefaultsIfNeeded()
            refresh()
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
            print("[SmartPlaylistService] refresh failed: \(error)")
        }
    }

    /// A rule the user wrote goes straight into their library: they opened a
    /// sheet and named it, which is the whole gesture of adding something. The
    /// shipped five are the ones that arrive on Home and wait to be asked for.
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

    /// Add this rule to Your Library, or take it back out. Removing is not
    /// deleting: a built-in goes back to living on Home, where it came from.
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
            context.delete(entity)
            try? context.save()
        }
        refresh()
    }

    // MARK: - Resolution

    /// Evaluates a smart playlist's rule against the live library and returns
    /// the matching tracks in rule-appropriate order.
    ///
    /// - `library`: source of truth for the current track collection + favourites.
    /// - `history`: optional play-history repository for play-count / last-played rules.
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
            // The recent window only — `mostPlayed` is the all-time list, and
            // two identical shelves under different names is worse than one.
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

        case .fieldContains(let field, let value):
            let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            return tracks
                .filter { matches(track: $0, field: field, needle: needle) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// These two rules have no limit of their own, and on an imported library
    /// they match nearly everything — a 2 000-song "Hidden Gems" is a library
    /// view, not a playlist anyone will play. Capped to N so the list stays
    /// listenable; the rule itself is unchanged, so nothing stored needs
    /// migrating.
    private static let openRuleCap = 100

    /// Below this a shipped smart playlist isn't worth a card. "Most Played"
    /// with one song in it is the complaint that produced this number: a rule
    /// that can only fill a single row is a rule whose inputs don't exist yet,
    /// and the honest thing is to not draw it until they do. The user's own
    /// rules are exempt — hiding one they wrote leaves them nowhere to edit or
    /// delete it.
    public static let minimumBuiltInSongs = 10

    /// Whether this playlist is worth putting on Home right now.
    public static func isWorthShowing(_ playlist: SmartPlaylist, count: Int) -> Bool {
        guard isBuiltIn(playlist) else { return count > 0 }
        return count >= minimumBuiltInSongs
    }

    /// One week's deal from an open-ended pool.
    ///
    /// Seeded by the ISO week and the playlist's own id, so it is the same list
    /// all week, the same list on every device, and not the same shuffle for
    /// two playlists at once. `prefix` alone showed the same hundred songs for
    /// as long as nothing was imported — which for "never played" is the one
    /// thing guaranteed not to happen.
    private func dealt(_ pool: [Track], for playlist: SmartPlaylist) -> [Track] {
        let ordered = pool.sorted { $0.dateImported > $1.dateImported }
        guard playlist.rule.rotatesWeekly, ordered.count > Self.openRuleCap else {
            return Array(ordered.prefix(Self.openRuleCap))
        }
        return Array(WeeklyDeal.shuffled(ordered, id: playlist.id).prefix(Self.openRuleCap))
    }

    // MARK: - Resolution helpers

    /// Builds a play-count map from the play history.
    ///
    /// The default is the whole retained history, not a recent window.
    /// `mostPlayed` says "all-time" on the card and was reading the last 200
    /// plays, which on a library that is mostly listened to elsewhere meant a
    /// "Most Played" of one song. `onRepeat` passes its own small window,
    /// which is the rule that genuinely wants one.
    private func playCounts(history: PlayHistoryRepository?, limit: Int = 10_000) -> [UUID: Int] {
        guard let ids = try? history?.fetchRecentTrackIDs(limit: limit) else { return [:] }
        var counts: [UUID: Int] = [:]
        for id in ids { counts[id, default: 0] += 1 }
        return counts
    }

    /// Returns IDs played at least once in the recent (capped) history window.
    /// Note: PlayHistory does not store per-entry dates here, so we treat any
    /// presence in recent history as "played recently" — a reasonable proxy
    /// given the 50-entry cap.
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

    /// The generation of the default set. Bumping it tops up existing installs
    /// with the defaults added since — once. A deleted default stays deleted;
    /// the flag is what stops a top-up from resurrecting it on the next launch.
    /// The shelf the app ships. Named here rather than inline in the seeder
    /// because `isBuiltIn` needs the same list: the entity carries no flag
    /// saying who made it, and the seeder's own names are the only thing that
    /// tells a shipped rule from one the user typed.
    static let defaultRules: [(String, SmartPlaylistRule)] = [
        ("Recently Added",       .recentlyAdded(limit: 50)),
        ("On Repeat",            .onRepeat(limit: 30)),
        ("Most Played",          .mostPlayed(limit: 25)),
        ("Hidden Gems",          .neverPlayed),
        ("Forgotten Favourites", .forgottenFavourites(days: 90)),
    ]

    /// True for the five the app seeds. A renamed built-in reads as the user's,
    /// which is the harmless direction to be wrong in — it only decides which
    /// shelf the card sits on.
    public static func isBuiltIn(_ playlist: SmartPlaylist) -> Bool {
        defaultRules.contains { $0.0 == playlist.name }
    }

    private static let defaultsGeneration = 2
    private static let defaultsKey = "smartPlaylists.defaultsGeneration"

    /// Rows from before rules had owners. Nothing recorded whose they were, so
    /// they go to the first account signed in on this build — along with that
    /// install's seeding generation, so a default it deleted stays deleted.
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

    /// Seeds the built-in smart playlists for the signed-in account: all of them
    /// the first time, afterwards only the ones added since its last generation.
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
