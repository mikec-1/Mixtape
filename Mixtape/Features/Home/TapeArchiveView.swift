// Every monthly tape, grouped by year: the Year in Tapes. Twelve tapes are the year,
// so it's an archive you can open in March, not a December event.

import SwiftUI

struct TapeArchiveView: View {

    let service: SmartPlaylistService
    /// Called with the tape the user picked. The host opens it after the sheet is gone.
    let onOpen: (SmartPlaylist) -> Void

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @Environment(\.dismiss) private var dismiss

    typealias Tape = (playlist: SmartPlaylist, tracks: [Track])
    /// Resolved in `.task`, newest year first, months oldest first inside it.
    @State private var years: [(year: Int, tapes: [Tape])] = []

    var body: some View {
        MixSheet(title: "Your Tapes",
                 subtitle: "Your top \(SmartPlaylistRule.tapeLength) of every month.",
                 size: .large) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(years, id: \.year) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        header(group.year, tapes: group.tapes)
                        ForEach(group.tapes, id: \.playlist.id) { row($0) }
                    }
                }
            }
        }
        .task {
            let history = PlayHistoryRepository()
            // `playlists` is by creation date, and a tape is created at its month's start.
            let tapes: [Tape] = service.playlists.compactMap { playlist in
                guard playlist.rule.tapeStart != nil else { return nil }
                let tracks = service.resolve(playlist, using: library, history: history)
                return tracks.isEmpty ? nil : (playlist, tracks)
            }
            let byYear = Dictionary(grouping: tapes) {
                Calendar.current.component(.year, from: $0.playlist.rule.tapeStart!)
            }
            years = byYear.keys.sorted(by: >).map { ($0, byYear[$0]!) }
        }
    }

    /// "2026" and a button that plays the year: its tapes back to back, each song once.
    private func header(_ year: Int, tapes: [Tape]) -> some View {
        HStack {
            Text(String(year))
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Spacer()
            MixPillButton(title: "Play \(year)", systemImage: "play.fill") {
                Haptics.play(.light)
                var seen = Set<UUID>()
                let tracks = tapes.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
                guard let first = tracks.first else { return }
                Task { await engine.play(track: first, in: tracks,
                                         source: .named("\(year) in Tapes")) }
            }
        }
    }

    private func row(_ tape: Tape) -> some View {
        Button {
            Haptics.play(.light)
            onOpen(tape.playlist)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SmartPlaylistCover(playlist: tape.playlist, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tape.playlist.name)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("\(tape.tracks.count) song\(tape.tracks.count == 1 ? "" : "s")")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}
