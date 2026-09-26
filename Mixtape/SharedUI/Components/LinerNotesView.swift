// The liner notes under a playlist's songs, on the playlist page and the public page.

import SwiftUI

struct LinerNotesView: View {
    private let text: String
    private let songs: [Line]

    private struct Line: Identifiable {
        let id: Int
        let title: String
        let note: String
    }

    /// `songs` in running order, so the numbers match the list above.
    init(notes: PlaylistNotes, songs: [(id: UUID, title: String)]) {
        text = notes.text
        self.songs = songs.enumerated().compactMap { index, song in
            notes[song: song.id].map { Line(id: index + 1, title: song.title, note: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Liner Notes")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            if !text.isEmpty {
                Text(text)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
            }
            ForEach(songs) { song in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(song.id). \(song.title)")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                    Text(song.note)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
