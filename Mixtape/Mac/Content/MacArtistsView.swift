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
            } else {
                HStack(spacing: 0) {
                    artistSidebar
                    Divider()
                    rightPanel
                }
            }
        }
        .navigationTitle(selectedArtist?.name ?? "Artists")
        .navigationSubtitle(navSubtitle)
        .onAppear {
            // Pre-select the first artist so the right panel isn't blank on launch.
            if selectedArtistID == nil {
                selectedArtistID = filteredArtists.first?.id
            }
        }
        .onChange(of: library.artists) { _, artists in
            if selectedArtistID == nil {
                selectedArtistID = artists.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var artistSidebar: some View {
        VStack(spacing: 0) {
            if filteredArtists.isEmpty {
                // Empty search results
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.mixTextTertiary)
                    Text("No artists found")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredArtists) { artist in
                            MacArtistSidebarRow(
                                artist:     artist,
                                isSelected: selectedArtistID == artist.id
                            ) {
                                selectedArtistID = artist.id
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color.mixBackground)
        .frame(width: 220)
    }


    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        if let artist = selectedArtist {
            MacArtistDetailPanel(artist: artist)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.mixTextTertiary)
                Text("Select an artist")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
                Text("Choose an artist from the sidebar to see their albums and songs.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Sidebar Row

private struct MacArtistSidebarRow: View {
    let artist:     Artist
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Circular avatar — artwork photo or initial letter
                Group {
                    if let data = artist.artworkData, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Text(String(artist.name.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                isSelected
                                    ? Color.mixPrimary.opacity(0.20)
                                    : Color.mixSurface
                            )
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                Text(artist.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                isSelected ? Color.mixPrimary.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())   // full-row hit target
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artist Detail Panel

private struct MacArtistDetailPanel: View {

    let artist: Artist

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    @State private var selectedIDs: Set<Track.ID> = []
    @State private var isHoveringAvatar = false
    @State private var isRefreshingImage = false

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

    var body: some View {
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
        .background(Color.mixBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)

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
                            Task { await engine.play(track: first, in: artistTracks) }
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.mixPrimary)
                        .controlSize(.regular)
                        .disabled(artistTracks.isEmpty)

                        Button {
                            guard let first = artistTracks.randomElement() else { return }
                            if !engine.queue.shuffleEnabled { engine.queue.toggleShuffle() }
                            Task { await engine.play(track: first, in: artistTracks) }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
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
            if let data = artist.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 28)
                    .scaleEffect(1.08)               // hide white blur-edge fringe
                    .overlay(Color.black.opacity(0.5))
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

    private func refreshImage() async {
        isRefreshingImage = true
        defer { isRefreshingImage = false }
        do {
            try await library.refreshArtistImage(artistID: artist.id)
            deps.showToast("Refreshed profile photo for \(artist.name)")
        } catch {
            deps.showToast("Failed to refresh photo: \(error.localizedDescription)")
        }
    }

    private var artistAvatar: some View {
        Button {
            Task { await refreshImage() }
        } label: {
            ZStack {
                Group {
                    if let data = artist.artworkData, let img = NSImage(data: data) {
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
                
                if isRefreshingImage {
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .overlay {
                            ProgressView().scaleEffect(0.8)
                        }
                } else if isHoveringAvatar {
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .overlay {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.65), radius: 12, y: 4)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHoveringAvatar = hovering
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingImage)
        .help("Click to refresh artist profile image from Deezer")
        .contextMenu {
            Button("Refresh Profile Photo") {
                Task { await refreshImage() }
            }
        }
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
        }
        .frame(maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    MacArtworkView(data: album.artworkData, size: cardSize, cornerRadius: 8)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

                    if isHovered {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.35))
                            .frame(width: cardSize, height: cardSize)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    }
                }
                .animation(.easeInOut(duration: 0.13), value: isHovered)

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
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#endif
