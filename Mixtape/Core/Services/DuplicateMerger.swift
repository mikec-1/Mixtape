// Merges duplicate rows from before LibraryTrackIndex existed. Builds a plan
// the user reviews first, then applies it.

import Foundation

// MARK: - Plan

public struct DuplicateMergePlan: Sendable {

    public struct Group: Identifiable, Sendable {
        public let id: UUID              // the keeper's id, which is unique per group
        public let title: String
        public let artistName: String
        public let keeperReason: String
        public let loserIDs: [UUID]
        /// Playlists that currently point at a copy being removed, by name.
        public let playlistNames: [String]
    }

    public var groups: [Group] = []

    public var isEmpty: Bool { groups.isEmpty }

    /// Rows removed, not songs affected.
    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.loserIDs.count } }

    public var playlistNames: [String] {
        Array(Set(groups.flatMap(\.playlistNames))).sorted()
    }
}

// MARK: - Merger

public enum DuplicateMerger {

    /// Same slack as LibraryTrackIndex.
    private static let durationSlack: TimeInterval = 15

    // MARK: Plan

    @MainActor
    public static func plan(library: LibraryService) -> DuplicateMergePlan {
        // Same identity the import dedup uses.
        var byKey: [String: [Track]] = [:]
        for track in library.tracks where !track.isDeleted {
            byKey[LibraryTrackIndex.key(title: track.title, artistName: track.artistName),
                  default: []].append(track)
        }

        // All Songs is left out since it holds everything.
        var playlistsByTrack: [UUID: [String]] = [:]
        for playlist in library.playlists where playlist.id != Playlist.allSongsID {
            for trackID in playlist.trackIDs {
                playlistsByTrack[trackID, default: []].append(playlist.name)
            }
        }

        var plan = DuplicateMergePlan()
        for (_, rows) in byKey where rows.count > 1 {
            for cluster in clusters(rows) where cluster.count > 1 {
                let ranked = cluster.sorted(by: outranks)
                guard let keeper = ranked.first else { continue }
                let losers = Array(ranked.dropFirst())

                plan.groups.append(.init(
                    id: keeper.id,
                    title: keeper.title,
                    artistName: keeper.artistName,
                    keeperReason: reason(for: keeper, over: losers),
                    loserIDs: losers.map(\.id),
                    playlistNames: Array(Set(losers.flatMap { playlistsByTrack[$0.id] ?? [] })).sorted()
                ))
            }
        }

        plan.groups.sort {
            ($0.artistName.lowercased(), $0.title.lowercased())
                < ($1.artistName.lowercased(), $1.title.lowercased())
        }
        return plan
    }

    // MARK: Apply

    /// Repoints playlists and favourites before deleting, since deleteTracks strips
    /// the ids from everything.
    @MainActor
    @discardableResult
    public static func apply(_ plan: DuplicateMergePlan, library: LibraryService) -> Int {
        var replacement: [UUID: UUID] = [:]
        for group in plan.groups {
            for loser in group.loserIDs { replacement[loser] = group.id }
        }
        guard !replacement.isEmpty else { return 0 }

        // A heart on any copy is a heart on the song.
        for (loser, keeper) in replacement
        where library.isFavourited(trackID: loser) && !library.isFavourited(trackID: keeper) {
            library.toggleFavourite(trackID: keeper)
        }

        for playlist in library.playlists
        where playlist.trackIDs.contains(where: { replacement[$0] != nil }) {
            var seen = Set<UUID>()
            let merged = playlist.trackIDs.compactMap { id -> UUID? in
                let resolved = replacement[id] ?? id
                return seen.insert(resolved).inserted ? resolved : nil
            }
            library.setTracks(merged, inPlaylist: playlist.id)
        }

        library.deleteTracks(ids: Array(replacement.keys))
        return replacement.count
    }

    // MARK: - Identity within a name

    /// Splits same-name rows by duration, so a live take and a studio cut stay apart.
    private static func clusters(_ rows: [Track]) -> [[Track]] {
        let timed = rows.filter { $0.duration > 0 }.sorted { $0.duration < $1.duration }
        let untimed = rows.filter { $0.duration <= 0 }

        var out: [[Track]] = []
        for track in timed {
            if let last = out.last?.last, track.duration - last.duration <= durationSlack {
                out[out.count - 1].append(track)
            } else {
                out.append([track])
            }
        }
        if !untimed.isEmpty {
            if out.isEmpty { out.append(untimed) } else { out[0].append(contentsOf: untimed) }
        }
        return out
    }

    // MARK: - Which copy survives

    /// Best first: the copy with bytes here, then the older one.
    private static func outranks(_ a: Track, _ b: Track) -> Bool {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra > rb }
        return a.dateImported < b.dateImported
    }

    private static func rank(_ track: Track) -> Int {
        if track.isUnresolvableShare { return 0 }
        let path = track.file.localPath
        guard !path.isEmpty else { return 1 }
        if AudioPaths.durableURL(forLocalPath: path) != nil { return 4 }
        if AudioPaths.resolve(localPath: path) != nil { return 3 }
        return 2  // path points at nothing
    }

    private static func reason(for keeper: Track, over losers: [Track]) -> String {
        let keeperRank = rank(keeper)
        if keeperRank >= 3, losers.contains(where: { rank($0) < 3 }) {
            return "Keeping the downloaded copy"
        }
        if losers.contains(where: { $0.isUnresolvableShare }) {
            return "Keeping your copy"
        }
        return "Keeping the one added \(keeper.dateImported.formatted(date: .abbreviated, time: .omitted))"
    }
}
