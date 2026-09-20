// DuplicateMerger.swift
// Mixtape — Core/Services
//
// The one-off cleanup for libraries that already doubled up.
//
// `LibraryTrackIndex` stops new duplicates arriving, but it can't reach back:
// a Spotify import that ran before it landed left a second row for every song
// the user already owned, and those rows are real — they're in playlists, they
// may be favourited, one of them may be the copy that's actually downloaded.
//
// So this doesn't delete anything on its own. It builds a plan the user can
// read first: which songs are doubled, which copy survives and why, and which
// playlists get repointed. Applying it is a separate step.

import Foundation

// MARK: - Plan

public struct DuplicateMergePlan: Sendable {

    public struct Group: Identifiable, Sendable {
        public let id: UUID              // the keeper's id, which is unique per group
        public let title: String
        public let artistName: String
        /// Why this copy is the one that survives — shown next to the song.
        public let keeperReason: String
        public let loserIDs: [UUID]
        /// Playlists that currently point at a copy being removed, by name.
        public let playlistNames: [String]
    }

    public var groups: [Group] = []

    public var isEmpty: Bool { groups.isEmpty }

    /// How many rows disappear — not how many songs are affected.
    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.loserIDs.count } }

    public var playlistNames: [String] {
        Array(Set(groups.flatMap(\.playlistNames))).sorted()
    }
}

// MARK: - Merger

public enum DuplicateMerger {

    /// How far apart two runtimes for "the same song" may be. The same slack
    /// `LibraryTrackIndex` matches on, and for the same reason: a rip that
    /// differs by a fade is one song, a radio edit and a club mix are two.
    private static let durationSlack: TimeInterval = 15

    // MARK: Plan

    @MainActor
    public static func plan(library: LibraryService) -> DuplicateMergePlan {
        // Grouped by the same identity the import paths de-duplicate on, so the
        // cleanup and the guard against new duplicates always agree about what
        // "the same song" means.
        var byKey: [String: [Track]] = [:]
        for track in library.tracks where !track.isDeleted {
            byKey[LibraryTrackIndex.key(title: track.title, artistName: track.artistName),
                  default: []].append(track)
        }

        // Playlists a row appears in, so the preview can name them. All Songs is
        // left out: it holds every track by definition, so naming it says nothing.
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

    /// Repoints every playlist and favourite at the keeper, then deletes the
    /// rows it replaced.
    ///
    /// Order matters: the favourite and the playlist entries have to move while
    /// the losing rows still exist, because `deleteTracks` strips a deleted id
    /// out of everything it can find — do it the other way round and a song
    /// that was only in one playlist would quietly leave it.
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
            // A playlist that held both copies ends up holding one, in the
            // position the first of them had.
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

    /// Splits rows filed under one title+artist into runs of the same recording.
    ///
    /// Two songs can share a name and be different takes — a studio cut and a
    /// live one, an interlude and the full version — and merging those would
    /// destroy music rather than tidy it. Duration is the only evidence
    /// available here, so rows sort by it and a gap wider than the slack starts
    /// a new cluster. Rows with no duration at all join the first cluster,
    /// having nothing to contradict it.
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

    /// Ordered best-first: the copy with real bytes on this device wins, and
    /// between two copies that are equally playable the older one wins — it's
    /// the one whose date, play count and place in a playlist the user has been
    /// looking at all along.
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
        return 2   // a path that points at nothing — the file was moved or purged
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
