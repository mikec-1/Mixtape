// MacSongsView.swift
// Mixtape — Mac/Content
//
// Songs list — backed by NativeTrackTable (NSTableView) for smooth
// scrolling at any library size. Sort state lives inside the AppKit coordinator;
// this view only owns the filter and selection bindings.

#if os(macOS)
import SwiftUI
import Combine

struct MacSongsView: View {

    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    let searchText: String

    // MARK: - Move to Artist Folder sheet

    @State private var moveArtistTrack:   Track? = nil
    @State private var moveArtistNewName: String = ""

    // MARK: - Derived Data

    /// The rows on screen, filtered once per real change.
    ///
    /// Read twice in `body` — once to decide whether to show the no-results
    /// view, once to hand to the table — and `body` runs for reasons that have
    /// nothing to do with either input.
    @State private var searchMemo = SearchMemo()

    private final class SearchMemo {
        private var revision: UInt64 = .max
        private var query = "\u{0}"
        private(set) var results: [Track] = []

        func update(revision: UInt64, query: String, tracks: [Track]) {
            guard revision != self.revision || query != self.query else { return }
            self.revision = revision
            self.query = query
            guard !query.isEmpty else { results = tracks; return }
            results = tracks.filter { track in
                track.title.localizedCaseInsensitiveContains(query)      ||
                track.artistName.localizedCaseInsensitiveContains(query) ||
                track.albumTitle.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var filteredTracks: [Track] {
        searchMemo.update(revision: library.revision,
                          query:    searchText,
                          tracks:   library.displayTracks)
        return searchMemo.results
    }

    // MARK: - Body

    /// Bumped whenever the download manager publishes.
    ///
    /// This view reads download state (`status(for:)` and friends) straight off
    /// the manager inside `body`, which is not observation — nothing here holds
    /// the manager, so nothing here hears it change. `AppDependencies` used to
    /// rebroadcast every service's publishes, which covered this by invalidating
    /// all 81 views that hold `deps` on every status transition. The views that
    /// actually draw download state say so themselves now.
    @State private var downloadTick = 0

    var body: some View {
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        Group {
            if library.tracks.isEmpty {
                MacEmptyLibraryView(context: .songs)
            } else if filteredTracks.isEmpty {
                MacNoSearchResultsView(query: searchText)
            } else {
                NativeTrackTable(
                    tracks:              filteredTracks,
                    currentTrackID:      engine.queue.currentTrack?.id,
                    isPlaying:           engine.state.isPlaying,
                    selectedIDs:         Binding(
                        get: { appState.selectedTrackIDs },
                        set: { appState.selectedTrackIDs = $0 }
                    ),
                    onPlay:              { track, ctx in Task { await engine.play(track: track, in: ctx, source: .playlist(id: Playlist.allSongsID, name: "All Songs")) } },
                    onPlayNext:          { engine.queue.insertNext($0) },
                    onAddToQueue:        { engine.queue.append($0) },
                    onGetInfo:           { appState.showInspector(for: $0) },
                    onDragTracksChanged: { appState.isDraggingTracks = $0 },
                    onGoToArtist:        { appState.openDiscoverArtist(named: $0) },
                    onGoToAlbum:         { appState.openDiscoverAlbum(for: $0) },
                    onOpenArtistLink:    { appState.openDiscoverArtist(named: $0) },
                    onOpenAlbumLink:     { appState.openDiscoverAlbum(for: $0) },
                    onRemove:            { selection in
                        for track in selection { engine.stopIfPlaying(trackID: track.id) }
                        deps.libraryService.deleteTracks(ids: selection.map(\.id))
                    },
                    onToggleFavourite:   { deps.toggleFavourite(trackID: $0.id) },
                    onAddToPlaylist:     { selection, playlistID in
                        deps.addTracks(ids: selection.map(\.id), toPlaylist: playlistID)
                    },
                    onMoveToArtistFolder: { track in
                        moveArtistNewName = ImportService.primaryArtistName(from: track.artistName)
                        moveArtistTrack   = track
                    },
                    isFavourited:        { deps.libraryService.isFavourited(trackID: $0) },
                    playlists:           deps.libraryService.playlists,
                    availability:      { deps.downloadManager.status(for: $0) },
                    onDownload:          { deps.downloadManager.download($0) },
                    onRemoveDownload:    { deps.downloadManager.removeDownload(for: $0) },
                    onSaveToDisk:        { macSaveToDisk(tracks: $0, deps: deps) },
                    onLinkCopied:        { deps.showToast(ShareSheet.copiedMessage) },
                    canDownload:         { deps.downloadManager.downloadUnavailableReason(for: $0) == nil },
                    scale:               appState.uiScale,
                    resolvingIDs:        engine.routingTrackIDs
                )
                .background(Color.mixBackground)
            }
        }
        .navigationTitle("Songs")
        .navigationSubtitle(subtitle)
        .onDisappear { appState.clearDeleteSelection() }
        // ── Move to Artist Folder sheet ───────────────────────────────────────
        .sheet(item: $moveArtistTrack) { track in
            MoveToArtistSheet(
                track:          track,
                initialName:    moveArtistNewName,
                existingArtists: library.artists
            ) { chosenName in
                let name = chosenName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { moveArtistTrack = nil; return }
                Task {
                    await deps.importService.moveToArtistFolder(trackID: track.id, newPrimaryArtist: name)
                    await MainActor.run { moveArtistTrack = nil }
                }
            } onCancel: {
                moveArtistTrack = nil
            }
        }
    }

    // MARK: - Helpers

    private var subtitle: String {
        searchText.isEmpty
            ? "\(library.tracks.count) songs"
            : "\(filteredTracks.count) of \(library.tracks.count) songs"
    }
}

// MARK: - Move to Artist Sheet

/// Sheet that lets the user pick or type an artist folder name.
/// Redesigned with a select-then-confirm model showing artist circular avatars and track counts.
private struct MoveToArtistSheet: View {

    let track:           Track
    let initialName:     String
    let existingArtists: [Artist]
    let onConfirm:       (String) -> Void
    let onCancel:        () -> Void

    @State private var searchText: String = ""
    @State private var selectedArtistName: String = ""

    private var currentPrimary: String {
        existingArtists.first(where: { $0.trackIDs.contains(track.id) })?.name
            ?? ImportService.primaryArtistName(from: track.artistName)
    }

    private var filteredArtists: [Artist] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return existingArtists }
        return existingArtists.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var showCreateOption: Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return !existingArtists.contains(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })
    }

