// MacSongsView.swift
// Mixtape — Mac/Content
//
// Songs list — backed by NativeTrackTable (NSTableView) for smooth
// scrolling at any library size. Sort state lives inside the AppKit coordinator;
// this view only owns the filter and selection bindings.

#if os(macOS)
import SwiftUI

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

    private var filteredTracks: [Track] {
        guard !searchText.isEmpty else { return library.tracks }
        return library.tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(searchText)      ||
            track.artistName.localizedCaseInsensitiveContains(searchText) ||
            track.albumTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Body

    var body: some View {
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
                    onPlay:              { track, ctx in Task { await engine.play(track: track, in: ctx) } },
                    onPlayNext:          { engine.queue.insertNext($0) },
                    onAddToQueue:        { engine.queue.append($0) },
                    onGetInfo:           { appState.showInspector(for: $0) },
                    onRemove:            { track in
                        engine.stopIfPlaying(trackID: track.id)
                        deps.libraryService.deleteTrack(id: track.id)
                    },
                    onToggleFavourite:   { deps.libraryService.toggleFavourite(trackID: $0.id) },
                    onAddToPlaylist:     { track, playlistID in
                        deps.libraryService.addTrack(id: track.id, toPlaylist: playlistID)
                    },
                    onMoveToArtistFolder: { track in
                        moveArtistNewName = ImportService.primaryArtistName(from: track.artistName)
                        moveArtistTrack   = track
                    },
                    isFavourited:        { deps.libraryService.isFavourited(trackID: $0) },
                    playlists:           deps.libraryService.playlists,
                    downloadStatus:      { deps.downloadManager.status(for: $0) },
                    onRemoveDownload:    { deps.downloadManager.removeDownload(for: $0) },
                    onSaveToDisk:        { macSaveToDisk(track: $0, deps: deps) },
                    scale:               appState.uiScale
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
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Move to Artist Folder")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                
                HStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                    Text("·")
                        .foregroundStyle(Color.mixTextTertiary)
                    Text(track.artistName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Current location status card
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.mixPrimary.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixPrimary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Location")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .tracking(0.5)
                        .textCase(.uppercase)
                    
                    Text(currentPrimary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                
                Spacer()
                
                Text("Assigned")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.mixPrimary.opacity(0.1), in: Capsule())
            }
            .padding(14)
            .background(Color.mixSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            // Search bar input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
                
                TextField("Search or type new artist...", text: $searchText)
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
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // Scrollable list of artists
            ScrollView {
                LazyVStack(spacing: 0) {
                    // New artist creation row
                    if showCreateOption {
                        let newName = searchText.trimmingCharacters(in: .whitespaces)
                        artistRow(name: newName, trackCount: 0, isNew: true, isSelected: selectedArtistName == newName) {
                            selectedArtistName = newName
                        }
                        Divider().padding(.horizontal, 24)
                    }
                    
                    ForEach(filteredArtists) { artist in
                        artistRow(
                            name: artist.name,
                            trackCount: artist.trackCount,
                            isNew: false,
                            isSelected: selectedArtistName == artist.name,
                            artworkData: artist.artworkData
                        ) {
                            selectedArtistName = artist.name
                        }
                        
                        if artist.id != filteredArtists.last?.id {
                            Divider().padding(.horizontal, 24)
                        }
                    }
                }
            }
            .background(Color.mixBackground)
            
            Divider()
            
            // Footer action buttons
            HStack(spacing: 12) {
                Spacer()
                
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.regular)
                
                Button {
                    onConfirm(selectedArtistName)
                } label: {
                    Text("Move Track")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mixPrimary)
                .controlSize(.regular)
                .disabled(selectedArtistName.trimmingCharacters(in: .whitespaces).isEmpty || selectedArtistName == currentPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.mixSurface)
        }
        .frame(width: 420, height: 500)
        .background(Color.mixBackground)
        .onAppear {
            selectedArtistName = currentPrimary
        }
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
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
            .background(isSelected ? Color.mixPrimary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
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
