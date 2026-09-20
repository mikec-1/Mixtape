// MacArtistsView.swift
// Mixtape — Mac/Content
//
// Redesigned artist view: two-panel Apple Music–style layout.
//
//   Left (220 pt) — scrollable artist sidebar with circular avatar + name.
//                   Uses List(selection:) so the selected row gets the
//                   accent-colour highlight automatically.
//   Right          — selected artist:
//                     · Hero banner (blurred artwork or gradient, artist photo,
//                       name, album/song count, Play All + Shuffle buttons)
//                     · Albums carousel (horizontal scroll, click → MacAlbumDetailView)
//                     · Songs table  (NativeTrackTable fills remaining height)
//
// When no artist is selected, the right panel shows an empty-state prompt.
// Album drill-down is handled via NavigationStack + .navigationDestination.

#if os(macOS)
import SwiftUI
import Combine

// MARK: - MacArtistsView

struct MacArtistsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    let searchText: String

    @State private var selectedArtistID: Artist.ID? = nil

    private var filteredArtists: [Artist] {
        guard !searchText.isEmpty else { return library.artists }
        return library.artists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedArtist: Artist? {
        library.artists.first { $0.id == selectedArtistID }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if library.artists.isEmpty {
                MacEmptyLibraryView(context: .artists)
            } else if let artist = selectedArtist {
                MacArtistDetailPanel(artist: artist) {
                    selectedArtistID = nil
                    // Belt and braces: a deep-link that hasn't been consumed
                    // yet would otherwise re-select the artist we're leaving.
                    appState.pendingArtistID = nil
                }
            } else {
                artistGrid
            }
        }
        .navigationTitle(selectedArtist?.name ?? "Artists")
        .navigationSubtitle(navSubtitle)
        .onAppear {
            // Honour a pending drill-in request (e.g. from the inspector).
            // Nothing is auto-selected otherwise: the grid *is* the landing
            // page, so every artist is visible instead of one being picked at
            // random and the rest hidden behind a scroll.
            if let pending = appState.pendingArtistID {
                selectedArtistID = pending
                appState.pendingArtistID = nil
            }
        }
        .onChange(of: appState.pendingArtistID) { _, pending in
            if let pending {
                selectedArtistID = pending
                appState.pendingArtistID = nil
            }
        }
        // Typing in the toolbar search means the user wants to find someone
        // else, so drop back out to the grid.
        .onChange(of: searchText) { _, text in
            if !text.isEmpty { selectedArtistID = nil }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var artistGrid: some View {
        if filteredArtists.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.mixTextTertiary)
                Text("No artists found")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mixBackground)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)],
                    spacing: 24
                ) {
                    ForEach(filteredArtists) { artist in
                        MacArtistCard(artist: artist) {
                            selectedArtistID = artist.id
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color.mixBackground)
        }
    }

    // MARK: - Navigation subtitle

    private var navSubtitle: String {
        if let artist = selectedArtist {
            let tracks = library.tracks(by: artist)
            let albums = artist.albumIDs.count
            return "\(albums) album\(albums == 1 ? "" : "s") · \(tracks.count) song\(tracks.count == 1 ? "" : "s")"
        }
        return searchText.isEmpty
            ? "\(library.artists.count) artist\(library.artists.count == 1 ? "" : "s")"
            : "\(filteredArtists.count) of \(library.artists.count) artists"
    }
}

// MARK: - Artist Card

/// Grid tile: circular photo, name, song count, and a play button that fades
/// in on hover — the same interaction as the album grid, so both browse
/// surfaces behave identically.
private struct MacArtistCard: View {
    let artist: Artist
    let onSelect: () -> Void

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var engine:  PlaybackEngine

    @State private var isHovered = false

