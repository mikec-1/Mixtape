// MacSearchResultsView.swift
// Mixtape — Mac/Content
//
// Unified search results shown whenever the toolbar search field is active.
// MacContentRouter swaps to this view instead of the per-section views so
// the user sees Songs, Albums, and Artists all at once without switching tabs.

#if os(macOS)
import SwiftUI

struct MacSearchResultsView: View {

    let query: String

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState

    // MARK: - Filtered results

    private var matchingTracks: [Track] {
        library.tracks.filter { $0.matches(query) }
    }

    private var matchingAlbums: [Album] {
        library.albums.filter { $0.title.localizedCaseInsensitiveContains(query)
                              || $0.artistName.localizedCaseInsensitiveContains(query) }
    }

    private var matchingArtists: [Artist] {
        library.artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var totalCount: Int { matchingTracks.count + matchingAlbums.count + matchingArtists.count }

    // MARK: - Body

    var body: some View {
        Group {
            if totalCount == 0 {
                emptyState
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(
            totalCount == 0
                ? "No results"
                : "\(totalCount) result\(totalCount == 1 ? "" : "s") for \"\(query)\""
        )
    }

    // MARK: - Results list

    private var resultsList: some View {
        List {
            if !matchingTracks.isEmpty {
                Section {
                    ForEach(matchingTracks) { track in
                        SearchTrackRow(track: track, tracks: matchingTracks)
                    }
                } header: {
                    sectionHeader("Songs", count: matchingTracks.count)
                }
            }

            if !matchingAlbums.isEmpty {
                Section {
                    ForEach(matchingAlbums) { album in
                        SearchAlbumRow(album: album)
                    }
                } header: {
                    sectionHeader("Albums", count: matchingAlbums.count)
                }
            }

            if !matchingArtists.isEmpty {
                Section {
                    ForEach(matchingArtists) { artist in
                        SearchArtistRow(artist: artist)
                    }
                } header: {
                    sectionHeader("Artists", count: matchingArtists.count)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No results for \"\(query)\"")
                .font(.title3).fontWeight(.medium)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Try a different search term.")
                .font(.callout)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mixBackground)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .textCase(nil)
            Text("(\(count))")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
                .textCase(nil)
        }
    }
}

// MARK: - Track Row

private struct SearchTrackRow: View {
    let track:  Track
    let tracks: [Track]

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    private var isCurrent: Bool { engine.queue.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 10) {
            // Artwork
            MacArtworkView(data: track.artworkData, size: 30, cornerRadius: 4)

            // Title + artist
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Now-playing indicator
            if isCurrent && engine.state.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }

            // Duration
            Text(track.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await engine.play(track: track, in: tracks) }
        }
        .contextMenu {
            Button("Play Now")      { Task { await engine.play(track: track, in: tracks) } }
            Button("Play Next")     { engine.queue.insertNext(track) }
            Button("Add to Queue")  { engine.queue.append(track) }
            Divider()
            let favoured = library.isFavourited(trackID: track.id)
            Button(favoured ? "Remove from Favourites" : "Add to Favourites") {
                library.toggleFavourite(trackID: track.id)
            }
            let targetPlaylists = library.playlists.filter { !$0.isAllSongs && !$0.isDeleted }
            if !targetPlaylists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(targetPlaylists) { pl in
                        Button(pl.name) {
                            library.addTrack(id: track.id, toPlaylist: pl.id)
                        }
                    }
                }
            }
            
            if deps.downloadManager.status(for: track.id) != .notDownloaded {
                Divider()
                Button("Remove Download") {
                    deps.downloadManager.removeDownload(for: track.id)
                }
            }
            
            Divider()
            Button("Get Info")      { appState.showInspector(for: track) }
        }
    }
}

// MARK: - Album Row

private struct SearchAlbumRow: View {
    let album: Album

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var engine:  PlaybackEngine

    private var albumTracks: [Track] {
        library.tracks
            .filter { $0.albumTitle == album.title && $0.artistName == album.artistName }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            MacArtworkView(data: album.artworkData, size: 36, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(album.artistName)
                    if let year = album.year {
                        Text("·")
                        Text(String(year))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary)
            }

            Spacer()

            Text("\(albumTracks.count) songs")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let first = albumTracks.first else { return }
            Task { await engine.play(track: first, in: albumTracks) }
        }
        .contextMenu {
            Button("Play Album") {
                guard let first = albumTracks.first else { return }
                Task { await engine.play(track: first, in: albumTracks) }
            }
            Button("Add to Queue") { albumTracks.forEach { engine.queue.append($0) } }
        }
    }
}

// MARK: - Artist Row

private struct SearchArtistRow: View {
    let artist: Artist

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var engine:  PlaybackEngine

    private var artistTracks: [Track] {
        library.tracks.filter { $0.artistName == artist.name }
    }

    private var albumCount: Int {
        Set(artistTracks.map(\.albumTitle)).count
    }

    var body: some View {
        HStack(spacing: 10) {
            // Avatar — artwork or initial circle
            Group {
                if let data = artist.artworkData, let img = Image(data: data) {
                    img.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.mixPrimary.opacity(0.15)
                        Text(String(artist.name.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.mixPrimary)
                    }
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            // Name + counts
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text("\(albumCount) \(albumCount == 1 ? "album" : "albums") · \(artistTracks.count) songs")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let first = artistTracks.first else { return }
            Task { await engine.play(track: first, in: artistTracks) }
        }
        .contextMenu {
            Button("Play All Songs") {
                guard let first = artistTracks.first else { return }
                Task { await engine.play(track: first, in: artistTracks) }
            }
            Button("Add to Queue") { artistTracks.forEach { engine.queue.append($0) } }
        }
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

// MARK: - Image(data:) convenience

private extension Image {
    init?(data: Data) {
        #if os(macOS)
        guard let nsImg = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImg)
        #else
        guard let uiImg = UIImage(data: data) else { return nil }
        self.init(uiImage: uiImg)
        #endif
    }
}

#endif
