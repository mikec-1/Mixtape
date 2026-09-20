// MacAlbumsView.swift
// Mixtape — Mac/Content
//
// Responsive album grid.
// Single tap on a card → MacAlbumDetailView (track list, stats, play button).
// Hover on artwork → instant-play overlay button.

#if os(macOS)
import SwiftUI
import Combine

struct MacAlbumsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState

    let searchText: String

    @ObservedObject private var saved = SavedAlbumsService.shared
    @EnvironmentObject private var deps: AppDependencies

    /// Only albums the user added. See `SavedAlbumsService`.
    private var albums: [Album] {
        library.albums.filter { saved.isSaved($0) && (!library.downloadedOnly || deps.downloadManager.isFullyDownloaded($0.trackIDs)) }
            .sorted { (saved.savedAt($0) ?? .distantPast) > (saved.savedAt($1) ?? .distantPast) }
    }

    private let cardMinWidth: CGFloat = 150
    private let cardMaxWidth: CGFloat = 200
    private let gridSpacing:  CGFloat = 16

    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)      ||
            $0.artistName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                MacEmptyLibraryView(context: .albums)
            } else if filteredAlbums.isEmpty {
                MacNoResultsView(query: searchText, context: "albums")
            } else {
                albumGrid
            }
        }
        .navigationTitle("Albums")
        .navigationSubtitle(subtitle)
    }

    // MARK: - Grid

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardMinWidth, maximum: cardMaxWidth),
                                   spacing: gridSpacing)],
                spacing: gridSpacing
            ) {
                ForEach(filteredAlbums) { album in
                    MacAlbumCard(album: album) {
                        appState.selectedAlbum = album     // routed by MacContentRouter
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground)
    }

    private var subtitle: String {
        searchText.isEmpty
            ? "\(albums.count) albums"
            : "\(filteredAlbums.count) of \(albums.count) albums"
    }
}

// MARK: - Album Card

private struct MacAlbumCard: View {
    let album:    Album
    let onSelect: () -> Void          // single tap → open detail

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var engine:  PlaybackEngine

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
        .onTapGesture { onSelect() }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): isHovered = true
            case .ended:     isHovered = false
            }
        }
        .contextMenu {
            Button("Play Album") {
                guard let first = albumTracks.first else { return }
                Task { await engine.play(track: first, in: albumTracks, source: .named(album.title)) }
            }
            Button("Add to Queue") {
                albumTracks.forEach { engine.queue.append($0) }
            }
        }
    }

    private var artworkArea: some View {
        ZStack(alignment: .bottomTrailing) {
            MacArtworkView(data: album.artworkData, artworkRef: .album(album.id), size: nil, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
                .mixShadow(color: .black.opacity(0.3), radius: 8, y: 4)

            // Instant-play overlay — fires play, NOT the detail navigation
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

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    @State private var selectedIDs: Set<Track.ID> = []

    private var tracks: [Track] {
        library.tracks(in: album)
    }

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
        VStack(spacing: 0) {
            albumHeader
            trackList
        }
        .background(Color.mixBackground)
        .artworkWash(source: album.artworkData, intensity: 0.72)
        // Warm the top of the album while the user is still looking at it — an
        // album is played top-down far more often than not.
        .task(id: album.id) {
            deps.onlineCoordinator.prefetchResolvable(tracks)
        }
        // Album detail is rendered flat (no NavigationStack), so there is no
        // system back button; the page carries its own.
        .pageBack { appState.selectedAlbum = nil }
    }

    // MARK: - Header

    /// Same hero as a playlist page — Spotify's album layout.
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
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        // Clears the floating back control, which sits over this header rather
        // than in a bar above it.
        .padding(.top, 52)
    }

    // MARK: - Track list

    private var trackList: some View {
        NativeTrackTable(
            tracks:             tracks,
            currentTrackID:     engine.queue.currentTrack?.id,
            isPlaying:          engine.state.isPlaying,
            selectedIDs:        $selectedIDs,
            onPlay:             { track, ctx in Task { await engine.play(track: track, in: ctx, source: .named(album.title)) } },
            onPlayNext:         { engine.queue.insertNext($0) },
            onAddToQueue:       { engine.queue.append($0) },
            onGetInfo:          { appState.showInspector(for: $0) },
            onDragTracksChanged: { appState.isDraggingTracks = $0 },

            // No "Go to Album" here — this *is* the album page.
            onGoToArtist:       { appState.openDiscoverArtist(named: $0) },
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
            resolvingIDs:       engine.routingTrackIDs
        )
        .background(Color.mixBackground)
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
