// Monthly recap maths: one finished month of plays in, one frozen snapshot out.
// Foundation only so the check script compiles against it:
//
//   xcrun swiftc Mixtape/Core/Services/ListeningTrends.swift Mixtape/Core/Services/RecapMath.swift \
//       scripts/recap-check.swift -o /tmp/recapcheck && /tmp/recapcheck

import Foundation

/// A finished month. Built once by whichever device gets there first and never
/// recalculated, so it reads the same everywhere and after history is capped.
public struct RecapSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String { month }
    /// "2026-09".
    public let month: String
    public let minutes: Int
    public let plays: Int
    public let songs: Int
    public let topSongs: [Song]
    public let topArtists: [Artist]
    /// Top five, as shares of tagged plays. Untagged songs are left out.
    public let genres: [Genre]
    public let onRepeat: Repeat?
    public let find: Find?
    /// Songs first heard this month.
    public let newSongs: Int
    /// Plays per hour of the day, 0 to 23.
    public let playsByHour: [Int]
    /// Calendar weekday, 1 is Sunday.
    public let busiestWeekday: Int
    /// Plays of songs heard before this month, as a percentage.
    public let loyalPct: Int
    public let bestStreak: Int
    public let topDevice: String
    public let topDevicePct: Int
    /// The top five are also the first five on the month's Tape.
    public let tapeMatches: Bool
    /// Spotify's own ranking for about the four weeks to the month's end, without counts.
    /// Nil when the account doesn't add Spotify listening.
    public var spotifyTop: SpotifyTop? = nil
    /// The month's most played songs, Spotify's included, so the story's clips are
    /// songs you actually heard. Nil on months built before it existed.
    public var played: [Song]? = nil
    /// A top artist whose plays were mostly one song.
    public var hooked: Hooked? = nil
    /// The song played most late at night, see `lateHours`.
    public var lateNight: LateNight? = nil
    /// Jams and shares. Nil when the server couldn't say.
    public var social: Social? = nil

    public struct Hooked: Codable, Sendable, Hashable {
        public let artist: String
        public let song: Song
        /// The song's share of the artist's plays.
        public let pct: Int
    }

    public struct LateNight: Codable, Sendable, Hashable {
        public let song: Song
        public let plays: Int
    }

    /// As `recap_social` returns it.
    public struct Social: Codable, Sendable, Hashable {
        /// Jams you started that someone joined.
        public let hosted: Int
        public let joined: Int
        /// Songs sent in messages.
        public let shared: Int
        public var isEmpty: Bool { hosted + joined + shared == 0 }
    }

    public struct SpotifyTop: Codable, Sendable, Hashable {
        public let songs: [Song]
        public let artists: [Artist]
        public struct Song: Codable, Sendable, Hashable {
            public let title: String
            public let artist: String
            public let image: String?
        }
        public struct Artist: Codable, Sendable, Hashable {
            public let name: String
            public let image: String?
        }
    }

    public struct Song: Codable, Sendable, Hashable {
        public let trackID: UUID
        public let title: String
        public let artist: String
        public let plays: Int
    }

    public struct Artist: Codable, Sendable, Hashable {
        public let name: String
        public let minutes: Int
        public let songs: Int
        /// Places climbed since last month. Nil when it wasn't ranked then.
        public let move: Int?
    }

    public struct Genre: Codable, Sendable, Hashable {
        public let name: String
        public let share: Double
    }

    public struct Repeat: Codable, Sendable, Hashable {
        public let song: Song
        public let count: Int
        public let day: Date
    }

    public struct Find: Codable, Sendable, Hashable {
        public let song: Song
        public let firstPlayed: Date
    }

    /// Every song a slide names.
    public var featured: [Song] {
        topSongs + [onRepeat?.song, find?.song, hooked?.song, lateNight?.song].compactMap { $0 }
    }

    public var year: Int { Int(month.prefix(4)) ?? 0 }
    public var monthNumber: Int { Int(month.suffix(2)) ?? 1 }

    // MARK: - Demo

    /// A hand-crafted snapshot that triggers every slide, for showcasing the UI
    /// without any real listening data.
    public static var demo: RecapSnapshot {
        let id1  = UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!
        let id2  = UUID(uuidString: "A0000002-0000-0000-0000-000000000002")!
        let id3  = UUID(uuidString: "A0000003-0000-0000-0000-000000000003")!
        let id4  = UUID(uuidString: "A0000004-0000-0000-0000-000000000004")!
        let id5  = UUID(uuidString: "A0000005-0000-0000-0000-000000000005")!
        let id6  = UUID(uuidString: "A0000006-0000-0000-0000-000000000006")!
        let id7  = UUID(uuidString: "A0000007-0000-0000-0000-000000000007")!
        let id8  = UUID(uuidString: "A0000008-0000-0000-0000-000000000008")!
        let id9  = UUID(uuidString: "A0000009-0000-0000-0000-000000000009")!
        let id10 = UUID(uuidString: "A0000010-0000-0000-0000-000000000010")!
        let id11 = UUID(uuidString: "A0000011-0000-0000-0000-000000000011")!
        let id12 = UUID(uuidString: "A0000012-0000-0000-0000-000000000012")!
        let id13 = UUID(uuidString: "A0000013-0000-0000-0000-000000000013")!
        let id14 = UUID(uuidString: "A0000014-0000-0000-0000-000000000014")!
        let id15 = UUID(uuidString: "A0000015-0000-0000-0000-000000000015")!

        let topSongs: [Song] = [
            Song(trackID: id1, title: "Trojan Horse",       artist: "Dave, Central Cee",               plays: 93),
            Song(trackID: id2, title: "PRINCE OF THE SCENE", artist: "Nemzzz",                         plays: 71),
            Song(trackID: id3, title: "Like a G6",          artist: "Far East Movement, The Cataracs",  plays: 58),
            Song(trackID: id4, title: "Plot Twist",         artist: "Drake",                            plays: 47),
            Song(trackID: id5, title: "Revenge of Fargo",   artist: "Tory Lanez",                       plays: 41),
        ]

        let topArtists: [Artist] = [
            Artist(name: "Dave",          minutes: 387, songs: 16, move: 2),
            Artist(name: "Drake",         minutes: 314, songs: 12, move: 0),
            Artist(name: "Central Cee",   minutes: 246, songs: 9,  move: nil),
            Artist(name: "Tory Lanez",    minutes: 178, songs: 7,  move: -1),
            Artist(name: "Nemzzz",        minutes: 132, songs: 5,  move: nil),
        ]

        let genres: [Genre] = [
            Genre(name: "UK Rap",   share: 0.38),
            Genre(name: "Hip Hop",  share: 0.27),
            Genre(name: "R&B",      share: 0.16),
            Genre(name: "Drill",    share: 0.11),
            Genre(name: "Pop",      share: 0.08),
        ]

        let cal = Calendar.current
        let now = Date()

        // Night-owl curve: quiet mornings, picks up in the afternoon, peaks late
        let playsByHour = [
            18, 11, 5, 2, 1, 0, 1, 3,      //  0am– 7am
             8, 14, 19, 22, 26, 24, 21, 25, //  8am– 3pm
            33, 41, 48, 52, 57, 63, 71, 42  //  4pm–11pm
        ]

        let played: [Song] = topSongs + [
            Song(trackID: id6,  title: "Sprinter",          artist: "Dave, Central Cee",   plays: 36),
            Song(trackID: id7,  title: "Doja",              artist: "Central Cee",         plays: 33),
            Song(trackID: id8,  title: "Starlight",         artist: "Dave",                plays: 28),
            Song(trackID: id9,  title: "God's Plan",        artist: "Drake",               plays: 25),
            Song(trackID: id10, title: "The Colour Violet",  artist: "Tory Lanez",         plays: 22),
            Song(trackID: id11, title: "Passion Fruit",     artist: "Drake",               plays: 19),
            Song(trackID: id12, title: "Shutdown",          artist: "Skepta",              plays: 17),
            Song(trackID: id13, title: "Band4Band",         artist: "Central Cee, Lil Baby", plays: 15),
            Song(trackID: id14, title: "Body",              artist: "Tion Wayne, Russ Millions", plays: 13),
            Song(trackID: id15, title: "Hurtin' Me",        artist: "Stormzy, Jhus",       plays: 11),
        ]

        var snapshot = RecapSnapshot(
            month: RecapMath.key(year: cal.component(.year, from: now),
                                month: cal.component(.month, from: now)),
            minutes: 2_134,
            plays: 726,
            songs: 158,
            topSongs: topSongs,
            topArtists: topArtists,
            genres: genres,
            onRepeat: Repeat(
                song: topSongs[0], // Trojan Horse 17 times in one day
                count: 17,
                day: cal.date(byAdding: .day, value: -6, to: now) ?? now
            ),
            find: Find(
                song: topSongs[1], // PRINCE OF THE SCENE as the discovery
                firstPlayed: cal.date(byAdding: .day, value: -22, to: now) ?? now
            ),
            newSongs: 43,
            playsByHour: playsByHour,
            busiestWeekday: 7, // Saturday
            loyalPct: 61,
            bestStreak: 23,
            topDevice: "iPhone",
            topDevicePct: 72,
            tapeMatches: true,
            played: played,
            hooked: Hooked(
                artist: "Dave",      // Trojan Horse was 48% of all Dave plays
                song: topSongs[0],
                pct: 48
            ),
            lateNight: LateNight(
                song: topSongs[3], // Plot Twist after dark
                plays: 21
            )
        )

        snapshot.spotifyTop = SpotifyTop(
            songs: [
                .init(title: "God's Plan",          artist: "Drake",                          image: nil),
                .init(title: "Doja",                artist: "Central Cee",                    image: nil),
                .init(title: "Trojan Horse",        artist: "Dave, Central Cee",              image: nil),
                .init(title: "PRINCE OF THE SCENE", artist: "Nemzzz",                        image: nil),
                .init(title: "Sprinter",            artist: "Dave, Central Cee",              image: nil),
            ],
            artists: [
                .init(name: "Dave",        image: nil),
                .init(name: "Drake",       image: nil),
                .init(name: "Central Cee", image: nil),
                .init(name: "Tory Lanez",  image: nil),
                .init(name: "Nemzzz",      image: nil),
            ]
        )

        snapshot.social = Social(hosted: 5, joined: 11, shared: 18)

        return snapshot
    }

}

