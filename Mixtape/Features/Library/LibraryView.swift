// LibraryView.swift
// Mixtape — Features/Library

import SwiftUI

public struct LibraryView: View {

    @EnvironmentObject private var deps: AppDependencies
    /// Directly: `deps.visibleSmartPlaylists` reads a nested ObservableObject,
    /// which doesn't republish through `deps`.
    @EnvironmentObject private var smartService: SmartPlaylistService
    @StateObject private var vm: LibraryViewModel

    // The + menu, and the sheet it asked for. Two pieces of state rather than
    // one because the chosen sheet can only be presented once the menu has
    // finished dismissing — see `pendingRoute`.
    @State private var showCreateMenu = false
    @State private var pendingRoute: LibraryCreateRoute?
    @State private var activeRoute:  LibraryCreateRoute?

    /// Whether the playlist list is in drag-to-reorder mode. Lives here rather
    /// than in the view model because it describes this screen right now, not
    /// how the person likes their library read.
    @State private var isArranging = false

    /// Programmatic navigation path so cross-tab requests (tapping an artist in
    /// the mini player / now-playing sheet) can push the artist page here.
    @State private var navPath = NavigationPath()

    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    public init(libraryService: LibraryService) {
        _vm = StateObject(wrappedValue: LibraryViewModel(libraryService: libraryService))
    }

    /// Reordering is only offered where a drop has an unambiguous meaning: the
    /// playlist list, unsorted and unfiltered.
    private var canArrange: Bool {
        vm.selectedSection != .smart && vm.selectedSection != .albums && vm.layout == .list && vm.canReorderPlaylists
    }

    public var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    #if os(iOS)
                    // Hand-built rather than a large navigation title: the
                    // avatar belongs on the title's own line, and the pills
                    // below have to scroll away without collapsing it. See
                    // `LibraryHeader`.
                    LibraryHeader(isSearching: $vm.isSearching,
                                  searchText:  $vm.searchText,
                                  onAdd:       { showCreateMenu = true })
                    #endif

                    // Sync and import announce themselves here and nowhere
                    // else: it is this list they are changing, and an
                    // app-wide banner meant every screen carried a caption
                    // about a screen you were not on.
                    LibraryActivityBar(library: deps.libraryService)
                        .mixAnimation(.spring(response: 0.32, dampingFraction: 0.86),
                                      value: deps.libraryService.activity)

                    DownloadStatusBar(downloads: deps.downloadManager)

                    sectionPicker
                        .padding(.horizontal, 16)

                    LibrarySortBar(order: $vm.sortOrder,
                                   layout: $vm.layout,
                                   showsLayoutToggle: vm.selectedSection != .smart,
                                   arranging: $isArranging,
                                   canArrange: canArrange)
                    .onChange(of: canArrange) { _, allowed in
                        // Sorting by name, or opening search, ends the drag
                        // session — there is nothing left to drag against.
                        if !allowed { isArranging = false }
                    }

                    Divider()
                        .background(Color.mixSeparator)

