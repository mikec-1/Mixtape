// Playlists list for macOS. Click to open; right-click to rename or delete.

#if os(macOS)
import SwiftUI

struct MacPlaylistsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies
    /// Observed directly: `deps.visibleSmartPlaylists` reads a nested ObservableObject that doesn't republish.
    @EnvironmentObject private var smartService: SmartPlaylistService

    /// The unfiltered Library also lists saved albums and smart playlists.
    var showPlaylists = true
    var showAlbums = false
    var showSmart  = false
    @ObservedObject private var saved = SavedAlbumsService.shared

    private var albums: [Album] {
        guard showAlbums else { return [] }
        return library.albums.filter { saved.isSaved($0) }
            .sorted { (saved.savedAt($0) ?? .distantPast) > (saved.savedAt($1) ?? .distantPast) }
    }

    // New playlist sheet
    @State private var showNewSheet          = false

    // Join shared playlist sheet
    @State private var showJoinShared        = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if items.isEmpty {
                    MacEmptyLibraryView(context: .playlists)
                } else {
                    playlistList
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationSubtitle("\(library.playlists.count) playlist\(library.playlists.count == 1 ? "" : "s")")
        // Toolbar + button
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showJoinShared = true } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Join Shared Playlist")
            }
            ToolbarItem(placement: .automatic) {
                Button { showNewSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help("New Playlist")
            }
        }
        // Join shared playlist sheet
        .sheet(isPresented: $showJoinShared) {
            JoinSharedPlaylistSheet()
                .environmentObject(deps)
        }
        // New playlist sheet
        .sheet(isPresented: $showNewSheet) {
            PlaylistEditorSheet()
                .environmentObject(deps)
        }
    }

    // MARK: - Ordering

    /// Sorted by `appState.playlistSortOrder` with the same `LibrarySortOrder.sorted(_:)` as the sidebar,
    /// which owns sorting and arranging.
    private var sortedPlaylists: [Playlist] {
        appState.playlistSortOrder.sorted(library.playlists)
    }

    // MARK: - List

    // A plain stack, not a `List`: List's selection chrome fought single-click navigation.
    private var items: [LibraryItem] {
        let all = appState.playlistSortOrder.mixed(showPlaylists ? library.playlists : [], albums: albums,
                                                   smart: showSmart ? deps.visibleSmartPlaylists : [])
        guard library.downloadedOnly else { return all }
        return all.filter {
            switch $0 {
            case .playlist(let p): deps.downloadManager.isFullyDownloaded(p.trackIDs)
            case .album(let a):    deps.downloadManager.isFullyDownloaded(a.trackIDs)
            case .smart(let s):    deps.downloadManager.isFullyDownloaded(deps.smartTrackIDs(s))
            }
        }
    }

    private var playlistList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    switch item {
                    case .playlist(let playlist): row(for: playlist)
                    case .album(let album): albumRow(album)
                    case .smart(let smart): smartRow(smart)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(MixPageBackground())
        .onDisappear { appState.clearDeleteSelection() }
    }

    @ViewBuilder
    private func albumRow(_ album: Album) -> some View {
                    PlaylistRowItem(playlist: Playlist(id: album.id, name: album.title, trackIDs: album.trackIDs,
                                                              sync: SyncMetadata(serverID: nil, status: .localOnly, localModifiedAt: Date(), serverModifiedAt: nil, lastSyncedAt: nil, deviceID: "")),
                                    kind: "Album • \(album.artistName)",
                                    album: album,
                                    onOpen: { appState.selectedAlbum = album })
                        .environmentObject(deps.downloadManager)
                        .contextMenu { AlbumActionsMenu(album: album) }
                
    }

    @ViewBuilder
    private func smartRow(_ smart: SmartPlaylist) -> some View {
        PlaylistRowItem(playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)),
                        kind: "Smart Playlist",
                        onOpen: { appState.showSmartPlaylist(smart) })
            .environmentObject(deps.downloadManager)
            .contextMenu {
                SmartPlaylistActionsMenu(playlist: smart, service: smartService)
            }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        PlaylistRowItem(
            playlist: playlist,
            isSelected: appState.selectedPlaylistIDs.contains(playlist.id),
            // ⌘/⇧ select rows; a plain click still opens the playlist.
            onSelect: { modifiers in
                appState.selectPlaylist(playlist.id,
                                        in: deps.libraryService.playlists.map(\.id),
                                        modifiers: modifiers)
            },
            onContextClick: { appState.contextClickPlaylist(playlist.id) },
            onOpen: {
                appState.clearPlaylistSelection()
                appState.selectedPlaylist = playlist
            }
        )
        .environmentObject(deps.downloadManager)
        // Drag onto the sidebar to add it there. The prefix tells it apart from a track drop.
        .onDrag {
            appState.isDraggingTracks = false
            return NSItemProvider(
                object: MacAppState.playlistDragPayload(playlist.id) as NSString
            )
        }
        .playlistActions(playlist, selection: appState.selectedPlaylistIDs)
    }

}

