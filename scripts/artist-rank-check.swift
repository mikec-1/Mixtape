// artist-rank-check.swift
// Mixtape — scripts
//
// The one check on the "your #3 artist this year" maths. No test target, so this
// compiles standalone against the real source file:
//
//   xcrun swiftc Mixtape/Core/Services/ArtistRanking.swift \
//       scripts/artist-rank-check.swift -o /tmp/rankcheck && /tmp/rankcheck

@main
struct ArtistRankCheck {
    static func main() {
        // "Digga" and "Digga D" are one artist: 30 + 10 plays, second behind Drake.
        let plays = ["drake": 50, "digga d": 30, "digga": 10, "skepta": 5]
        let digga = ArtistRanking.place(of: ["digga d", "digga"], in: plays)
        assert(digga?.plays == 40, "spellings must sum")
        assert(digga?.rank == 2, "an artist's own spellings can't rank them below themselves")

        assert(ArtistRanking.place(of: ["drake"], in: plays)?.rank == 1)
        assert(ArtistRanking.place(of: ["skepta"], in: plays)?.rank == 4)
        assert(ArtistRanking.place(of: ["nobody"], in: plays) == nil, "never played is nil")
        assert(ArtistRanking.place(of: [], in: plays) == nil)

        // Equal totals share a place.
        let tied = ["a": 10, "b": 10, "c": 20]
        assert(ArtistRanking.place(of: ["a"], in: tied)?.rank == 2)
        assert(ArtistRanking.place(of: ["b"], in: tied)?.rank == 2)

        print("artist-rank-check: ok")
    }
}
