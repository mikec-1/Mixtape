// Library search results: a top result beside a short songs column, then albums, artists and
// people, mirroring Discover's layout. Discover's components are private and typed on online
// models, so the structure is restated over local models.

#if os(macOS)
import SwiftUI
import Combine

struct MacSearchResultsView: View {

    let query: String

    @Environment(LibraryService.self) private var library
    @Environment(PlaybackEngine.self) private var engine
    @Environment(MacAppState.self) private var appState
    @Environment(AppDependencies.self) private var deps

    /// Row index into `matchingTracks` that arrow keys are currently on.
    @State private var focusedIndex: Int? = nil
    @FocusState private var listFocused: Bool

    /// Its own object so a slow directory lookup doesn't hold up the songs.
    @StateObject private var people = PeopleSearch()

    // MARK: - Filtered results

    private var matchingTracks: [Track] {
        library.displayTracks.filter { $0.matches(query) }
    }

    private var matchingAlbums: [Album] {
        library.albums.filter { $0.title.localizedCaseInsensitiveContains(query)
                              || $0.artistName.localizedCaseInsensitiveContains(query) }
    }

    private var matchingArtists: [Artist] {
        library.artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var matchingPlaylists: [Playlist] {
        library.playlists.filter {
            !$0.isDeleted && $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var totalCount: Int {
        matchingTracks.count + matchingAlbums.count
            + matchingArtists.count + matchingPlaylists.count
    }

    /// One songs list, as on Discover.
    private var songs: [Track] { Array(matchingTracks.prefix(50)) }

    /// Like Spotify: an exactly-named artist, then an exact album, then the first song.
    private var topResult: LocalTopResult? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let artist = matchingArtists.first(where: { $0.name.lowercased() == q })
            ?? matchingArtists.first(where: { $0.name.lowercased().hasPrefix(q) }) {
            return .artist(artist)
        }
        if let album = matchingAlbums.first(where: { $0.title.lowercased() == q }) {
            return .album(album)
        }
        if let playlist = matchingPlaylists.first(where: { $0.name.lowercased() == q }) {
            return .playlist(playlist)
        }
        if let artist = matchingArtists.first { return .artist(artist) }
        if let song = matchingTracks.first { return .song(song) }
        if let album = matchingAlbums.first { return .album(album) }
        if let playlist = matchingPlaylists.first { return .playlist(playlist) }
        return nil
    }

    // MARK: - Body

    /// Includes people, so a username-only match isn't briefly "No results".
    private var combinedCount: Int { totalCount + people.results.count }

    /// Bumped when the download manager publishes, since `body` reads its state without observing it.
    @State private var downloadTick = 0

    var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        Group {
            if combinedCount == 0 && !people.isSearching {
                emptyState
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(
            combinedCount == 0
                ? "No results"
                : "\(combinedCount) result\(combinedCount == 1 ? "" : "s") for \"\(query)\""
        )
        .task(id: query) {
            await people.search(query, using: deps.authService)
        }
        // A new query invalidates the old row position.
        .onChange(of: query) { _, _ in focusedIndex = nil }
        // ↓ from the search field moves keyboard focus into the list.
        .onChange(of: appState.resultsFocusToken) { _, _ in
            guard !matchingTracks.isEmpty else { return }
            focusedIndex = 0
            listFocused  = true
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    topRow

                    if !songs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Songs")
                            VStack(spacing: 2) {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { offset, track in
                                    songRow(track, index: offset)
                                }
                            }
                        }
                    }

                    if !matchingAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("Albums")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(matchingAlbums) { album in
                                        LocalAlbumCard(album: album) { appState.showAlbum(album) }
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }

                    if !matchingArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("Artists")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 18) {
                                    ForEach(matchingArtists) { artist in
                                        LocalArtistCircle(artist: artist) { appState.showArtist(artist) }
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }

                    if !matchingPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("Playlists")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(matchingPlaylists) { playlist in
                                        LocalPlaylistCard(playlist: playlist) { open(playlist) }
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }

                    peopleSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(MixPageBackground())
            // Arrows walk the songs, Return plays. The container is focusable, not each row.
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                move(direction, proxy: proxy)
            }
            .onKeyPress(.return) {
                guard let i = focusedIndex, matchingTracks.indices.contains(i) else { return .ignored }
                play(matchingTracks[i])
                return .handled
            }
        }
    }

