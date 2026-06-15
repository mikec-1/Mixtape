// MacAlbumsView.swift
// Mixtape — Mac/Content
//
// Responsive album grid.
// Single tap on a card → MacAlbumDetailView (track list, stats, play button).
// Hover on artwork → instant-play overlay button.

#if os(macOS)
import SwiftUI

struct MacAlbumsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState

    let searchText: String

    private let cardMinWidth: CGFloat = 150
    private let cardMaxWidth: CGFloat = 200
    private let gridSpacing:  CGFloat = 16

    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return library.albums }
        return library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)      ||
            $0.artistName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if library.albums.isEmpty {
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
            ? "\(library.albums.count) albums"
            : "\(filteredAlbums.count) of \(library.albums.count) albums"
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
                Task { await engine.play(track: first, in: albumTracks) }
            }
            Button("Add to Queue") {
                albumTracks.forEach { engine.queue.append($0) }
            }
        }
    }

    private var artworkArea: some View {
        ZStack(alignment: .bottomTrailing) {
            MacArtworkView(data: album.artworkData, size: nil, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            // Instant-play overlay — fires play, NOT the detail navigation
            if isHovered {
                Button {
                    guard let first = albumTracks.first else { return }
                    Task { await engine.play(track: first, in: albumTracks) }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.mixPrimary)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
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

    var body: some View {
        VStack(spacing: 0) {
            // Back bar — since album detail is rendered flat (no NavigationStack),
            // there is no system back button; we provide our own.
            HStack {
                Button {
                    appState.selectedAlbum = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color.mixPrimary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.mixBackground)

            albumHeader
            Divider()
            trackList
        }
        .background(Color.mixBackground)
    }

    // MARK: - Header

    private var albumHeader: some View {
        HStack(alignment: .top, spacing: 20) {

            MacArtworkView(data: album.artworkData, size: 120, cornerRadius: 10)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)

                Text(album.artistName)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mixPrimary)

                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                    .padding(.top, 2)

                HStack(spacing: 10) {
                    Button {
                        guard let first = tracks.first else { return }
                        Task { await engine.play(track: first, in: tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mixPrimary)
                    .controlSize(.regular)

                    Button {
                        engine.queue.toggleShuffle()
                        guard let first = tracks.randomElement() else { return }
                        Task { await engine.play(track: first, in: tracks) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(20)
        .background(Color.mixBackground)
    }

    // MARK: - Track list

    private var trackList: some View {
        NativeTrackTable(
            tracks:             tracks,
            currentTrackID:     engine.queue.currentTrack?.id,
            isPlaying:          engine.state.isPlaying,
            selectedIDs:        $selectedIDs,
            onPlay:             { track, ctx in Task { await engine.play(track: track, in: ctx) } },
            onPlayNext:         { engine.queue.insertNext($0) },
            onAddToQueue:       { engine.queue.append($0) },
            onGetInfo:          { appState.showInspector(for: $0) },
            onRemove:           { track in
                engine.stopIfPlaying(trackID: track.id)
                deps.libraryService.deleteTrack(id: track.id)
            },
            onToggleFavourite:  { deps.libraryService.toggleFavourite(trackID: $0.id) },
            onAddToPlaylist:    { track, playlistID in
                deps.libraryService.addTrack(id: track.id, toPlaylist: playlistID)
            },
            isFavourited:       { deps.libraryService.isFavourited(trackID: $0) },
            playlists:          deps.libraryService.playlists,
            downloadStatus:     { deps.downloadManager.status(for: $0) },
            onRemoveDownload:   { deps.downloadManager.removeDownload(for: $0) },
            onSaveToDisk:       { macSaveToDisk(track: $0, deps: deps) },
            scale:              appState.uiScale
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
