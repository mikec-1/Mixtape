// Shared wording and confirmation for deleting songs. The one operation is
// `LibraryService.deleteTrack(id:)`: tombstone, sync to every device, remove
// local audio. `NativeTrackTable` runs its own `NSAlert` but uses these strings.

import SwiftUI

enum TrackDeletionPrompt {

    static func title(count: Int, name: String? = nil) -> String {
        if count == 1, let name { return "Delete \"\(name)\"?" }
        return count == 1 ? "Delete Song" : "Delete \(count) Songs"
    }

    /// Deletes follow the account, so say "on all devices".
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

    /// Confirms deleting `tracks`, then clears them. One song is named, a
    /// selection is counted.
    func confirmsTrackDeletion(_ tracks: Binding<[Track]>,
                               perform delete: @escaping ([Track]) -> Void) -> some View {
        let pending = tracks.wrappedValue
        return mixConfirmationDialog(
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