    // MARK: - People

    /// Last: most searches are for music.
    @ViewBuilder
    private var peopleSection: some View {
        if !people.results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("People")
                VStack(spacing: 2) {
                    ForEach(people.results) { profile in
                        Button {
                            appState.showProfile(profile)
                        } label: {
                            PersonResultRow(profile: profile)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        } else if people.isSearching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for people…")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
    }

    // MARK: - Top row

    /// The top result as one full-width strip, like Discover's `TopResultBanner`.
    @ViewBuilder
    private var topRow: some View {
        if let top = topResult {
            LocalTopResultCard(top: top, onOpen: { open(top) })
        }
    }

    private func songRow(_ track: Track, index: Int) -> some View {
        LocalSongRow(
            track:       track,
            isCurrent:   engine.queue.currentTrack?.id == track.id,
            isPlaying:   engine.state.isPlaying,
            isFocused:   focusedIndex == index,
            onPlay:      { play(track) },
            onSelect:    { focusedIndex = index; listFocused = true },
            onOpenAlbum: { appState.openDiscoverAlbum(for: track) },
            onOpenArtist: { appState.openDiscoverArtist(named: track.artistName) }
        )
        .id(track.id)
        .contextMenu { trackMenu(track) }
    }

    private func trackMenu(_ track: Track) -> some View {
        LibrarySongMenu(targets: [track], onPlay: { play(track) })
    }

    // MARK: - Actions

    private func play(_ track: Track) {
        Task { await engine.play(track: track, in: [track], source: .named("Search results")) }
    }

    private func open(_ top: LocalTopResult) {
        switch top {
        case .artist(let a):   appState.showArtist(a)
        case .album(let a):    appState.showAlbum(a)
        case .playlist(let p): open(p)
        case .song(let t):     play(t)
        }
    }

    private func open(_ playlist: Playlist) {
        appState.selectedPlaylist = playlist
        appState.selectedAlbum    = nil
        appState.selection        = nil
    }

    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !matchingTracks.isEmpty else { return }
        let last = matchingTracks.count - 1
        switch direction {
        case .down: focusedIndex = min((focusedIndex ?? -1) + 1, last)
        case .up:   focusedIndex = max((focusedIndex ?? 1) - 1, 0)
        default:    return
        }
        if let i = focusedIndex {
            withMixAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(matchingTracks[i].id, anchor: .center)
            }
        }
    }

    // MARK: - Chrome

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.mixTextPrimary)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No results for \"\(query)\"")
                .font(.title3).fontWeight(.medium)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Try a different search term, or search Discover for music you don't own yet.")
                .font(.callout)
                .foregroundStyle(Color.mixTextSecondary)
            Button("Search Discover") {
                appState.selection       = .discover
                appState.selectedAlbum   = nil
                appState.selectedPlaylist = nil
            }
            .buttonStyle(.borderedProminent).mixHandCursor()
            .tint(Color.mixPrimary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MixPageBackground())
    }
}

// MARK: - Top result model

enum LocalTopResult {
    case artist(Artist)
    case album(Album)
    case playlist(Playlist)
    case song(Track)
}

// MARK: - Top result card

