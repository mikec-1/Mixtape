// Checks the playlist track merge against the real source file:
//
//   xcrun swiftc Mixtape/Data/Sync/TrackListMerge.swift scripts/track-merge-check.swift \
//       -o /tmp/mergecheck && /tmp/mergecheck

import Foundation

@main
struct TrackMergeCheck {
    static func main() {
        let ids = (0..<40).map { _ in UUID() }
        let three = Array(ids[0..<3]), latin = Array(ids[3..<28]), extra = ids[28]

        // The 10-02 incident: a stale phone copy (3 + 25 + 1) drops 8 ids the Mac removed,
        // while the server already holds the cleaned-up 3. Nothing comes back.
        let stale = three + latin + [extra] + Array(ids[30..<38])
        let pruned = three + latin + [extra]
        assert(mergeTrackIDs(base: stale, local: pruned, server: three) == three)

        // Unchanged server: local wins as is, reorders included.
        assert(mergeTrackIDs(base: three, local: three.reversed(), server: three) == three.reversed())

        // Both sides changed: server removal kept, local add appended once.
        let server = [ids[0], ids[2], ids[39]]
        let local = three + [ids[38]]
        assert(mergeTrackIDs(base: three, local: local, server: server) == [ids[0], ids[2], ids[39], ids[38]])

        // Local removal of a song the server still has.
        assert(mergeTrackIDs(base: three, local: [ids[0]], server: three + [ids[39]]) == [ids[0], ids[39]])

        // Same song added on both sides isn't doubled.
        assert(mergeTrackIDs(base: three, local: three + [ids[39]], server: three + [ids[39]]) == three + [ids[39]])

        print("track merge: ok")
    }
}
