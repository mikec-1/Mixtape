// The maths behind "your #3 artist this year". Split out from ListeningStatsService
// so it can be checked without the model layer — see scripts/artist-rank-check.swift.

import Foundation

enum ArtistRanking {

    /// How often the artist spelled any of `spellings` was played, and their 1-based
    /// place among `plays` (folded artist name -> plays). Nil when never played.
    ///
    /// Equal totals share a place: only strictly busier artists are counted ahead.
    static func place(of spellings: Set<String>, in plays: [String: Int]) -> (plays: Int, rank: Int)? {
        // Every spelling is the same artist, so they sum — and none of them counts
        // as a rival, or an artist with two spellings would rank below themselves.
        let mine = spellings.reduce(0) { $0 + (plays[$1] ?? 0) }
        guard mine > 0 else { return nil }
        // ponytail: other artists' alias groups stay split, so a rank can read a place
        // or two low. Merging them all would mean reading the whole alias map per pass.
        let ahead = plays.filter { !spellings.contains($0.key) && $0.value > mine }.count
        return (mine, ahead + 1)
    }
}
