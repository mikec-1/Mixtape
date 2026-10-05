// Songs in the user's watched folders. Derived from a scan: not in the library
// or database, so nothing to delete or sync. "Save to Mixtape" runs the normal import.

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct LocalFilesPage: View {

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService

    @State private var searchText = ""
    @State private var savingAll  = false
    @State private var confirmSaveAll = false
    #if os(macOS)
    @State private var selectedIDs: Set<Track.ID> = []
    @State private var savingSelection = false
    @EnvironmentObject private var appState: MacAppState
    #endif
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    public init() {}

    private var tracks: [Track] {
        let all = deps.localFiles.tracks
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artistName.localizedCaseInsensitiveContains(searchText) ||
            $0.albumTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        content
            .onAppear { deps.localFiles.rescan() }
            .mixConfirmationDialog("Save everything to Mixtape?",
                                isPresented: $confirmSaveAll,
                                titleVisibility: .visible) {
                Button("Save \(tracks.count) Songs") { Task { await saveAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mixtape copies these files into its own storage \u{2014} about \(sizeText) \u{2014} so they play on your phone and on the web too. The originals stay where they are.")
            }
    }

    // MARK: - Layout
    // macOS uses the NSTableView, which scrolls itself; iOS keeps a scrolling stack.

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)

            if hasSongs {
                macTable
            } else {
                emptyState
                Spacer()
            }
        }
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header

                if hasSongs {
                    ForEach(tracks) { track in
                        row(track)
                    }
                    .padding(.horizontal, 4)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        // iOS only: the Mac window already has a search field.
        .searchable(text: $searchText, prompt: "Find in local files")
        #endif
    }

    private var hasSongs: Bool { !deps.localFiles.tracks.isEmpty }

    @ViewBuilder
    private var emptyState: some View {
        if deps.watchedFolders.isEmpty {
            EmptyStateView(
                icon: "folder.badge.plus",
                title: "No folders yet",
                message: "Add a folder and the music in it shows up here. Mixtape reads those folders and never writes to them."
            )
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                icon: "folder",
                title: deps.localFiles.isScanning ? "Looking through your folders\u{2026}" : "Nothing found",
                message: deps.localFiles.isScanning
                    ? "This takes a moment the first time."
                    : "There are no audio files in the folders you added."
            )
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Files")
                .font(.mixDisplay)

            Text(subtitle)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)

            HStack(spacing: 10) {
                Button {
                    guard let first = tracks.first else { return }
                    Task { await engine.play(track: first, in: tracks, source: .named("Local Files")) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(tracks.isEmpty)

                #if os(macOS)
                // Same action as the selection's right-click "Add to Library". Disabled rather than hidden so the row doesn't jump.
                Button {
                    Task { await saveSelection() }
                } label: {
                    Label(savingSelection ? "Adding\u{2026}" : selectionButtonTitle,
                          systemImage: "plus.circle")
                }
                .disabled(selectedTracks.isEmpty || savingSelection)
                #endif

                Button {
                    confirmSaveAll = true
                } label: {
                    Label(savingAll ? "Saving…" : "Save All to Mixtape",
                          systemImage: "arrow.down.circle")
                }
                .disabled(tracks.isEmpty || savingAll)

                Button {
                    deps.localFiles.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(deps.localFiles.isScanning)
            }
            .buttonStyle(.bordered).mixHandCursor()
            .padding(.top, 4)
        }
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let folders = deps.watchedFolders.folders.count
        let songs   = deps.localFiles.tracks.count
        if deps.localFiles.isScanning { return "Scanning\u{2026}" }
        guard folders > 0 else { return "Add a folder in Settings to see your own music here." }
        let folderPart = folders == 1 ? "1 folder" : "\(folders) folders"
        let songPart   = songs == 1 ? "1 song" : "\(songs) songs"
        return "\(songPart) in \(folderPart) \u{00B7} played from where they are, never uploaded"
    }

    #if os(macOS)
    /// The songs the table has selected, in the order the page shows them.
    private var selectedTracks: [Track] {
        tracks.filter { selectedIDs.contains($0.id) }
    }

    private var selectionButtonTitle: String {
        let count = selectedTracks.count
        switch count {
        case 0:  return "Add to Library"      // disabled; a count of zero reads as a bug
        case 1:  return "Add Song to Library"
        default: return "Add \(count) Songs to Library"
        }
    }
    #endif

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: deps.localFiles.totalSize, countStyle: .file)
    }

    // MARK: - Rows (macOS)

    #if os(macOS)
    /// The shared Mac song table, since a folder can hold thousands of files. Rows
    /// aren't library songs, so its menu offers "Add to Library" instead of Remove.
    private var macTable: some View {
        NativeTrackTable(
            tracks:         tracks,
            currentTrackID: engine.queue.currentTrack?.id,
            isPlaying:      engine.state.isPlaying,
            selectedIDs:    $selectedIDs,
            onPlay:         { track, ctx in Task { await engine.play(track: track, in: ctx, source: .named("Local Files")) } },
            onPlayNext:     { engine.queue.insertNext($0) },
            onAddToQueue:   { engine.queue.append($0) },
            onGetInfo:      { appState.showInspector(for: $0) },
            onGoToArtist:   nil,
            onGoToAlbum:    nil,
            onOpenArtistLink: { appState.openDiscoverArtist(named: $0) },
            onRemove:       { _ in },
            onToggleFavourite: { track in
                Task {
                    if let id = await save(track) { deps.toggleFavourite(trackID: id) }
                }
            },
            onAddToPlaylist: { selection, playlistID in
                Task {
                    var ids: [UUID] = []
                    for track in selection {
                        if let id = await save(track) { ids.append(id) }
                    }
                    guard !ids.isEmpty else { return }
                    deps.addTracks(ids: ids, toPlaylist: playlistID)
                }
            },
            showsRemoveFromLibrary: false,
            onAddToLibrary: { selection in
                Task { for track in selection { await save(track) } }
            },
            isInLibrary:  { _ in false },
            playlists:    library.playlists.filter(\.isEditable),
            onSaveToDisk: { macSaveToDisk(tracks: $0, deps: deps) },
            onLinkCopied: { deps.showToast(ShareSheet.copiedMessage) },
            resolvingIDs: engine.routingTrackIDs
        )
    }
    #endif

    // MARK: - Rows (iOS)

    #if os(iOS)
    @ViewBuilder
    private func row(_ track: Track) -> some View {
        TrackRowView(
            track:         track,
            isCurrent:     engine.queue.currentTrack?.id == track.id,
            isPlaying:     engine.state.isPlaying && engine.queue.currentTrack?.id == track.id,
            // A plus, not a heart: the question is whether to keep a copy at all.
            onSaveToLibrary: { Task { await save(track) } }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await engine.play(track: track, in: tracks, source: .named("Local Files")) }
        }
        .contextMenu {
            Button("Play")        { Task { await engine.play(track: track, in: tracks, source: .named("Local Files")) } }
            Button("Play Next")   { engine.queue.insertNext(track) }
            Button("Add to Queue") { engine.queue.append(track) }
            Divider()
            // Everything below outlives the folder, so it saves the file into Mixtape first.
            Button("Save to Mixtape") { Task { await save(track) } }
            Button("Add to Liked Songs") {
                Task {
                    if let id = await save(track) { deps.toggleFavourite(trackID: id) }
                }
            }
            Menu("Add to Playlist") {
                ForEach(library.playlists.filter(\.isEditable)) { playlist in
                    Button(playlist.name) {
                        Task {
                            if let id = await save(track) {
                                deps.addTracks(ids: [id], toPlaylist: playlist.id)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: track.file.localPath)]
                )
            }
            #endif
        }
    }

    #endif

    // MARK: - Promotion

    /// Imports one file and returns its library id, or nil on failure. Already-imported files return the existing id.
    @discardableResult
    private func save(_ track: Track) async -> UUID? {
        switch await deps.localFiles.promote(track, using: deps.importService) {
        case .imported(let saved, let review):
            enqueueReview(review)
            return saved.id
        case .duplicate(let existing): return existing.id
        case .failed:                  return nil
        }
    }

    /// Queues the imported song for the same review sheet as a dragged-in file.
    private func enqueueReview(_ review: MetadataReviewItem) {
        #if os(macOS)
        appState.enqueueReview(review)
        #else
        iosAppState.enqueueReview(review)
        #endif
    }

    #if os(macOS)
    private func saveSelection() async {
        savingSelection = true
        for track in selectedTracks { await save(track) }
        savingSelection = false
    }
    #endif

    private func saveAll() async {
        savingAll = true
        for track in tracks {
            await save(track)
        }
        savingAll = false
    }
}
