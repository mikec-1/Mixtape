// ⌘K: jump to sections, run playback commands, or open any library song, album, artist or playlist.
// Unlike the toolbar search, the palette navigates and closes.
// Type to filter, ↑/↓ to move, Return to run, Esc to close. The field keeps focus and intercepts arrows.

#if os(macOS)
import SwiftUI

struct MacCommandPalette: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var deps:     AppDependencies
    @Environment(\.mixChrome) private var chrome

    @ObservedObject private var meta = PlaylistMetadataService.shared

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    /// Per-section cap so a large library can't push the commands off screen.
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

        out.append(PaletteItem(kind: .command, title: deps.jam.session == nil ? "Start a Jam" : "Open Jam",
                               subtitle: "Listen together", icon: "person.2.wave.2") {
            deps.jam.present()
        })

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
                // Play just this song, so suggestions follow it.
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

    /// Library lookups wait for a query; an empty palette shows commands and recent playlists.
    // MARK: - Verbs

    private struct Verb {
        let name: String
        let usage: String
        let summary: String
        let icon: String
    }

    private static let verbs = [
        Verb(name: "queue", usage: "queue <song>", summary: "Add a song to the queue", icon: "text.append"),
        Verb(name: "radio", usage: "radio <artist>", summary: "Start a station from an artist", icon: "dot.radiowaves.left.and.right"),
        Verb(name: "download", usage: "download <album>", summary: "Download an album", icon: "arrow.down.circle"),
        Verb(name: "dub", usage: "dub <playlist> to <person>", summary: "Dub a playlist for someone", icon: "recordingtape"),
        Verb(name: "goto", usage: "goto settings/playback", summary: "Jump to a page or a setting", icon: "arrow.turn.down.right"),
        Verb(name: "jam", usage: "jam <code>", summary: "Join a Jam", icon: "person.2.wave.2"),
    ]

    /// The verb the query starts with, and what follows it.
    private var verb: (verb: Verb, argument: String)? {
        let parts = trimmedQuery.split(separator: " ", maxSplits: 1)
        guard let first = parts.first?.lowercased(),
              let verb = Self.verbs.first(where: { $0.name == first }) else { return nil }
        return (verb, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    /// The verbs as rows that fill the field, until one has an argument.
    private var verbHints: [PaletteItem] {
        let typed = trimmedQuery.lowercased()
        return Self.verbs.filter { typed.isEmpty || $0.name.hasPrefix(typed) }.map { verb in
            PaletteItem(kind: .command, title: verb.usage, subtitle: verb.summary,
                        icon: verb.icon, fill: verb.name + " ") {}
        }
    }

    private var verbItems: [PaletteItem] {
        guard let parsed = verb, !parsed.argument.isEmpty else { return [] }
        let verb = parsed.verb, argument = parsed.argument
        switch verb.name {
        case "queue":
            return matching(library.displayTracks) {
                $0.title.localizedCaseInsensitiveContains(argument)
                    || $0.artistName.localizedCaseInsensitiveContains(argument)
            }.map { track in
                PaletteItem(kind: .song, title: "Queue \(track.title)", subtitle: track.artistName,
                            icon: verb.icon, artwork: track.displayArtwork) {
                    engine.queue.append(track)
                    deps.showToast(.done("Added to Queue"))
                }
            }
        case "radio":
            let artists = matching(library.artists) { $0.name.localizedCaseInsensitiveContains(argument) }
            var items = artists.map { radioItem($0.name, artwork: $0.displayArtwork) }
            // The catalogue has artists the library doesn't.
            if !artists.contains(where: { $0.name.caseInsensitiveCompare(argument) == .orderedSame }) {
                items.append(radioItem(argument, artwork: nil))
            }
            return items
        case "download":
            return matching(library.albums) {
                $0.title.localizedCaseInsensitiveContains(argument)
                    || $0.artistName.localizedCaseInsensitiveContains(argument)
            }.map { album in
                PaletteItem(kind: .album, title: "Download \(album.title)", subtitle: album.artistName,
                            icon: verb.icon, artwork: album.displayArtwork) {
                    let started = library.tracks(in: album).filter { deps.downloadManager.download($0) == nil }.count
                    deps.showToast(started == 0
                                   ? "Nothing left to download in \u{201C}\(album.title)\u{201D}"
                                   : "Downloading \(started) song\(started == 1 ? "" : "s")")
                }
            }
        case "dub":
            guard deps.authService.currentUser != nil else { return [] }
            // "dub road trip to sam": the last " to " splits playlist from person.
            let padded = argument + " "
            let split = padded.range(of: " to ", options: [.caseInsensitive, .backwards])
            let name = split.map { String(padded[..<$0.lowerBound]) } ?? argument
            let person = split.map { padded[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
            return matching(library.playlists) {
                $0.isEditable && !$0.isSystem && !$0.isDeleted && !$0.trackIDs.isEmpty
                    && $0.name.localizedCaseInsensitiveContains(name)
            }.map { playlist in
                PaletteItem(kind: .playlist, title: "Dub \(playlist.name)",
                            subtitle: person.isEmpty ? "For someone" : "For \(person)",
                            icon: verb.icon, artwork: library.coverData(for: playlist)) {
                    appState.dubRequest = MacAppState.DubRequest(playlist: playlist, recipient: person)
                }
            }
        case "goto":
            let words = argument.lowercased().split { $0 == " " || $0 == "/" }
            let pages = MacSidebarItem.allCases.map { item in
                (key: item.title.lowercased(),
                 item: PaletteItem(kind: .command, title: item.title, subtitle: "Page",
                                   icon: item.systemImage) { appState.goToSection(item) })
            }
            let user = deps.authService.currentUser
            let settings = SettingsCategory.visible(isSignedIn: user != nil,
                                                    isDeveloper: user?.isDeveloper == true).map { category in
                (key: "settings \(category.title.lowercased())",
                 item: PaletteItem(kind: .command, title: "Settings \u{203A} \(category.title)",
                                   subtitle: category.summary, icon: category.icon) {
                     SettingsRoute.shared.open(category)
                     appState.goToSection(.settings)
                 })
            }
            return Array((pages + settings)
                .filter { page in words.allSatisfy { page.key.contains($0) } }
                .prefix(perSectionLimit)
                .map { $0.item })
        case "jam":
            return jamItem(argument).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// "Join Jam ABC234" once `text` is a whole code.
    private func jamItem(_ text: String) -> PaletteItem? {
        let code = JamCodeField.clean(text)
        guard code.count == JamCodeField.length else { return nil }
        return PaletteItem(kind: .command, title: "Join Jam \(code)", subtitle: "Listen together",
                           icon: "person.2.wave.2") {
            Task { await deps.jam.join(code: code) }
        }
    }

    /// A code typed on its own, last so a six-letter song name still wins.
    private var bareJamCode: [PaletteItem] {
        guard verb == nil, trimmedQuery.count == JamCodeField.length,
              JamCodeField.clean(trimmedQuery) == trimmedQuery.uppercased() else { return [] }
        return jamItem(trimmedQuery).map { [$0] } ?? []
    }

    private func radioItem(_ name: String, artwork: Data?) -> PaletteItem {
        PaletteItem(kind: .artist, title: "\(name) Radio", subtitle: "Station",
                    icon: "dot.radiowaves.left.and.right", artwork: artwork, circular: true) {
            appState.showArtistRadio(name: name)
        }
    }

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

    /// In display order, the order arrow keys walk.
    private var sections: [(String, [PaletteItem])] {
        [
            (verb?.verb.summary ?? "", verbItems),
            ("Jump back in", recentPlaylists),
            ("Actions",      verbHints),
            ("Commands",     filteredCommands),
            ("Songs",        songs),
            ("Albums",       albums),
            ("Artists",      artists),
            ("Playlists",    playlists),
            ("Jam",          bareJamCode),
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
        // Next turn, once the palette's own host view is in the window.
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
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
                .onKeyPress(.escape)    { appState.commandPaletteOpen = false; return .handled }
                .onSubmit(run)
                // ⌘⌫ clears the field instead of deleting a song behind the palette.
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
                    // Global index so ↑/↓ walk across sections.
                    let secs = sections
                    let starts = secs.reduce(into: [0]) { $0.append($0.last! + $1.1.count) }
                    ForEach(Array(secs.enumerated()), id: \.element.0) { s, section in
                        Text(section.0.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.mixTextTertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        // By position: item ids are minted fresh on every redraw.
                        ForEach(Array(section.1.enumerated()), id: \.offset) { i, item in
                            let index = starts[s] + i
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
        if let fill = item.fill {
            query = fill
            return
        }
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
    /// Set on verb hints: running the row types this instead of closing.
    var fill:     String? = nil
    let action:   () -> Void

    init(kind: Kind, title: String, subtitle: String, icon: String,
         artwork: Data? = nil, circular: Bool = false, fill: String? = nil,
         action: @escaping () -> Void) {
        self.fill = fill
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

    @State private var isHovered = false

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
        // Hover is a lighter tint than the keyboard selection.
        .background(Color.mixPrimary.opacity(isSelected ? 0.18 : isHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
