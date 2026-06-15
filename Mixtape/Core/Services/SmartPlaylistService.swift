// SmartPlaylistService.swift
// Mixtape — Core/Services
//
// CRUD + live resolution for SmartPlaylists. Smart playlists are local-only:
// they persist their *rule* (via SwiftData SmartPlaylistEntity) but never their
// contents, which are resolved on demand against the current library, play
// history and favourites.
//
// ModelContext is obtained the same way the repositories get theirs — passed in
// from the shared ModelContainer. The UI constructs this with
// `deps.modelContainer.mainContext`.
//
// Minimum deployment: iOS 17 / macOS 14

import Foundation
import SwiftData
import Combine

@MainActor
public final class SmartPlaylistService: ObservableObject {

    /// Published list of the user's smart playlists, sorted by creation date.
    @Published public private(set) var playlists: [SmartPlaylist] = []

    private let context: ModelContext
    private let deviceID: String

    public init(context: ModelContext, deviceID: String) {
        self.context  = context
        self.deviceID = deviceID
        seedDefaultsIfEmpty()
        refresh()
    }

    // MARK: - CRUD

    /// Re-reads all smart playlists from SwiftData into `playlists`.
    public func refresh() {
        do {
            let desc = FetchDescriptor<SmartPlaylistEntity>(
                sortBy: [SortDescriptor(\.dateCreated)]
            )
            playlists = try context.fetch(desc).map { entity in
                SmartPlaylist(
                    id:          entity.id,
                    name:        entity.name,
                    iconName:    entity.iconName,
                    rule:        SmartPlaylist.decodeRule(entity.ruleData),
                    dateCreated: entity.dateCreated
                )
            }
        } catch {
            print("[SmartPlaylistService] refresh failed: \(error)")
        }
    }

    @discardableResult
    public func create(name: String, iconName: String, rule: SmartPlaylistRule) -> SmartPlaylist {
        let playlist = SmartPlaylist(name: name, iconName: iconName, rule: rule)
        let entity = SmartPlaylistEntity(
            id:          playlist.id,
            name:        playlist.name,
            iconName:    playlist.iconName,
            ruleData:    playlist.encodedRule(),
            dateCreated: playlist.dateCreated
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

        case .recentlyAdded(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: Date()) ?? .distantPast
            return tracks
                .filter { $0.dateImported >= cutoff }
                .sorted { $0.dateImported > $1.dateImported }

        case .mostPlayed(let limit):
            let counts = playCounts(history: history)
            return tracks
                .filter { (counts[$0.id] ?? 0) > 0 }
                .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
                .prefix(max(limit, 0))
                .map { $0 }

        case .neverPlayed:
            let counts = playCounts(history: history)
            return tracks
                .filter { (counts[$0.id] ?? 0) == 0 }
                .sorted { $0.dateImported > $1.dateImported }

        case .forgottenFavourites(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: Date()) ?? .distantPast
            // recently played IDs (history is capped, so this is a best-effort window)
            let recentIDs = Set(recentlyPlayedIDs(history: history, since: cutoff))
            return tracks
                .filter { library.isFavourited(trackID: $0.id) && !recentIDs.contains($0.id) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        case .fieldContains(let field, let value):
            let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            return tracks
                .filter { matches(track: $0, field: field, needle: needle) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Resolution helpers

    /// Builds a play-count map from the (capped) play history.
    private func playCounts(history: PlayHistoryRepository?) -> [UUID: Int] {
        guard let ids = try? history?.fetchRecentTrackIDs(limit: 200) else { return [:] }
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

    /// On first run (no smart playlists yet) seed a couple of sensible defaults.
    private func seedDefaultsIfEmpty() {
        let desc = FetchDescriptor<SmartPlaylistEntity>()
        let existing = (try? context.fetch(desc)) ?? []
        guard existing.isEmpty else { return }

        let defaults: [SmartPlaylist] = [
            SmartPlaylist(name: "Recently Added", iconName: SmartPlaylistRule.recentlyAdded(days: 30).defaultIcon, rule: .recentlyAdded(days: 30)),
            SmartPlaylist(name: "Most Played",    iconName: SmartPlaylistRule.mostPlayed(limit: 25).defaultIcon,   rule: .mostPlayed(limit: 25)),
            SmartPlaylist(name: "Hidden Gems",    iconName: SmartPlaylistRule.neverPlayed.defaultIcon,             rule: .neverPlayed),
        ]
        for p in defaults {
            context.insert(SmartPlaylistEntity(
                id:          p.id,
                name:        p.name,
                iconName:    p.iconName,
                ruleData:    p.encodedRule(),
                dateCreated: p.dateCreated
            ))
        }
        try? context.save()
    }
}
