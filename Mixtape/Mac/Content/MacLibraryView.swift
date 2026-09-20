// MacLibraryView.swift
// Mixtape — Mac/Content
//
// Playlists, Songs, Albums and Artists as four tabs of one page.
//
// These were four sidebar rows until the sidebar overhaul. They are all views of
// the same set of records — the same songs grouped by nothing, by release, by
// performer — so four permanent rows spent a quarter of the sidebar restating
// one destination, and pushed the playlists (the thing people actually navigate
// to) below the fold behind a button.
//
// Nothing became unreachable. `MacSidebarItem.songs` and friends still exist and
// still work as destinations: MacContentRouter renders this page and hands the
// matching tab straight to `appState.libraryTab`, so Home's quick links, the
// "Go to Album" menus and the command palette all land exactly where they did.
//
// The tab lives on `MacAppState` rather than in `@State` here for that reason —
// something outside this view needs to be able to set it — and it persists, so
// someone who lives in Albums doesn't land on Playlists every launch.

#if os(macOS)
import SwiftUI

struct MacLibraryView: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var library: LibraryService

    /// The Smart tab's empty state offers to make one; the + menu's copy of this
    /// sheet lives in `MacTopBar`.
    @State private var showSmartEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Each tab keeps its own scroll view and its own padding — they were
            // full pages a moment ago and still are, just reached differently.
            Group {
                switch appState.libraryTab {
                case .all:       MacPlaylistsView(showAlbums: true, showSmart: true)
                case .playlists: MacPlaylistsView()
                // `activeSearchText`, not `searchText`: a query that was typed
                // but never asked for is still sitting in the field, and it must
                // not quietly filter the list you came here to look at.
                case .songs:     MacSongsView(searchText: appState.activeSearchText)
                case .albums:    MacAlbumsView(searchText: appState.activeSearchText)
                case .artists:   MacArtistsView(searchText: appState.activeSearchText)
                // Rows open through the router, same as the Playlists tab.
                case .smart where library.downloadedOnly:
                    MacPlaylistsView(showPlaylists: false, showSmart: true)
                case .smart:
                    SmartPlaylistsSection(service: deps.smartPlaylistService,
                                          onCreate: { showSmartEditor = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(service: deps.smartPlaylistService)
                .environmentObject(deps)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
                .mixTightened()

            HStack(spacing: 8) {
                let dl = library.downloadedOnly
                Button { library.downloadedOnly.toggle() } label: {
                    Label("Downloaded", systemImage: MixtapeIcons.download)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dl ? Color.mixBackground : Color.mixTextPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(dl ? Color.mixPrimary : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).mixHandCursor()

                ForEach([LibraryTab.playlists, .albums, .smart]) { tab in
                    let on = appState.libraryTab == tab
                    Button { appState.libraryTab = on ? .all : tab } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? Color.mixBackground : Color.mixTextPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(on ? Color.mixTextPrimary : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

#endif
