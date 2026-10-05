import SwiftUI

public struct LibraryView: View {

    @EnvironmentObject private var deps: AppDependencies
    /// Observed directly: `deps.visibleSmartPlaylists` doesn't republish through `deps`.
    @EnvironmentObject private var smartService: SmartPlaylistService
    @StateObject private var vm: LibraryViewModel

    // The + menu and its chosen sheet. Separate because the sheet waits for the
    // menu to dismiss; see `pendingRoute`.
    @State private var showCreateMenu = false
    @State private var pendingRoute: LibraryCreateRoute?
    @State private var activeRoute:  LibraryCreateRoute?

    /// Drag-to-reorder mode. Screen state, so not in the view model.
    @State private var isArranging = false

    /// Navigation path, so other tabs can push an artist page here.
    @State private var navPath = NavigationPath()

    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    public init(libraryService: LibraryService) {
        _vm = StateObject(wrappedValue: LibraryViewModel(libraryService: libraryService))
    }

    /// Reordering only makes sense in the unsorted, unfiltered playlist list.
    private var canArrange: Bool {
        vm.selectedSection != .smart && vm.selectedSection != .albums && vm.layout == .list && vm.canReorderPlaylists
    }

    public var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                MixPageBackground()

                VStack(spacing: 0) {
                    #if os(iOS)
                    // Hand-built header instead of a large nav title. See `LibraryHeader`.
                    LibraryHeader(isSearching: $vm.isSearching,
                                  searchText:  $vm.searchText,
                                  onAdd:       { showCreateMenu = true })
                    #endif

                    // Sync and import progress, shown on the list they change.
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
                        // Sorting or searching ends the drag session.
                        if !allowed { isArranging = false }
                    }

                    Divider()
                        .background(Color.mixSeparator)

