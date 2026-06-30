// PlaylistDetailView.swift
// Mixtape — Features/Library/Detail

import SwiftUI

public struct PlaylistDetailView: View {

    let playlist: Playlist

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    @Environment(\.dismiss) private var dismiss

    // Rename
    @State private var showRenameAlert   = false
    @State private var renameText        = ""
    // Delete
    @State private var showDeleteConfirm = false
    // Add to Playlist sheet
    @State private var trackForAddToPlaylist: Track? = nil
    // Collaborative share sheet
    @State private var showCollabShare = false

    /// Always fetches the freshest version of this playlist from the live library,
    /// falling back to the captured `let playlist` only if the library hasn't loaded yet.
    private var livePlaylist: Playlist {
        deps.libraryService.playlist(id: playlist.id) ?? playlist
    }

    private var tracks: [Track] {
        livePlaylist.trackIDs.compactMap { deps.libraryService.track(id: $0) }
    }

    private var totalDuration: String {
        let secs = Int(tracks.map(\.duration).reduce(0, +))
        if secs >= 3600 { return "\(secs / 3600) hr \((secs % 3600) / 60) min" }
        return "\(secs / 60) min"
    }

    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Back bar — since playlist detail is rendered flat on macOS (no NavigationStack),
            // we provide our own back button.
            HStack {
                Button {
                    appState.selectedPlaylist = nil
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
            #endif

            // List is required for .swipeActions to fire.
            // The header is embedded as a plain list row with all insets removed.
            List {
            // ── Header (artwork + title + action buttons) ─────────────────────
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.mixBackground)
                .listRowSeparator(.hidden)

            // ── Track rows (or empty state) ────────────────────────────────────
            if tracks.isEmpty {
                emptyState
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    let isSelected = {
                        #if os(macOS)
                        return appState.selectedTrackIDs.contains(track.id)
                        #else
                        return false
                        #endif
                    }()
                    
                    trackRow(track: track, isSelected: isSelected)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground.ignoresSafeArea())
        // Pull the latest shared track list when opening a collaborative playlist.
        // No-op for non-shared playlists.
        .task(id: playlist.id) {
            await PlaylistSharingService.shared.refreshSharedPlaylist(
                localPlaylistID:  playlist.id,
                libraryService:   deps.libraryService
            )
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Share is always available
                    let shareText = tracks.isEmpty
                        ? playlist.name
                        : "\(playlist.name)\n" + tracks.enumerated()
                            .map { "\($0.offset + 1). \($0.element.title) — \($0.element.artistName)" }
                            .joined(separator: "\n")
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    // Rename + Delete only for user-created playlists
                    if !playlist.isSystem {
                        Divider()
                        Button {
                            showCollabShare = true
                        } label: {
                            Label("Share Collaboratively", systemImage: "person.2.wave.2")
                        }
                        Button {
                            renameText = playlist.name
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.mixTextPrimary)
                }
            }
            #else
            // macOS: collaborative share — user-created playlists only
            if !playlist.isSystem {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCollabShare = true
                    } label: {
                        Label("Share Collaboratively", systemImage: "person.2.wave.2")
                    }
                    .help("Share this playlist with a join code")
                }
            }
            // macOS: visible download button — enabled when a track is selected (single-click)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let id    = appState.selectedTrackIDs.first,
                          let track = tracks.first(where: { $0.id == id }) else { return }
                    saveToDisk(track)
                } label: {
                    Label("Save to Disk", systemImage: "arrow.down.circle")
                }
                .disabled(appState.selectedTrackIDs.isEmpty)
                .help("Click a track to select it, then click here to save it to disk")
            }
            #endif
        }
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    deps.libraryService.renamePlaylist(id: playlist.id, newName: trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(playlist.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                deps.libraryService.deletePlaylist(id: playlist.id)
                #if os(macOS)
                appState.selectedPlaylist = nil
                #endif
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the playlist. Your songs won't be affected.")
        }
        // Add to Playlist sheet
        .sheet(item: $trackForAddToPlaylist) { track in
            AddToPlaylistSheet(track: track, sourcePlaylistID: playlist.id)
                .environmentObject(deps)
        }
        // Collaborative share sheet
        .sheet(isPresented: $showCollabShare) {
            ShareCollaborativeSheet(playlist: livePlaylist, tracks: tracks)
                .environmentObject(deps)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            // Artwork or system playlist icon
            if playlist.isFavourites {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.mixPrimary.opacity(0.15))
                        .frame(width: 200, height: 200)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.mixPrimary)
                }
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                .padding(.top, 24)
            } else if playlist.isAllSongs {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.mixPrimary.opacity(0.15))
                        .frame(width: 200, height: 200)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.mixPrimary)
                }
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                .padding(.top, 24)
            } else {
                ArtworkThumbnail(
                    data: tracks.first?.artworkData ?? playlist.artworkData,
                    size: 200,
                    cornerRadius: 14,
                    placeholder: MixtapeIcons.playlist
                )
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                .padding(.top, 24)
            }

            VStack(spacing: 6) {
                Text(playlist.name)
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(.center)

                if let desc = playlist.description, !desc.isEmpty {
                    Text(desc)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                HStack(spacing: 4) {
                    Text("\(livePlaylist.trackCount) song\(livePlaylist.trackCount == 1 ? "" : "s")")
                    if !tracks.isEmpty {
                        Text("·").foregroundStyle(Color.mixTextTertiary)
                        Text(totalDuration)
                    }
                }
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
            }

            actionButtons
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                playAndMark(first)
            } label: {
                Label("Play", systemImage: MixtapeIcons.play)
                    .font(.mixButtonSmall)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mixPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            Button {
                if !engine.queue.shuffleEnabled { engine.queue.toggleShuffle() }
                guard let first = tracks.first else { return }
                playAndMark(first)
            } label: {
                Label("Shuffle", systemImage: MixtapeIcons.shuffle)
                    .font(.mixButtonSmall)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mixSurface)
                    .foregroundStyle(Color.mixTextPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mixSeparator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            Button {
                deps.downloadManager.togglePlaylistOffline(playlist.id)
            } label: {
                let isOffline = deps.downloadManager.isPlaylistOffline(playlist.id)
                Image(systemName: isOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isOffline ? Color.green : Color.mixTextPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.mixSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mixSeparator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let (icon, title, message): (String, String, String) = {
            if playlist.isAllSongs {
                return ("music.note.list",
                        "No Songs Yet",
                        "Import music to fill your library. Every song you add will appear here automatically.")
            } else if playlist.isFavourites {
                return ("heart",
                        "No Favourites Yet",
                        "Tap ♥ on any song to favourite it. Your hearted songs will appear here.")
            } else {
                return (MixtapeIcons.playlist,
                        "Playlist is Empty",
                        "Swipe right on any song and tap \"Add to Playlist\" to add songs here.")
            }
        }()
        return VStack(spacing: 16) {
            Spacer(minLength: 40)
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(message)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func playAndMark(_ track: Track) {
        PlaylistMetadataService.shared.markPlayed(playlistID: playlist.id)
        deps.libraryService.refreshPlaylists()
        // play() resets the source playlist, so mark it after playback starts.
        Task {
            await engine.play(track: track, in: tracks)
            engine.queue.setSourcePlaylist(playlist.id)
        }
    }

    /// Downloads `track` from Supabase (or uses the playback cache) and exports it
    /// to the user's chosen folder with proper filename and embedded ID3 metadata.
    /// On macOS, if no export folder is configured, opens the folder picker first.
    private func saveToDisk(_ track: Track) {
        Task { @MainActor in
            do {
                #if os(macOS)
                if ExportManager.shared.exportURL == nil {
                    let picked: URL? = await withCheckedContinuation { cont in
                        FolderPickerHelper.show { url in cont.resume(returning: url) }
                    }
                    guard let folder = picked else { return }   // user cancelled
                    try ExportManager.shared.setExportURL(folder)
                }
                #endif

                let src: URL
                var tempURL: URL? = nil

                if let cached = deps.fileStorage.localURL(for: track) {
                    src = cached
                } else {
                    let token = deps.authService.accessToken ?? ""
                    let data  = try await deps.fileStorage.downloadRawData(
                        track: track,
                        accessToken: token
                    )
                    let ext = track.file.remoteKey
                        .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
                        ?? "mp3"
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try data.write(to: tmp, options: .atomic)
                    tempURL = tmp
                    src     = tmp
                }

                try ExportManager.shared.export(track: track, from: src)
                if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }
                deps.showToast("Saved \"\(track.title)\"")
            } catch {
                deps.showToast(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(for track: Track) -> some View {
        Button("Play Now") { playAndMark(track) }
        Button("Play Next") { engine.queue.insertNext(track) }
        Button("Add to Queue") { engine.queue.append(track) }
        Divider()
        
        let favoured = deps.libraryService.isFavourited(trackID: track.id)
        Button(favoured ? "Remove from Favourites" : "Add to Favourites") {
            deps.libraryService.toggleFavourite(trackID: track.id)
        }
        
        let targetPlaylists = deps.libraryService.playlists.filter { !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id) }
        if !targetPlaylists.isEmpty {
            Menu("Add to Playlist") {
                ForEach(targetPlaylists) { pl in
                    Button(pl.name) {
                        deps.libraryService.addTrack(id: track.id, toPlaylist: pl.id)
                    }
                }
            }
        }
        Divider()
        Button("Save to Disk", systemImage: "arrow.down.circle") {
            saveToDisk(track)
        }
        if deps.downloadManager.status(for: track.id) != .notDownloaded {
            Button("Remove Download", systemImage: "xmark.circle") {
                deps.downloadManager.removeDownload(for: track.id)
            }
        }
        Divider()
        if playlist.isAllSongs {
            Button("Remove from Library", role: .destructive) {
                engine.stopIfPlaying(trackID: track.id)
                deps.libraryService.deleteTrack(id: track.id)
            }
        } else {
            Button("Remove from Playlist", role: .destructive) {
                deps.libraryService.removeTrack(id: track.id, fromPlaylist: playlist.id)
            }
        }
    }

    @ViewBuilder
    private func trackRow(track: Track, isSelected: Bool) -> some View {
        TrackRowView(
            track:             track,
            isCurrent:         engine.queue.currentTrack?.id == track.id,
            isPlaying:         engine.state.isPlaying,
            isFavourited:      deps.libraryService.isFavourited(trackID: track.id),
            onToggleFavourite: { deps.libraryService.toggleFavourite(trackID: track.id) },
            downloadStatus:    deps.downloadManager.status(for: track.id)
        )
        .listRowBackground(isSelected ? Color.mixPrimary.opacity(0.2) : Color.mixBackground)
        .listRowSeparatorTint(Color.mixSeparator)
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture(count: 2) {
            playAndMark(track)
        }
        .onTapGesture(count: 1) {
            appState.selectedTrackIDs = [track.id]
        }
        #else
        .onTapGesture {
            playAndMark(track)
        }
        #endif
        .contextMenu {
            trackContextMenu(for: track)
        }
        #if os(iOS)
        // ── Swipe left: delete / remove ──────────────────────────
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if playlist.isAllSongs {
                Button(role: .destructive) {
                    engine.stopIfPlaying(trackID: track.id)
                    deps.libraryService.deleteTrack(id: track.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    deps.libraryService.removeTrack(id: track.id, fromPlaylist: playlist.id)
                } label: {
                    Label(
                        playlist.isFavourites ? "Unfavourite" : "Remove",
                        systemImage: playlist.isFavourites ? "heart.slash" : "minus.circle"
                    )
                }
            }
        }
        // ── Swipe right: add to playlist ─────────────────────────
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                trackForAddToPlaylist = track
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .tint(Color.mixPrimary)
        }
        #endif
    }
}

// MARK: - Add to Playlist Sheet

struct AddToPlaylistSheet: View {

    let track: Track
    let sourcePlaylistID: UUID

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    // Show user-created playlists + Favourites (heart state); exclude All Songs (auto-managed)
    private var targetPlaylists: [Playlist] {
        deps.libraryService.playlists.filter {
            $0.id != sourcePlaylistID && !$0.isDeleted && !$0.isAllSongs
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if targetPlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Other Playlists",
                        systemImage: MixtapeIcons.playlist,
                        description: Text("Create a playlist first from Your Library.")
                    )
                } else {
                    ForEach(targetPlaylists) { playlist in
                        Button {
                            deps.libraryService.addTrack(id: track.id, toPlaylist: playlist.id)
                            deps.showToast("\"\(track.title)\" added to \(playlist.name)")
                            dismiss()
                        } label: {
                            PlaylistRowView(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.mixBackground)
                        .listRowSeparatorTint(Color.mixSeparator)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.mixBackground.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.mixTextPrimary)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: Playlist(
            id: Playlist.favouritesID,
            name: "Favourites",
            sync: SyncMetadata(deviceID: "preview")
        ))
        .environmentObject(AppDependencies())
        .environmentObject(PlaybackEngine(
            queue: QueueService(),
            fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
            equalizer: AudioEqualizer()
        ))
    }
}
