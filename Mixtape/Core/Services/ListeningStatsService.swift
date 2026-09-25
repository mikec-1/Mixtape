// ListeningStatsService.swift
// Mixtape — Core/Services
//
// Pure read-side aggregation over the persistent play history ("Year in
// Mixtape"). No new schema, no writes — it joins PlayHistory play events
// against the in-memory library to produce top tracks/artists, estimated
// minutes and a by-hour distribution.

import Foundation
import OSLog

// MARK: - Period

public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case last30Days
    case thisYear
    case allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .last30Days: return "30 Days"
        case .thisYear:   return "This Year"
        case .allTime:    return "All Time"
        }
    }

    /// Tail of a sentence: "your #3 artist **this year**".
    var sentenceSuffix: String {
        switch self {
        case .last30Days: return "of the last 30 days"
        case .thisYear:   return "this year"
        case .allTime:    return "of all time"
        }
    }

    /// Lower bound for the query, or nil for all-time.
    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .thisYear:
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .allTime:
            return nil
        }
    }
}

// MARK: - Result types

public struct ArtistStat: Identifiable, Sendable {
    public let id: String          // artist name (lowercased key)
    public let name: String
    public let playCount: Int
    public let artworkData: Data?
}

public struct TrackStat: Identifiable, Sendable {
    public var id: UUID { track.id }
    public let track: Track
    public let playCount: Int
}

/// Where one artist sits in the account's own listening. About the user, not the
/// catalogue: `plays` is how often *they* played this artist.
public struct ArtistStanding: Sendable {
    public let plays: Int
    /// 1-based place among every artist played in the period. Nil once it's too deep
    /// down the list to mean anything.
    public let rank: Int?
    public let period: StatsPeriod

    /// "Played 412 times · your #3 artist this year". One phrasing for every page.
    public var summary: String {
        let times = "Played \(plays) time\(plays == 1 ? "" : "s")"
        guard let rank else { return times }
        return times + " \u{00B7} your #\(rank) artist \(period.sentenceSuffix)"
    }
}

/// One song's history: how often, when it started, when it was last on.
public struct SongStanding: Sendable {
    public let plays: Int
    public let firstPlay: Date?
    public let lastPlay: Date?
    public let artist: ArtistStanding?

    public var hasData: Bool { plays > 0 || artist != nil }
}

/// One play in the log, resolved to the song it played.
public struct HistoryPlay: Identifiable, Sendable {
    /// The same song appears many times; the moment it played is what separates them.
    public var id: String { "\(track.id)-\(playedAt.timeIntervalSince1970)" }
    public let track: Track
    public let playedAt: Date
    /// Where it was played from: a playlist, album, artist or mix name. Nil for plays
    /// recorded before 2.0, which didn't keep one.
    public let source: String?
}

public struct ListeningStats: Sendable {
    public let period: StatsPeriod
    public let totalPlays: Int
    public let uniqueTracks: Int
    public let estimatedMinutes: Int
    public let topTracks: [TrackStat]
    public let topArtists: [ArtistStat]
    public let busiestHour: Int?            // 0...23
    public let playsByHour: [Int]           // 24 buckets
    public let firstPlay: Date?

    public static let empty = ListeningStats(
        period: .allTime, totalPlays: 0, uniqueTracks: 0, estimatedMinutes: 0,
        topTracks: [], topArtists: [],
        busiestHour: nil, playsByHour: Array(repeating: 0, count: 24), firstPlay: nil
    )

    public var hasData: Bool { totalPlays > 0 }
}

// MARK: - Service

@MainActor
public final class ListeningStatsService {

    private let history: PlayHistoryRepository
    private let library: LibraryService
    private let snapshots: PlayedTrackSnapshotRepository?
    private let calendar: Calendar

    /// Folded artist name -> plays for one period. Ranking an artist means scanning the
    /// whole log, and every Get Info sheet asks, so the scan is kept for `standingTTL`.
    private var artistPlaysCache: (period: StatsPeriod, at: Date, plays: [String: Int])?
    private let standingTTL: TimeInterval = 120
    /// Past this place a rank stops meaning anything, so it isn't shown.
    private let rankDepth = 50

    /// Wipes the account's play history on the server too. Set by
    /// `AppDependencies` once the sync service exists — without it, a reset is
    /// undone the next time another device pushes the plays it still holds.
    public var remoteWipe: (() -> Void)?

    /// What has to follow a wipe the user asked for: rebuild derived state, republish the
    /// profile. Set by AppDependencies, which owns the services that do both.
    public var afterClear: (@MainActor () async -> Void)?

