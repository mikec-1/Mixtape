// LocalFilesPage.swift
// Mixtape — Features/LocalFiles
//
// The music in the user's watched folders, on both platforms.
//
// Everything on this page is derived from a scan: these songs are not in the
// library and not in the database, so there is nothing here to delete, nothing
// to sync and nothing to go stale. Remove a file from the folder and it leaves
// this list; put it back and it returns.
//
// The one action that crosses over is "Save to Mixtape", which runs the ordinary
// import: a copy into Mixtape's own storage, an `.imported` row, an upload. That
// is the only shape that can reach the phone and the web, because the audio has
// to land somewhere both of them can read.

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
            .confirmationDialog("Save everything to Mixtape?",
                                isPresented: $confirmSaveAll,
                                titleVisibility: .visible) {
                Button("Save \(tracks.count) Songs") { Task { await saveAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mixtape copies these files into its own storage \u{2014} about \(sizeText) \u{2014} so they play on your phone and on the web too. The originals stay where they are.")
            }
    }

    // MARK: - Layout
    //
    // The two platforms lay this out differently for the same reason every other
    // list does: the Mac list is an NSTableView, which scrolls itself, so it
    // can't sit inside a SwiftUI ScrollView without two scroll views fighting
    // over the wheel. iOS keeps the simple scrolling stack.

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
        // iOS only: the Mac window already owns a search field in its top bar,
        // and a second one on the page fights it for the same keystrokes.
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
                // The selection already has "Add to Library" in its right-click
                // menu; this is the same action with a label, so you can see it
                // without going looking for it. Disabled until something is
                // selected rather than hidden, so the row doesn't jump.
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
    /// The same NSTableView every other Mac song list uses. Worth the plumbing:
    /// a watched folder can hold ten thousand files, and a SwiftUI row per song
    /// is exactly the case that table exists to avoid.
    ///
    /// The table is told these rows aren't library songs — `isInLibrary` is
    /// false for all of them and `showsRemoveFromLibrary` is off — so its menu
    /// offers "Add to Library" instead of a Remove that would have nothing to
    /// remove. Everything that outlives the folder saves the file into Mixtape
    /// first; see `save(_:)`.
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
            // A plus, not a heart. A heart claims a song you already have; the
            // question here is whether you want Mixtape to keep a copy at all.
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
            // Everything below this line puts the song somewhere that outlives
            // the folder, so all of it saves the file into Mixtape first.
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

    /// Copies one file into Mixtape and returns the library row's id, or nil if
    /// the import failed. A file that was already imported comes back with the
    /// existing row's id, so adding it to a playlist still does the right thing.
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

    /// Hand the imported song to the same review sheet a dragged-in file gets.
    ///
    /// Saving one song opens the editor on that song; "Save All" runs the loop
    /// and every item lands in the same queue, so the sheet steps through them
    /// as "N of M" exactly like importing a folder of files does.
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
