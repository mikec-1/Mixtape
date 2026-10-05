// Artists page: a grid of artists, drilling into one artist's hero, albums and songs.

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

    /// On MacAppState so Back and Forward can bring an artist back.
    private var selectedArtistID: Artist.ID? {
        get { appState.libraryArtistID }
        nonmutating set { appState.libraryArtistID = newValue }
    }

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
                MacArtistDetailPanel(artist: artist) { selectedArtistID = nil }
            } else {
                artistGrid
            }
        }
        .navigationTitle(selectedArtist?.name ?? "Artists")
        .navigationSubtitle(navSubtitle)
        // Typing a search drops back to the grid.
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
            .background(MixPageBackground())
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
            .background(MixPageBackground())
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

/// Grid tile with a hover play button, like the album grid.
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
        .mixTapAction { onSelect() }
        .onHover { hovering in
            withMixAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu { ArtistActionsMenu(name: artist.name) }
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

    /// Bumped when the download manager publishes, since `body` reads its state without observing it.
    @State private var downloadTick = 0
    /// How much *you* played this artist. Loaded in `.task`: it reads play history.
    @State private var standing: ArtistStanding?

    // One scroll view owns the page; the song table sizes to its content.
    var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
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
        .background(MixPageBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Warm the first few songs so the first tap doesn't wait on a resolve.
        .task(id: artist.id) {
            deps.onlineCoordinator.prefetchResolvable(artistTracks)
            standing = deps.statsService.artistStanding(for: artist.name)
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
                        // Halo in the opposite tone of the text.
                        .shadow(color: Color.mixBackground.opacity(0.7), radius: 4, y: 2)

                    let albums = artistAlbums.count
                    let songs  = artistTracks.count
                    // Lowercased: the standing joins a counts line, not a sentence of its own.
                    Text(
                        "\(albums) album\(albums == 1 ? "" : "s") · \(songs) song\(songs == 1 ? "" : "s")"
                        + (standing.map { " · " + $0.summary.lowercased() } ?? "")
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

                        // Overflow menu, as on iPhone.
                        Menu {
                            ArtistActionsMenu(name: artist.name)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered).mixHandCursor()
                        .menuIndicator(.hidden)
                        .controlSize(.regular)
                        // Bounded: an unbounded vertical `fixedSize` in a split view causes the constraint crash.
                        .fixedSize(horizontal: true, vertical: false)
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
            // `mixImage` downsamples; this banner decode sat in a frequently re-run `body`.
            if let data = artist.displayArtwork, let img = mixImage(from: data) {
                img
                    .resizable()
                    .scaledToFill()
                    // The blur is the costliest thing here and pure decoration.
                    .blur(radius: chrome.showsMaterials ? 28 : 0)
                    .scaleEffect(1.08)               // hide white blur-edge fringe
                    // Adaptive scrim so the hero text reads in light and dark.
                    .overlay(Color.mixBackground.opacity(0.5))
            } else {
                // No artwork: branded gradient.
                LinearGradient(
                    colors: [Color.mixPrimary.opacity(0.28), Color.mixBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    /// Just the photo. `LibraryService.scheduleArtistImageBackfill()` fetches artist pictures.
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
                onEditMetadata:     { appState.enqueueReview(MetadataReviewItem(editing: $0)) },
                onEditSong:         { appState.editTrack = $0 },
                onPostSong:         { appState.postTrack = $0 },
                onDragTracksChanged: { appState.isDraggingTracks = $0 },
                // On a featured track this opens the other credited artist.
                onGoToArtist:       { appState.openDiscoverArtist(named: $0) },
                onGoToAlbum:        { appState.openDiscoverAlbum(for: $0) },
                onSongRadio:        deps.downloadManager.isConnected
                                    ? { appState.openSongRadio(for: $0) } : nil,
                onOpenArtistLink:   { appState.openDiscoverArtist(named: $0) },
                onOpenAlbumLink:    { appState.openDiscoverAlbum(for: $0) },
                onRemove:           { selection in
                    for track in selection { engine.stopIfPlaying(trackID: track.id) }
                    SupabaseSyncService.allowBulk("user-remove")
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
                // Sized to its rows so the page scrolls, not a nested scroll view.
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
