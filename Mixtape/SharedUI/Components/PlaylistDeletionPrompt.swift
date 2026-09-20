// PlaylistDeletionPrompt.swift
// Mixtape — SharedUI/Components
//
// One wording for every way a playlist leaves the library.
//
// The sibling of `TrackDeletionPrompt`, and written for the same reason: there
// are five ways to delete a playlist (the detail page, the library swipe, the
// library context menu, the Mac grid, ⌘⌫) and three of them carried their own
// copy of the message. All three said "Your songs won't be affected", which is
// no longer true — deleting a playlist now takes the songs nothing else in the
// library is holding on to, and their downloads with them.
//
// So the message says how many, because "this also deletes 47 songs" and "this
// also deletes nothing" are different decisions, and the user is the only one
// who can tell which of the two they're making.

import SwiftUI

enum PlaylistDeletionPrompt {

    /// `isReadOnly` is a saved mix or someone else's playlist: removing it isn't
    /// destroying anything of the user's own, and the title shouldn't imply it.
    static func title(name: String, isReadOnly: Bool) -> String {
        isReadOnly ? "Remove \"\(name)\"?" : "Delete \"\(name)\"?"
    }

    static func confirmLabel(isReadOnly: Bool) -> String {
        isReadOnly ? "Remove from Library" : "Delete Playlist"
    }

    /// `songCount` is `LibraryService.songCountRemovedWithPlaylist(id:)` — the
    /// songs in it that aren't in another playlist and aren't favourited.
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
