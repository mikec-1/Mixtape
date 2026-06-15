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

    // New playlist sheet
    @State private var showNewSheet          = false

    // Edit playlist sheet
    @State private var editTarget:           Playlist?  = nil

    // Local selection state to require double click for navigation
    @State private var selectedLocalPlaylist: Playlist? = nil

    var body: some View {
        Group {
            if library.playlists.isEmpty {
                MacEmptyLibraryView(context: .playlists)
            } else {
                playlistList
            }
        }
        .navigationTitle("Playlists")
        .navigationSubtitle("\(library.playlists.count) playlist\(library.playlists.count == 1 ? "" : "s")")
        // Toolbar + button
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showNewSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help("New Playlist")
            }
        }
        // New playlist sheet
        .sheet(isPresented: $showNewSheet) {
            PlaylistEditorSheet()
                .environmentObject(deps)
        }

        .sheet(item: $editTarget) { playlist in
            PlaylistEditorSheet(editingPlaylist: playlist)
                .environmentObject(deps)
        }
    }

    // MARK: - List

    @ObservedObject private var meta = PlaylistMetadataService.shared

    private var playlistList: some View {
        List(
            deps.libraryService.playlists,
            selection: $selectedLocalPlaylist
        ) { playlist in
            PlaylistRowItem(playlist: playlist)
                .tag(playlist)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    appState.selectedPlaylist = playlist
                }
                .contextMenu {
                    Button(meta.isPinned(playlistID: playlist.id) ? "Unpin Playlist" : "Pin Playlist") {
                        meta.togglePin(playlistID: playlist.id)
                        deps.libraryService.refreshPlaylists()
                    }
                    Button(meta.isInSidebar(playlistID: playlist.id) ? "Remove from Sidebar" : "Add to Sidebar") {
                        meta.toggleSidebar(playlistID: playlist.id)
                    }
                    if !playlist.isSystem {
                        Button("Edit Details…") {
                            editTarget = playlist
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            confirmDelete(playlist)
                        }
                    }
                }
        }
        .listStyle(.inset)
        .onDisappear { appState.clearDeleteSelection() }
        .onAppear {
            selectedLocalPlaylist = appState.selectedPlaylist
        }
        .onChange(of: appState.selectedPlaylist) { _, newValue in
            selectedLocalPlaylist = newValue
        }
    }

    // MARK: - Delete confirmation (macOS NSAlert)

    private func confirmDelete(_ playlist: Playlist) {
        let alert             = NSAlert()
        alert.messageText     = "Delete \"\(playlist.name)\"?"
        alert.informativeText = "This will remove the playlist. Your songs won't be affected."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if appState.selectedPlaylist?.id == playlist.id {
            appState.selectedPlaylist = nil
        }
        deps.libraryService.deletePlaylist(id: playlist.id)
    }
}

// MARK: - Row

private struct PlaylistRowItem: View {
    let playlist: Playlist
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine: PlaybackEngine

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    private var iconName: String {
        if playlist.isAllSongs   { return "music.note.list" }
        if playlist.isFavourites { return "heart.fill" }
        return "music.note.list"
    }

    private var iconColor: Color {
        if playlist.isAllSongs   { return Color.mixPrimary }
        if playlist.isFavourites { return Color.mixPrimary }
        return Color.mixTextTertiary
    }

    private var iconBackground: Color {
        if playlist.isAllSongs   { return Color.mixPrimary.opacity(0.15) }
        if playlist.isFavourites { return Color.mixPrimary.opacity(0.15) }
        return Color.mixSurface
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(iconBackground)
                    .frame(width: 32, height: 32)
                if !playlist.isSystem,
                   let data = playlist.artworkData,
                   let ns   = NSImage(data: data) {
                    Image(nsImage: ns)
                        .resizable().scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(iconColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: playlist.isSystem ? .semibold : .regular))
                        .foregroundStyle(isNowPlaying ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if meta.isPinned(playlistID: playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mixPrimary)
                            .rotationEffect(.degrees(45))
                    }
                }
                Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            if isNowPlaying {
                NowPlayingBars(isPlaying: engine.state.isPlaying, barWidth: 2, barSpacing: 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.vertical, 3)
        .animation(.easeInOut(duration: 0.25), value: isNowPlaying)
    }
}

#endif