public enum RecapMath {

    public struct Play: Sendable {
        public let trackID: UUID
        public let playedAt: Date
        /// Zero when unknown; the song's duration stands in.
        public let seconds: TimeInterval
        public let deviceID: String

        public init(trackID: UUID, playedAt: Date, seconds: TimeInterval, deviceID: String) {
            self.trackID = trackID
            self.playedAt = playedAt
            self.seconds = seconds
            self.deviceID = deviceID
        }
    }

    /// What the maths needs to know about a song.
    public struct Meta: Sendable {
        public let title: String
        public let artist: String
        /// Everyone credited, so a feature counts for both artists.
        public let artists: [String]
        public let genre: String?
        public let duration: TimeInterval
        /// Monthly tapes only hold library songs.
        public let inLibrary: Bool

        public init(title: String, artist: String, artists: [String], genre: String?,
                    duration: TimeInterval, inLibrary: Bool) {
            self.title = title
            self.artist = artist
            self.artists = artists
            self.genre = genre
            self.duration = duration
            self.inLibrary = inLibrary
        }
    }

    /// Quieter months get no recap.
    public static let minimumPlays = 30

    public static func key(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// `plays` and `previous` are newest first, as history returns them.
    /// `knownBefore` is every song played before the month started.
    public static func build(key: String, plays: [Play], previous: [Play], knownBefore: Set<UUID>,
                             meta: (UUID) -> Meta?, deviceName: (String) -> String,
                             calendar: Calendar) -> RecapSnapshot? {
        guard plays.count >= minimumPlays else { return nil }
        // History has to reach the month's first week, or the app only saw its end.
        guard let first = (previous + plays).lazy.map(\.playedAt).min(),
              let start = calendar.date(from: DateComponents(year: Int(key.prefix(4)), month: Int(key.suffix(2)))),
              let cutoff = calendar.date(byAdding: .day, value: 7, to: start),
              first < cutoff else { return nil }
        var metas: [UUID: Meta] = [:]
        for id in Set((plays + previous).map(\.trackID)) { metas[id] = meta(id) }

        var count: [UUID: Int] = [:]
        for p in plays { count[p.trackID, default: 0] += 1 }
        func song(_ id: UUID) -> RecapSnapshot.Song? {
            metas[id].map { .init(trackID: id, title: $0.title, artist: $0.artist, plays: count[id] ?? 0) }
        }
        func seconds(_ p: Play) -> TimeInterval {
            p.seconds > 0 ? p.seconds : metas[p.trackID]?.duration ?? 0
        }

        let order = ListeningTrends.tapeOrder(plays.map(\.trackID))
        let topSongs = Array(order.lazy.compactMap(song).prefix(5))
        var played = Array(order.lazy.compactMap(song).prefix(40))
        let tapeFive = Array(order.lazy.filter { metas[$0]?.inLibrary == true }.prefix(5))

        let ranked = artistRanking(plays, metas: metas, seconds: seconds)
        let moves = ListeningTrends.moves(current: ranked.map(\.name),
                                          previous: artistRanking(previous, metas: metas, seconds: seconds).map(\.name))
        let topArtists = ranked.prefix(5).map { a -> RecapSnapshot.Artist in
            var move: Int?
            if case .moved(let n) = moves[a.name] { move = n }
            return .init(name: a.name, minutes: Int(a.seconds / 60), songs: a.songs, move: move)
        }
        // Every top artist gets their most played song, even one outside the top 40.
        for a in topArtists where !played.contains(where: { metas[$0.trackID]?.artists.contains(a.name) == true }) {
            if let s = order.first(where: { metas[$0]?.artists.contains(a.name) == true }).flatMap(song) { played.append(s) }
        }

        var genrePlays: [String: Int] = [:]
        for p in plays { if let g = metas[p.trackID]?.genre { genrePlays[g, default: 0] += 1 } }
        let tagged = Double(genrePlays.values.reduce(0, +))
        let genres = genrePlays.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(5).map { RecapSnapshot.Genre(name: $0.key, share: Double($0.value) / tagged) }

        struct DayPlay: Hashable { let id: UUID; let day: Date }
        var perDay: [DayPlay: Int] = [:]
        for p in plays { perDay[DayPlay(id: p.trackID, day: calendar.startOfDay(for: p.playedAt)), default: 0] += 1 }
        let onRepeat = perDay.filter { $0.value > 1 && metas[$0.key.id] != nil }
            .max { ($0.value, $0.key.day) < ($1.value, $1.key.day) }
            .flatMap { hit in song(hit.key.id).map { RecapSnapshot.Repeat(song: $0, count: hit.value, day: hit.key.day) } }

        let fresh = Set(count.keys).subtracting(knownBefore)
        let find = order.first { fresh.contains($0) && metas[$0] != nil }.flatMap { id in
            song(id).map { RecapSnapshot.Find(song: $0, firstPlayed: plays.last { $0.trackID == id }!.playedAt) }
        }

        var hours = Array(repeating: 0, count: 24)
        var weekdays: [Int: Int] = [:]
        var devices: [String: Int] = [:]
        for p in plays {
            let c = calendar.dateComponents([.hour, .weekday], from: p.playedAt)
            hours[c.hour!] += 1
            weekdays[c.weekday!, default: 0] += 1
            devices[p.deviceID, default: 0] += 1
        }
        var late: [UUID: Int] = [:]
        for p in plays where lateHours.contains(calendar.component(.hour, from: p.playedAt)) { late[p.trackID, default: 0] += 1 }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let lateNight = late.filter { $0.value >= 3 && metas[$0.key] != nil }
            .max { ($0.value, -(rank[$0.key] ?? .max)) < ($1.value, -(rank[$1.key] ?? .max)) }
            .flatMap { hit in song(hit.key).map { RecapSnapshot.LateNight(song: $0, plays: hit.value) } }

        let busiestDay = weekdays.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        let device = devices.max { ($0.value, $1.key) < ($1.value, $0.key) }!

        return RecapSnapshot(
            month: key,
            minutes: Int(plays.map(seconds).reduce(0, +) / 60),
            plays: plays.count,
            songs: count.count,
            topSongs: topSongs,
            topArtists: topArtists,
            genres: genres,
            onRepeat: onRepeat,
            find: find,
            newSongs: fresh.count,
            playsByHour: hours,
            busiestWeekday: busiestDay,
            loyalPct: percent(plays.filter { knownBefore.contains($0.trackID) }.count, of: plays.count),
            bestStreak: ListeningTrends.streaks(days: Set(plays.map(\.playedAt)), today: plays[0].playedAt,
                                                calendar: calendar).best,
            topDevice: deviceName(device.key),
            topDevicePct: percent(device.value, of: plays.count),
            tapeMatches: !topSongs.isEmpty && topSongs.map(\.trackID) == tapeFive,
            played: played,
            hooked: hooked(topArtists.prefix(3).map(\.name), plays: plays, order: order, metas: metas, song: song),
            lateNight: lateNight
        )
    }

    /// 9pm.
    static let lateStart = 21
    /// From `lateStart` to 4am.
    static let lateHours = Set(Array(lateStart..<24) + Array(0..<4))

    /// The first of `artists` with at least two songs and eight plays, where one song
    /// took 40% of them or more.
    private static func hooked(_ artists: [String], plays: [Play], order: [UUID], metas: [UUID: Meta],
                               song: (UUID) -> RecapSnapshot.Song?) -> RecapSnapshot.Hooked? {
        for name in artists {
            let theirs = plays.filter { metas[$0.trackID]?.artists.contains(name) == true }
            guard Set(theirs.map(\.trackID)).count >= 2, theirs.count >= 8,
                  let top = order.first(where: { metas[$0]?.artists.contains(name) == true }).flatMap(song) else { continue }
            let pct = percent(top.plays, of: theirs.count)
            if pct >= 40 { return .init(artist: name, song: top, pct: pct) }
        }
        return nil
    }

    /// Minutes per credited artist, most first, ties by name.
    private static func artistRanking(_ plays: [Play], metas: [UUID: Meta],
                                      seconds: (Play) -> TimeInterval) -> [(name: String, seconds: TimeInterval, songs: Int)] {
        var time: [String: TimeInterval] = [:]
        var songs: [String: Set<UUID>] = [:]
        for p in plays {
            for name in metas[p.trackID]?.artists ?? [] {
                time[name, default: 0] += seconds(p)
                songs[name, default: []].insert(p.trackID)
            }
        }
        return time.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { ($0.key, $0.value, songs[$0.key]?.count ?? 0) }
    }

    static func percent(_ part: Int, of whole: Int) -> Int {
        whole > 0 ? Int((Double(part) * 100 / Double(whole)).rounded()) : 0
    }

    // MARK: - Story clips

    /// A song the story can play.
    public struct ClipSong: Sendable, Equatable {
        public let id: UUID
        public let title: String
        public let artist: String
        public let genre: String?
        /// Already on disk, so it starts at once.
        public let ready: Bool

        public init(id: UUID, title: String, artist: String, genre: String?, ready: Bool = false) {
            self.id = id
            self.title = title
            self.artist = artist
            self.genre = genre
            self.ready = ready
        }
    }

    /// What a slide would like to play.
    public enum ClipWant: Sendable {
        /// This song, even if another slide has it.
        case song(UUID)
        case artist(String)
        case genre(String)
        /// Spotify's list, best placed first.
        case named([RecapSnapshot.SpotifyTop.Song])
        case any
        case silent
    }

    /// Songs for each slide, best first; the rest are backups for when it won't load.
    /// Slides about a song get it, the rest take `pool` in order, so nothing repeats
    /// until the pool runs out. Among equals a song already on disk wins.
    public static func clipPicks(_ wants: [ClipWant], pool: [ClipSong], backups: Int = 2) -> [[UUID]] {
        var picks = [UUID?](repeating: nil, count: wants.count)
        var used = Set<UUID>()
        func take(_ i: Int, _ match: (ClipSong) -> Bool) {
            guard picks[i] == nil else { return }
            let fresh = pool.filter { !used.contains($0.id) && match($0) }
            guard let s = fresh.first(where: \.ready) ?? fresh.first else { return }
            picks[i] = s.id
            used.insert(s.id)
        }
        for (i, want) in wants.enumerated() {
            if case .song(let id) = want, pool.contains(where: { $0.id == id }) {
                picks[i] = id
                used.insert(id)
            }
        }
        // Narrowest first: Spotify's list names songs, an artist has fewer to spare than a genre.
        for (i, want) in wants.enumerated() {
            guard case .named(let songs) = want else { continue }
            for song in songs where picks[i] == nil {
                guard let s = pool.first(where: { clipMatches(song, $0) }) else { continue }
                if !used.contains(s.id) { picks[i] = s.id; used.insert(s.id) }
            }
        }
        for (i, want) in wants.enumerated() {
            if case .artist(let name) = want { take(i) { $0.artist.localizedCaseInsensitiveContains(name) } }
        }
        // Their song again beats somebody else's.
        for (i, want) in wants.enumerated() where picks[i] == nil {
            if case .artist(let name) = want { picks[i] = pool.first { $0.artist.localizedCaseInsensitiveContains(name) }?.id }
        }
        for (i, want) in wants.enumerated() {
            if case .genre(let name) = want { take(i) { $0.genre?.caseInsensitiveCompare(name) == .orderedSame } }
        }
        for (i, want) in wants.enumerated() {
            if case .silent = want { continue }
            take(i) { _ in true }
        }
        // Out of fresh songs: reuse, but never the neighbour's.
        for (i, want) in wants.enumerated() where picks[i] == nil {
            if case .silent = want { continue }
            let near = [i > 0 ? picks[i - 1] : nil, i + 1 < picks.count ? picks[i + 1] : nil]
            picks[i] = (pool.first { !near.contains($0.id) } ?? pool.first)?.id
        }

        // Backups come from songs no slide picked: ones that fit the slide, then any ready one.
        let spare = pool.filter { !used.contains($0.id) }
        return wants.enumerated().map { i, want in
            guard let pick = picks[i] else { return [] }
            let fits: [ClipSong]
            switch want {
            case .artist(let name): fits = spare.filter { $0.artist.localizedCaseInsensitiveContains(name) }
            case .genre(let name):  fits = spare.filter { $0.genre?.caseInsensitiveCompare(name) == .orderedSame }
            case .named(let songs): fits = songs.compactMap { song in spare.first { clipMatches(song, $0) } }
            default:                fits = []
            }
            var out = [pick]
            for s in fits.filter(\.ready) + fits + spare.filter(\.ready) + spare
            where out.count <= backups && !out.contains(s.id) {
                out.append(s.id)
            }
            return out
        }
    }

    /// Spotify's spelling against the library's: same title, give or take a
    /// feature credit or a version, and the lead artist.
    public static func clipMatches(_ song: RecapSnapshot.SpotifyTop.Song, _ s: ClipSong) -> Bool {
        let theirs = fold(song.title), mine = fold(s.title)
        let lead = fold(song.artist.split(separator: ",").first.map(String.init) ?? song.artist)
        guard !mine.isEmpty, !lead.isEmpty, theirs.hasPrefix(mine), fold(s.artist).contains(lead) else { return false }
        // "Wow" isn't "Wowzers".
        return !(theirs.dropFirst(mine.count).first.map { $0.isLetter || $0.isNumber } ?? false)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Clock

    /// Which part of the day most plays landed in. 3am to 5am belongs to nobody.
    public enum ClockBlock: CaseIterable, Sendable {
        case nightOwl, earlyBird, nineToFive, afterWork

        public var title: String {
            switch self {
            case .nightOwl:   "Night owl"
            case .earlyBird:  "Early bird"
            case .nineToFive: "Nine to five"
            case .afterWork:  "After work"
            }
        }

        public var hours: [Int] {
            switch self {
            case .nightOwl:   [22, 23, 0, 1, 2]
            case .earlyBird:  Array(5..<9)
            case .nineToFive: Array(9..<17)
            case .afterWork:  Array(17..<22)
            }
        }

        public var span: String {
            switch self {
            case .nightOwl:   "between 10pm and 3am"
            case .earlyBird:  "between 5am and 9am"
            case .nineToFive: "between 9am and 5pm"
            case .afterWork:  "between 5pm and 10pm"
            }
        }
    }

    public static func clockBlock(_ playsByHour: [Int]) -> (block: ClockBlock, pct: Int) {
        let total = playsByHour.reduce(0, +)
        func plays(_ b: ClockBlock) -> Int { b.hours.reduce(0) { $0 + playsByHour[$1] } }
        let best = ClockBlock.allCases.max { plays($0) < plays($1) }!
        return (best, percent(plays(best), of: total))
    }
}
