// LibraryView.swift
// Mixtape — Features/Library

import SwiftUI

public struct LibraryView: View {

    @EnvironmentObject private var deps: AppDependencies
    @StateObject private var vm: LibraryViewModel

    @State private var showPlaylistEditorSheet = false
    @State private var showJoinShared = false

    public init(libraryService: LibraryService) {
        _vm = StateObject(wrappedValue: LibraryViewModel(libraryService: libraryService))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    sectionPicker
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    Divider()
                        .background(Color.mixSeparator)

                    contentArea
                }
            }
            .navigationTitle("Your Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                // Import — always accessible
                ToolbarItem(placement: .confirmationAction) {
                    Button { vm.showImportSheet = true } label: {
                        Image(systemName: MixtapeIcons.importFile)
                            .foregroundStyle(Color.mixTextPrimary)
                    }
                }
                // New Playlist — only in the playlists section (macOS has its own + in MacPlaylistsView)
                #if os(iOS)
                if vm.selectedSection == .playlists {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showPlaylistEditorSheet = true } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.mixTextPrimary)
                        }
                    }
                }
                #endif
            }
            .sheet(isPresented: $vm.showImportSheet) {
                ImportView(importService: deps.importService,
                           spotifyClient: deps.spotifyClient,
                           spotifyImportService: deps.spotifyImportService,
                           spotifyAuth: deps.spotifyAuth)
                    .environmentObject(deps)
            }
            .navigationDestination(for: Album.self)    { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self)   { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0)
                    .environmentObject(deps)
            }
            .task { await vm.load() }
            .sheet(isPresented: $showPlaylistEditorSheet) {
                PlaylistEditorSheet()
                    .environmentObject(deps)
            }
            .sheet(isPresented: $showJoinShared) {
                JoinSharedPlaylistSheet()
                    .environmentObject(deps)
            }
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { section in
                    SectionChip(
                        title: section.rawValue,
                        isSelected: vm.selectedSection == section
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            vm.selectedSection = section
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch vm.selectedSection {
        case .playlists:
            VStack(spacing: 0) {
                NavigationLink {
                    SmartPlaylistsView(deps: deps)
                        .environmentObject(deps)
                } label: {
                    SmartPlaylistsEntryRow()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Button {
                    showJoinShared = true
                } label: {
                    JoinSharedEntryRow()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                PlaylistsListView(playlists: vm.playlists)
            }
        case .albums:
            AlbumsGridView(albums: vm.albums)
        case .artists:
            ArtistsListView(artists: vm.artists)
        }
    }
}

// MARK: - Section Chip

private struct SectionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.mixButtonSmall)
                .foregroundStyle(isSelected ? .white : Color.mixTextSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.mixPrimary : Color.mixSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Smart Playlists Entry

private struct SmartPlaylistsEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mixPrimary.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Smart Playlists")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("Auto-updating rule-based playlists")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            Image(systemName: MixtapeIcons.forward)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Join Shared Entry

private struct JoinSharedEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mixPrimary.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Join Shared Playlist")
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("Add a playlist someone shared with a code")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            Image(systemName: MixtapeIcons.forward)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Playlists List

private struct PlaylistsListView: View {
    let playlists: [Playlist]
    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @State private var editTarget: Playlist? = nil

    var body: some View {
        if playlists.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.playlist,
                title: "No Playlists Yet",
                subtitle: "Your imported songs appear in Favourites. Tap + to create a playlist."
            )
        } else {
            List(playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistRowView(playlist: playlist)
                }
                .listRowBackground(Color.mixBackground)
                .listRowSeparatorTint(Color.mixSeparator)
                .swipeActions(edge: .leading) {
                    Button {
                        meta.togglePin(playlistID: playlist.id)
                        deps.libraryService.refreshPlaylists()
                    } label: {
                        Label(meta.isPinned(playlistID: playlist.id) ? "Unpin" : "Pin", systemImage: meta.isPinned(playlistID: playlist.id) ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(.mixPrimary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: !playlist.isSystem) {
                    if !playlist.isSystem {
                        Button(role: .destructive) {
                            deps.libraryService.deletePlaylist(id: playlist.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    Button(meta.isPinned(playlistID: playlist.id) ? "Unpin Playlist" : "Pin Playlist") {
                        meta.togglePin(playlistID: playlist.id)
                        deps.libraryService.refreshPlaylists()
                    }
                    if !playlist.isSystem {
                        Button("Edit Details…") {
                            editTarget = playlist
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deps.libraryService.deletePlaylist(id: playlist.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .sheet(item: $editTarget) { playlist in
                PlaylistEditorSheet(editingPlaylist: playlist)
                    .environmentObject(deps)
            }
        }
    }
}

// MARK: - Albums Grid

private struct AlbumsGridView: View {
    let albums: [Album]

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        if albums.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.album,
                title: "No Albums Yet",
                subtitle: "Albums are built automatically from your imported tracks."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Artists List

private struct ArtistsListView: View {
    let artists: [Artist]

    var body: some View {
        if artists.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.artist,
                title: "No Artists Yet",
                subtitle: "Artist profiles are built from your track metadata."
            )
        } else {
            List(artists) { artist in
                NavigationLink(value: artist) {
                    ArtistRowView(artist: artist)
                }
                .listRowBackground(Color.mixBackground)
                .listRowSeparatorTint(Color.mixSeparator)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Empty State

private struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(subtitle)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Row / Card Views (public — shared with macOS and detail views)

public struct TrackRowView: View {
    let track: Track
    var isCurrent:          Bool      = false
    var isPlaying:          Bool      = false
    /// When non-nil, a heart icon is shown; set to true/false for filled/outline.
    var isFavourited:       Bool?     = nil
    var onToggleFavourite: (() -> Void)? = nil
    var downloadStatus:     DownloadStatus = .notDownloaded

    public var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: track.artworkData, size: 44, cornerRadius: 6, placeholder: MixtapeIcons.track)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    switch downloadStatus {
                    case .downloaded:
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.green)
                    case .downloading:
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.mixPrimary)
                            .symbolEffect(.pulse)
                    case .notDownloaded:
                        EmptyView()
                    }

                    Text(track.artistName)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailingControl
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingControl: some View {
        if let favoured = isFavourited, let toggle = onToggleFavourite {
            Button {
                toggle()
            } label: {
                Image(systemName: favoured ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if isCurrent {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else {
            Text(track.formattedDuration)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }
}

public struct AlbumCardView: View {
    let album: Album
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkThumbnail(data: album.artworkData, size: nil, cornerRadius: 10, placeholder: MixtapeIcons.album)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text(album.artistName)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
        }
    }
}

public struct ArtistRowView: View {
    let artist: Artist
    public var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: artist.artworkData, size: 48, cornerRadius: 24, placeholder: MixtapeIcons.artist)
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("\(artist.trackCount) songs")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            if artist.isFollowed {
                Image(systemName: MixtapeIcons.checkmark)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
            }
        }
        .padding(.vertical, 4)
    }
}

public struct PlaylistRowView: View {
    let playlist: Playlist
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine: PlaybackEngine

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    public var body: some View {
        HStack(spacing: 12) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.mixBodyBold)
                        .foregroundStyle(isNowPlaying ? Color.mixPrimary : Color.mixTextPrimary)
                    if meta.isPinned(playlistID: playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mixPrimary)
                            .rotationEffect(.degrees(45))
                    }
                }
                Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            if isNowPlaying {
                NowPlayingBars(isPlaying: engine.state.isPlaying)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.25), value: isNowPlaying)
    }

    @ViewBuilder
    private var playlistArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    playlist.isAllSongs   ? Color.mixPrimary.opacity(0.15) :
                    playlist.isFavourites ? Color.mixPrimary.opacity(0.15) :
                                           Color.mixSurface2
                )
                .frame(width: 48, height: 48)

            if playlist.isAllSongs {
                Image(systemName: "music.note.list")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)
            } else if playlist.isFavourites {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixPrimary)
            } else if let data = playlist.artworkData,
                      let image = platformImage(from: data) {
                image.resizable().scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: MixtapeIcons.playlist)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #else
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

// MARK: - Artwork Thumbnail

public struct ArtworkThumbnail: View {
    let data: Data?
    let size: CGFloat?
    let cornerRadius: CGFloat
    let placeholder: String

    public var body: some View {
        Group {
            if let data, let image = platformImage(from: data) {
                image.resizable().scaledToFill()
            } else {
                Color.mixSurface2
                    .overlay(
                        Image(systemName: placeholder)
                            .font(.system(size: (size ?? 48) * 0.45))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #else
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    LibraryView(libraryService: deps.libraryService)
        .environmentObject(deps)
}
