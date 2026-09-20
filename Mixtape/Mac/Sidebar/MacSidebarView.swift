// MacSidebarView.swift
// Mixtape — Mac/Sidebar
//
// Three ways into the app, then every playlist you have.
//
// What this replaced, and why
// ---------------------------
// The old sidebar was a set of arrangeable sections: Home and Discover fixed at
// the top, then LIBRARY (Songs / Albums / Artists / Playlists) and PLAYLISTS,
// each foldable, each draggable past the other, with the library rows themselves
// reorderable inside their section.
//
// That was a lot of machinery in service of a shape that had stopped being
// right. Four permanent rows went to slicing the *local* library — a sensible
// centre of gravity when Mixtape was a place to keep files you owned, and no
// longer where the app's weight sits now that most of what people play arrives
// from Discover. Worse, they pushed the playlists below the fold, so the one
// thing anyone actually navigates to had to be reached by clicking "Playlists"
// and drilling into a page. A sidebar whose job is to list things you can go to
// shouldn't hide the list behind a button.
//
// So: Songs / Albums / Artists / Playlists collapsed into one `Library` row (the
// four are tabs inside that page now — see `LibraryTab`), and the space that
// freed goes to the playlists themselves, all of them, drawn directly. The
// folding and section-reordering went with it; with two groups left, one of
// which is three fixed rows, there was nothing left to arrange.
//
// What survived is what people actually did with it: dragging songs onto a
// playlist to add them, and dragging playlists into the order they like.
//
// Collapsing
// ----------
// `appState.sidebarCollapsed` folds this down to `MacSidebarRail`. MacRootView
// cross-fades the two inside one animated width — see `sidebarColumn` there for
// why it's a swap rather than this view at a narrower width.

#if os(macOS)
import SwiftUI
import AppKit

