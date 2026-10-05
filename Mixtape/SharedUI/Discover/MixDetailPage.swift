// Page behind a mix card, shared by both platforms. Nothing is fetched: the mix arrives with its tracks.
// Drawn with the library's playlist lists (AppKit table on macOS, `PlaylistTrackRow` on iOS). Songs not in
// the library yet get provisional rows (`OnlineTrack.asTrack`); actions that need a library row save first.

import SwiftUI
import Combine

struct MixDetailPage: View {

    let mix: PersonalMix
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onShuffle: () -> Void

    /// Track whose stream is being resolved, if any.
    var resolvingID: String? = nil

    /// Open Mixtape's own profile, from the owner name in the byline.
    var onOpenMixtape: (() -> Void)? = nil
    /// Open the profile the mix was made for. Both nil leaves the byline inert.
    var onOpenProfile: ((UserProfile) -> Void)? = nil
    /// Open one of the artists named in the header. Nil leaves them plain text.
    var onOpenArtist: ((String) -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    #if os(macOS)
    @EnvironmentObject private var appState:    MacAppState
    #endif

    @State private var saveError: String?

    /// Search text and sort, the same pair as the library's playlist page.
    @State private var trackQuery = ""
    @State private var trackSort  = TrackSort()

    /// Cover bytes for songs not in the library yet, keyed by online id.
    @State private var artwork: [String: Data] = [:]

    /// First cover's bytes, for the page tint.
    @State private var washData: Data?

    /// See `MixListingMemo`. A class in `@State` so the cache outlives view rebuilds.
    @State private var memo = MixListingMemo()

    /// Songs headed to the add-to-playlist sheet. Saved to the library first, see `chooseAPlaylist`.
    @State private var tracksForAddToPlaylist: [Track] = []

    #if os(macOS)
    /// Page-local selection: the window-wide one is what ⌘⌫ deletes, and many of these rows aren't in the library.
    @State private var selectedIDs: Set<Track.ID> = []
    #else
    @State private var listWidth: CGFloat = 0
    #endif

    /// DownloadManager changes don't come through `deps`, so this is bumped on its notification to keep
    /// the download button live.
    @State private var downloadTick = 0

    /// Signed-in user's profile for "Made for". `currentUser` falls back to the email when no name is set.
    @State private var me: UserProfile?

    // MARK: - Saved state

    /// This mix's playlist in the library, once saved. Looked up by derived id, not name: mixes can share a
    /// title across weeks.
    private var savedPlaylist: Playlist? {
        guard let p = deps.libraryService.playlist(id: mix.savedPlaylistID), !p.isDeleted else { return nil }
        return p
    }

    /// Set on press, cleared only if the save fails, so the checkmark doesn't wait for every song to be written.
    @State private var optimisticallySaved = false

    private var isSaved: Bool { optimisticallySaved || savedPlaylist != nil }

    /// Who the mix was made for. Nil when signed out. Paints from `currentUser` first, then the profile,
    /// which carries the id that makes the name tappable.
    private var madeForMember: BylineMember? {
        if let me {
            return BylineMember(id: me.id, name: me.name, avatarURL: me.avatarURL)
        }
        guard let user = deps.authService.currentUser,
              !user.displayName.isEmpty else { return nil }
        return BylineMember(id: user.id, name: user.displayName, avatarURL: user.avatarURL)
    }

    var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        page
        .task(id: deps.authService.currentUser?.id) {
            guard let id = deps.authService.currentUser?.id else { me = nil; return }
            me = try? await deps.authService.fetchProfile(id: id)
        }
        .onReceive(deps.downloadManager.didChangeThrottled) { _ in
            downloadTick &+= 1
        }
        .task(id: mix.id) { await loadArtwork() }
        .artworkWash(source: washData, intensity: Self.washIntensity)
        .alert("Couldn't add this mix",
               isPresented: Binding(get: { saveError != nil },
                                    set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        #if !os(macOS)
        .sheet(isPresented: Binding(get: { !tracksForAddToPlaylist.isEmpty },
                                    set: { if !$0 { tracksForAddToPlaylist = [] } })) {
            AddToPlaylistSheet(tracks: tracksForAddToPlaylist)
                .environmentObject(deps)
        }
        #else
        // macOS raises the corner panel instead of a sheet. Handled here so the menus mean the same on both platforms.
        .onChange(of: tracksForAddToPlaylist) { _, tracks in
            guard !tracks.isEmpty else { return }
            deps.savedInPanel.show(tracks: tracks, isSavedIn: false)
            tracksForAddToPlaylist = []
        }
        #endif
    }

    // MARK: - The page, per platform

    #if os(macOS)
    /// Hero then table. The page scrolls so the hero leaves the screen, see `fitsContent`.
    private var page: some View {
        let listing = self.listing   // updates the memo; `visibleRows` reads it
        let shown   = visibleRows
        return ScrollView {
            VStack(spacing: 0) {
                header
                if mix.tracks.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if shown.isEmpty {
                    noMatchesState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    trackTable(shown, savedIDs: listing.savedIDs)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { selectedIDs.removeAll() }
    }

    private func trackTable(_ shown: [MixRow], savedIDs: Set<UUID>) -> some View {
        NativeTrackTable(
            tracks:              shown.map(\.track),
            currentTrackID:      currentTrackID,
            isPlaying:           engine.state.isPlaying,
            selectedIDs:         $selectedIDs,
            onPlay:              { track, _ in play(track, in: shown) },
            onPlayNext:          { track in withOnline(track) { await coordinator.playNext($0) } },
            onAddToQueue:        { track in withOnline(track) { await coordinator.addToQueue($0) } },
            onGetInfo:           { appState.showInspector(for: $0) },
            onEditMetadata:      { appState.enqueueReview(MetadataReviewItem(editing: $0)) },
            // Both go to the Discover page: many of these songs aren't in the library.
            onGoToArtist:        { appState.openDiscoverArtist(named: $0) },
            onGoToAlbum:         { appState.openDiscoverAlbum(for: $0) },
            onSongRadio:         deps.downloadManager.isConnected
                                 ? { appState.openSongRadio(for: $0) } : nil,
            onOpenArtistLink:    { appState.openDiscoverArtist(named: $0) },
            onOpenAlbumLink:     { appState.openDiscoverAlbum(for: $0) },
            // Nothing removes anything: the mix is Mixtape's list.
            onRemove:            { _ in },
            onToggleFavourite:   { toggleFavourite($0) },
            onAddToPlaylist:     { tracks, playlistID in addToPlaylist(tracks, playlistID) },
            showsRemoveFromLibrary: false,
            onChoosePlaylist:    { chooseAPlaylist($0) },
            onAddToLibrary:      { addToLibrary($0) },
            isInLibrary:         { savedIDs.contains($0) },
            isFavourited:        { deps.libraryService.isFavourited(trackID: $0) },
            playlists:           deps.libraryService.playlists,
            availability:        { deps.downloadManager.status(for: $0) },
            onDownload:          { deps.downloadManager.download($0) },
            onRemoveDownload:    { deps.downloadManager.removeDownload(for: $0) },
            onLinkCopied:        { deps.showToast(ShareSheet.copiedMessage) },
            canDownload:         { savedIDs.contains($0.id)
                                   && deps.downloadManager.downloadUnavailableReason(for: $0) == nil },
            scale:               appState.uiScale,
            fitsContent:         true,
            sort:                $trackSort,
            metrics:             .roomy,
            showsIndex:          true,
            showsDateAdded:      false,
            resolvingIDs:        resolvingIDs
        )
    }
    #else
    private var page: some View {
        _ = self.listing   // updates the memo; `visibleRows` reads it
        let shown   = visibleRows
        return List {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !mix.tracks.isEmpty, columns.isTable {
                TrackListHeader(columns: columns)
                    .listRowInsets(EdgeInsets(top: 0, leading: TrackColumns.rowLeading,
                                              bottom: 0, trailing: TrackColumns.rowTrailing))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if mix.tracks.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if shown.isEmpty {
                noMatchesState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                    trackRow(row, index: index + 1, in: shown)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The list drops its background so the page can paint one; the Mac inherits Discover's `mixBackground`.
        .background(MixPageBackground())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { listWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in listWidth = width }
            }
        }
    }

    private var columns: TrackColumns { TrackColumns(width: listWidth) }

    private func trackRow(_ row: MixRow, index: Int, in shown: [MixRow]) -> some View {
        PlaylistTrackRow(
            track:             row.track,
            index:             index,
            columns:           columns,
            isSelected:        false,
            isCurrent:         currentTrackID == row.track.id,
            isPlaying:         engine.state.isPlaying,
            isFavourited:      deps.libraryService.isFavourited(trackID: row.track.id),
            onToggleFavourite: { toggleFavourite(row.track) },
            availability:      deps.downloadManager.status(for: row.track.id),
            isResolving:       resolvingIDs.contains(row.track.id),
            onPlay:            { play(row.track, in: shown) },
            onSelect:          {},
            // Not a heart: many rows aren't in the library, so the question is "keep this?".
            onSaveToLibrary:   { addToLibrary([row.track]) }
        )
        .listRowInsets(TrackColumns.rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { trackMenu(row, in: shown) }
    }
    #endif

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundStyle(Color.mixTextTertiary)
            Text("This mix came back empty.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: MixtapeIcons.search)
                .font(.system(size: 36))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No songs match \u{201C}\(trackQuery)\u{201D}")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.center)
            Button("Clear Search") { trackQuery = "" }
                .buttonStyle(.plain).mixHandCursor()
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: "Playlist",
            title: mix.title,
            subtitle: mix.featured.isEmpty ? mix.subtitle : nil
        ) {
            VStack(alignment: .leading, spacing: 6) {
                featuredLine
                PlaylistByline(members: [.mixtape],
                               metadata: metadataLine,
                               madeFor: madeForMember,
                               onOpenMember: bylineTapHandler)
            }
        } cover: { size in
            mosaic(side: size)
        } actions: {
            actionRow
        }
    }

    /// The card subtitle's names, one tap target each.
    @ViewBuilder
    private var featuredLine: some View {
        if !mix.featured.isEmpty {
            HStack(spacing: 0) {
                TappableArtistRow(
                    targets: mix.featured.map { name in
                        (name: name, action: onOpenArtist.map { open in { open(name) } })
                    },
                    font: .mixBody,
                    color: .mixTextSecondary
                )
                Text(" and more")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize()
            }
        }
    }

    /// Play, shuffle, save and overflow on the left; search and sort beside them. Same layout as the playlist page.
    @ViewBuilder
    private var actionRow: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            actionButtons
            if !mix.tracks.isEmpty { trackTools }
        }
        #else
        VStack(spacing: 10) {
            actionButtons
            if !mix.tracks.isEmpty {
                trackTools
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        #endif
    }

    private var trackTools: some View {
        TrackListTools(
            query: $trackQuery,
            sort:  $trackSort,
            listOrderTitle: "Mix Order",
            searchPrompt: "Search in \(mix.title)"
        )
    }

    /// Where a tapped byline name goes: Mixtape to its profile, anyone else to theirs. Nil leaves plain text.
    private var bylineTapHandler: ((BylineMember) -> Void)? {
        guard onOpenMixtape != nil || onOpenProfile != nil else { return nil }
        return { member in
            if member.isApp {
                onOpenMixtape?()
            } else if let me, member.id == me.id {
                onOpenProfile?(me)
            }
        }
    }

    /// "24 songs, 1 hr 38 min", plus "1 save" once kept. Counted locally: a mix only exists for the reader.
    private var metadataLine: String {
        let count = mix.tracks.count
        var line = "\(count) song\(count == 1 ? "" : "s")"
        let total = mix.tracks.reduce(0) { $0 + $1.duration }
        if total > 0 { line += ", \(Self.durationPhrase(total))" }
        if isSaved { line += " · 1 save" }
        return line
    }

    private var actionButtons: some View {
        HeroActionBar(
            isPlaying: isPlayingThisMix,
            isShuffling: queueService.shuffleEnabled,
            isEmpty: mix.tracks.isEmpty,
            onPlay: {
                if isPlayingThisMix {
                    engine.pause()
                } else if let first = mix.tracks.first {
                    onPlay(first, mix.tracks)
                }
            },
            onShuffle: {
                engine.queue.toggleShuffle()
                onShuffle()
            }
        ) {
            saveButton

            // Only once saved: downloading acts on library rows.
            if isSaved { downloadButton }

            Menu { overflowMenu } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            #if os(macOS)
            // Otherwise a Menu draws as a bordered pop-up with a chevron.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .frame(width: 40, height: 40)
            .help("More actions for \u{201C}\(mix.title)\u{201D}")
        }
    }

    /// Adds the whole mix to the library. Becomes a checkmark once saved rather than disappearing.
    private var saveButton: some View {
        Button(action: save) {
            HeroCircleLabel(systemImage: isSaved ? MixtapeIcons.checkmark : MixtapeIcons.add,
                            foreground: isSaved ? .green : .mixTextSecondary,
                            fill: isSaved ? Color.green.opacity(0.18) : .mixSurface)
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(isSaved || mix.tracks.isEmpty)
        .mixAnimation(.snappy(duration: 0.2), value: isSaved)
        .help(isSaved ? "This mix is in your library" : "Add this mix to your library")
        .accessibilityLabel(isSaved ? "In your library" : "Add to library")
    }

    private var downloadButton: some View {
        let id = mix.savedPlaylistID
        // Kept is the user's choice; complete is whether the songs have landed. Same as the playlist page.
        let savedIDs   = deps.libraryService.playlist(id: id)?.trackIDs ?? []
        let isKept     = deps.downloadManager.isPlaylistOffline(id)
        // Complete reads the disk, not the opt-in: kept with nothing left to fetch is finished, not 0%.
        let isComplete = deps.downloadManager.isOffline(trackIDs: savedIDs)
            || (isKept && deps.downloadManager.nothingToDownload(trackIDs: savedIDs))
        let isFetching = isKept && !isComplete
        return Button {
            deps.downloadManager.togglePlaylistOffline(id)
        } label: {
            HeroCircleLabel(systemImage: isComplete ? "arrow.down.circle.fill"
                                                    : (isFetching ? "arrow.down" : "arrow.down.circle"),
                            foreground: isComplete ? .black : (isKept ? .green : .mixTextSecondary),
                            fill: isComplete ? .green
                                             : (isKept ? Color.green.opacity(0.18) : .mixSurface),
                            progress: isFetching
                                ? deps.downloadManager.offlineFraction(trackIDs: savedIDs) : nil,
                            progressTint: .green)
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(downloadHelp(isKept: isKept, isComplete: isComplete, trackIDs: savedIDs))
        .accessibilityLabel(downloadHelp(isKept: isKept, isComplete: isComplete, trackIDs: savedIDs))
    }

    private func downloadHelp(isKept: Bool, isComplete: Bool, trackIDs: [UUID]) -> String {
        guard isKept else {
            return isComplete
                ? "Every song here is already on this device — keep it that way for songs added later"
                : "Keep this mix offline — songs added later download too"
        }
        guard isComplete else {
            let percent = Int((deps.downloadManager.offlineFraction(trackIDs: trackIDs) * 100).rounded())
            return "Downloading this mix for offline listening — \(percent)% done"
        }
        return "Stop keeping this mix offline"
    }

    @ViewBuilder
    private var overflowMenu: some View {
        if !isSaved {
            Button(action: save) {
                Label("Add to Library", systemImage: MixtapeIcons.add)
            }
            .disabled(mix.tracks.isEmpty)
        }

        // The whole mix in one call: the single-song version warms each cache first, which is slow across a mix.
        Button {
            Task { await coordinator.addToQueue(mix.tracks) }
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(mix.tracks.isEmpty)

        // A mix only has a link once it's a playlist in the library.
        if let saved = savedPlaylist {
            Divider()
            PlaylistShareMenuItems(playlist: saved)
        }
    }

    #if os(iOS)
    /// Same menu the Mac table builds in AppKit. Items that must save the song first come back here, where
    /// the online copy is.
    private func trackMenu(_ row: MixRow, in shown: [MixRow]) -> some View {
        LibrarySongMenu(
            targets: [row.track],
            onPlay:         { play(row.track, in: shown) },
            onPlayNext:     { withOnline($0) { await coordinator.playNext($0) } },
            onAddToQueue:   { withOnline($0) { await coordinator.addToQueue($0) } },
            onChoosePlaylist: { chooseAPlaylist($0) },
            onAddToLibrary:  { addToLibrary($0) },
            onToggleLike:    { toggleFavourite($0) },
            onAddToPlaylist: { addToPlaylist($0, $1) },
            shareItem:       .track(row.online)
        )
    }
    #endif

    // MARK: - Rows

    /// One mix song: the row the list draws and the online track behind it.
    struct MixRow: Identifiable {
        let online: OnlineTrack
        let track:  Track
        var id: UUID { track.id }
    }

    /// The mix's rows plus which ones the library holds, from one pass over the library (not one scan per song).
    fileprivate struct MixListing {
        var rows: [MixRow] = []
        var savedIDs: Set<UUID> = []
    }

    /// Page cache of the derived listing and visible rows. Same contract as `TrackListMemo`: rebuild only
    /// when an input moves. `covers` is a count, which works because artwork is only ever added; if that
    /// merge ever replaces entries, use a version counter.
    @MainActor
    final class MixListingMemo {

        private struct Key: Equatable {
            var revision: UInt64
            var mixID: String
            var songIDs: [UUID]
            var covers: Int
            var query: String
            var sort: TrackSort
        }

        private var key: Key?
        fileprivate private(set) var listing = MixListing()
        fileprivate private(set) var visible: [MixRow] = []

        /// `compute` and `filter` are passed in so this holds no reference to the page or library.
        fileprivate func update(revision: UInt64,
                    mixID: String,
                    songIDs: [UUID],
                    covers: Int,
                    query: String,
                    sort: TrackSort,
                    compute: () -> MixListing,
                    filter: (MixListing) -> [MixRow]) {
            let next = Key(revision: revision, mixID: mixID, songIDs: songIDs,
                           covers: covers, query: query, sort: sort)
            guard key != next else { return }
            key = next
            listing = compute()
            visible = filter(listing)
        }
    }

    /// The listing, computed at most once per input change. It's a full library pass, so it can't run from `body`.
    /// Keyed on `trackRevision` like `TrackListMemo`: playing a song is a playlist write.
    private var listing: MixListing {
        memo.update(revision: deps.libraryService.trackRevision,
                    mixID:    mix.id,
                    songIDs:  mix.tracks.map(\.stableTrackID),
                    covers:   artwork.count,
                    query:    trackQuery,
                    sort:     trackSort,
                    compute:  { mixMainActivity("mix-page/listing") { computeListing() } },
                    filter:   { visible($0) })
        return memo.listing
    }

    private var visibleRows: [MixRow] { memo.visible }

    private func computeListing() -> MixListing {
        let wanted = Set(mix.tracks.map(\.stableTrackID))
        var saved: [UUID: Track] = [:]
        for track in deps.libraryService.tracks where wanted.contains(track.id) {
            saved[track.id] = track
        }
        // Songs owned under another id (an imported file, a different catalogue spelling). Saving matches on this too.
        let owned = deps.libraryService.ownedRecordingIndex
        for online in mix.tracks where saved[online.stableTrackID] == nil {
            if let row = owned.match(title: online.title,
                                     artistName: online.artistName,
                                     duration: online.duration) {
                saved[online.stableTrackID] = row
            }
        }

        let deviceID = AppDependencies.deviceID
        var listing = MixListing()
        // Both ids for every held song: a recording match is drawn as the library row, and readers check `row.track.id`.
        listing.savedIDs = Set(saved.keys).union(saved.values.map(\.id))
        listing.rows = mix.tracks.map { online in
            // The library's row when there is one: it has real artwork, download state and date added.
            if let row = saved[online.stableTrackID] {
                return MixRow(online: online, track: row)
            }
            return MixRow(online: online,
                          track: online.asTrack(artworkData: artwork[online.id],
                                                deviceID: deviceID))
        }
        return listing
    }

    /// Search filter first, then the sort.
    private func visible(_ listing: MixListing) -> [MixRow] {
        guard !trackQuery.isEmpty || !trackSort.isDefault else { return listing.rows }
        let ordered = listing.rows.map(\.track).matching(query: trackQuery).sorted(by: trackSort)
        var byID: [UUID: MixRow] = [:]
        for row in listing.rows where byID[row.track.id] == nil { byID[row.track.id] = row }
        return ordered.compactMap { byID[$0.id] }
    }

    /// The playing row. The player uses online ids in Discover and library ids otherwise; both map to the same UUID.
    private var currentTrackID: UUID? {
        if let nowPlaying = coordinator.nowPlayingID { return OnlineTrack.stableID(for: nowPlaying) }
        return engine.queue.currentTrack?.id
    }

    /// Songs with a spinner: whatever the engine is routing, plus the one this page was told about.
    private var resolvingIDs: Set<UUID> {
        var ids = engine.routingTrackIDs
        if let resolvingID { ids.insert(OnlineTrack.stableID(for: resolvingID)) }
        return ids
    }

    /// The online track a row was built from.
    private func online(for track: Track) -> OnlineTrack? {
        mix.tracks.first { $0.stableTrackID == track.id }
    }

    private func withOnline(_ track: Track, _ body: @escaping (OnlineTrack) async -> Void) {
        guard let online = online(for: track) else { return }
        Task { await body(online) }
    }

    // MARK: - Row actions

    /// Plays in the list's current order, so a searched or re-sorted list plays as shown.
    private func play(_ track: Track, in shown: [MixRow]) {
        guard let picked = shown.first(where: { $0.track.id == track.id }) else { return }
        onPlay(picked.online, shown.map(\.online))
    }

    private func addToLibrary(_ tracks: [Track]) {
        Task {
            var added = 0
            for track in tracks {
                guard let online = online(for: track), savedRow(for: online) == nil else { continue }
                await coordinator.addToLibrary(online)
                added += 1
            }
            guard added > 0 else { return }
            deps.showSavedToast(.library, count: added)
        }
    }

    /// Favouriting an unsaved song saves it first: a favourite is a flag on a library row.
    private func toggleFavourite(_ track: Track) {
        if deps.libraryService.track(id: track.id) != nil {
            deps.toggleFavourite(trackID: track.id)
            return
        }
        Task {
            let ids = await ensureSaved([track])
            guard let id = ids.first else { return }
            // Always an add: a song that needed saving can't already be a favourite.
            deps.toggleFavourite(trackID: id)
        }
    }

    /// Saves on the way, like favouriting: a playlist holds library rows.
    private func addToPlaylist(_ tracks: [Track], _ playlistID: UUID) {
        Task {
            let ids = await ensureSaved(tracks)
            guard !ids.isEmpty else { return }
            deps.addTracks(ids: ids, toPlaylist: playlistID)
        }
    }

    private func chooseAPlaylist(_ tracks: [Track]) {
        Task {
            let ids = await ensureSaved(tracks)
            tracksForAddToPlaylist = ids.compactMap { deps.libraryService.track(id: $0) }
        }
    }

    /// The library ids for `tracks`, saving whatever isn't there yet.
    private func ensureSaved(_ tracks: [Track]) async -> [UUID] {
        var ids: [UUID] = []
        for track in tracks {
            if let existing = deps.libraryService.track(id: track.id) {
                ids.append(existing.id)
                continue
            }
            guard let online = online(for: track) else { continue }
            if savedRow(for: online) == nil { await coordinator.addToLibrary(online) }
            if let saved = savedRow(for: online) { ids.append(saved.id) }
        }
        return ids
    }

    /// This song's library row, by id then name. `importOnlineTrack` may keep an older row's id for the same
    /// file hash. `SaveToLibraryButton` falls back the same way.
    private func savedRow(for online: OnlineTrack) -> Track? {
        deps.libraryService.tracks.first { track in
            if track.id == online.stableTrackID { return true }
            guard track.title.localizedCaseInsensitiveCompare(online.title) == .orderedSame else {
                return false
            }
            return track.artistName.localizedCaseInsensitiveCompare(online.artistName) == .orderedSame
        }
    }

    // MARK: - Artwork

    /// Cover bytes for unsaved songs, fetched once for the provisional rows. Saved songs use their own artwork.
    #if os(macOS)
    private static let washIntensity: Double = 0.72
    #else
    private static let washIntensity: Double = 1.0
    #endif

    private func loadArtwork() async {
        if washData == nil, let cover = mix.covers.first {
            washData = try? await URLSession.shared.data(from: cover).0
        }

        let saved = listing.savedIDs
        let needed: [(String, URL)] = mix.tracks.compactMap { track in
            guard !saved.contains(track.stableTrackID), artwork[track.id] == nil,
                  let url = track.artworkURL else { return nil }
            return (track.id, url)
        }
        guard !needed.isEmpty else { return }

        var fetched: [String: Data] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            for (id, url) in needed {
                group.addTask {
                    (id, try? await URLSession.shared.data(from: url).0)
                }
            }
            for await (id, data) in group {
                if let data { fetched[id] = data }
            }
        }
        guard !fetched.isEmpty else { return }
        artwork.merge(fetched) { _, new in new }
    }

    // MARK: - Actions

    /// Whether the player is in this mix, so Play can pause instead of restarting.
    private var isPlayingThisMix: Bool {
        guard engine.state.isPlaying, let id = currentTrackID else { return false }
        return memo.listing.rows.contains { $0.track.id == id || $0.online.stableTrackID == id }
    }

    /// Synchronous: the songs are already here, so the playlist exists before the press finishes; covers follow.
    private func save() {
        guard !isSaved else { return }

        // Flip first, then write, so the checkmark animates in while the songs land.
        withMixAnimation(.snappy(duration: 0.2)) { optimisticallySaved = true }

        Task { @MainActor in
            await Task.yield()
            performSave()
        }
    }

    private func performSave() {
        // The covers fetched for this page, so rows don't go grey once saved.
        let saved = deps.importService.saveMix(mix, coverBytes: artwork)

        if saved == nil {
            optimisticallySaved = false
            saveError = "None of the songs in this mix could be saved. Check your connection and try again."
        }
    }

    // MARK: - Cover

    private func mosaic(side: CGFloat) -> some View {
        let half = (side - 2) / 2
        let count = mix.covers.isEmpty ? localCovers.count : mix.covers.count
        return Group {
            if count >= 4 {
                VStack(spacing: 2) {
                    HStack(spacing: 2) { cell(0, side: half); cell(1, side: half) }
                    HStack(spacing: 2) { cell(2, side: half); cell(3, side: half) }
                }
            } else {
                cell(0, side: side)
            }
        }
        .frame(width: side, height: side)
        .overlay(MixCoverBand(title: mix.title,
                              accent: MixCoverStyle.color(for: mix.id),
                              side: side))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A mix of downloads has no catalogue links, so its songs' own covers stand in, one per album.
    private var localCovers: [Track] {
        var seen = Set<String>()
        return Array(memo.listing.rows.map(\.track).filter { seen.insert($0.albumTitle).inserted }.prefix(4))
    }

    @ViewBuilder
    private func cell(_ i: Int, side: CGFloat) -> some View {
        if mix.covers.isEmpty {
            let track = localCovers.indices.contains(i) ? localCovers[i] : nil
            ArtworkThumbnail(data: track?.artworkData, artworkRef: track.map { .track($0.id) },
                             size: side, cornerRadius: 0, placeholder: MixtapeIcons.track)
                .frame(width: side, height: side)
                .clipped()
        } else {
            tile(mix.covers.indices.contains(i) ? mix.covers[i] : nil, side: side)
        }
    }

    private func tile(_ url: URL?, side: CGFloat) -> some View {
        CachedRemoteImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.mixSurface2
        }
        .frame(width: side, height: side)
        .clipped()
    }

    /// "4 hr 44 min", "38 min". Hours only when there are some.
    static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total   = Int(seconds.rounded())
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(max(minutes, 1)) min"
    }
}

// MARK: - Saving

extension ImportService {

    /// Keep a mix as a playlist. Nil when none of its songs could be saved.
    func saveMix(_ mix: PersonalMix, coverBytes: [String: Data] = [:]) -> Playlist? {
        saveOnlinePlaylist(id:          mix.savedPlaylistID,
                           name:        mix.title,
                           description: mix.subtitle,
                           coverURLs:   mix.covers,
                           origin:      .mix,
                           ownerName:   BylineMember.mixtape.name,
                           tracks:      mix.tracks,
                           coverBytes:  coverBytes,
                           coverBand:   .init(title: mix.title, rgb: MixCoverStyle.rgb(for: mix.id)))
    }
}

// MARK: - Saved identity

extension PersonalMix {

    /// Playlist id for this mix once saved, derived from the mix and its contents: saving twice is idempotent,
    /// and next week's rebuild gets its own id instead of replacing a kept snapshot.
    var savedPlaylistID: UUID {
        OnlineTrack.stableID(for: "mix:\(id)|" + tracks.map(\.id).joined(separator: ","))
    }
}