    private var artistTracks: [Track] { library.tracks(by: artist) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                avatar

                if isHovered {
                    Button {
                        guard let first = artistTracks.first else { return }
                        Task { await engine.play(track: first, in: artistTracks, source: .named(artist.name)) }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.mixPrimary)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }

            VStack(spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                Text("\(artistTracks.count) song\(artistTracks.count == 1 ? "" : "s")")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            withMixAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Play Artist") {
                guard let first = artistTracks.first else { return }
                Task { await engine.play(track: first, in: artistTracks, source: .named(artist.name)) }
            }
            Button("Add to Queue") {
                artistTracks.forEach { engine.queue.append($0) }
            }
        }
    }

    private var avatar: some View {
        Group {
            if let data = artist.displayArtwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.mixTextTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mixSurface)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(Circle())
        .mixShadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

// MARK: - Artist Detail Panel

private struct MacArtistDetailPanel: View {

    let artist: Artist
    let onBack: () -> Void

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    @Environment(\.mixChrome) private var chrome

    @State private var selectedIDs: Set<Track.ID> = []

    private var artistTracks: [Track] {
        library.tracks(by: artist)
            .sorted { ($0.albumTitle, $0.trackNumber ?? 999) < ($1.albumTitle, $1.trackNumber ?? 999) }
    }

    private var artistAlbums: [Album] {
        let ids = Set(artist.albumIDs)
        return library.albums
            .filter { ids.contains($0.id) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }   // newest first
    }

    // MARK: - Body

    // One scroll view owns the whole page. It used to be a fixed VStack whose
    // songs table scrolled inside itself, which meant a short window had to
    // find the height for hero + albums + a table from a budget that didn't
    // have it — the table kept its minimum, the stack overflowed its slot, and
    // the songs went off the bottom with no way to reach them. Now the hero
    // scrolls away like everything else and the table is sized to its content.
    /// Bumped whenever the download manager publishes.
    ///
    /// This view reads download state (`status(for:)` and friends) straight off
    /// the manager inside `body`, which is not observation — nothing here holds
    /// the manager, so nothing here hears it change. `AppDependencies` used to
    /// rebroadcast every service's publishes, which covered this by invalidating
    /// all 81 views that hold `deps` on every status transition. The views that
    /// actually draw download state say so themselves now.
    @State private var downloadTick = 0

    var body: some View {
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                if !artistAlbums.isEmpty { albumsSection }
                Divider()
                if artistTracks.isEmpty {
                    emptyTracksView
                } else {
                    songsSection
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Warm the first few songs while the user reads the page, so the tap
        // that follows doesn't pay for the resolve.
        .task(id: artist.id) {
            deps.onlineCoordinator.prefetchResolvable(artistTracks)
        }
        .pageBack("All artists", action: onBack)
    }

    // MARK: - Hero Banner

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Blurred artwork fills the banner
            heroBackground
                .frame(height: 210)
                .clipped()

            // Fade-to-background gradient at the bottom so content blends in
            LinearGradient(
                colors: [.clear, Color.mixBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 210)

            // Artist photo + info pinned to the bottom of the banner
            HStack(alignment: .bottom, spacing: 18) {
                artistAvatar
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 5) {
                    Text(artist.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        // Halo in the opposite tone of the text (dark behind
                        // light text, light behind dark text) for legibility.
                        .shadow(color: Color.mixBackground.opacity(0.7), radius: 4, y: 2)

                    let albums = artistAlbums.count
                    let songs  = artistTracks.count
                    Text(
                        "\(albums) album\(albums == 1 ? "" : "s") · \(songs) song\(songs == 1 ? "" : "s")"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)

                    HStack(spacing: 10) {
                        Button {
                            guard let first = artistTracks.first else { return }
                            Task { await engine.play(track: first, in: artistTracks, source: .named(artist.name)) }
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent).mixHandCursor()
                        .tint(Color.mixPrimary)
                        .controlSize(.regular)
                        .disabled(artistTracks.isEmpty)

                        Button {
                            guard let first = artistTracks.randomElement() else { return }
                            engine.queue.setShuffle(true)
                            Task { await engine.play(track: first, in: artistTracks, source: .named(artist.name)) }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered).mixHandCursor()
                        .controlSize(.regular)
                        .disabled(artistTracks.isEmpty)

                    }
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private var heroBackground: some View {
        Group {
            // `mixImage` rather than a bare `NSImage(data:)`: this decodes a
            // full banner-sized cover, and it sat in a `body` that re-ran on
            // every hover in the grid below it.
            if let data = artist.displayArtwork, let img = mixImage(from: data) {
                img
                    .resizable()
                    .scaledToFill()
                    // A 28pt gaussian over a banner is the most expensive single
                    // thing the artist page draws, and it is pure decoration —
                    // the scrim below it is what makes the text readable.
                    .blur(radius: chrome.showsMaterials ? 28 : 0)
                    .scaleEffect(1.08)               // hide white blur-edge fringe
                    // Adaptive scrim: lightens the banner in light mode and
                    // darkens it in dark mode, so the hero text stays readable
                    // in both (a fixed black scrim left light mode muddy).
                    .overlay(Color.mixBackground.opacity(0.5))
            } else {
                // No artwork — use a branded gradient
                LinearGradient(
                    colors: [Color.mixPrimary.opacity(0.28), Color.mixBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    /// Just the photo. It used to be a button that re-fetched the artist's
    /// picture — with a hover spinner over it — from back when import left new
    /// artists wearing an album cover and you had to fix each one by hand.
    /// `LibraryService.scheduleArtistImageBackfill()` does that automatically
    /// now, so the control was a reload for its own sake sitting on top of the
    /// artwork it kept replacing.
    private var artistAvatar: some View {
        Group {
            if let data = artist.displayArtwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.mixPrimary.opacity(0.20)
                    Image(systemName: "person.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.mixPrimary)
                }
            }
        }
        .frame(width: 90, height: 90)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
        .mixShadow(color: .black.opacity(0.65), radius: 12, y: 4)
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Albums")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(artistAlbums) { album in
                        MacArtistAlbumCard(album: album) {
                            appState.selectedAlbum = album
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: - Songs Section

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Songs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 8)

            NativeTrackTable(
                tracks:             artistTracks,
                currentTrackID:     engine.queue.currentTrack?.id,
                isPlaying:          engine.state.isPlaying,
                selectedIDs:        $selectedIDs,
                onPlay:             { track, ctx in Task { await engine.play(track: track, in: ctx, source: .named(artist.name)) } },
                onPlayNext:         { engine.queue.insertNext($0) },
                onAddToQueue:       { engine.queue.append($0) },
                onGetInfo:          { appState.showInspector(for: $0) },
                onDragTracksChanged: { appState.isDraggingTracks = $0 },
                // Artist is still offered: on a featured track it opens the
                // *other* credited artist, which is the whole point.
                onGoToArtist:       { appState.openDiscoverArtist(named: $0) },
                onGoToAlbum:        { appState.openDiscoverAlbum(for: $0) },
                onOpenArtistLink:   { appState.openDiscoverArtist(named: $0) },
                onOpenAlbumLink:    { appState.openDiscoverAlbum(for: $0) },
                onRemove:           { selection in
                    for track in selection { engine.stopIfPlaying(trackID: track.id) }
                    deps.libraryService.deleteTracks(ids: selection.map(\.id))
                },
                onToggleFavourite:  { deps.toggleFavourite(trackID: $0.id) },
                onAddToPlaylist:    { selection, playlistID in
                    deps.addTracks(ids: selection.map(\.id), toPlaylist: playlistID)
                },
                isFavourited:       { deps.libraryService.isFavourited(trackID: $0) },
                playlists:          deps.libraryService.playlists,
                availability:     { deps.downloadManager.status(for: $0) },
                onDownload:         { deps.downloadManager.download($0) },
                onRemoveDownload:   { deps.downloadManager.removeDownload(for: $0) },
                onSaveToDisk:       { macSaveToDisk(tracks: $0, deps: deps) },
                onLinkCopied:       { deps.showToast(ShareSheet.copiedMessage) },
                canDownload:         { deps.downloadManager.downloadUnavailableReason(for: $0) == nil },
                scale:              appState.uiScale,
                // Sized to its rows and scrolled by the page, not by itself —
                // a scroll view inside a scroll view would trap the wheel over
                // the song list.
                fitsContent:        true,
                resolvingIDs:       engine.routingTrackIDs
            )
        }
    }

    private var emptyTracksView: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No songs yet")
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Album Card (within artist detail)

private struct MacArtistAlbumCard: View {
    let album:  Album
    let onTap:  () -> Void

    @State private var isHovered = false

    private let cardSize: CGFloat = 120

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    MacArtworkView(data: album.artworkData, artworkRef: .album(album.id), size: cardSize, cornerRadius: 8)
                        .mixShadow(color: .black.opacity(0.35), radius: 6, y: 3)

                    if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                            .frame(width: cardSize, height: cardSize)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .mixShadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    }
                }
                .mixAnimation(.easeInOut(duration: 0.13), value: isHovered)

                Text(album.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .frame(width: cardSize, alignment: .leading)

                if let year = album.year {
                    Text(String(year))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
    }
}

#endif