struct MacSidebarView: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var engine:   PlaybackEngine
    /// Observed directly, not through `deps`: a nested ObservableObject's
    /// changes don't reach this view, so adding a rule to the library would
    /// leave the sidebar showing the old list until something else redrew it.
    @EnvironmentObject private var smartService: SmartPlaylistService
    @ObservedObject private var meta = PlaylistMetadataService.shared

    /// Playlist a drag is currently over — draws the insertion line, or the
    /// drop-into highlight when what's being dragged is songs.
    @State private var hoveredPlaylistID: UUID? = nil
    /// Whether a drag is over the empty-state drop zone.
    @State private var emptyZoneTargeted = false

    @State private var showFilter = false
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool

    @State private var showNewPlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: []) {
                    ForEach(MacSidebarItem.primaryItems) { item in
                        MacSidebarRow(item: item, isSelected: isSelected(item)) {
                            select(item)
                        }
                    }

                    // Only once there is something to show. A row for a feature
                    // nobody has set up is a row that only ever disappoints.
                    if !deps.localFiles.tracks.isEmpty {
                        MacSidebarRow(item: .localFiles,
                                      isSelected: isSelected(.localFiles)) {
                            select(.localFiles)
                        }
                    }

                    playlistsHeader
                        .padding(.top, 18)

                    if !library.playlists.isEmpty {
                        playlistsToolbar
                            .onChange(of: canArrangePlaylists) { _, allowed in
                                // Sorting away from Custom Order, or an active
                                // search, ends the drag session — there's
                                // nothing left to drag against.
                                if !allowed { appState.isArrangingPlaylists = false }
                            }
                    }

                    if showFilter { filterField }

                    playlistRows
                }
                .padding(.bottom, 12)
            }
            // Catches a playlist let go over blank space or over the top rows,
            // which own no drop target of their own: it means "put it last".
            .dropDestination(for: String.self) { dropped, _ in
                guard canArrangePlaylists, appState.isArrangingPlaylists else { return false }
                let ids = MacAppState.playlistIDs(fromDrop: dropped)
                guard let id = ids.first else { return false }
                reorder(id, before: nil)
                return true
            }

            // Above Settings rather than under the header: a download run
            // outlives whatever page started it, so it has to sit outside the
            // scroll view — but at the top it pushed the whole sidebar down
            // every time one started. Down here it shares the pinned footer
            // with Settings and nothing above it moves.
            LibraryActivityBar(library: deps.libraryService)
            DownloadStatusBar(downloads: deps.downloadManager)
            OfflineBanner(downloads: deps.downloadManager, auth: deps.authService)

            Divider()
                .padding(.horizontal, 10)

            MacSidebarRow(item: .settings, isSelected: appState.selection == .settings) {
                select(.settings)
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No opaque fill: the column's material behind it gives the
        // translucency every native Mac app has (see `sidebarColumn`).
        .scrollContentBackground(.hidden)
        .navigationTitle("Mixtape")
        .sheet(isPresented: $showNewPlaylist) { PlaylistEditorSheet() }
    }

    // MARK: - Header

    /// A slim strip holding nothing but the collapse control.
    ///
    /// No wordmark, deliberately: MacTopBar already spans the full width of the
    /// window directly above this, so a "Mixtape" here would be a second title
    /// four points below the first one.
    private var header: some View {
        HStack {
            Spacer(minLength: 0)
            MacSidebarIconButton(systemImage: "sidebar.leading",
                                 help: "Collapse Sidebar") {
                appState.toggleSidebar()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Playlists

    /// Every playlist, in `appState.playlistSortOrder`.
    ///
    /// `appState.playlistSortOrder` is the single source both this sidebar and
    /// the Library → Playlists overview draw from — see
    /// `LibrarySortOrder.sorted(_:)` — so the two can never disagree about
    /// what a given sort choice means. In `.manual` this is simply the order
    /// the library publishes: pinned first, then the arrangement the user
    /// dragged (`Playlist.sortIndex`), then everything they never arranged.
    /// That order used to be assembled here out of a local `UserDefaults`
    /// list, which is exactly why the phone showed a different one — it
    /// lives on the playlist rows now and crosses with them.
    private var orderedPlaylists: [Playlist] {
        appState.playlistSortOrder.sorted(library.playlists)
    }

    private var visiblePlaylists: [Playlist] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return orderedPlaylists }
        return orderedPlaylists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var pinnedVisible:   [Playlist] { visiblePlaylists.filter { meta.isPinned(playlistID: $0.id) } }
    private var unpinnedVisible: [Playlist] { visiblePlaylists.filter { !meta.isPinned(playlistID: $0.id) } }

    private var sortOrderBinding: Binding<LibrarySortOrder> {
        Binding(get: { appState.playlistSortOrder }, set: { appState.playlistSortOrder = $0 })
    }

    /// Reordering only means something in the custom order, and only while
    /// nothing is filtering the list out from under the drag.
    private var canArrangePlaylists: Bool {
        appState.playlistSortOrder == .manual
            && filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var playlistsHeader: some View {
        HStack(spacing: 2) {
            Text("Playlists")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
                .textCase(.uppercase)
                .tracking(0.4)

            Spacer(minLength: 0)

            MacSidebarIconButton(systemImage: "plus", help: "New Playlist") {
                showNewPlaylist = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    /// The search-and-sort row, styled after Spotify's own: the current sort
    /// spelled out rather than buried in an icon-only menu, with search
    /// opposite it. Arrange folds in beside search as a third
    /// icon instead of a text pill — the old `LibrarySortBar` reused from the
    /// wider content column read as two competing buttons crammed into 220pt.
    ///
    /// The sort control leads the row: it's the one thing here that names the
    /// state the list is in. Stacked rather than spelled out on one line —
    /// "Sort" over its value, in the same caption the PLAYLISTS header uses —
    /// because "Sort: Recently Added" is a long phrase in a 220pt sidebar, and
    /// at that width it ran at the icons and read as a loose orange label
    /// hanging off the section rather than part of it.
    ///
    /// The search glyph is always drawn. Hiding it under a playlist count made
    /// it look like a control that had gone missing, which is worse than a
    /// button nobody needs on a short list.
    private var playlistsToolbar: some View {
        HStack(spacing: 4) {
            Menu {
                // Flat, not `Picker("Sort by", …)`: a titled picker inside a
                // macOS menu renders as a "Sort by ▸" submenu, putting every
                // order two clicks deep to name the one thing a menu hanging
                // off a control that says "Sort" could possibly be offering.
                Picker("", selection: sortOrderBinding) {
                    ForEach(LibrarySortOrder.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sort")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    HStack(spacing: 3) {
                        Text(appState.playlistSortOrder.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(Color.mixTextSecondary)
                }
                .lineLimit(1)
            }
            // `.borderlessButton` insets its label and tints its own arrow with
            // the accent colour, which is what made this stick out of the
            // section it belongs to — and it draws only the first element of a
            // composed label, so a stack was never going to render under it.
            // The plain style is what the app's other custom menus use.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Sort by \(appState.playlistSortOrder.rawValue)")

            Spacer(minLength: 0)

            MacSidebarIconButton(systemImage: "magnifyingglass",
                                 help: "Search Playlists",
                                 isActive: showFilter) {
                withMixAnimation(.easeOut(duration: 0.16)) { showFilter.toggle() }
                if showFilter {
                    filterFocused = true
                } else {
                    filterText = ""
                }
            }

            if canArrangePlaylists {
                MacSidebarIconButton(systemImage: "checklist",
                                     help: appState.isArrangingPlaylists ? "Done Arranging" : "Arrange",
                                     isActive: appState.isArrangingPlaylists) {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        appState.isArrangingPlaylists.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)

            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onSubmit { filterFocused = false }
                // ⌘⌫ clears the filter instead of reaching past it to the
                // song selection in the content column.
                .mixEditingFocus(filterFocused)

            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var playlistRows: some View {
        if visiblePlaylists.isEmpty, visibleSmart.isEmpty {
            emptyState
        } else {
            ForEach(pinnedVisible) { playlist in row(for: playlist) }

            // A pinned playlist's place is decided by pinning it, not by
            // where a drag left it — `handleDrop` rejects a drop that
            // crosses this boundary. Shown only while arranging, and only
            // when it would actually mark something.
            if appState.isArrangingPlaylists, !pinnedVisible.isEmpty, !unpinnedVisible.isEmpty {
                Rectangle()
                    .fill(Color.mixPrimary.opacity(0.6))
                    .frame(height: 2)
                    .padding(.horizontal, 16)
                    // Sits tight against the two rows it divides: the stack's
                    // own spacing is already the gap, and padding on top of it
                    // read as a hole in the list rather than a boundary.
                    .padding(.vertical, -1)
            }

            ForEach(unpinnedVisible) { playlist in row(for: playlist) }

            // Smart playlists the user added, last: they are rules, not rows,
            // so they take no part in pinning or reordering — but a list you
            // added to your library belongs in the list of your library.
            ForEach(visibleSmart, id: \.id) { smart in
                MacSidebarPlaylistRow(
                    playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)),
                    isSelected: appState.selectedSmartPlaylist?.id == smart.id
                ) {
                    appState.clearPlaylistSelection()
                    appState.showSmartPlaylist(smart)
                }
                .environmentObject(deps.downloadManager)
            }
        }
    }

    /// The added smart playlists, honouring the filter box like everything else
    /// in this list.
    private var visibleSmart: [SmartPlaylist] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let all = deps.visibleSmartPlaylists
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            // A reorder shows an insertion line; a song drag shows a
            // drop-into highlight on the row itself. Same rows, two
            // gestures, and they have to look different or neither
            // reads as having a target at all.
            if hoveredPlaylistID == playlist.id, !appState.isDraggingTracks {
                insertionLine
            }

            MacSidebarPlaylistRow(
                playlist: playlist,
                isSelected: appState.selectedPlaylist?.id == playlist.id,
                isPicked: appState.selectedPlaylistIDs.contains(playlist.id),
                isDropTarget: hoveredPlaylistID == playlist.id
                    && appState.isDraggingTracks
                    && !playlist.isAllSongs,
                // Ranges extend over what the sidebar is actually
                // showing, filter included — shift-clicking two visible
                // rows must not quietly take the hidden ones between.
                onSelect: { modifiers in
                    appState.selectPlaylist(playlist.id,
                                            in: visiblePlaylists.map(\.id),
                                            modifiers: modifiers)
                },
                onContextClick: { appState.contextClickPlaylist(playlist.id) }
            ) {
                appState.clearPlaylistSelection()
                openPlaylist(playlist)
            }
        }
        // The badge tracks downloads as they land, so the row needs the
        // manager itself — a value read once through `deps` would go
        // stale the moment a download finished.
        .environmentObject(deps.downloadManager)
        // Right-click on the row itself: the same list of actions the
        // playlist's own "…" offers, so reaching any of them doesn't
        // mean opening the playlist first.
        .playlistActions(playlist, selection: appState.selectedPlaylistIDs)
        // `.onDrag` rather than `.draggable` so a reorder can clear a
        // stale song-drag flag left behind by a cancelled row drag
        // (which never reaches a drop). Always attached — same as
        // dragging a playlist from the Playlists overview onto the
        // sidebar — but `handleDrop` only honours it as a *reorder*
        // while arranging in Custom Order.
        .onDrag {
            appState.isDraggingTracks = false
            return NSItemProvider(object: MacAppState.playlistDragPayload(playlist.id) as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            let result = handleDrop(dropped, onto: playlist)
            hoveredPlaylistID = nil
            return result
        } isTargeted: { isTargeted in
            withMixAnimation(.easeInOut(duration: 0.15)) {
                if isTargeted {
                    hoveredPlaylistID = playlist.id
                } else if hoveredPlaylistID == playlist.id {
                    hoveredPlaylistID = nil
                }
            }
        }
    }

    /// Two different empty states, because they mean opposite things: nothing
    /// matched the filter, versus there is nothing here yet.
    @ViewBuilder
    private var emptyState: some View {
        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("No playlists match")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        } else {
            Button { showNewPlaylist = true } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.mixSurface2)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.mixTextTertiary)
                        }
                    Text("Create your first playlist")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(emptyZoneTargeted ? Color.mixPrimary.opacity(0.15) : .clear)
                    .padding(.horizontal, 8)
            )
            .dropDestination(for: String.self) { dropped, _ in
                emptyZoneTargeted = false
                guard canArrangePlaylists, appState.isArrangingPlaylists else { return false }
                guard let id = MacAppState.playlistIDs(fromDrop: dropped).first else { return false }
                reorder(id, before: nil)
                return true
            } isTargeted: { isTargeted in
                withMixAnimation(.easeInOut(duration: 0.15)) { emptyZoneTargeted = isTargeted }
            }
        }
    }

    /// Where the thing being dragged will land.
    private var insertionLine: some View {
        Rectangle()
            .fill(Color.mixPrimary)
            .frame(height: 2)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .transition(.opacity)
    }

    // MARK: - Navigation

    /// True when `item` is the page on screen.
    ///
    /// `Library` also lights up for the four tab identities, since selecting
    /// `.songs` *is* being on the Library page — the router turns it into exactly
    /// that. Without this, arriving from a Home quick link or a "go to album"
    /// menu left the sidebar showing nothing selected at all.
    private func isSelected(_ item: MacSidebarItem) -> Bool {
        guard appState.selectedPlaylist == nil else { return false }
        if item == .library { return appState.selection?.isLibraryPage == true }
        if item == .home    { return appState.selection?.isLandingPage == true }
        return appState.selection == item
    }

    private func select(_ item: MacSidebarItem) {
        appState.goToSection(item)
    }

    private func openPlaylist(_ playlist: Playlist) {
        appState.selectedPlaylist = playlist
        appState.selectedAlbum = nil
        appState.selection = nil
    }

    // MARK: - Drag & drop

    private func handleDrop(_ dropped: [String], onto playlist: Playlist) -> Bool {
        appState.isDraggingTracks = false

        // Songs dragged from any track list land here first: the same rows are
        // both a reorder target and an "add to this playlist" target, told apart
        // by the payload prefix.
        let trackIDs = MacAppState.trackIDs(fromDrop: dropped)
        if !trackIDs.isEmpty {
            // All Songs only — it's rebuilt from the library on every refresh, so
            // adding to it by hand means nothing. Favourites is a real target:
            // `addTrack` keeps `favoriteRepo` in sync for it. Mixes and saved
            // playlists refuse the drop rather than swallow it: `addTrack` would
            // decline them anyway, and a drag that lands and then does nothing
            // looks like the app dropped the songs on the floor.
            guard !playlist.isAllSongs, playlist.isEditable else { return false }
            let added = trackIDs.filter { !playlist.trackIDs.contains($0) }
            // One card for the drop, not one per song: `deps.addTracks`
            // counts the selection itself.
            deps.addTracks(ids: added, toPlaylist: playlist.id)
            return !added.isEmpty
        }

        // Reordering only means something in Custom Order, and only while
        // arranging — otherwise a dropped row would silently write a
        // `sortIndex` the current sort doesn't even display.
        guard canArrangePlaylists, appState.isArrangingPlaylists else { return false }

        guard let sourceID = MacAppState.playlistIDs(fromDrop: dropped).first,
              sourceID != playlist.id
        else { return false }

        // A drag can't cross the pinned/unpinned boundary: pinned playlists
        // always sort first regardless of where a drop leaves them, so an
        // unpinned row dropped ahead of a pinned one — or a pinned row
        // dropped into the unpinned block — looked like it worked for a
        // frame and then snapped back the moment the sidebar re-sorted. See
        // `LibraryView.PlaylistsListView.moveUnpinned` for the same rule on
        // iOS.
        guard meta.isPinned(playlistID: sourceID) == meta.isPinned(playlistID: playlist.id)
        else { return false }

        reorder(sourceID, before: playlist.id)
        return true
    }

    /// Move `id` so it sits immediately before `target`, or last when nil.
    ///
    /// The whole visible order is written back rather than an index shuffled
    /// inside a stored list, so the very first drag has something complete to
    /// say rather than describing a list that has never heard of most of the
    /// rows. It goes onto the playlists themselves, which is what carries it to
    /// the phone — see `LibraryService.setPlaylistOrder`.
    private func reorder(_ id: UUID, before target: UUID?) {
        var order = orderedPlaylists.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)

        if let target, let to = order.firstIndex(of: target) {
            order.insert(id, at: to)
        } else {
            order.append(id)
        }

        withMixAnimation { library.setPlaylistOrder(order) }
    }
}

// MARK: - Collapsed rail

/// The sidebar folded down to icons.
///
/// A separate view rather than `MacSidebarView` at a narrower width, because at
/// 64pt almost nothing survives the squeeze: the header, the filter field, every
/// row label and the whole playlist list would each need their own collapsed
/// form, which is a second view written in the margins of the first one.
///
/// Playlists keep their artwork here. Six identical grey squares would be no
/// better than nothing, but album covers are what people recognise a playlist
/// by, and at 34pt they're still recognisable — which is what makes the rail a
/// usable place to stay rather than a state you immediately undo.
struct MacSidebarRail: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var library:  LibraryService
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var engine:   PlaybackEngine
    @ObservedObject private var meta = PlaylistMetadataService.shared

    @State private var hoveredPlaylistID: UUID? = nil

    static let width: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            MacSidebarIconButton(systemImage: "sidebar.leading", help: "Expand Sidebar") {
                appState.toggleSidebar()
            }
            .padding(.top, 8)
            .padding(.bottom, 6)

            LibraryActivityRing(library: deps.libraryService)
            DownloadStatusRing(downloads: deps.downloadManager)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(MacSidebarItem.primaryItems) { item in
                        railButton(item)
                    }

                    if !deps.localFiles.tracks.isEmpty {
                        railButton(.localFiles)
                    }

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    ForEach(playlists) { playlist in
                        railPlaylist(playlist)
                    }
                }
                .padding(.bottom, 12)
            }

            Divider()
                .padding(.horizontal, 12)

            railButton(.settings)
                .padding(.vertical, 6)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // No fill of its own: the column underneath paints one material behind
        // both this and the full sidebar, which is what lets them cross-fade
        // without the backdrop flickering between them. See `sidebarColumn`.
    }

    /// The same order the full sidebar draws — see
    /// `MacSidebarView.orderedPlaylists`.
    private var playlists: [Playlist] { appState.playlistSortOrder.sorted(library.playlists) }

    private func isSelected(_ item: MacSidebarItem) -> Bool {
        guard appState.selectedPlaylist == nil else { return false }
        if item == .library { return appState.selection?.isLibraryPage == true }
        if item == .home    { return appState.selection?.isLandingPage == true }
        return appState.selection == item
    }

    private func railButton(_ item: MacSidebarItem) -> some View {
        MacRailIcon(systemImage: item.systemImage,
                    title: item.title,
                    isSelected: isSelected(item)) {
            appState.goToSection(item)
        }
    }

    private func railPlaylist(_ playlist: Playlist) -> some View {
        let isSelected = appState.selectedPlaylist?.id == playlist.id

        return Button {
            appState.selectedPlaylist = playlist
            appState.selectedAlbum = nil
            appState.selection = nil
        } label: {
            PlaylistArtwork(playlist: playlist, size: 34, cornerRadius: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.mixPrimary,
                                      lineWidth: isSelected ? 2 : 0)
                }
                .opacity(hoveredPlaylistID == playlist.id || isSelected ? 1 : 0.82)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(playlist.name)
        .mixAnimation(.easeOut(duration: 0.1), value: hoveredPlaylistID)
        .onHover { hovering in
            if hovering {
                hoveredPlaylistID = playlist.id
                NSCursor.pointingHand.push()
            } else {
                if hoveredPlaylistID == playlist.id { hoveredPlaylistID = nil }
                NSCursor.pop()
            }
        }
        // Songs can still be dropped onto a rail tile. Collapsing the sidebar is
        // a decision about width, not a decision to give up a gesture.
        .dropDestination(for: String.self) { dropped, _ in
            appState.isDraggingTracks = false
            let ids = MacAppState.trackIDs(fromDrop: dropped)
            guard !ids.isEmpty, !playlist.isAllSongs, playlist.isEditable else { return false }
            let added = ids.filter { !playlist.trackIDs.contains($0) }
            deps.addTracks(ids: added, toPlaylist: playlist.id)
            return !added.isEmpty
        }
    }
}