                    contentArea
                }
            }
            .miniPlayerSafeArea()
            #if os(iOS)
            // `LibraryHeader` is the title bar, so hide the nav bar.
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
            .navigationDestination(for: Crate.self) {
                CrateDetailView(crateID: $0.id, library: deps.libraryService)
            }
            #if os(iOS)
            // Open a local artist requested from another tab (mini player, Now Playing, Home).
            .onChange(of: iosAppState.pendingLibraryArtist, initial: true) { _, artist in
                guard let artist else { return }
                navPath.append(artist)
                iosAppState.pendingLibraryArtist = nil
            }
            // Same for a playlist picked elsewhere, like a saved mix.
            .onChange(of: iosAppState.pendingLibraryPlaylist, initial: true) { _, playlist in
                guard let playlist else { return }
                navPath.append(playlist)
                iosAppState.pendingLibraryPlaylist = nil
            }
            .onChange(of: iosAppState.pendingLibraryCrate, initial: true) { _, crate in
                guard let crate else { return }
                navPath.append(crate)
                iosAppState.pendingLibraryCrate = nil
            }
            #endif
            .task { await vm.load() }
            // Present the chosen route only once the menu is gone.
            .sheet(isPresented: $showCreateMenu, onDismiss: {
                guard let route = pendingRoute else { return }
                pendingRoute = nil
                if let landing = section(landingFor: route) {
                    vm.selectedSection = landing
                }
                // A crate only needs a name, asked at the root.
                if route == .crate { CrateService.shared.requestNewCrate(); return }
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
        case .crate:
            EmptyView()
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

    /// Switch to the section the new item lands in.
    private func section(landingFor route: LibraryCreateRoute) -> LibrarySection? {
        switch route {
        case .playlist, .joinShared, .generateMix, .crate: return .playlists
        case .smartPlaylist:         return .smart
        case .importSongs:           return nil
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // First, and styled as a toggle: it filters across the other chips.
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
                // Only once a watched folder has music. It's a view of the user's folders, above the playlists.
                if !deps.localFiles.tracks.isEmpty {
                    LocalFilesLibraryLink(count: deps.localFiles.tracks.count)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                CratesShelf(library: deps.libraryService)

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

/// Entry to `LocalFilesPage` on iOS, which has no sidebar. Only shown when there are files.
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

struct SectionChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: MixFontScale.size(11), weight: .semibold))
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
    /// Explicit mode, since rows already use tap, swipe and long press.
    @Binding var isArranging: Bool
    /// Saved albums and smart playlists, after the playlists in the unfiltered library.
    var albums: [Album] = []
    var smart: [SmartPlaylist] = []
    /// Set outside Custom Order: everything interleaved by the sort.
    var mixed: [LibraryItem]? = nil
    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var meta = PlaylistMetadataService.shared
    /// Swipe-to-delete asks first, with counts, since it removes songs and downloads too.
    @State private var deleteTarget: Playlist? = nil

    /// Pinned first, then the given order. `LibraryService` already sorts this way,
    /// but pins may load later, so partition here too.
    private var ordered: [Playlist] {
        pinnedPlaylists + unpinnedPlaylists
    }

    private var pinnedPlaylists:   [Playlist] { playlists.filter { meta.isPinned(playlistID: $0.id) } }
    private var unpinnedPlaylists: [Playlist] { playlists.filter { !meta.isPinned(playlistID: $0.id) } }

    /// Writes the visible order back, which syncs it to the Mac (see
    /// `LibraryService.setPlaylistOrder`). Pinned rows are a separate `ForEach`, so
    /// a drag can't cross the pinned boundary and snap back.
    private func moveUnpinned(from source: IndexSet, to destination: Int) {
        var unpinned = unpinnedPlaylists
        unpinned.move(fromOffsets: source, toOffset: destination)
        deps.libraryService.setPlaylistOrder((pinnedPlaylists + unpinned).map(\.id))
    }

    /// Same, within the pinned group.
    private func movePinned(from source: IndexSet, to destination: Int) {
        var pinned = pinnedPlaylists
        pinned.move(fromOffsets: source, toOffset: destination)
        deps.libraryService.setPlaylistOrder((pinned + unpinnedPlaylists).map(\.id))
    }

    /// One row for both groups.
    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        NavigationLink(value: playlist) {
            PlaylistRowView(playlist: playlist)
                // The offline badge observes the manager directly; `deps` doesn't republish it.
                .environmentObject(deps.downloadManager)
        }
        .listRowBackground(MixRowBackground())
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
        // Long press gets the full "..." menu.
        .playlistActions(playlist)
    }

    @ViewBuilder
    private func albumRow(_ album: Album) -> some View {
                  NavigationLink(value: album) {
                      AlbumRowView(album: album, downloads: deps.downloadManager)
                  }
                  .listRowBackground(MixRowBackground())
                  .listRowSeparatorTint(Color.mixSeparator)
                  .swipeActions(edge: .trailing) {
                      Button(role: .destructive) {
                          SavedAlbumsService.shared.setSaved(false, title: album.title, artistName: album.artistName)
                      } label: { Label("Remove", systemImage: "minus.circle") }
                  }
                  // Full album menu on long press, like playlists.
                  .contextMenu { AlbumActionsMenu(album: album) }
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
                  .listRowBackground(MixRowBackground())
                  .listRowSeparatorTint(Color.mixSeparator)
                  .contextMenu {
                      SmartPlaylistActionsMenu(playlist: item, service: deps.smartPlaylistService)
                  }
                  .moveDisabled(true)
              
    }

    /// Rule between pinned and unpinned, shown only while arranging.
    private var pinnedBoundary: some View {
        Rectangle()
            .fill(Color.mixPrimary.opacity(0.6))
            .frame(height: 2)
            // Tight insets so the rule doesn't become a gap.
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

              // Explains why a drag won't go above the pinned group. See `moveUnpinned`.
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
            .mixConfirmationDialog(
                PlaylistDeletionPrompt.title(name: deleteTarget?.name ?? "",
                                             isReadOnly: deleteTarget?.isEditable == false),
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { playlist in
                Button(PlaylistDeletionPrompt.confirmLabel(isReadOnly: !playlist.isEditable),
                       role: .destructive) {
                    SupabaseSyncService.allowBulk("delete-playlists")
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

/// The grid layout. A `ScrollView`, not a `List`, since swipe actions mean nothing on tiles.
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

/// Songs with audio on this device. Reads `library.tracks`, not the filtered
/// `displayTracks`, or this would be empty whenever online.
struct DownloadedSongsView: View {

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @ObservedObject var downloads: DownloadManager
    var query: String = ""
    /// Drawn inside another ScrollView (Home) instead of owning the screen.
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
                    .listRowBackground(MixRowBackground())
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

// MARK: - Row / Card Views (public, shared with macOS and detail views)

public struct TrackRowView: View {
    let track: Track
    var isCurrent:          Bool      = false
    var isPlaying:          Bool      = false
    /// When non-nil, a heart icon is shown; set to true/false for filled/outline.
    var isFavourited:       Bool?     = nil
    var onToggleFavourite: (() -> Void)? = nil
    var availability:       TrackAvailability = .streamOnly
    /// False when the caller draws its own trailing columns.
    var showsTrailing:      Bool      = true
    /// Set on pages whose songs aren't in the library: the trailing slot shows the
    /// plus/check save control instead of a heart. See `SaveToLibraryButton`.
    var onSaveToLibrary: (() -> Void)? = nil
    /// The engine is resolving this song online. Shown so the tap visibly registered.
    var isResolving:        Bool      = false

    /// A shared-playlist song this device can't get audio for. Dimmed, not hidden,
    /// so the playlist looks the same to everyone. Uses `canResolveAudio`, since a
    /// share with a title still resolves online and plays fine.
    private var isMissing: Bool { !track.canResolveAudio }

    /// Offline and not downloaded. Greyed like a missing song rather than hidden.
    var isOfflineUnavailable: Bool = false

    /// Everything that makes a row look unreachable, whatever the reason.
    private var dimmed: Bool { isMissing || isOfflineUnavailable }

    @Environment(\.mixDensity) private var density

    public var body: some View {
        HStack(spacing: density == .compact ? 10 : 12) {
            // On the cover, where the user tapped, since the trailing column is taken.
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
                    if track.origin == .edit { MixEditBadge() }
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

    /// The reason is appended to the artist line instead of adding a badge.
    private var subtitle: String {
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

/// Keeps a thumbnail square when no size is given; otherwise `scaledToFill`
/// reports its overflowed size and a portrait image stretches the cell.
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
    /// Replaces "Playlist • owner", e.g. "Smart Playlist".
    var kind: String? = nil
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @EnvironmentObject private var engine:    PlaybackEngine
    @EnvironmentObject private var downloads: DownloadManager

    /// Every song is on disk (the whole library, for All Songs). Mirrors the macOS
    /// sidebar and Playlists page.
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

                // Pinned and downloaded glyphs lead the subtitle; the song count goes at the end.
                HStack(spacing: 5) {
                    if meta.isPinned(playlistID: playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mixPrimary)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel("Pinned")
                    }
                    DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads, showsProgress: downloads.isPlaylistOffline(playlist.id))
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
    /// The row this cover belongs to, used when `data` is nil. See `ArtworkProvider`.
    var artworkRef: ArtworkRef? = nil
    let size: CGFloat?
    let cornerRadius: CGFloat
    let placeholder: String
    /// Fallback tile colours. Only Favourites overrides them, with the brand colour.
    var placeholderTint: Color = .mixTextTertiary
    var placeholderBackground: Color = .mixSurface2
    /// Artwork not in the library (e.g. someone else's song). Only used when `data`
    /// is nil, so a local copy always wins.
    var remoteURL: URL? = nil

    /// Artwork the caller already has draws synchronously; row ids go through the async loader.
    private var explicit: Image? {
        guard let data, !data.isEmpty else { return nil }
        return mixImage(from: data, displaySize: size)
    }

    /// Nil for the online-artwork case above, or with nothing to draw.
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
                // `CachedRemoteImage`, not `AsyncImage`: one download per URL, and a cache hit
                // draws on the first frame.
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
