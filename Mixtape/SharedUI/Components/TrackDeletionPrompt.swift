// TrackDeletionPrompt.swift
// Mixtape — SharedUI/Components
//
// One wording, and one confirmation, for every way a song leaves the library.
//
// There is only one destructive operation behind all of them —
// `LibraryService.deleteTrack(id:)`, which tombstones the track, syncs that
// tombstone to every signed-in device and removes the local audio. But each
// entry point used to describe it differently: ⌘⌫ said "permanently … on all
// devices", the table's right-click menu said "deleted from this device"
// (wrong — the delete follows the account), and the playlist row's menu said
// nothing at all and just did it. Same button, three different promises.
//
// AppKit can't present a SwiftUI dialog, so `NativeTrackTable` still runs its
// own `NSAlert` — but it takes its strings from here, so the promise matches.

import SwiftUI

enum TrackDeletionPrompt {

    static func title(count: Int, name: String? = nil) -> String {
        if count == 1, let name { return "Delete \"\(name)\"?" }
        return count == 1 ? "Delete Song" : "Delete \(count) Songs"
    }

    /// Says "on all devices" because that is what happens. A user who thinks
    /// they're tidying up one Mac and finds the song gone from their phone has
    /// been told the wrong thing.
    static func message(count: Int) -> String {
        count == 1
            ? "This will permanently remove the song from your library on all devices."
            : "This will permanently remove \(count) songs from your library on all devices."
    }

    static func confirmLabel(count: Int) -> String {
        count == 1 ? "Delete Song" : "Delete \(count) Songs"
    }
}

extension View {

    /// Confirms deleting the songs held in `tracks`, then clears them either way.
    ///
    /// Driven by the songs themselves rather than a bool so the prompt can say
    /// what it is about — a context menu opens on a row that may not be in the
    /// selection, and "Delete Song" alone doesn't say which. A single song is
    /// named; a selection is counted.
    func confirmsTrackDeletion(_ tracks: Binding<[Track]>,
                               perform delete: @escaping ([Track]) -> Void) -> some View {
        let pending = tracks.wrappedValue
        return confirmationDialog(
            TrackDeletionPrompt.title(count: pending.count,
                                      name: pending.count == 1 ? pending.first?.title : nil),
            isPresented: Binding(get: { !tracks.wrappedValue.isEmpty },
                                 set: { if !$0 { tracks.wrappedValue = [] } }),
            titleVisibility: .visible
        ) {
            Button(TrackDeletionPrompt.confirmLabel(count: pending.count), role: .destructive) {
                delete(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TrackDeletionPrompt.message(count: pending.count))
        }
    }
}