private struct MacRailIcon: View {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.mixPrimary
                                 : isHovered ? Color.mixTextPrimary : Color.mixTextSecondary)
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.mixPrimary.opacity(0.15)
                              : isHovered ? Color.primary.opacity(0.07) : .clear)
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(title)
        .mixAnimation(.easeOut(duration: 0.1), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Sidebar Row Chrome

/// Selection and hover chrome shared by every sidebar row.
///
/// Selection is drawn by hand rather than via `List(selection:)` so the brand
/// colour is used instead of the system accent. The hover fill is what makes the
/// sidebar feel alive — without it the rows look inert until clicked.
private struct SidebarRowChrome: ViewModifier {
    let isSelected: Bool
    let isHovered:  Bool

    private var fill: Color {
        if isSelected { return Color.mixPrimary.opacity(0.15) }
        if isHovered  { return Color.primary.opacity(0.07) }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.mixPrimary
                             : isHovered ? Color.mixTextPrimary : Color.mixTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .contentShape(Rectangle())   // full-row hit target
            .mixAnimation(.easeOut(duration: 0.1), value: isHovered)
    }
}

private struct MacSidebarRow: View {

    let item:       MacSidebarItem
    let isSelected: Bool
    let action:     () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
            }
            .modifier(SidebarRowChrome(isSelected: isSelected, isHovered: isHovered))
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// The small square glyph buttons in the sidebar's headers — collapse, filter,
/// new playlist. Quiet until pointed at, which is what keeps three of them in a
/// header from reading as a toolbar.
private struct MacSidebarIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.mixPrimary
                                 : isHovered ? Color.mixTextPrimary : Color.mixTextTertiary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(help)
        .mixAnimation(.easeOut(duration: 0.1), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Sidebar Playlist Row

private struct MacSidebarPlaylistRow: View {
    let playlist:   Playlist
    /// True when this playlist is the one currently open.
    let isSelected: Bool
    /// True when this row is part of a ⌘/⇧ multi-selection. Deliberately
    /// separate from `isSelected`: "the page you are looking at" and "the rows
    /// you have picked to act on" are different things, and a right-click menu
    /// that says "Delete 3 Playlists" has to be able to show which three.
    var isPicked: Bool = false
    /// True while songs are being dragged over this row.
    var isDropTarget: Bool = false
    /// A modified click: ⌘ toggles this row, ⇧ extends from the anchor.
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// A right-click landed here, before the menu is built.
    var onContextClick: () -> Void = {}
    let action:     () -> Void

    @EnvironmentObject private var engine:    PlaybackEngine
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var meta = PlaylistMetadataService.shared

    @State private var isHovered = false

    private var isPinned: Bool { meta.isPinned(playlistID: playlist.id) }

    /// True when every song in the playlist is on disk. Reads
    /// `downloads.downloadedTrackIDs` rather than asking for a cached verdict
    /// so the badge appears the moment the last download lands — and on All
    /// Songs that means "the whole library is offline".
    private var isFullyDownloaded: Bool {
        downloads.isFullyDownloaded(playlist.trackIDs)
    }

    private var isNowPlaying: Bool {
        engine.queue.sourcePlaylistID == playlist.id && engine.queue.currentTrack != nil
    }

    private var fill: Color {
        if isDropTarget { return Color.mixPrimary.opacity(0.28) }
        if isPicked   { return Color.mixPrimary.opacity(0.22) }
        if isSelected { return Color.mixPrimary.opacity(0.15) }
        if isHovered  { return Color.primary.opacity(0.07) }
        return .clear
    }

    /// What the second line says. "Playlist · 12" on every row was twelve
    /// repetitions of a word the artwork and the section header have both
    /// already said; the count on its own carries the same information in a
    /// third of the width.
    private var subtitle: String {
        playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs"
    }

    // Two lines and a 32pt cover instead of a 13pt label beside an 18pt chip —
    // the same proportions Spotify's sidebar uses, and legible at a glance.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Covers, the borrowed-from-the-first-song fallback, and the two
                // system rows' own tiles all live in `PlaylistArtwork` — this
                // row is where they most obviously have to agree with the page
                // each one opens.
                PlaylistArtwork(playlist: playlist, size: 32, cornerRadius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected || isNowPlaying
                                         ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)

                    // Both marks sit on the second line, ahead of the count, so
                    // the name keeps the full width it had — the same order the
                    // Playlists page uses.
                    HStack(spacing: 4) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.mixPrimary)
                                .rotationEffect(.degrees(45))
                                .help("Pinned")
                        }
                        DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads, size: 10)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mixTextTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isNowPlaying {
                    NowPlayingBars(isPlaying: engine.state.isPlaying, barWidth: 2, barSpacing: 1.5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                // A picked row is outlined as well as tinted. Tint alone reads
                // as hover, and "which rows will this menu act on" is not a
                // question the answer should be ambiguous about.
                if isPicked, !isDropTarget {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.mixPrimary.opacity(0.65), lineWidth: 1)
                }
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.mixPrimary, lineWidth: 1.5)
                }
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .mixAnimation(.easeOut(duration: 0.1), value: isHovered)
            .mixAnimation(.easeOut(duration: 0.1), value: isDropTarget)
        }
        .buttonStyle(.plain).mixHandCursor()
        // ⌘- and ⇧-clicks come from AppKit: a SwiftUI Button (like a tap
        // gesture) never fires while a modifier is held, so without this the
        // only thing a ⌘-click did was nothing at all.
        .overlay(ModifiedClickCatcher(onClick: onSelect, onRightClick: onContextClick))
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

#endif
