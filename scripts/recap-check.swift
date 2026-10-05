// Checks the monthly recap maths against the real source files:
//
//   xcrun swiftc Mixtape/Core/Services/ListeningTrends.swift Mixtape/Core/Services/RecapMath.swift \
//       scripts/recap-check.swift -o /tmp/recapcheck && /tmp/recapcheck

import Foundation

@main
struct RecapCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }

        let a = UUID(), b = UUID(), c = UUID(), untagged = UUID(), gone = UUID()
        let meta: [UUID: RecapMath.Meta] = [
            a: .init(title: "A", artist: "X feat. Y", artists: ["X", "Y"], genre: "Pop", duration: 200, inLibrary: true),
            b: .init(title: "B", artist: "Y", artists: ["Y"], genre: "Rap", duration: 100, inLibrary: true),
            c: .init(title: "C", artist: "Z", artists: ["Z"], genre: "Pop", duration: 60, inLibrary: false),
            untagged: .init(title: "U", artist: "Z", artists: ["Z"], genre: nil, duration: 60, inLibrary: true),
        ]
        func play(_ id: UUID, _ date: Date, _ secs: TimeInterval = 0, _ dev: String = "mac") -> RecapMath.Play {
            .init(trackID: id, playedAt: date, seconds: secs, deviceID: dev)
        }

        // September: A 12 times on the 13th (a Sunday) at 23:00, B once a day on 1st to 10th
        // at 9am from the phone, C 5 times on the 20th, U 3 times, an unresolvable song twice.
        var plays: [RecapMath.Play] = []
        for _ in 0..<12 { plays.append(play(a, day(2026, 9, 13, 23))) }
        for d in 1...10 { plays.append(play(b, day(2026, 9, d, 9), 30, "phone")) }
        for _ in 0..<5 { plays.append(play(c, day(2026, 9, 20, 18))) }
        for d in 21...23 { plays.append(play(untagged, day(2026, 9, d, 1))) }
        plays.append(play(gone, day(2026, 9, 25))); plays.append(play(gone, day(2026, 9, 26)))
        plays.sort { $0.playedAt > $1.playedAt }
        assert(plays.count == 32)

        // August: Y was top, X unranked.
        let previous = [play(b, day(2026, 8, 5)), play(c, day(2026, 8, 6))]
        let names = ["mac": "MacBook", "phone": "iPhone"]
        let r = RecapMath.build(key: RecapMath.key(year: 2026, month: 9), plays: plays, previous: previous,
                                knownBefore: [b, c], meta: { meta[$0] }, deviceName: { names[$0] ?? "?" },
                                calendar: cal)!

        assert(r.month == "2026-09" && r.year == 2026 && r.monthNumber == 9)
        assert(r.plays == 32 && r.songs == 5)
        // 12x200 + 10x30 + 5x60 + 3x60 + 0 for the unknown song = 3180s.
        assert(r.minutes == 53, "\(r.minutes)")
        assert(r.topSongs.map(\.title) == ["A", "B", "C", "U"], "\(r.topSongs.map(\.title))")
        assert(r.topSongs[0].plays == 12)
        // What the story's clips draw from: every heard song with a name, most played first.
        assert(r.played?.map(\.title) == ["A", "B", "C", "U"], "\(String(describing: r.played))")
        // C isn't in the library, so the Tape's third song is U.
        assert(!r.tapeMatches)

        // A's features count for X and Y; Y also has B.
        assert(r.topArtists.map(\.name) == ["Y", "X", "Z"], "\(r.topArtists.map(\.name))")
        assert(r.topArtists[0].minutes == 45 && r.topArtists[0].songs == 2)
        assert(r.topArtists[0].move == 0, "Y held first: \(r.topArtists)")
        assert(r.topArtists[1].move == nil, "X is new")
        assert(r.topArtists[2].move == -1, "Z fell from 2nd to 3rd")

        // Pop 17, Rap 10 of 27 tagged plays; untagged and unknown left out.
        assert(r.genres.map(\.name) == ["Pop", "Rap"])
        assert(abs(r.genres[0].share - 17.0 / 27) < 0.0001)

        assert(r.onRepeat?.song.title == "A" && r.onRepeat?.count == 12)
        assert(r.onRepeat?.day == cal.startOfDay(for: day(2026, 9, 13)))
        // A and U are new; A has more plays. The unknown song counts as new but can't win.
        assert(r.find?.song.title == "A" && r.newSongs == 3, "\(String(describing: r.find)) \(r.newSongs)")
        assert(r.find?.firstPlayed == day(2026, 9, 13, 23))

        assert(r.playsByHour[23] == 12 && r.playsByHour[9] == 10 && r.playsByHour.reduce(0, +) == 32)
        assert(r.busiestWeekday == 1, "Sunday: \(r.busiestWeekday)")
        assert(r.loyalPct == RecapMath.percent(15, of: 32))
        assert(r.bestStreak == 10, "\(r.bestStreak)")
        assert(r.topDevice == "MacBook" && r.topDevicePct == 69, "\(r.topDevice) \(r.topDevicePct)")

        // 23:00 x12 + 01:00 x3 beats 9am x10.
        let clock = RecapMath.clockBlock(r.playsByHour)
        assert(clock.block == .nightOwl && clock.pct == 47, "\(clock)")

        // Y's 22 plays are A 12, B 10. A is also the late-night song, over U's three at 1am.
        assert(r.hooked == .init(artist: "Y", song: r.topSongs[0], pct: RecapMath.percent(12, of: 22)), "\(String(describing: r.hooked))")
        assert(r.lateNight?.song.title == "A" && r.lateNight?.plays == 12, "\(String(describing: r.lateNight))")

        // Round trip, so a cached or fetched snapshot reads back the same.
        let data = try! JSONEncoder().encode(r)
        assert(try! JSONDecoder().decode(RecapSnapshot.self, from: data) == r)
        // Snapshots saved before the newer fields still read.
        var old = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        for k in ["played", "hooked", "lateNight", "social"] { old[k] = nil }
        let o = try! JSONDecoder().decode(RecapSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        assert(o.hooked == nil && o.lateNight == nil && o.social == nil && o.plays == r.plays)

        // Too quiet for a recap.
        assert(RecapMath.build(key: "2026-09", plays: Array(plays.prefix(29)), previous: [], knownBefore: [],
                               meta: { meta[$0] }, deviceName: { $0 }, calendar: cal) == nil)

        // Recording only started near the end of the month.
        let late = plays.filter { $0.playedAt >= day(2026, 9, 9) }
        assert(RecapMath.build(key: "2026-09", plays: late + late.prefix(10), previous: [], knownBefore: [],
                               meta: { meta[$0] }, deviceName: { $0 }, calendar: cal) == nil)

        // Library-only top five match the Tape.
        let tapeOnly = plays.filter { $0.trackID != c }
        let t = RecapMath.build(key: "2026-09", plays: tapeOnly + tapeOnly.prefix(3), previous: [], knownBefore: [],
                                meta: { meta[$0] }, deviceName: { $0 }, calendar: cal)!
        assert(t.tapeMatches, "\(t.topSongs.map(\.title))")

        // Story clips: slides about a song keep it, the rest don't repeat until the pool runs out,
        // and a song already on disk goes first.
        let s = (0..<7).map { _ in UUID() }
        let pool: [RecapMath.ClipSong] = [
            .init(id: s[0], title: "One", artist: "X", genre: "Pop", ready: true),
            .init(id: s[1], title: "Two", artist: "Y", genre: "Rap"),
            .init(id: s[2], title: "Three", artist: "X feat. Y", genre: "Pop"),
            .init(id: s[3], title: "Four", artist: "Z", genre: "Rock"),
            .init(id: s[4], title: "Five", artist: "W", genre: nil, ready: true),
            .init(id: s[5], title: "Friends", artist: "Chase Atlantic", genre: nil),
            .init(id: s[6], title: "That\u{2019}s Not Me", artist: "Skepta", genre: nil),
        ]
        func spotify(_ title: String, _ artist: String) -> RecapSnapshot.SpotifyTop.Song {
            .init(title: title, artist: artist, image: nil)
        }
        let notMe = spotify("That's Not Me", "Skepta, Jme")
        let picks = RecapMath.clipPicks([.any, .genre("Pop"), .artist("X"), .song(s[1]), .named([notMe]),
                                         .song(s[0]), .song(s[0]), .any, .any, .silent], pool: pool)
        assert(picks.map(\.first) == [s[4], s[3], s[2], s[1], s[6], s[0], s[0], s[5], s[0], nil], "\(picks)")
        assert(RecapMath.clipPicks([.any, .any, .any], pool: Array(pool.prefix(1))) == [[s[0]], [s[0]], [s[0]]])
        assert(RecapMath.clipPicks([.any], pool: []) == [[]])

        // The artist slide gets another song by them when the top song is taken; Spotify's list
        // skips what you don't have. Backups are songs nobody picked.
        let c2 = (0..<4).map { _ in UUID() }
        let backups = RecapMath.clipPicks(
            [.artist("Chase Atlantic"), .named([notMe, spotify("Hawk Em", "Pop Smoke")]), .song(c2[0])],
            pool: [.init(id: c2[0], title: "Friends", artist: "Chase Atlantic", genre: nil),
                   .init(id: c2[1], title: "Swim", artist: "Chase Atlantic", genre: nil),
                   .init(id: c2[2], title: "Other", artist: "Q", genre: nil, ready: true),
                   .init(id: c2[3], title: "Hawk Em", artist: "Pop Smoke", genre: nil)])
        assert(backups == [[c2[1], c2[2]], [c2[3], c2[2]], [c2[0], c2[2]]], "\(backups)")

        // Their only song is taken, so the artist slide plays it again rather than someone else's.
        let only = (0..<2).map { _ in UUID() }
        assert(RecapMath.clipPicks([.song(only[0]), .artist("Chase Atlantic")],
                                   pool: [.init(id: only[1], title: "Other", artist: "Q", genre: nil, ready: true),
                                          .init(id: only[0], title: "Swim", artist: "Chase Atlantic", genre: nil)])
               .map(\.first) == [only[0], only[0]])

        // A backup already on disk beats one that still has to stream.
        let d = (0..<3).map { _ in UUID() }
        let dlmd = spotify("Don't Let Me Down - W&W Remix", "The Chainsmokers")
        assert(RecapMath.clipPicks([.named([notMe, dlmd, spotify("Hawk Em", "Pop Smoke")])],
                                   pool: [.init(id: d[0], title: "Hawk Em", artist: "Pop Smoke", genre: nil, ready: true),
                                          .init(id: d[1], title: notMe.title, artist: notMe.artist, genre: nil),
                                          .init(id: d[2], title: dlmd.title, artist: dlmd.artist, genre: nil)])
               == [[d[1], d[0], d[2]]])

        let friends = RecapMath.ClipSong(id: s[0], title: "Friends", artist: "Chase Atlantic", genre: nil)
        assert(RecapMath.clipMatches(spotify("Friends (feat. Q)", "Chase Atlantic, Q"), friends))
        assert(!RecapMath.clipMatches(spotify("Friendship", "Chase Atlantic"), friends))
        assert(!RecapMath.clipMatches(spotify("Friends", "Someone Else"), friends))

        print("recap-check: all passed")
    }
}
