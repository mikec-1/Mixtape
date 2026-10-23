// Writing a playlist's liner notes: a few words on the whole thing and on any of its songs.

import SwiftUI

struct LinerNotesSheet: View {
    let playlist: Playlist
    let tracks: [Track]

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var notes = PlaylistNotes()

    var body: some View {
        MixSheet(title: "Liner Notes",
                 subtitle: "A few words on the playlist and its songs. They go with it when you share it.",
                 size: .large,
                 primary: MixSheetAction("Save", action: save)) {
            VStack(alignment: .leading, spacing: 16) {
                TextField("About this playlist", text: $notes.text, axis: .vertical)
                    .lineLimit(3...10)
                    .mixSheetField()
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(track.displayTitle)")
                                .font(.mixLabel)
                                .foregroundStyle(Color.mixTextSecondary)
                                .lineLimit(1)
                            TextField("Add a note", text: songNote(track.id), axis: .vertical)
                                .lineLimit(1...4)
                                .mixSheetField()
                        }
                    }
                }
            }
        }
        .task { notes = playlist.notes }
        .onChange(of: notes.text) { _, v in if v.count > 2000 { notes.text = String(v.prefix(2000)) } }
    }

    private func songNote(_ id: UUID) -> Binding<String> {
        Binding(
            get: { notes[song: id] ?? "" },
            set: { notes[song: id] = String($0.prefix(280)) }
        )
    }

    private func save() {
        var tidy = PlaylistNotes()
        tidy.text = notes.text.trimmingCharacters(in: .whitespacesAndNewlines)
        tidy.songs = notes.songs
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        if tidy != playlist.notes {
            deps.libraryService.setNotes(tidy, ofPlaylist: playlist.id)
        }
        dismiss()
    }
}