// MARK: - Row

struct PlaylistRowItem: View {
    let playlist: Playlist
    /// First word of the grey line, e.g. "Smart Playlist".
    var kind = "Playlist"
    /// Album rows dressed as playlists, with no playlist for `PlaylistArtwork` to find a cover on.
    var album: Album? = nil
    /// In the current multi-selection; drawn distinct from hover.
    var isSelected: Bool = false
    /// A modified click: ⌘ toggles this row, ⇧ extends from the anchor.
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// A right-click landed here, before the menu is built.
    var onContextClick: () -> Void = {}
    let onOpen:   () -> Void

    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    /// Injected so the offline badge updates when a download finishes; `deps` doesn't republish it.
    @EnvironmentObject private var downloads: DownloadManager

    @State private var isHovered = false

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    /// Every song is on disk. Reads `downloadedTrackIDs` so the badge stays live.
    private var isFullyDownloaded: Bool {
        downloads.isFullyDownloaded(playlist.trackIDs)
    }

    private var playlistTracks: [Track] {
        playlist.trackIDs.compactMap { id in library.displayTrack(id: id) }
    }

    private var iconBackground: Color  { PlaylistArtwork.background(for: playlist) }

    var body: some View {
        HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(playlist.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isNowPlaying ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if meta.isPinned(playlistID: playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mixPrimary)
                            .rotationEffect(.degrees(45))
                    }
                }
                HStack(spacing: 5) {
                    // Green arrow: fully offline, matching the playlist's own download button.
                    DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads, showsProgress: downloads.isPlaylistOffline(playlist.id))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isNowPlaying {
                NowPlayingBars(isPlaying: engine.state.isPlaying, barWidth: 2, barSpacing: 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.mixPrimary.opacity(0.18)
                                 : (isHovered ? Color.primary.opacity(0.07) : .clear))
        )
        .contentShape(Rectangle())
        .mixTapAction { onOpen() }          // one click enters the playlist
        // ⌘- and ⇧-clicks come from AppKit: SwiftUI drops a plain tap while a modifier is held.
        // The catcher only hit-tests modified left clicks, so everything else stays SwiftUI's.
        .overlay(ModifiedClickCatcher(onClick: onSelect, onRightClick: onContextClick))
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
        .mixAnimation(.easeOut(duration: 0.12), value: isSelected)
        .mixAnimation(.easeInOut(duration: 0.25), value: isNowPlaying)
    }

    private var subtitle: String {
        let count = playlist.trackCount
        return "\(kind) · \(count) song\(count == 1 ? "" : "s")"
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconBackground)
                .frame(width: 48, height: 48)
            // The shared playlist cover, which smart playlists can use too.
            if let album {
                // The first song's cover: Discover albums have no artwork on the album row.
                MacArtworkView(data: album.artworkData,
                               artworkRef: album.trackIDs.first.map { .track($0) } ?? .album(album.id),
                               size: 48, cornerRadius: 6)
            } else {
                PlaylistArtwork(playlist: playlist, size: 48, cornerRadius: 6)
            }

            // Hover play, without opening the playlist.
            if isHovered, !playlist.trackIDs.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 48, height: 48)
                Button {
                    let tracks = playlistTracks
                    guard let first = tracks.first else { return }
                    Task {
                        await engine.play(track: first, in: tracks,
                                          source: .playlist(id: playlist.id, name: playlist.name))
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).mixHandCursor()
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(width: 48, height: 48)
        .mixShadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}


#endif
