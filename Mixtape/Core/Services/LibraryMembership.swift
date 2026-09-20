// LibraryMembership.swift
// Mixtape — Core/Services
//
// The one-shot split that moves an existing library onto the derived rule, as
// set algebra, away from the repositories that supply the sets.
//
// Having a row used to mean being in the library. It doesn't any more — four
// things hold a song (a like, a playlist, a saved album, or being one of the
// user's own files, see `LibraryService.heldTrackIDs`) and All Songs is derived
// from that. So every existing row held by none of them has to be read as one
// of two opposite intentions:
//
//   · saved from Discover — the user meant to keep it, so it becomes a like;
//   · left behind by a playlist they deleted — they meant to be rid of it.
//
// The tombstones tell the two apart, which is the only reason they are kept.
// It lives here, out of the way of the store, because it is the one step in
// this change that can delete a song the user wanted, and a set expression that
// can do that is worth being able to run on its own.

import Foundation

public enum LibraryMembership {

    /// A row this migration has to make a decision about.
    public struct Row {
        public let id: UUID
        /// Metadata-only rows are the ones a like holds. A file holds itself.
        public let isOnline: Bool
        public init(id: UUID, isOnline: Bool) {
            self.id = id
            self.isOnline = isOnline
        }
    }

    /// Splits the rows nothing holds into the ones to collect and the ones to
    /// like. Disjoint by construction: a song stranded by a deleted playlist is
    /// never also rescued, whichever order the caller runs them in.
    public static func migration(
        rows: [Row],
        held: Set<UUID>,
        /// Track ids named by playlists that were deleted — the tombstones.
        strandedByDeletedPlaylists: Set<UUID>
    ) -> (delete: [UUID], like: [UUID]) {
        let unheld = rows.filter { !held.contains($0.id) }
        let delete = unheld.filter { strandedByDeletedPlaylists.contains($0.id) }.map(\.id)
        let doomed = Set(delete)
        // Files are already held, so anything left here is online — but it is
        // said rather than assumed, because liking an import is exactly the
        // mess this migration must not make.
        let like = unheld.filter { $0.isOnline && !doomed.contains($0.id) }.map(\.id)
        return (delete, like)
    }
}
