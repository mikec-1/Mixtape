// MacSidebarView.swift
// Mixtape — Mac/Sidebar

#if os(macOS)
import SwiftUI

struct MacSidebarView: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var engine:   PlaybackEngine
    @ObservedObject private var meta = PlaylistMetadataService.shared

    @State private var hoveredLibraryItem: MacSidebarItem? = nil
    @State private var hoveredPlaylistID: UUID? = nil

    private func handleLibraryItemDrop(droppedItems: [String], targetItem: MacSidebarItem) -> Bool {
        guard let first = droppedItems.first,
              let sourceItem = MacSidebarItem(rawValue: first),
              let sourceIndex = appState.libraryItems.firstIndex(of: sourceItem),
              let destIndex = appState.libraryItems.firstIndex(of: targetItem)
        else { return false }
        
        if sourceIndex != destIndex {
            withAnimation {
                appState.moveLibraryItem(from: IndexSet(integer: sourceIndex), to: destIndex)
            }
        }
        return true
    }

    private func handlePlaylistDrop(droppedIDs: [String], targetPlaylist: Playlist) -> Bool {
        guard let first = droppedIDs.first,
              let sourceID = UUID(uuidString: first),
              let sourceIndex = meta.sidebarPlaylistIDs.firstIndex(of: sourceID),
              let destIndex = meta.sidebarPlaylistIDs.firstIndex(of: targetPlaylist.id)
        else { return false }
        
        if sourceIndex != destIndex {
            withAnimation {
                meta.moveSidebarPlaylist(from: IndexSet(integer: sourceIndex), to: destIndex)
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Home — standalone, above the (reorderable) Library section.
                    MacSidebarRow(
                        item:       .home,
                        isSelected: appState.selection == .home
                    ) {
                        appState.selection = .home
                        appState.selectedAlbum = nil
                        appState.selectedPlaylist = nil
                    }
                    .padding(.top, 12)

                    // Section header
                    Text("Library")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 4)

                    // Library rows
                    ForEach(appState.libraryItems) { item in
                        VStack(spacing: 0) {
                            if hoveredLibraryItem == item {
                                Rectangle()
                                    .fill(Color.mixPrimary)
                                    .frame(height: 2)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                    .transition(.opacity)
                            }
                            
                            MacSidebarRow(
                                item:       item,
                                isSelected: appState.selection == item
                            ) {
                                appState.selection = item
                            }
                        }
                        .draggable(item.rawValue)
                        .dropDestination(for: String.self) { droppedItems, _ in
                            let result = handleLibraryItemDrop(droppedItems: droppedItems, targetItem: item)
                            hoveredLibraryItem = nil
                            return result
                        } isTargeted: { isTargeted in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isTargeted {
                                    hoveredLibraryItem = item
                                } else if hoveredLibraryItem == item {
                                    hoveredLibraryItem = nil
                                }
                            }
                        }
                    }

                    // Custom playlists section
                    let sidebarPlaylists = meta.sidebarPlaylistIDs.compactMap { id in
                        library.playlists.first(where: { $0.id == id })
                    }
                    if !sidebarPlaylists.isEmpty {
                        Text("Playlists")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.mixTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 4)

                        ForEach(sidebarPlaylists) { playlist in
                            VStack(spacing: 0) {
                                if hoveredPlaylistID == playlist.id {
                                    Rectangle()
                                        .fill(Color.mixPrimary)
                                        .frame(height: 2)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 2)
                                        .transition(.opacity)
                                }
                                
                                MacSidebarPlaylistRow(
                                    playlist: playlist,
                                    isSelected: appState.selectedPlaylist?.id == playlist.id
                                ) {
                                    appState.selectedPlaylist = playlist
                                    appState.selectedAlbum = nil
                                    appState.selection = nil
                                }
                            }
                            .contextMenu {
                                Button("Remove from Sidebar") {
                                    meta.toggleSidebar(playlistID: playlist.id)
                                }
                            }
                            .draggable(playlist.id.uuidString)
                            .dropDestination(for: String.self) { droppedIDs, _ in
                                let result = handlePlaylistDrop(droppedIDs: droppedIDs, targetPlaylist: playlist)
                                hoveredPlaylistID = nil
                                return result
                            } isTargeted: { isTargeted in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isTargeted {
                                        hoveredPlaylistID = playlist.id
                                    } else if hoveredPlaylistID == playlist.id {
                                        hoveredPlaylistID = nil
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Settings at bottom — unchanged
            Divider()
            MacSidebarSettingsButton()
                .environmentObject(appState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("Mixtape")
    }
}

// MARK: - Sidebar Row

/// Custom row that draws its own selection highlight using mixPrimary,
/// bypassing the macOS system accent colour that List(selection:) would apply.
private struct MacSidebarRow: View {

    let item:       MacSidebarItem
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Label(item.title, systemImage: item.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.mixPrimary.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .padding(.horizontal, 8)
                .contentShape(Rectangle())   // full-row hit target
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Button

struct MacSidebarSettingsButton: View {
    @EnvironmentObject var appState: MacAppState

    private var isSelected: Bool { appState.selection == .settings }

    var body: some View {
        Button {
            appState.selection = .settings
        } label: {
            Label("Settings", systemImage: "gear")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.mixPrimary.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}

// MARK: - Sidebar Playlist Row

private struct MacSidebarPlaylistRow: View {
    let playlist:   Playlist
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(playlist.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "music.note.list")
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.mixPrimary.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())   // full-row hit target
        }
        .buttonStyle(.plain)
    }
}

#endif
