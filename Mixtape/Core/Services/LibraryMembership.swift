// One-time split moving an existing library onto derived membership.
// A song is held by a like, a playlist, a saved album or being the user's own
// file. Unheld rows are either Discover saves (become likes) or leftovers from a
// deleted playlist (collected). The tombstones tell them apart.

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

    /// Splits unheld rows into ones to collect and ones to like. Never both.
    public static func migration(
        rows: [Row],
        held: Set<UUID>,
        /// Track ids from deleted playlists' tombstones.
        strandedByDeletedPlaylists: Set<UUID>
    ) -> (delete: [UUID], like: [UUID]) {
        let unheld = rows.filter { !held.contains($0.id) }
        let delete = unheld.filter { strandedByDeletedPlaylists.contains($0.id) }.map(\.id)
        let doomed = Set(delete)
        // Files are already held, but check isOnline so an import is never liked.
        let like = unheld.filter { $0.isOnline && !doomed.contains($0.id) }.map(\.id)
        return (delete, like)
    }
}
