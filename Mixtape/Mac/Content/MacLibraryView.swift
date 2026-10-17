// Playlists, Songs, Albums and Artists as tabs of one page. `MacSidebarItem.songs` etc. still
// work as destinations and set `appState.libraryTab`, which persists across launches.

#if os(macOS)
import SwiftUI

struct MacLibraryView: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var library: LibraryService

    /// The Smart tab's empty state can open the editor; the + menu's copy lives in `MacTopBar`.
    @State private var showSmartEditor = false
    @Namespace private var tabPill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Each tab keeps its own scroll view and padding.
            Group {
                switch appState.libraryTab {
                case .all:       MacPlaylistsView(showAlbums: true, showSmart: true)
                case .playlists: MacPlaylistsView()
                // `activeSearchText`, so an uncommitted query doesn't filter the list.
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
                            .mixSlidingPill(isSelected: on, in: tabPill,
                                            selected: Color.mixTextPrimary, idle: Color.primary.opacity(0.08))
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
            }
            .mixAnimation(.mixSnappy, value: appState.libraryTab)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

#endif
