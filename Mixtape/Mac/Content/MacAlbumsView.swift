// Album grid. Tap opens MacAlbumDetailView; hover shows a play button.

#if os(macOS)
import SwiftUI
import Combine

struct MacAlbumsView: View {

    @Environment(LibraryService.self) private var library
    @Environment(PlaybackEngine.self) private var engine
    @Environment(MacAppState.self) private var appState

    let searchText: String

    private var saved: SavedAlbumsService { .shared }
    @Environment(AppDependencies.self) private var deps

    /// Only albums the user added. See `SavedAlbumsService`.
    /// One key lookup per album: sorting on `savedAt` rebuilt both keys on every comparison.
    private var albums: [Album] {
        library.albums.compactMap { album -> (Album, Date)? in
            guard let at = saved.savedAt(album),
                  !library.downloadedOnly || deps.downloadManager.isFullyDownloaded(album.trackIDs) else { return nil }
            return (album, at)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private let cardMinWidth: CGFloat = 150
    private let cardMaxWidth: CGFloat = 200
    private let gridSpacing:  CGFloat = 16

    private func filtered(_ albums: [Album]) -> [Album] {
        guard !searchText.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)      ||
            $0.artistName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // Built once per pass; the empty checks, grid and subtitle each rebuilt it.
        let albums = self.albums
        let shown = filtered(albums)
        Group {
            if albums.isEmpty {
                MacEmptyLibraryView(context: .albums)
            } else if shown.isEmpty {
                MacNoResultsView(query: searchText, context: "albums")
            } else {
                albumGrid(shown)
            }
        }
        .navigationTitle("Albums")
        .navigationSubtitle(searchText.isEmpty ? "\(albums.count) albums" : "\(shown.count) of \(albums.count) albums")
    }

    // MARK: - Grid

    private func albumGrid(_ albums: [Album]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardMinWidth, maximum: cardMaxWidth),
                                   spacing: gridSpacing)],
                spacing: gridSpacing
            ) {
                ForEach(albums) { album in
                    MacAlbumCard(album: album) {
                        appState.selectedAlbum = album     // routed by MacContentRouter
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .background(MixPageBackground())
    }
}

// MARK: - Album Card

private struct MacAlbumCard: View {
    let album:    Album
    let onSelect: () -> Void          // single tap -> open detail

    @Environment(LibraryService.self) private var library
    @Environment(PlaybackEngine.self) private var engine

    @State private var isHovered = false

    private var albumTracks: [Track] {
        library.tracks(in: album)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkArea
            infoArea
        }
        .contentShape(Rectangle())
        .mixTapAction { onSelect() }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): isHovered = true
            case .ended:     isHovered = false
            }
        }
        .contextMenu { AlbumActionsMenu(album: album) }
    }

    private var artworkArea: some View {
        ZStack(alignment: .bottomTrailing) {
            MacArtworkView(data: album.artworkData, artworkRef: .album(album.id), size: nil, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
                .mixShadow(color: .black.opacity(0.3), radius: 8, y: 4)

            // Plays without navigating.
            if isHovered {
                Button {
                    guard let first = albumTracks.first else { return }
                    Task { await engine.play(track: first, in: albumTracks, source: .named(album.title)) }
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
        .mixAnimation(.easeOut(duration: 0.15), value: isHovered)
        .clipped()
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text(album.artistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
            Text(yearAndCount)
                .font(.system(size: 10))
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private var yearAndCount: String {
        var parts: [String] = []
        if let year = album.year { parts.append("\(year)") }
        let count = albumTracks.count
        parts.append("\(count) \(count == 1 ? "song" : "songs")")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Album Detail View

struct MacAlbumDetailView: View {

    let album: Album

    @Environment(LibraryService.self) private var library
    @Environment(PlaybackEngine.self) private var engine
    @Environment(MacAppState.self) private var appState
    @Environment(AppDependencies.self) private var deps

    @State private var selectedIDs: Set<Track.ID> = []
    /// Album order until a column header is clicked.
    @State private var sort = TrackSort()

    private var tracks: [Track] {
        library.tracks(in: album)
    }

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
        VStack(spacing: 0) {
            albumHeader
            trackList
        }
        .background(MixPageBackground())
        .artworkWash(source: album.artworkData, intensity: 0.72)
        // Warm the top of the album; albums are usually played top-down.
        .task(id: album.id) {
            deps.onlineCoordinator.prefetchResolvable(tracks)
        }
        // Flat page with no NavigationStack, so it carries its own back button.
        .pageBack { appState.selectedAlbum = nil }
    }

    // MARK: - Header

    /// Same hero as a playlist page.
    private var albumHeader: some View {
        let playingHere = tracks.contains { $0.id == engine.queue.currentTrack?.id }
        return DetailHero(eyebrow: "Album",
                          title: album.title,
                          subtitle: album.artistName,
                          subtitleIsProminent: true,
                          metadata: metaLine) { size in
            MacArtworkView(data: album.artworkData,
                           artworkRef: album.trackIDs.first.map { .track($0) } ?? .album(album.id),
                           size: size, cornerRadius: 8)
        } actions: {
            HeroActionBar(isPlaying: playingHere && engine.state.isPlaying,
                          isShuffling: engine.queue.shuffleEnabled,
                          isEmpty: tracks.isEmpty,
                          onPlay: {
                              if playingHere && engine.state.isPlaying { engine.pause() }
                              else if playingHere { engine.resume() }
                              else if let first = engine.queue.shuffleEnabled ? tracks.randomElement() : tracks.first {
                                  Task { await engine.play(track: first, in: tracks, source: .named(album.title)) }
                              }
                          },
                          onShuffle: { engine.queue.setShuffle(!engine.queue.shuffleEnabled) }) {
                AlbumSaveButton(title: album.title, artistName: album.artistName)
                AlbumDownloadButton(ids: album.trackIDs, downloads: deps.downloadManager, library: library)
                ShareHeroButton(.album(album))
                // Same overflow as the iPhone album page and the playlist page.
                Menu { AlbumActionsMenu(album: album, showsShare: false) } label: {
                    HeroCircleLabel(systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain).mixHandCursor()
                .menuIndicator(.hidden)
                .frame(width: 40, height: 40)
                .help("More actions for \u{201C}\(album.title)\u{201D}")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        // Clears the floating back button.
        .padding(.top, 52)
    }

    // MARK: - Track list

    private var trackList: some View {
        NativeTrackTable(
            tracks:             tracks.sorted(by: sort),
            currentTrackID:     engine.queue.currentTrack?.id,
            isPlaying:          engine.state.isPlaying,
            selectedIDs:        $selectedIDs,
            onPlay:             { track, ctx in Task { await engine.play(track: track, in: ctx, source: .named(album.title)) } },
            onPlayNext:         { engine.queue.insertNext($0) },
            onAddToQueue:       { engine.queue.append($0) },
            onGetInfo:          { appState.showInspector(for: $0) },
            onEditMetadata:     { appState.enqueueReview(MetadataReviewItem(editing: $0)) },
            onEditSong:         { appState.editTrack = $0 },
            onPostSong:         { appState.postTrack = $0 },
            onDragTracksChanged: { appState.isDraggingTracks = $0 },

            // No Go to Album here.
            onGoToArtist:       { appState.openDiscoverArtist(named: $0) },
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
            // Rows arrive in album order; headers re-sort through `sort`.
            sort:               $sort,
            // Same row style as a playlist page.
            metrics:            .roomy,
            showsIndex:         true,
            resolvingIDs:       engine.routingTrackIDs
        )
        .background(MixPageBackground())
    }

    // MARK: - Meta

    private var metaLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append("\(year)") }
        let count = tracks.count
        parts.append("\(count) \(count == 1 ? "song" : "songs")")
        let total = tracks.reduce(0) { $0 + $1.duration }
        parts.append(formattedDuration(total))
        return parts.joined(separator: " · ")
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total   = Int(seconds)
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }
}

// MARK: - No Results

private struct MacNoResultsView: View {
    let query:   String
    let context: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No \(context) matching \"\(query)\"")
                .font(.title3).fontWeight(.medium)
                .foregroundStyle(Color.mixTextPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