    var body: some View {
        // Was a hand-built 420×500 panel: its own title block, its own three
        // Dividers, and its own grey button bar with `.bordered` /
        // `.borderedProminent` system buttons that match nothing else here.
        MixSheet(title: "Move to Artist Folder",
                 subtitle: "\(track.title) \u{2014} \(track.artistName)",
                 size: .large,
                 scroll: false) {
            content
        } footer: {
            actions
        }
        .onAppear { selectedArtistName = currentPrimary }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                currentLocationCard
                searchField
            }
            .padding(.horizontal, MixSheetMetrics.margin)
            .padding(.top, MixSheetMetrics.contentVertical)
            .padding(.bottom, 12)

            MixSheetHairline(visible: true)

            // The list is the sheet's real body, so it scrolls on its own and
            // runs to both edges rather than sitting inside the margins.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showCreateOption {
                        let newName = searchText.trimmingCharacters(in: .whitespaces)
                        artistRow(name: newName,
                                  trackCount: 0,
                                  isNew: true,
                                  isSelected: selectedArtistName == newName) {
                            selectedArtistName = newName
                        }
                    }

                    ForEach(filteredArtists) { artist in
                        artistRow(
                            name: artist.name,
                            trackCount: artist.trackCount,
                            isNew: false,
                            isSelected: selectedArtistName == artist.name,
                            artworkData: artist.displayArtwork
                        ) {
                            selectedArtistName = artist.name
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var currentLocationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.mixPrimary)
                .frame(width: 32, height: 32)
                .background(Color.mixPrimary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT FOLDER")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
                    .tracking(0.6)
                Text(currentPrimary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.mixSurface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)

            TextField("Search, or type a new artist", text: $searchText)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.mixTextPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.mixSurface2,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Cancel is the caller's, not the environment's — this sheet is driven by
    /// an `item:` binding the parent clears.
    private var actions: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixTextSecondary)
                .keyboardShortcut(.cancelAction)

            MixSheetPrimaryButton(
                action: MixSheetAction("Move Song", isEnabled: canMove) {
                    onConfirm(selectedArtistName)
                },
                fullWidth: false
            )
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canMove: Bool {
        let trimmed = selectedArtistName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != currentPrimary
    }

    private func artistRow(
        name: String,
        trackCount: Int,
        isNew: Bool,
        isSelected: Bool,
        artworkData: Data? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                Group {
                    if let data = artworkData, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Circle()
                                .fill(isNew ? Color.mixPrimary.opacity(0.12) : Color.mixSurface2)
                            
                            Image(systemName: isNew ? "plus" : "music.mic")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isNew ? Color.mixPrimary : Color.mixTextTertiary)
                        }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    
                    if isNew {
                        Text("Create new artist folder")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mixPrimary)
                    } else {
                        Text("\(trackCount) song\(trackCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
                
                Spacer()
                
                // Radio Checkbox indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextTertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
            .padding(.horizontal, MixSheetMetrics.margin)
            .background(isSelected ? Color.mixPrimary.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - No Search Results

private struct MacNoSearchResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No results for \"\(query)\"")
                .font(.title3).fontWeight(.medium)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Try a different search term.")
                .font(.callout)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
