// Checks the playlist sides rules against the real model:
//
//   xcrun swiftc Mixtape/Core/Models/Playlist.swift \
//       scripts/playlist-sides-check.swift -o /tmp/sidescheck && /tmp/sidescheck

import Foundation

// The real one pulls in half the app. Playlist only needs these two.
public struct SyncMetadata: Codable, Hashable, Sendable {
    init(deviceID: String) {}
    mutating func markModified() {}
}

@main
struct PlaylistSidesCheck {
    static func main() {
        let ids = (0..<6).map { _ in UUID() }
        var p = Playlist(name: "Tape", trackIDs: ids, sync: SyncMetadata(deviceID: "check"))

        // The first song and a missing song never start a side.
        p.startSide(at: ids[0])
        p.startSide(at: UUID())
        assert(p.sides.isEmpty && p.sideLayout.isEmpty)

        p.startSide(at: ids[3])
        assert(p.sideLayout.map(\.offset) == [0, 3], "A at the top, B at the fourth song")
        assert(p.sideNumbers()[ids[2]] == 0 && p.sideNumbers()[ids[3]] == 1)
        p.startSide(at: ids[3])
        assert(p.sides.count == 2, "starting a side twice is a no-op")

        p.renameSide(startingAt: nil, to: "  Morning ")
        assert(p.sides[0].name == "Morning")

        // Removing B's first song moves B onto the next one.
        p.removeTracks([ids[3]])
        assert(p.sides[1].start == ids[4])
        assert(p.sideLayout.map(\.offset) == [0, 3])

        // Removing everything after the break drops B, and a lone side is none.
        p.removeTracks([ids[4], ids[5]])
        assert(p.sides.isEmpty, "a lone side means none")

        // A side whose next surviving song already starts one folds into it.
        var q = Playlist(name: "Tape", trackIDs: ids, sync: SyncMetadata(deviceID: "check"))
        q.startSide(at: ids[2])
        q.startSide(at: ids[3])
        q.startSide(at: ids[5])
        q.removeTracks([ids[2]])
        assert(q.sideLayout.map(\.offset) == [0, 2, 4], "B folded into C's start, not doubled")

        // Web edits track_ids without knowing about sides: breaks follow their songs.
        var r = Playlist(name: "Tape", trackIDs: ids, sync: SyncMetadata(deviceID: "check"))
        r.startSide(at: ids[4])
        r.trackIDs = [ids[4], ids[0], ids[1], ids[2], ids[3], ids[5]]
        assert(r.sideLayout.isEmpty, "a break moved to the top is Side A, so no sides")
        r.trackIDs = [ids[0], ids[4], ids[1]]
        assert(r.sideLayout.map(\.offset) == [0, 1])

        r.removeSide(startingAt: ids[4])
        assert(r.sides.isEmpty)

        // Sides past Z get numbers.
        assert(PlaylistSide.letter(0) == "A" && PlaylistSide.letter(25) == "Z" && PlaylistSide.letter(26) == "27")

        print("playlist-sides-check: ok")
    }
}
