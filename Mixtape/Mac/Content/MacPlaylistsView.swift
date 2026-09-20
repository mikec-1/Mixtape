// MacPlaylistsView.swift
// Mixtape — Mac/Content
//
// Playlists list for the macOS app.
// Toolbar "+" creates a new playlist via an alert.
// Clicking a row navigates to PlaylistDetailView.
// Right-click → Delete or Rename.

#if os(macOS)
import SwiftUI

struct MacPlaylistsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies
    /// Directly: `deps.visibleSmartPlaylists` reads a nested ObservableObject,
    /// which doesn't republish through `deps`.
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
            // Outside the empty/non-empty branch below on purpose. A brand-new
            // account is exactly the one most likely to have been invited to
            // something, and putting the card inside `playlistList` would hide it
            // from precisely that person behind the empty-library illustration.
            PlaylistInviteInbox(horizontalPadding: 12)

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

    /// Everything drawn below, already in `appState.playlistSortOrder` — the
    /// same order and the same shared function
    /// (`LibrarySortOrder.sorted(_:)`) the sidebar uses, so this overview can
    /// never show a different order than the sidebar for the same choice.
    /// Sorting and arranging both live in the sidebar now — see
    /// `MacSidebarView` — this page is just a plain read of the result.
    private var sortedPlaylists: [Playlist] {
        appState.playlistSortOrder.sorted(library.playlists)
    }

    // MARK: - List

    // A plain scrolling stack rather than a `List`: `List` insisted on its own
    // selection/inset chrome, and a single click had to fight the row selection
    // before it could navigate. Rows own their hover state and open on one click.
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
        .background(Color.mixBackground)
        .onDisappear { appState.clearDeleteSelection() }
    }

    @ViewBuilder
    private func albumRow(_ album: Album) -> some View {
                    PlaylistRowItem(playlist: Playlist(id: album.id, name: album.title, trackIDs: album.trackIDs,
                                                              sync: SyncMetadata(serverID: nil, status: .localOnly, localModifiedAt: Date(), serverModifiedAt: nil, lastSyncedAt: nil, deviceID: "")),
                                    kind: "Album • \(album.artistName)",
                                    onOpen: { appState.selectedAlbum = album })
                        .environmentObject(deps.downloadManager)
                        .contextMenu {
                            Button("Remove from Library") {
                                saved.setSaved(false, title: album.title, artistName: album.artistName)
                            }
                        }
                
    }

    @ViewBuilder
    private func smartRow(_ smart: SmartPlaylist) -> some View {
                        PlaylistRowItem(playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)),
                                        kind: "Smart Playlist",
                                        onOpen: { appState.showSmartPlaylist(smart) })
                            .environmentObject(deps.downloadManager)
                    
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        PlaylistRowItem(
            playlist: playlist,
            isSelected: appState.selectedPlaylistIDs.contains(playlist.id),
            // ⌘ and ⇧ pick rows; a plain click still opens the
            // playlist, because that is what a single click has
            // always done here and a list you could only enter
            // after deselecting would be worse for the common case.
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
        // Drag a playlist onto the sidebar to move it there in the
        // order — the same gesture as dragging songs onto a sidebar
        // playlist, which is why the payload carries a prefix: those
        // rows are a drop target both for tracks and for playlists.
        // Reordering itself happens in the sidebar now, not here.
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
    /// The first word of the grey line — "Smart Playlist" for the Smart tab.
    var kind = "Playlist"
    /// Whether this row is part of the current multi-selection — the picked
    /// look, distinct from hover, so a selection stays visible once the pointer
    /// moves off it.
    var isSelected: Bool = false
    /// A modified click: ⌘ toggles this row, ⇧ extends from the anchor.
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// A right-click landed here, before the menu is built.
    var onContextClick: () -> Void = {}
    let onOpen:   () -> Void

    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    /// Injected by the parent so the offline badge updates the moment a
    /// download finishes — `deps` alone doesn't republish DownloadManager.
    @EnvironmentObject private var downloads: DownloadManager

    @State private var isHovered = false

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    /// True when every song in the playlist is on disk. Reading
    /// `downloads.downloadedTrackIDs` (not just calling `isPlaylistOffline`)
    /// keeps the badge live as downloads land.
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
                    // The green arrow is the "this playlist is fully offline"
                    // signal, matching the highlighted download button inside
                    // the playlist itself.
                    DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads)
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
        .onTapGesture { onOpen() }          // one click enters the playlist
        // ⌘- and ⇧-clicks come from AppKit instead.
        //
        // SwiftUI drops a plain tap while a modifier key is held, so those
        // clicks reached nothing at all — and declaring `TapGesture()
        // .modifiers(…)` alongside it didn't deliver them either. The catcher
        // makes itself invisible to hit testing for everything except a
        // modified left click, so hover, plain clicks, dragging a playlist to
        // the sidebar and the right-click menu all still belong to SwiftUI.
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
            // The same cover every other playlist surface draws, composed off
            // the render path — and the one a smart playlist can wear too,
            // since it isn't a library row `coverData` could look up.
            PlaylistArtwork(playlist: playlist, size: 48, cornerRadius: 6)

            // Hover play — fires playback without opening the playlist.
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