private struct LocalTopResultCard: View {
    let top:    LocalTopResult
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 16) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface2)
                .opacity(hovering ? 1 : 0)
        )
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
        .mixAnimation(.easeInOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Top result: \(title), \(subtitle)")
    }

    @ViewBuilder
    private var artwork: some View {
        switch top {
        case .artist(let a):
            MacArtworkView(data: a.artworkData, artworkRef: .artist(a.id), size: 72, cornerRadius: 36)
        case .album(let a):
            MacArtworkView(data: a.artworkData, artworkRef: .album(a.id), size: 72, cornerRadius: 6)
        case .playlist(let p):
            MacArtworkView(data: p.displayArtwork, artworkRef: .playlist(p.id), size: 72, cornerRadius: 6)
        case .song(let t):
            MacArtworkView(data: t.artworkData, artworkRef: .track(t.id), size: 72, cornerRadius: 6)
        }
    }

    private var title: String {
        switch top {
        case .artist(let a):   return a.name
        case .album(let a):    return a.title
        case .playlist(let p): return p.name
        case .song(let t):     return t.title
        }
    }

    private var subtitle: String {
        switch top {
        case .artist:          return "Artist"
        case .album(let a):    return "Album · \(a.artistName)"
        case .playlist(let p): return "Playlist · \(p.trackCount) song\(p.trackCount == 1 ? "" : "s")"
        case .song(let t):     return "Song · \(t.artistName)"
        }
    }
}

// MARK: - Song row

/// Discover's row treatment over a local `Track`: artwork click plays, title/artist click
/// navigates, double click plays. Focus paints the hover fill.
private struct LocalSongRow: View {
    let track:     Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isFocused: Bool
    let onPlay:    () -> Void
    let onSelect:  () -> Void
    let onOpenAlbum:  () -> Void
    let onOpenArtist: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                MacArtworkView(data: track.artworkData, artworkRef: .track(track.id), size: 40, cornerRadius: 4)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.mixPrimary)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .mixTapAction(onPlay)

            VStack(alignment: .leading, spacing: 2) {
                LocalClickableText(text: track.title,
                                   font: .system(size: 13, weight: .medium),
                                   color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary,
                                   action: track.albumTitle.isEmpty ? nil : onOpenAlbum)
                LocalClickableText(text: track.artistName,
                                   font: .system(size: 12),
                                   color: Color.mixTextSecondary,
                                   action: onOpenArtist)
            }

            Spacer()

            if isCurrent {
                PlayingWave(size: 13, isPlaying: isPlaying)
            } else {
                Text(track.formattedDuration)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering || isFocused ? Color.mixSurface : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.mixPrimary.opacity(0.7), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(count: 1, perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Text that only behaves like a link when there's somewhere to go.
private struct LocalClickableText: View {
    let text:   String
    let font:   Font
    let color:  Color
    let action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .underline(hovering && action != nil)
            .contentShape(Rectangle())
            .onHover { hovering = action != nil && $0 }
            .onTapGesture { action?() }
    }
}

// MARK: - Cards

private struct LocalAlbumCard: View {
    let album: Album
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacArtworkView(data: album.artworkData, artworkRef: .album(album.id), size: 150, cornerRadius: 6)
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.mixPrimary)
                            .padding(8)
                    }
                }
            Text(album.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text(album.artistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
    }
}

private struct LocalArtistCircle: View {
    let artist: Artist
    let onTap:  () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            MacArtworkView(data: artist.artworkData, artworkRef: .artist(artist.id), size: 116, cornerRadius: 58)
                .overlay {
                    if hovering { Circle().stroke(Color.mixPrimary, lineWidth: 2) }
                }
            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text("Artist")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .frame(width: 124)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
    }
}

private struct LocalPlaylistCard: View {
    let playlist: Playlist
    let onTap:    () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacArtworkView(data: playlist.displayArtwork, artworkRef: .playlist(playlist.id), size: 150, cornerRadius: 6)
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.mixPrimary)
                            .padding(8)
                    }
                }
            Text(playlist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
    }
}

// MARK: - Track.matches helper

private extension Track {
    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)     ||
        artistName.localizedCaseInsensitiveContains(query) ||
        albumTitle.localizedCaseInsensitiveContains(query)
    }
}

#endif