                    contentArea
                }
            }
            .miniPlayerSafeArea()
            #if os(iOS)
            // `LibraryHeader` *is* the title bar here. Leaving the navigation
            // bar visible would draw "Your Library" twice, and hiding only the
            // title would leave an empty bar pushing the header down.
            .navigationBarHidden(true)
            #else
            .navigationTitle("Your Library")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { vm.showImportSheet = true } label: {
                        Image(systemName: MixtapeIcons.importFile)
                            .foregroundStyle(Color.mixTextPrimary)
                    }
                    .accessibilityLabel("Import Songs")
                }
            }
            #endif
            .sheet(isPresented: $vm.showImportSheet) {
                ImportView(importService: deps.importService,
                           spotifyClient: deps.spotifyClient,
                           spotifyImportService: deps.spotifyImportService,
                           spotifyAuth: deps.spotifyAuth)
                    .environmentObject(deps)
            }
            .navigationDestination(for: Album.self)    { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self)   { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0)
                    .environmentObject(deps)
            }
            #if os(iOS)
            // Consume a cross-tab request to open a local artist (set when an
            // artist is tapped in the mini player / now-playing sheet / Home).
            .onChange(of: iosAppState.pendingLibraryArtist) { _, artist in
                guard let artist else { return }
                navPath.append(artist)
                iosAppState.pendingLibraryArtist = nil
            }
            // Same shape, for a playlist picked outside the library — a saved
            // mix opened from Mixtape's profile.
            .onChange(of: iosAppState.pendingLibraryPlaylist) { _, playlist in
                guard let playlist else { return }
                navPath.append(playlist)
                iosAppState.pendingLibraryPlaylist = nil
            }
            #endif
            .task { await vm.load() }
            // The + menu hands back a route and closes; the route is only
            // presented from `onDismiss`, once the menu is actually gone.
            .sheet(isPresented: $showCreateMenu, onDismiss: {
                guard let route = pendingRoute else { return }
                pendingRoute = nil
                if let landing = section(landingFor: route) {
                    vm.selectedSection = landing
                }
                activeRoute = route
            }) {
                LibraryCreateMenu { pendingRoute = $0 }
            }
            .sheet(item: $activeRoute) { route in
                createSheet(for: route)
            }
        }
    }

    // MARK: - Create routes

    @ViewBuilder
    private func createSheet(for route: LibraryCreateRoute) -> some View {
        switch route {
        case .playlist:
            PlaylistEditorSheet()
                .environmentObject(deps)
        case .smartPlaylist:
            SmartPlaylistEditorView(service: deps.smartPlaylistService)
                .environmentObject(deps)
        case .generateMix:
            GenerateMixSheet()
                .environmentObject(deps)
        case .joinShared:
            JoinSharedPlaylistSheet()
                .environmentObject(deps)
        case .importSongs:
            ImportView(importService: deps.importService,
                       spotifyClient: deps.spotifyClient,
                       spotifyImportService: deps.spotifyImportService,
                       spotifyAuth: deps.spotifyAuth)
                .environmentObject(deps)
        }
    }

    /// Move to the section the new thing will land in, so creating it doesn't
    /// finish with the user looking at a page it isn't on.
    private func section(landingFor route: LibraryCreateRoute) -> LibrarySection? {
        switch route {
        case .playlist, .joinShared, .generateMix: return .playlists
        case .smartPlaylist:         return .smart
        case .importSongs:           return nil
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Leads the row and reads as a switch, not a destination: it
                // cuts across every chip after it rather than replacing them.
                SectionChip(title: "Downloaded",
                            icon: MixtapeIcons.download,
                            isSelected: vm.downloadedOnly) {
                    withMixAnimation(.easeInOut(duration: 0.18)) {
                        vm.downloadedOnly.toggle()
                    }
                }

                ForEach(LibrarySection.allCases) { section in
                    SectionChip(
                        title: section.rawValue,
                        isSelected: vm.selectedSection == section
                    ) {
                        withMixAnimation(.easeInOut(duration: 0.18)) {
                            vm.selectedSection = vm.selectedSection == section ? nil : section
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch vm.selectedSection {
        case nil, .playlists:
            let showsAll = vm.selectedSection == nil
            let smart = showsAll ? vm.visibleSmart(deps.visibleSmartPlaylists, ids: deps.smartTrackIDs) : []
            let albums = showsAll ? vm.visibleAlbums : []
            VStack(spacing: 0) {
                // Above everything else, and only when there is one: an invite is
                // the one thing here that expires socially — somebody is waiting
                // on an answer — and it's the surface the invitee looks at when
                // they go hunting for the playlist they were told about.
                PlaylistInviteInbox(horizontalPadding: 16)

                // Only once a watched folder actually has music in it. This is
                // a view over the user's own folders, not a library row, so it
                // sits above the playlists rather than pretending to be one.
                if !deps.localFiles.tracks.isEmpty {
                    LocalFilesLibraryLink(count: deps.localFiles.tracks.count)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                if vm.layout == .grid {
                    PlaylistsGridView(items: vm.sortOrder.mixed(vm.visiblePlaylists, albums: albums, smart: smart))
                } else {
                    PlaylistsListView(playlists: vm.visiblePlaylists,
                                      isArranging: $isArranging,
                                      albums: albums, smart: smart,
                                      mixed: vm.sortOrder == .manual ? nil
                                          : vm.sortOrder.mixed(vm.visiblePlaylists, albums: albums, smart: smart))
                }
            }
        case .smart:
            SmartPlaylistsSection(service: deps.smartPlaylistService,
                                  onCreate: { activeRoute = .smartPlaylist })
                .environmentObject(deps)
        case .albums:
            if vm.layout == .grid {
                AlbumsGridView(albums: vm.visibleAlbums)
            } else {
                PlaylistsListView(playlists: [], isArranging: .constant(false), albums: vm.visibleAlbums, smart: [])
            }
        }
    }
}

// MARK: - Local Files Link

/// The way into `LocalFilesPage` on iOS, where there is no sidebar to hang it
/// off. Appears only when a watched folder has something in it.
private struct LocalFilesLibraryLink: View {
    let count: Int

    var body: some View {
        NavigationLink {
            LocalFilesPage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.mixSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Files")
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(count == 1 ? "1 song on this device" : "\(count) songs on this device")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - Section Chip

private struct SectionChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
            }
                .font(.mixButtonSmall)
                .foregroundStyle(isSelected ? .white : Color.mixTextSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.mixPrimary : Color.mixSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}

// MARK: - Playlists List

private struct PlaylistsListView: View {
    let playlists: [Playlist]
    /// Reordering is an explicit mode: the rows already answer a tap, a swipe
    /// and a long press, and a fourth gesture on top of those would be a
    /// coin toss every time somebody's thumb rested a moment too long.
    @Binding var isArranging: Bool
    /// Saved albums and smart playlists, listed after the playlists in the
    /// unfiltered library.
    var albums: [Album] = []
    var smart: [SmartPlaylist] = []
    /// Set outside Custom Order: everything interleaved by the sort.
    var mixed: [LibraryItem]? = nil
    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var meta = PlaylistMetadataService.shared
    /// A swipe used to be the one delete in the app that asked nothing, which was
    /// fair while it only threw away a list. It now takes songs and downloads
    /// with it, so it asks — and, like every other entry point, says how many.
    @State private var deleteTarget: Playlist? = nil

    /// Pinned first, everything else in the order it arrived.
    ///
    /// `LibraryService` already orders the list this way, but only at the moment
    /// it rebuilds it — and the pins are read from a separate store that may not
    /// have loaded yet on the first pass, which left a pinned playlist sitting
    /// wherever the alphabet put it until something else forced a refresh. A
    /// stable partition here costs nothing and is answered by the same object
    /// the pin control writes to, so it is right immediately and stays right.
    private var ordered: [Playlist] {
        pinnedPlaylists + unpinnedPlaylists
    }

    private var pinnedPlaylists:   [Playlist] { playlists.filter { meta.isPinned(playlistID: $0.id) } }
    private var unpinnedPlaylists: [Playlist] { playlists.filter { !meta.isPinned(playlistID: $0.id) } }

    /// Writes the whole visible sequence back, which is what carries the
    /// arrangement to the Mac — see `LibraryService.setPlaylistOrder`.
    ///
    /// Scoped to the unpinned rows: pinned playlists are drawn in their own
    /// `ForEach` with no `onMove` of their own, so a drag can never leave the
    /// group it started in. It used to be one `ForEach` over the whole list —
    /// dragging a row past the pinned/unpinned boundary looked like it worked
    /// for a frame, then snapped back the moment the list re-sorted, because
    /// pinned playlists always sort first regardless of where the drag left
    /// them. Two groups the drag can't cross means that snap can't happen.
    private func moveUnpinned(from source: IndexSet, to destination: Int) {
        var unpinned = unpinnedPlaylists
        unpinned.move(fromOffsets: source, toOffset: destination)
        deps.libraryService.setPlaylistOrder((pinnedPlaylists + unpinned).map(\.id))
    }

    /// The same move, scoped to the pinned group. Pinned rows are arrangeable
    /// among themselves — the boundary is the only thing a drag can't cross,
    /// not the pin itself — and because each group has its own `ForEach` and
    /// its own `onMove`, neither drag can reach the other's rows.
    private func movePinned(from source: IndexSet, to destination: Int) {
        var pinned = pinnedPlaylists
        pinned.move(fromOffsets: source, toOffset: destination)
        deps.libraryService.setPlaylistOrder((pinned + unpinnedPlaylists).map(\.id))
    }

    /// One row, shared by the pinned and unpinned groups so the two `ForEach`
    /// blocks below stay a list split, not two different rows.
    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        NavigationLink(value: playlist) {
            PlaylistRowView(playlist: playlist)
                // The offline badge tracks downloads as they land, so the row
                // observes the manager itself rather than reading a value
                // through `deps` that wouldn't republish.
                .environmentObject(deps.downloadManager)
        }
        .listRowBackground(Color.mixBackground)
        .listRowSeparatorTint(Color.mixSeparator)
        .swipeActions(edge: .leading) {
            Button {
                meta.togglePin(playlistID: playlist.id)
                deps.libraryService.refreshPlaylists()
            } label: {
                Label(meta.isPinned(playlistID: playlist.id) ? "Unpin" : "Pin", systemImage: meta.isPinned(playlistID: playlist.id) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.mixPrimary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !playlist.isSystem) {
            if !playlist.isSystem {
                Button(role: .destructive) {
                    deleteTarget = playlist
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        // Long-press gets the playlist's whole "…" menu, not a shortened copy
        // of it.
        .playlistActions(playlist)
    }

    @ViewBuilder
    private func albumRow(_ album: Album) -> some View {
                  NavigationLink(value: album) {
                      AlbumRowView(album: album, downloads: deps.downloadManager)
                  }
                  .listRowBackground(Color.mixBackground)
                  .listRowSeparatorTint(Color.mixSeparator)
                  .swipeActions(edge: .trailing) {
                      Button(role: .destructive) {
                          SavedAlbumsService.shared.setSaved(false, title: album.title, artistName: album.artistName)
                      } label: { Label("Remove", systemImage: "minus.circle") }
                  }
                  .moveDisabled(true)
              
    }

    @ViewBuilder
    private func smartRow(_ item: SmartPlaylist) -> some View {
                  NavigationLink {
                      SmartPlaylistDetailView(playlist: item, service: deps.smartPlaylistService)
                          .environmentObject(deps)
                  } label: {
                      PlaylistRowView(playlist: item.asPlaylist(trackIDs: deps.smartTrackIDs(item)),
                                      kind: "Smart Playlist")
                          .environmentObject(deps.downloadManager)
                  }
                  .listRowBackground(Color.mixBackground)
                  .listRowSeparatorTint(Color.mixSeparator)
                  .moveDisabled(true)
              
    }

    /// A thin rule between the pinned group and everything else, shown only
    /// while arranging — the one moment the boundary actually matters to
    /// someone with a thumb on a row.
    private var pinnedBoundary: some View {
        Rectangle()
            .fill(Color.mixPrimary.opacity(0.6))
            .frame(height: 2)
            // A `List` row is generously padded by default, which turned a
            // 2pt rule into a visible gap in the list. The insets are the
            // whole row here, so the boundary sits tight against the rows.
            .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
    }

    var body: some View {
        if playlists.isEmpty && albums.isEmpty && smart.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.playlist,
                title: "Nothing Here Yet",
                subtitle: "Playlists and albums you add show up here. Tap + to create a playlist."
            )
        } else {
            List {
              if let mixed {
                ForEach(mixed) { item in
                  switch item {
                  case .playlist(let playlist): row(for: playlist)
                  case .album(let album): albumRow(album)
                  case .smart(let item): smartRow(item)
                  }
                }
              } else {
              ForEach(pinnedPlaylists) { playlist in
                  row(for: playlist)
              }
              .onMove(perform: movePinned)

              // A pinned playlist's place is decided by pinning it, not by
              // where a drag left it — see `moveUnpinned`. Named rather than
              // just left implicit, so someone mid-drag can see why the list
              // stopped taking their row any higher.
              if isArranging, !pinnedPlaylists.isEmpty, !unpinnedPlaylists.isEmpty {
                  pinnedBoundary
              }

              ForEach(unpinnedPlaylists) { playlist in
                  row(for: playlist)
              }
              .onMove(perform: moveUnpinned)

              ForEach(albums) { albumRow($0) }
              ForEach(smart) { smartRow($0) }
              }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(isArranging ? .active : .inactive))
            #endif
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .mixPullToRefresh(deps)
            .confirmationDialog(
                PlaylistDeletionPrompt.title(name: deleteTarget?.name ?? "",
                                             isReadOnly: deleteTarget?.isEditable == false),
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { playlist in
                Button(PlaylistDeletionPrompt.confirmLabel(isReadOnly: !playlist.isEditable),
                       role: .destructive) {
                    deps.libraryService.deletePlaylist(id: playlist.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { playlist in
                Text(PlaylistDeletionPrompt.message(
                    songCount: deps.libraryService.songCountRemovedWithPlaylist(id: playlist.id),
                    isReadOnly: !playlist.isEditable))
            }
        }
    }
}

// MARK: - Playlists Grid

/// The grid half of the layout toggle.
///
/// A plain `ScrollView` rather than a `List` in grid clothing: the swipe
/// actions the list row carries have no meaning on a tile, and the long-press
/// menu — which does — comes along on its own.
private struct PlaylistsGridView: View {
    let items: [LibraryItem]
    @EnvironmentObject private var deps: AppDependencies

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        if items.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.playlist,
                title: "Nothing Here Yet",
                subtitle: "Your imported songs appear in All Songs. Tap + to create a playlist."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        switch item {
                        case .playlist(let playlist):
                            NavigationLink(value: playlist) {
                                PlaylistGridCell(playlist: playlist)
                                    .environmentObject(deps.downloadManager)
                            }
                            .buttonStyle(.plain).mixHandCursor()
                            .playlistActions(playlist)
                        case .album(let album):
                            NavigationLink(value: album) { AlbumCardView(album: album) }
                                .buttonStyle(.plain).mixHandCursor()
                        case .smart(let smart):
                            NavigationLink {
                                SmartPlaylistDetailView(playlist: smart, service: deps.smartPlaylistService)
                                    .environmentObject(deps)
                            } label: {
                                PlaylistGridCell(playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)))
                                    .environmentObject(deps.downloadManager)
                            }
                            .buttonStyle(.plain).mixHandCursor()
                        }
                    }
                }
                .padding(16)
            }
            .mixPullToRefresh(deps)
        }
    }
}

// MARK: - Albums Grid

private struct AlbumsGridView: View {
    let albums: [Album]

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        if albums.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.album,
                title: "No Albums Yet",
                subtitle: "Open an album and tap + to add it to your library."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Downloaded

/// The songs whose audio is actually on this device — the offline shelf.
///
/// Reads `library.tracks`, not `displayTracks`: the filter those apply *is*
/// this list, and asking for it twice would only mean this section shows
/// nothing whenever the app is online.
struct DownloadedSongsView: View {

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @ObservedObject var downloads: DownloadManager
    var query: String = ""
    /// Drawn inside somebody else's ScrollView (Home) rather than owning the
    /// screen (Library) — two scroll views fighting over one gesture is the
    /// only difference between the two.
    var embedded: Bool = false

    private var tracks: [Track] {
        let ids = downloads.downloadedTrackIDs
        return library.tracks.filter {
            guard ids.contains($0.id) else { return false }
            guard !query.isEmpty else { return true }
            return $0.title.localizedCaseInsensitiveContains(query)
                || $0.artistName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let rows = tracks
        if rows.isEmpty {
            LibraryEmptyState(
                icon: MixtapeIcons.download,
                title: "Nothing Downloaded",
                subtitle: "Download a song, playlist or album and it shows up here — ready to play with no connection."
            )
        } else if embedded {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { track in row(track, in: rows) }
            }
        } else {
            List(rows) { track in
                row(track, in: rows)
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ track: Track, in rows: [Track]) -> some View {
        TrackRowView(track:     track,
                     isCurrent: engine.queue.currentTrack?.id == track.id,
                     isPlaying: engine.state.isPlaying && engine.queue.currentTrack?.id == track.id)
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await engine.play(track: track, in: rows, source: .named("Downloaded")) }
            }
    }
}

// MARK: - Empty State

private struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(subtitle)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Row / Card Views (public — shared with macOS and detail views)

public struct TrackRowView: View {
    let track: Track
    var isCurrent:          Bool      = false
    var isPlaying:          Bool      = false
    /// When non-nil, a heart icon is shown; set to true/false for filled/outline.
    var isFavourited:       Bool?     = nil
    var onToggleFavourite: (() -> Void)? = nil
    var availability:       TrackAvailability = .streamOnly
    /// False when the caller lays out its own trailing columns (the playlist
    /// table's heart + duration), so the row doesn't paint a second one.
    var showsTrailing:      Bool      = true
    /// Non-nil on a page whose songs aren't in the library yet — the trailing
    /// slot then carries the plus / check save control instead of a heart.
    ///
    /// The two say different things. A heart claims a song as a favourite,
    /// which you can only do to a song you have; outside the library the
    /// question is "do I want this at all", and the answer is the same plus /
    /// check every other Discover row shows — including on the songs already
    /// saved, where the filled check *is* the answer. See `SaveToLibraryButton`.
    var onSaveToLibrary: (() -> Void)? = nil
    /// True while the engine is off resolving this song's audio online.
    ///
    /// The wait is real — a search plus a download, several seconds on a phone —
    /// and until this existed the row did nothing at all in the meantime. A tap
    /// that produces no visible change reads as a tap that didn't register, so
    /// people tapped again, which is how the premature "no audio on this device"
    /// error was being provoked in the first place.
    var isResolving:        Bool      = false

    /// A song a shared playlist names that this device has no copy of *and* no
    /// way to go and get one.
    ///
    /// Dimmed and labelled rather than hidden: a collaborative playlist is
    /// supposed to look the same to everyone in it, and a row you can see is a
    /// row you can go and find. It stops reading this way on its own the moment
    /// the real track lands under the same id.
    ///
    /// The origin alone is not the question, which is why this asks
    /// `canResolveAudio`: a share that knows its own title is resolved online
    /// on the way to playing it, so it is an ordinary song that happens to have
    /// no file yet — dimming it would label a row that plays perfectly well as
    /// broken.
    private var isMissing: Bool { !track.canResolveAudio }

    /// Offline, and this one isn't on the device. Greyed the same way a missing
    /// song is — the row stays in the list and says why, rather than vanishing
    /// and leaving a playlist that looks empty for no reason.
    var isOfflineUnavailable: Bool = false

    /// Everything that makes a row look unreachable, whatever the reason.
    private var dimmed: Bool { isMissing || isOfflineUnavailable }

    @Environment(\.mixDensity) private var density

    public var body: some View {
        HStack(spacing: density == .compact ? 10 : 12) {
            // On the cover rather than in the trailing column, which in table mode
            // belongs to the duration and in list mode to the heart — and which is
            // the far side of the row from the thing the user just tapped.
            ZStack {
                ArtworkThumbnail(data: track.artworkData, artworkRef: .track(track.id), size: density.trackArtwork,
                                 cornerRadius: 6, placeholder: MixtapeIcons.track)
                    .opacity(dimmed && !isResolving ? 0.45 : 1)
                if isResolving {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: density.trackArtwork, height: density.trackArtwork)

            VStack(alignment: .leading, spacing: density.trackTitleSpacing) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.mixBodyBold)
                        .foregroundStyle(titleColour)
                        .lineLimit(1)
                    if track.isExplicit { MixExplicitBadge() }
                }

                HStack(spacing: 4) {
                    if isResolving {
                        EmptyView()
                    } else if dimmed {
                        Image(systemName: isMissing ? "questionmark.circle" : "arrow.down.circle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.mixTextTertiary)
                    } else {
                        AvailabilityBadge(availability: availability)
                    }

                    Text(subtitle)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if showsTrailing { trailingControl }
        }
        .padding(.vertical, density.trackRowPadding)
        .contentShape(Rectangle())
    }

    private var titleColour: Color {
        if isCurrent || isResolving { return .mixPrimary }
        return dimmed ? .mixTextTertiary : .mixTextPrimary
    }

    /// The reason is appended to the artist rather than given a badge of its
    /// own: the row is 44pt tall and already carries a number, a heart and a
    /// duration, and a fourth thing competing for the same line reads as
    /// clutter long before it reads as an explanation.
    private var subtitle: String {
        // While it's being fetched, "Not in your library" is both true and
        // useless — it's the sentence that made people give up on a song that was
        // thirty seconds from playing.
        if isResolving { return decorate(track.artistName, with: "Finding audio\u{2026}") }
        if isMissing { return decorate(track.artistName, with: "Not in your library") }
        if isOfflineUnavailable { return decorate(track.artistName, with: "Not downloaded") }
        return track.artistName
    }

    private func decorate(_ artist: String, with note: String) -> String {
        artist.isEmpty ? note : "\(artist) \u{00B7} \(note)"
    }

    @ViewBuilder
    private var trailingControl: some View {
        if let save = onSaveToLibrary {
            SaveToLibraryButton(trackID:  track.id,
                                identity: (track.title, track.artistName, track.duration),
                                size:     15,
                                action:   save)
        } else if let favoured = isFavourited, let toggle = onToggleFavourite {
            Button {
                toggle()
            } label: {
                Image(systemName: favoured ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
        } else if isCurrent {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
                .mixVariableColor(isActive: isPlaying)
        } else {
            Text(track.formattedDuration)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
    }
}

/// Pins a thumbnail to a square when no explicit size was given.
///
/// `.frame(width: nil, height: nil)` is a no-op, so the `size: nil` case had
/// nothing holding the artwork's shape — and the artwork fills (`scaledToFill`),
/// which overflows to cover and then reports the overflowed size upwards. One
/// portrait photo in a grid therefore stretched its whole cell. Sizing with
/// `Color.clear` fixes the footprint first and clips the picture into it.
private struct SquareIfUnsized: ViewModifier {
    let size: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size, height: size)
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { content }
                .clipped()
        }
    }
}

public struct AlbumCardView: View {
    let album: Album
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkThumbnail(data: album.artworkData, artworkRef: album.trackIDs.first.map { .track($0) } ?? .album(album.id), size: nil, cornerRadius: 10, placeholder: MixtapeIcons.album)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text(album.artistName)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
        }
    }
}

/// A saved album in the library list, dressed like a playlist row.
struct AlbumRowView: View {
    let album: Album
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: album.artworkData, artworkRef: album.trackIDs.first.map { .track($0) } ?? .album(album.id), size: 64, cornerRadius: 8, placeholder: MixtapeIcons.album)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    DownloadStateBadge(ids: album.trackIDs, downloads: downloads)
                    Text("Album • \(album.artistName)")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

public struct ArtistRowView: View {
    let artist: Artist
    public var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: artist.artworkData, artworkRef: .artist(artist.id), size: 48, cornerRadius: 24, placeholder: MixtapeIcons.artist)
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("\(artist.trackCount) songs")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
            if artist.isFollowed {
                Image(systemName: MixtapeIcons.checkmark)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
            }
        }
        .padding(.vertical, 4)
    }
}

public struct PlaylistRowView: View {
    let playlist: Playlist
    /// Replaces "Playlist • owner" — the Smart tab says "Smart Playlist".
    var kind: String? = nil
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine:    PlaybackEngine
    @EnvironmentObject private var downloads: DownloadManager

    /// True when every song in the playlist is on disk — on All Songs that
    /// means the whole library is offline. Mirrors the macOS sidebar and the
    /// Playlists page.
    private var isFullyDownloaded: Bool {
        downloads.isFullyDownloaded(playlist.trackIDs)
    }

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    public var body: some View {
        HStack(spacing: 12) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(isNowPlaying ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)

                // The glyphs lead the line rather than trailing the title:
                // pinned and downloaded are facts about the playlist's standing,
                // and they read as a pair with the "Playlist • owner" they
                // qualify. The song count moves to the end of the same line so
                // the row stays two lines tall at the larger artwork size.
                HStack(spacing: 5) {
                    if meta.isPinned(playlistID: playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mixPrimary)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel("Pinned")
                    }
                    DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads)
                    Text("\(kind ?? PlaylistDescriptor.line(playlist)) • \(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isNowPlaying {
                NowPlayingBars(isPlaying: engine.state.isPlaying)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.vertical, 4)
        .mixAnimation(.easeInOut(duration: 0.25), value: isNowPlaying)
    }

    private var playlistArtwork: some View {
        PlaylistArtwork(playlist: playlist, size: 64, cornerRadius: 8)
    }
}

// MARK: - Artwork Thumbnail

public struct ArtworkThumbnail: View {
    let data: Data?
    /// The row this cover belongs to, for rows whose blob the bulk fetch skipped.
    /// Consulted only when `data` is nil — see `ArtworkProvider`.
    var artworkRef: ArtworkRef? = nil
    let size: CGFloat?
    let cornerRadius: CGFloat
    let placeholder: String
    /// Colours for the fallback tile. Defaulted to the neutral pair, so the
    /// only callers that pass them are the ones saying something with it —
    /// Favourites wearing the brand colour it wears everywhere else.
    var placeholderTint: Color = .mixTextTertiary
    var placeholderBackground: Color = .mixSurface2
    /// Artwork that isn't in this library — someone else's published song, in
    /// practice. Consulted only when `data` is nil, so a local copy always wins
    /// and no view that already had its picture starts touching the network.
    var remoteURL: URL? = nil

    /// A cover the caller is already holding — an online track's artwork, an
    /// image the user just picked — needs no fetching and no waiting, so it
    /// goes straight through the synchronous path. Everything else is a row
    /// identity, and rows are what the async loader exists for.
    private var explicit: Image? {
        guard let data, !data.isEmpty else { return nil }
        return mixImage(from: data, displaySize: size)
    }

    /// Nil when this is the online-artwork case above, or when there is nothing
    /// to draw at all.
    private var source: ArtworkSource? {
        guard data == nil || data?.isEmpty == true, let artworkRef else { return nil }
        return .row(artworkRef)
    }

    public var body: some View {
        Group {
            if let explicit {
                explicit.resizable().scaledToFill()
            } else if source != nil {
                AsyncArtworkImage(source: source, size: size) {
                    if let remoteURL {
                        CachedRemoteImage(url: remoteURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            fallback
                        }
                    } else {
                        fallback
                    }
                }
            } else if let remoteURL {
                // `CachedRemoteImage` rather than `AsyncImage`: a grid of cards
                // that all show the same artist opened one download each, and
                // scrolling a row off screen and back re-fetched and re-decoded
                // it. The cache is process-wide and seeded during `init`, so a
                // hit draws on the first frame with no placeholder flash.
                CachedRemoteImage(url: remoteURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .modifier(SquareIfUnsized(size: size))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fallback: some View {
        placeholderBackground
            .overlay(
                Image(systemName: placeholder)
                    .font(.system(size: (size ?? 48) * 0.45))
                    .foregroundStyle(placeholderTint)
            )
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    LibraryView(libraryService: deps.libraryService)
        .environmentObject(deps)
}
