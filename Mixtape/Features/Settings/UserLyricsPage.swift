// The songs whose lyrics the user wrote. Each row opens the editor, which has Remove,
// so there's no delete on the rows.
// The store's filenames hash title|artist (see `UserLyricsStore`), so entries are found
// by re-hashing the library. Normalisation folds "Song", "Song (Live)" and "Song (feat. X)"
// onto one key, and the row says when a set covers several songs. Lyrics whose song was
// deleted are listed at the end as a count and a delete.

import SwiftUI

struct UserLyricsPage: View {

    @Environment(AppDependencies.self) private var deps
    private var store: UserLyricsStore { .shared }
    let onBack: () -> Void

    /// Built on appear and after changes, not in body: it hashes the whole library.
    @State private var entries: [UserLyricsStore.Entry] = []
    @State private var editing: Track?
    @State private var confirmRemoveOrphans = false

    private var named: [UserLyricsStore.Entry] { entries.filter { !$0.isOrphaned } }
    private var orphans: [UserLyricsStore.Entry] { entries.filter(\.isOrphaned) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                    if !named.isEmpty {
                        SettingsGroup(footer: "Choose a song to read or change what you wrote. Your words are always shown instead of any lyrics found online.") {
                            ForEach(named) { entry in
                                if let track = entry.track {
                                    row(for: entry, track: track)
                                }
                            }
                        }
                    }

                    if !orphans.isEmpty { orphanGroup }
                }
                .frame(maxWidth: SettingsMetrics.pageMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mixBackground)
        .onAppear(perform: reload)
        // The editor writes straight to the store, so rebuild on the way out.
        .sheet(item: $editing, onDismiss: reload) { track in
            LyricsEditorSheet(track: track)
                .environment(deps)
        }
        .alert("Remove these lyrics?", isPresented: $confirmRemoveOrphans) {
            Button("Remove", role: .destructive) {
                for entry in orphans { store.remove(key: entry.key) }
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The songs they belong to aren't in your library any more, so nothing can show them. This can't be undone.")
        }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Storage")
                        .font(.mixLabel)
                }
                .foregroundStyle(Color.mixTextSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()

            VStack(alignment: .leading, spacing: 4) {
                Text("Your Lyrics")
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                Text(subtitle)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    // Bounded, like the push page's. See `mixtape-fixedsize-splitview-balloon`.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let songs = named.count
        guard songs > 0 else {
            return "Lyrics you added yourself, for songs that aren't in your library any more."
        }
        return "\(songs) song\(songs == 1 ? "" : "s") you wrote the lyrics for yourself."
    }

    // MARK: Rows

    /// The song and a way into its lyrics. Removal happens in `LyricsEditorSheet`, with the text on screen.
    private func row(for entry: UserLyricsStore.Entry, track: Track) -> some View {
        SettingsButtonRow(title: track.title,
                          subtitle: rowSubtitle(for: entry, track: track),
                          icon: "text.quote",
                          role: .plain,
                          showsChevron: true) {
            editing = track
        }
    }

    /// Artist, last saved, and how many songs share this set when it's more than one.
    private func rowSubtitle(for entry: UserLyricsStore.Entry, track: Track) -> String {
        var parts = [track.artistName]
        if let modified = entry.modified {
            // Same wording as the Date added column.
            parts.append(AddedDateText.relative(modified))
        }
        if entry.tracks.count > 1 {
            parts.append("Used by \(entry.tracks.count) versions")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    private var orphanGroup: some View {
        SettingsGroup(title: "No Longer in Your Library",
                      footer: "The songs these belong to were deleted. Mixtape can't tell you which songs they were — nothing is stored but the lyrics themselves — and nothing can show them again. They're kept in case you import those songs back.") {
            SettingsRow(title: "\(orphans.count) set\(orphans.count == 1 ? "" : "s") of lyrics",
                        subtitle: "For songs that aren't here any more",
                        icon: "questionmark.circle") {
                SettingsValue(text: SettingsStorageReport.format(orphans.reduce(into: Int64(0)) { $0 += $1.bytes }))
            }

            SettingsButtonRow(title: "Remove Them",
                              icon: "trash",
                              role: .destructive) {
                confirmRemoveOrphans = true
            }
        }
    }

    // MARK: Loading

    private func reload() {
        // Deleted songs excluded. Watched-folder songs included: they play, so they can have lyrics.
        let songs = deps.libraryService.tracks.filter { !$0.isDeleted }
                  + deps.localFiles.tracks
        entries = store.entries(in: songs)
        // Nothing left: go back, since the Storage row disappears too.
        if entries.isEmpty { onBack() }
    }
}
