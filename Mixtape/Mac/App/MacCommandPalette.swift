// MacCommandPalette.swift
// Mixtape — Mac/App
//
// ⌘K: one field that reaches everything — sections, playback commands, and any
// song, album, artist or playlist in the library — without touching the mouse.
//
// It is deliberately *not* the toolbar search field. The toolbar field filters
// the section you're looking at; the palette navigates and acts, and closes as
// soon as it has done so.
//
// Keyboard contract: type to filter, ↑/↓ to move, Return to run, Esc to close.
// The text field keeps focus the whole time, so arrow keys are intercepted there
// rather than moving focus between rows.

#if os(macOS)
import SwiftUI

struct MacCommandPalette: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @Environment(\.mixChrome) private var chrome

    @ObservedObject private var meta = PlaylistMetadataService.shared

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    /// Each section is capped so a large library can't push the commands off
    /// screen — the palette is for jumping, not for browsing.
    private let perSectionLimit = 6

    // MARK: - Items

    private var commands: [PaletteItem] {
        var out: [PaletteItem] = []

        for item in MacSidebarItem.allCases {
            out.append(PaletteItem(
                kind: .command,
                title: "Go to \(item.title)",
                subtitle: "Navigate",
                icon: item.systemImage
            ) {
                appState.selection        = item
                appState.selectedAlbum    = nil
                appState.selectedPlaylist = nil
            })
        }

        if engine.state.isActive {
            out.append(PaletteItem(
                kind: .command,
                title: engine.state.isPlaying ? "Pause" : "Play",
                subtitle: "Playback",
                icon: engine.state.isPlaying ? "pause.fill" : "play.fill"
            ) { engine.togglePlayPause() })

            out.append(PaletteItem(kind: .command, title: "Next Track",
                                   subtitle: "Playback", icon: "forward.fill") {
                Task { await engine.playNext() }
            })
            out.append(PaletteItem(kind: .command, title: "Previous Track",
                                   subtitle: "Playback", icon: "backward.fill") {
                Task { await engine.playPrevious() }
            })
        }

        out.append(PaletteItem(
            kind: .command,
            title: engine.queue.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
            subtitle: "Playback",
            icon: "shuffle"
        ) { engine.queue.toggleShuffle() })

        return out
    }

    private var songs: [PaletteItem] {
        matching(library.displayTracks) {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artistName.localizedCaseInsensitiveContains(query)
        }.map { track in
            PaletteItem(kind: .song, title: track.title,
                        subtitle: track.artistName, icon: "music.note",
                        artwork: track.displayArtwork) {
                // Just this song: picking one out of the palette is a request
                // for it, not for the library in stored order behind it — and a
                // one-song context is what lets the suggestions follow it.
                Task { await engine.play(track: track, in: [track], source: .named("Search results")) }
            }
        }
    }

    private var albums: [PaletteItem] {
        matching(library.albums) {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artistName.localizedCaseInsensitiveContains(query)
        }.map { album in
            PaletteItem(kind: .album, title: album.title,
                        subtitle: album.artistName, icon: "square.stack",
                        artwork: album.displayArtwork) {
                appState.showAlbum(album)
            }
        }
    }

    private var artists: [PaletteItem] {
        matching(library.artists) {
            $0.name.localizedCaseInsensitiveContains(query)
        }.map { artist in
            PaletteItem(kind: .artist, title: artist.name,
                        subtitle: "Artist", icon: "music.mic",
                        artwork: artist.displayArtwork, circular: true) {
                appState.showArtist(artist)
            }
        }
    }

    private var playlists: [PaletteItem] {
        matching(library.playlists.filter { !$0.isDeleted }) {
            $0.name.localizedCaseInsensitiveContains(query)
        }.map { playlist in
            PaletteItem(kind: .playlist, title: playlist.name,
                        subtitle: "\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")",
                        icon: PlaylistArtwork.placeholder(for: playlist),
                        artwork: library.coverData(for: playlist)) {
                appState.selectedPlaylist = playlist
                appState.selectedAlbum    = nil
                appState.selection        = nil
            }
        }
    }

    /// Library lookups only run once there's something to look up — an empty
    /// palette shows commands and recently played playlists, not 4000 songs.
    private func matching<T>(_ source: [T], _ predicate: (T) -> Bool) -> [T] {
        guard !trimmedQuery.isEmpty else { return [] }
        return Array(source.lazy.filter(predicate).prefix(perSectionLimit))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var recentPlaylists: [PaletteItem] {
        guard trimmedQuery.isEmpty else { return [] }
        return meta.playlistLastPlayedDates
            .sorted { $0.value > $1.value }
            .compactMap { entry in library.playlists.first { $0.id == entry.key } }
            .prefix(3)
            .map { playlist in
                PaletteItem(kind: .playlist, title: playlist.name,
                            subtitle: "Recently played",
                            icon: PlaylistArtwork.placeholder(for: playlist),
                            artwork: library.coverData(for: playlist)) {
                    appState.selectedPlaylist = playlist
                    appState.selectedAlbum    = nil
                    appState.selection        = nil
                }
            }
    }

    private var filteredCommands: [PaletteItem] {
        guard !trimmedQuery.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// Flat, in display order — the same order arrow keys walk.
    private var sections: [(String, [PaletteItem])] {
        [
            ("Jump back in", recentPlaylists),
            ("Commands",     filteredCommands),
            ("Songs",        songs),
            ("Albums",       albums),
            ("Artists",      artists),
            ("Playlists",    playlists),
        ].filter { !$0.1.isEmpty }
    }

    private var flatItems: [PaletteItem] { sections.flatMap { $0.1 } }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if flatItems.isEmpty {
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                list
            }
        }
        .frame(width: 620)
        .background(chrome.material(.regularMaterial, flat: .mixSurface),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .onAppear { fieldFocused = true }
        // Any change to the result set can strand the cursor past the end.
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mixTextTertiary)

            TextField("Search or jump to…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Color.mixTextPrimary)
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { move(1);  return .handled }
                .onKeyPress(.upArrow)   { move(-1); return .handled }
                .onSubmit(run)
                // ⌘⌫ clears what's been typed here rather than reaching the
                // window behind the palette and offering to delete a song.
                .mixEditingFocus(fieldFocused)

            Text("esc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Index has to be tracked across sections so ↑/↓ walk the
                    // whole palette, not each group independently.
                    let all = flatItems
                    ForEach(sections, id: \.0) { title, items in
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.mixTextTertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(items) { item in
                            let index = all.firstIndex(where: { $0.id == item.id }) ?? 0
                            PaletteRow(item: item, isSelected: index == selection)
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    run()
                                }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 400)
            .onChange(of: selection) { _, new in
                withMixAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run() {
        guard flatItems.indices.contains(selection) else { return }
        let item = flatItems[selection]
        appState.commandPaletteOpen = false
        item.action()
    }
}

// MARK: - Item model

struct PaletteItem: Identifiable {
    enum Kind { case command, song, album, artist, playlist }

    let id = UUID()
    let kind:     Kind
    let title:    String
    let subtitle: String
    let icon:     String
    var artwork:  Data? = nil
    var circular: Bool  = false
    let action:   () -> Void

    init(kind: Kind, title: String, subtitle: String, icon: String,
         artwork: Data? = nil, circular: Bool = false,
         action: @escaping () -> Void) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.artwork = artwork
        self.circular = circular
        self.action = action
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isSelected {
                Text("↩")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.mixPrimary.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if let artwork = item.artwork {
            MacArtworkView(data: artwork, size: 30, cornerRadius: item.circular ? 15 : 4)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: item.circular ? 15 : 4, style: .continuous)
                    .fill(Color.mixSurface2)
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixPrimary)
            }
        }
    }
}

#endif
