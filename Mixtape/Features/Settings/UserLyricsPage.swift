// UserLyricsPage.swift
// Mixtape — Features/Settings
//
// The songs whose lyrics the user wrote themselves.
//
// Storage used to report this as a number: "Your Lyrics — 3 songs", a size, and
// a button that deleted all three. A count is the one thing nobody needs to be
// told; anyone who typed those lyrics knows roughly how many they typed. What
// they can't do from a count is go back to the one they got wrong — and lyrics
// are typed in a hurry, from memory, against a song that's still playing, so
// getting one wrong is the ordinary case rather than the rare one.
//
// So the row opens a list, and every song on it opens the same editor that
// wrote it. That editor already offers Remove, which is why there is no delete
// control on the rows themselves: the decision to throw away something you typed
// should be made with the text in front of you, not from a list of titles.
//
// The awkward part is that the store can't name its own contents. Its filenames
// are a one-way hash of title and artist (see `UserLyricsStore`), so the only
// way to label these is to re-derive the key for every song in the library and
// see which ones land on a file. Two consequences show up on this page:
//
//   · Normalisation folds "Song", "Song (Live)" and "Song (feat. X)" onto one
//     key, so a single stored set can belong to several rows in the library.
//     The row says so, because those rows all show the same lyrics and all lose
//     them together.
//
//   · Delete the song and the lyrics stay behind, with nothing left to name
//     them by. Those are listed at the end as a count and a delete, which is
//     everything that can honestly be said about them.

import SwiftUI

struct UserLyricsPage: View {

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var store = UserLyricsStore.shared
    let onBack: () -> Void

    /// Built once on appear and after every change, rather than per body pass:
    /// it hashes the whole library, and the body runs on hover.
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
        // The editor writes straight to the store, so the list is rebuilt on the
        // way out — a set removed in there has to leave this page with it.
        .sheet(item: $editing, onDismiss: reload) { track in
            LyricsEditorSheet(track: track)
                .environmentObject(deps)
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
                    // Bounded for the same reason as the push page's: an
                    // unbounded vertical `fixedSize` measured against the narrow
                    // settings column locks in a minimum height taller than the
                    // window. See `mixtape-fixedsize-splitview-balloon`.
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

    /// A row is one thing: the song, and a way into what was written for it.
    ///
    /// No inline delete. `LyricsEditorSheet` already has a Remove button, and it
    /// is one tap further into the same journey — with the text on screen, which
    /// is where anyone should be standing when they decide to throw it away. A
    /// second remove control here would only be quicker at the one thing that
    /// can't be undone.
    private func row(for entry: UserLyricsStore.Entry, track: Track) -> some View {
        SettingsButtonRow(title: track.title,
                          subtitle: rowSubtitle(for: entry, track: track),
                          icon: "text.quote",
                          role: .plain,
                          showsChevron: true) {
            editing = track
        }
    }

    /// Artist, when the lyrics were last saved, and — when one stored set covers
    /// more than one row in the library — how many songs the minus above would
    /// take them off. That last part is the whole reason it's spelled out: the
    /// row names one song and quietly speaks for several.
    private func rowSubtitle(for entry: UserLyricsStore.Entry, track: Track) -> String {
        var parts = [track.artistName]
        if let modified = entry.modified {
            // The same vocabulary as the Date added column, and no verb: on a
            // page of lyrics the user typed, there is only one thing a date on
            // the row could be the date of.
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
        // Deleted rows are excluded on purpose — a tombstoned song is one the
        // user has already thrown away, and naming a row after it would be an
        // orphan wearing a title. Watched-folder songs are included: they never
        // enter the library, but they play, so they can have lyrics.
        let songs = deps.libraryService.tracks.filter { !$0.isDeleted }
                  + deps.localFiles.tracks
        entries = store.entries(in: songs)
        // Nothing left to list: the group in Storage disappears with it, so
        // staying here would leave the user on a page about nothing, with a
        // back button to a pane that no longer mentions it.
        if entries.isEmpty { onBack() }
    }
}