    public init(history: PlayHistoryRepository, library: LibraryService,
                snapshots: PlayedTrackSnapshotRepository? = nil, calendar: Calendar = .current) {
        self.history = history
        self.library = library
        self.snapshots = snapshots
        self.calendar = calendar
        // A wipe delivered by sync doesn't come through `resetHistory`, and clearing the
        // library changes which artists a play resolves to. Either invalidates the scan.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.artistPlaysCache = nil }
        }
    }

    /// Erases everything the stats are computed from: the play log, and the
    /// snapshots of played tracks that never lived in the library.
    ///
    /// Deleting your music does NOT do this, and shouldn't — history is a record
    /// of what you listened to, not of what you own, and re-importing a song
    /// should not resurrect zeroed play counts. But it does mean a wiped library
    /// can still report top artists, which is only ever what someone wants when
    /// they asked for it explicitly.
    public func resetHistory() {
        artistPlaysCache = nil
        do { try history.deleteAll() } catch {
            MixLog.library.error("[ListeningStats] history wipe failed: \(error)")
        }
        remoteWipe?()
        do { try snapshots?.deleteAll() } catch {
            MixLog.library.error("[ListeningStats] snapshot wipe failed: \(error)")
        }
    }

    /// Clearing history from a page: the wipe plus everything that has to follow it, so
    /// every Clear button has the same consequences. `resetHistory` is the mechanical
    /// half, for callers that announce their own reset.
    public func clearHistory() async {
        resetHistory()
        await afterClear?()
    }

    public func compute(period: StatsPeriod, now: Date = Date()) -> ListeningStats {
        mixMainActivity("stats-compute") { computeBody(period: period, now: now) }
    }

    private func computeBody(period: StatsPeriod, now: Date) -> ListeningStats {
        // Two SwiftData fetches and then pure in-memory work, spanned apart
        // because the cost is lopsided in a way the total hides: one call in
        // seven measured 746 ms and the rest were single digits. That is the
        // shape of a cold fetch, not of the loops below — and `library.track(id:)`
        // is already an O(1) index lookup, so the loops were never the suspect
        // they look like.
        let plays = mixMainActivity("stats-compute ▸ fetch-plays") {
            (try? history.fetchAllPlays(since: period.startDate(now: now, calendar: calendar))) ?? []
        }
        guard !plays.isEmpty else { return ListeningStats.empty }

        // Resolve a play's track against the library first, then the online-track
        // snapshot store — so Discover plays count toward stats too.
        let snapshotMap = mixMainActivity("stats-compute ▸ fetch-snapshots") {
            (try? snapshots?.fetchAll()) ?? [:]
        }
        func resolve(_ id: UUID) -> Track? { library.track(id: id) ?? snapshotMap[id] }

        // Per-track play counts
        var countByTrack: [UUID: Int] = [:]
        var playsByHour = Array(repeating: 0, count: 24)
        var estimatedSeconds: TimeInterval = 0

        for play in plays {
            countByTrack[play.trackID, default: 0] += 1
            let hour = calendar.component(.hour, from: play.playedAt)
            if hour >= 0 && hour < 24 { playsByHour[hour] += 1 }
            // The real listen when the play recorded one; rows written before
            // the engine reported it, and plays the app never finalised, fall
            // back to the track's full length.
            if play.secondsPlayed > 0 {
                estimatedSeconds += play.secondsPlayed
            } else if let track = resolve(play.trackID) {
                estimatedSeconds += track.duration
            }
        }

        // Top tracks (resolve against library; drop tracks no longer present)
        let topTracks: [TrackStat] = countByTrack
            .compactMap { id, count -> TrackStat? in
                guard let track = resolve(id) else { return nil }
                return TrackStat(track: track, playCount: count)
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(10)
            .map { $0 }

        // Top artists (group resolved tracks by artist name)
        // The cover is carried as a track id rather than bytes: this loop runs
        // over every song ever played, and only ten of them end up on screen.
        var artistCount: [String: (name: String, count: Int, cover: UUID?)] = [:]
        // Each credited artist counted separately: "Dave, Stormzy" is two
        // artists, and bucketing it whole both hid them from the stats and fed
        // the recommendation seeds a name no catalogue can resolve.
        for (id, count) in countByTrack {
            guard let track = resolve(id) else { continue }
            for name in ImportService.creditedArtists(from: track.artistName) {
                let key = name.lowercased()
                var entry = artistCount[key] ?? (name, 0, nil)
                entry.count += count
                if entry.cover == nil { entry.cover = track.id }
                artistCount[key] = entry
            }
        }
        let topArtists: [ArtistStat] = artistCount
            .sorted { $0.value.count > $1.value.count }
            .prefix(10)
            .map { entry in
                ArtistStat(id: entry.key,
                           name: entry.value.name,
                           playCount: entry.value.count,
                           artworkData: entry.value.cover
                               .flatMap { ArtworkProvider.shared.data(for: .track($0)) })
            }

        let busiestHour = playsByHour.enumerated().max(by: { $0.element < $1.element })
            .flatMap { $0.element > 0 ? $0.offset : nil }

        return ListeningStats(
            period: period,
            totalPlays: plays.count,
            uniqueTracks: countByTrack.count,
            estimatedMinutes: Int(estimatedSeconds / 60),
            topTracks: topTracks,
            topArtists: topArtists,
            busiestHour: busiestHour,
            playsByHour: playsByHour,
            firstPlay: plays.last?.playedAt   // plays sorted newest-first
        )
    }

    // MARK: - Standings

    /// Play count, first and last play for one song, plus where its artist stands.
    /// Called when a sheet opens, not in a view body: the artist half scans history.
    public func songStanding(for track: Track, period: StatsPeriod = .thisYear,
                             now: Date = Date()) -> SongStanding {
        let plays = (try? history.plays(of: track.id)) ?? .none
        // The lead credit, so a feature doesn't rank the guest artist.
        let lead = ImportService.creditedArtists(from: track.artistName).first ?? track.artistName
        return SongStanding(plays: plays.count,
                            firstPlay: plays.first,
                            lastPlay: plays.last,
                            artist: artistStanding(for: lead, period: period, now: now))
    }

    /// Where `name` sits in the account's own listening, or nil if never played.
    public func artistStanding(for name: String, period: StatsPeriod = .thisYear,
                               now: Date = Date()) -> ArtistStanding? {
        let plays = artistPlays(period: period, now: now)
        guard !plays.isEmpty else { return nil }
        // Every spelling of the artist is the same artist. See `ArtistAliases`.
        guard let place = ArtistRanking.place(of: ArtistAliases.spellings(of: name), in: plays)
        else { return nil }
        return ArtistStanding(plays: place.plays,
                              rank: place.rank <= rankDepth ? place.rank : nil,
                              period: period)
    }

    /// Plays per credited artist for the period, cached. Shares `computeBody`'s rules:
    /// snapshots fill in Discover plays, and every credited artist counts separately.
    private func artistPlays(period: StatsPeriod, now: Date) -> [String: Int] {
        if let cache = artistPlaysCache, cache.period == period,
           now.timeIntervalSince(cache.at) < standingTTL { return cache.plays }

        let plays = mixMainActivity("stats-artist-plays") { () -> [String: Int] in
            let rows = (try? history.fetchAllPlays(since: period.startDate(now: now, calendar: calendar))) ?? []
            guard !rows.isEmpty else { return [:] }
            let snapshotMap = (try? snapshots?.fetchAll()) ?? [:]

            var countByTrack: [UUID: Int] = [:]
            for row in rows { countByTrack[row.trackID, default: 0] += 1 }

            var out: [String: Int] = [:]
            for (id, count) in countByTrack {
                guard let track = library.track(id: id) ?? snapshotMap[id] else { continue }
                for name in ImportService.creditedArtists(from: track.artistName) {
                    out[ArtistAliases.fold(name), default: 0] += count
                }
            }
            return out
        }
        artistPlaysCache = (period, now, plays)
        return plays
    }

    // MARK: - Log

    /// One page of the log, newest first, resolved to songs. `rows` is how many plays the
    /// page held before songs that are gone were dropped, so a short page isn't
    /// necessarily the last one.
    public func historyPage(limit: Int = 100, offset: Int = 0) -> (plays: [HistoryPlay], rows: Int) {
        let rows = (try? history.fetchPlays(limit: limit, offset: offset)) ?? []
        guard !rows.isEmpty else { return ([], 0) }
        // Same fallback as `computeBody`, so Discover plays resolve too.
        let snapshotMap = (try? snapshots?.fetchAll()) ?? [:]
        // A playlist recorded its id, so the name is read now and follows a rename.
        let names = Dictionary(library.playlists.map { ($0.id.uuidString, $0.name) },
                               uniquingKeysWith: { first, _ in first })

        let plays: [HistoryPlay] = rows.compactMap { row in
            guard let track = library.track(id: row.trackID) ?? snapshotMap[row.trackID]
            else { return nil }
            let source: String?
            switch row.sourceKind {
            // ponytail: a smart playlist isn't in `playlists`, so it reads as no source
            // rather than as a uuid. Naming it needs the smart list in the lookup.
            case "playlist": source = row.sourceID.flatMap { names[$0] }
            case "name":     source = row.sourceID
            default:         source = nil
            }
            return HistoryPlay(track: track, playedAt: row.playedAt, source: source)
        }
        return (plays, rows.count)
    }
}
