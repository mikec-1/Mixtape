// Shared wording for deleting a playlist (detail page, swipe, context menu,
// Mac grid, ⌘⌫). Deleting takes songs nothing else holds, so the message
// says how many.

import SwiftUI

enum PlaylistDeletionPrompt {

    /// Saved mixes and others' playlists are removed, not deleted.
    static func title(name: String, isReadOnly: Bool) -> String {
        isReadOnly ? "Remove \"\(name)\"?" : "Delete \"\(name)\"?"
    }

    static func confirmLabel(isReadOnly: Bool) -> String {
        isReadOnly ? "Remove from Library" : "Delete Playlist"
    }

    /// `songCount` from `LibraryService.songCountRemovedWithPlaylist(id:)`.
    static func message(songCount: Int, isReadOnly: Bool) -> String {
        let opening = isReadOnly
            ? "This takes it out of your library."
            : "This deletes the playlist."

        guard songCount > 0 else {
            return "\(opening) Every song in it is in another playlist or in your Liked Songs, so none of them will be removed."
        }

        let songs = songCount == 1 ? "1 song" : "\(songCount) songs"
        return "\(opening) \(songs) will be removed from your library on all devices, along with any downloads — everything else in it is in another playlist or in your Liked Songs."
    }
}
