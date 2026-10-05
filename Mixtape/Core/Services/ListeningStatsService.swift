// Read-only stats over play history ("Year in Mixtape"): top tracks and
// artists, minutes, and plays by hour.

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

    /// Start of the period before this one, which the ▲/▼ badges measure against.
    /// Nil for all-time: nothing comes before it.
    func previousStartDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .last30Days:
            return calendar.date(byAdding: .day, value: -60, to: now)
        case .thisYear:
            return startDate(now: now, calendar: calendar)
                .flatMap { calendar.date(byAdding: .year, value: -1, to: $0) }
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
    /// Against the period before. Nil when there's nothing to compare with.
    public var movement: RankMove? = nil
}

public struct TrackStat: Identifiable, Sendable {
    public var id: UUID { track.id }
    public let track: Track
    public let playCount: Int
    public var movement: RankMove? = nil
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

public struct AlbumStat: Identifiable, Sendable {
    public let id: String          // folded title|lead artist: two records can share a title
    public let title: String
    public let artist: String
    public let playCount: Int
    public let artworkData: Data?
}

/// A name and how often it played. Genres.
public struct CountStat: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let playCount: Int
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
    public let topAlbums: [AlbumStat]
    public let topGenres: [CountStat]
    /// Plays per install id. Naming them is the view's job: names live on the server.
    public let devicePlays: [String: Int]
    /// Listening over time, one point per `seriesUnit`.
    public let series: [PlayPoint]
    public let seriesUnit: Calendar.Component
    /// Plays per day (keyed by start of day), for the heatmap.
    public let playsByDay: [Date: Int]
    public let currentStreak: Int
    public let bestStreak: Int
    /// Songs whose first-ever play is in this period. Nil for all-time, where every song is.
    public let newTracks: Int?

    public static let empty = ListeningStats(
        period: .allTime, totalPlays: 0, uniqueTracks: 0, estimatedMinutes: 0,
        topTracks: [], topArtists: [],
        busiestHour: nil, playsByHour: Array(repeating: 0, count: 24), firstPlay: nil,
        topAlbums: [], topGenres: [], devicePlays: [:], series: [], seriesUnit: .day,
        playsByDay: [:], currentStreak: 0, bestStreak: 0, newTracks: nil
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

    /// Wipes history on the server too, or other devices push it back. Set by AppDependencies.
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

    /// Erases the play log and snapshots of played tracks that aren't in the library.
    /// Deleting music doesn't do this; history is what you listened to.
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

    /// The wipe plus everything that follows it, so every Clear button behaves the same.
    /// `resetHistory` is the bare wipe for callers that announce their own reset.
    public func clearHistory() async {
        resetHistory()
        await afterClear?()
    }

    public func compute(period: StatsPeriod, now: Date = Date()) -> ListeningStats {
        mixMainActivity("stats-compute") { computeBody(period: period, now: now) }
    }

    private func computeBody(period: StatsPeriod, now: Date) -> ListeningStats {
        // Fetches are spanned apart from the in-memory work: a cold fetch is the slow part.
        let start = period.startDate(now: now, calendar: calendar)
        let previousStart = period.previousStartDate(now: now, calendar: calendar)
        // One fetch covers this period and the one before, which only says what moved.
        let rows = mixMainActivity("stats-compute ▸ fetch-plays") {
            (try? history.fetchAllPlays(since: previousStart ?? start)) ?? []
        }
        let plays = start.map { s in rows.filter { $0.playedAt >= s } } ?? rows
        guard !plays.isEmpty else { return ListeningStats.empty }

        // Library first, then online-track snapshots, so Discover plays count too.
        let snapshotMap = mixMainActivity("stats-compute ▸ fetch-snapshots") {
            (try? snapshots?.fetchAll()) ?? [:]
        }
        func resolve(_ id: UUID) -> Track? { library.track(id: id) ?? snapshotMap[id] }

        var countByTrack: [UUID: Int] = [:]
        var playsByHour = Array(repeating: 0, count: 24)
        var playsByDay: [Date: Int] = [:]
        var devicePlays: [String: Int] = [:]
        var estimatedSeconds: TimeInterval = 0

        for play in plays {
            countByTrack[play.trackID, default: 0] += 1
            let hour = calendar.component(.hour, from: play.playedAt)
            if hour >= 0 && hour < 24 { playsByHour[hour] += 1 }
            playsByDay[calendar.startOfDay(for: play.playedAt), default: 0] += 1
            devicePlays[play.deviceID, default: 0] += 1
            // Recorded listen time, else the track's full length (older or unfinalised rows).
            if play.secondsPlayed > 0 {
                estimatedSeconds += play.secondsPlayed
            } else if let track = resolve(play.trackID) {
                estimatedSeconds += track.duration
            }
        }

        // The period before, counted the same way. Nothing in it means no badges,
        // rather than every row reading NEW.
        var previousByTrack: [UUID: Int] = [:]
        if let start, previousStart != nil {
            for row in rows where row.playedAt < start { previousByTrack[row.trackID, default: 0] += 1 }
        }
        let compare = !previousByTrack.isEmpty

        // Most plays first, ties broken by key so equal counts can't swap places between
        // the two periods and show as movement.
        func ranked<K>(_ counts: [K: Int], _ tie: (K) -> String) -> [K] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : tie($0.key) < tie($1.key) }
                .map(\.key)
        }

        // Top tracks (drop songs no longer present)
        func trackOrder(_ counts: [UUID: Int]) -> [UUID] {
            ranked(counts.filter { resolve($0.key) != nil }) { $0.uuidString }
        }
        let tracksNow = Array(trackOrder(countByTrack).prefix(10))
        let trackMoves = compare
            ? ListeningTrends.moves(current: tracksNow, previous: trackOrder(previousByTrack)) : [:]
        let topTracks: [TrackStat] = tracksNow.compactMap { id in
            resolve(id).map { TrackStat(track: $0, playCount: countByTrack[id] ?? 0, movement: trackMoves[id]) }
        }

        // Grouped per song, not per play. Covers are track ids, not bytes; only ten get drawn.
        typealias Group = (name: String, detail: String, count: Int, cover: UUID?)
        func add(_ key: String, _ name: String, _ detail: String, _ count: Int, _ cover: UUID,
                 to groups: inout [String: Group]) {
            var entry = groups[key] ?? (name, detail, 0, nil)
            entry.count += count
            if entry.cover == nil { entry.cover = cover }
            groups[key] = entry
        }
        // Each credited artist counts separately: "Dave, Stormzy" is two artists.
        func artistGroups(_ counts: [UUID: Int]) -> [String: Group] {
            var out: [String: Group] = [:]
            for (id, count) in counts {
                guard let track = resolve(id) else { continue }
                for name in ImportService.creditedArtists(from: track.artistName) {
                    add(name.lowercased(), name, "", count, track.id, to: &out)
                }
            }
            return out
        }
        var albums: [String: Group] = [:]
        var genres: [String: Group] = [:]
        for (id, count) in countByTrack {
            guard let track = resolve(id) else { continue }
            // Title and lead artist: two records sharing a title are different albums.
            let lead = ImportService.creditedArtists(from: track.artistName).first ?? track.artistName
            if !track.albumTitle.isEmpty, track.albumTitle != "Unknown Album" {
                add("\(track.albumTitle.lowercased())|\(lead.lowercased())",
                    track.albumTitle, lead, count, track.id, to: &albums)
            }
            if let genre = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
                add(genre.lowercased(), genre, "", count, track.id, to: &genres)
            }
        }
        func cover(_ group: Group) -> Data? {
            group.cover.flatMap { ArtworkProvider.shared.data(for: .track($0)) }
        }

        let artists = artistGroups(countByTrack)
        let artistsNow = Array(ranked(artists.mapValues { $0.count }) { $0 }.prefix(10))
        let artistMoves = compare
            ? ListeningTrends.moves(current: artistsNow,
                                    previous: ranked(artistGroups(previousByTrack).mapValues { $0.count }) { $0 })
            : [:]
        let topArtists: [ArtistStat] = artistsNow.compactMap { key in
            artists[key].map { ArtistStat(id: key, name: $0.name, playCount: $0.count,
                                          artworkData: cover($0), movement: artistMoves[key]) }
        }
        let topAlbums: [AlbumStat] = ranked(albums.mapValues { $0.count }) { $0 }.prefix(10).compactMap { key in
            albums[key].map { AlbumStat(id: key, title: $0.name, artist: $0.detail,
                                        playCount: $0.count, artworkData: cover($0)) }
        }
        let topGenres: [CountStat] = ranked(genres.mapValues { $0.count }) { $0 }.prefix(5).compactMap { key in
            genres[key].map { CountStat(id: key, name: $0.name, playCount: $0.count) }
        }

        // Discovery: songs in this period that had never played before it.
        let newTracks: Int? = start.map { s in
            let before = mixMainActivity("stats-compute ▸ fetch-earlier-ids") {
                (try? history.fetchTrackIDs(before: s)) ?? []
            }
            return Set(countByTrack.keys).subtracting(before).count
        }

        let busiestHour = playsByHour.enumerated().max(by: { $0.element < $1.element })
            .flatMap { $0.element > 0 ? $0.offset : nil }
        let firstPlay = plays.last?.playedAt   // plays sorted newest-first
        let seriesStart = start ?? firstPlay ?? now
        let unit = ListeningTrends.bucketUnit(from: seriesStart, to: now)
        // ponytail: streaks only see this period's days, so "30 Days" caps a longer run
        // at 30. Counting the current streak off the whole log needs its own day fetch.
        let streaks = ListeningTrends.streaks(days: Set(playsByDay.keys), today: now, calendar: calendar)

        return ListeningStats(
            period: period,
            totalPlays: plays.count,
            uniqueTracks: countByTrack.count,
            estimatedMinutes: Int(estimatedSeconds / 60),
            topTracks: topTracks,
            topArtists: topArtists,
            busiestHour: busiestHour,
            playsByHour: playsByHour,
            firstPlay: firstPlay,
            topAlbums: topAlbums,
            topGenres: topGenres,
            devicePlays: devicePlays,
            series: ListeningTrends.series(playsByDay: playsByDay, from: seriesStart, to: now,
                                           unit: unit, calendar: calendar),
            seriesUnit: unit,
            playsByDay: playsByDay,
            currentStreak: streaks.current,
            bestStreak: streaks.best,
            newTracks: newTracks
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

    /// One page of the log, newest first. `rows` counts plays before deleted songs were
    /// dropped, so a short page isn't necessarily the last.
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
