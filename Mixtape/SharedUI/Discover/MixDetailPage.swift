// MixDetailPage.swift
// Mixtape — SharedUI/Discover
//
// The page behind a mix card. Shared by both platforms, same reasoning as
// PersonalLandingSections: the layout is identical, only "play this" differs.
//
// Nothing is fetched here. The mix arrived with its tracks already loaded — the
// landing needed them to build the card's mosaic and subtitle — so the page
// paints in one frame with no spinner, which is what makes tapping a mix feel
// like opening a folder rather than loading a website.
//
// It reads as a playlist rather than as a Discover shelf with a Play button,
// because that's what it is: a named, ordered list of songs with an owner. The
// owner is Mixtape — the app made this, not the user and not a friend — and the
// user's own name appears only in the "Made for" line, the same way a playlist
// built for you is attributed everywhere else.
//
// And it is drawn by the same two lists the library's playlists use — the
// AppKit table on macOS, `PlaylistTrackRow` on iOS — rather than by a shelf row
// of its own. A mix *is* a playlist; the only thing separating it from the ones
// in the sidebar is who wrote it. So it gets the numbered rows, the resizable
// columns, the search field and the sort menu, and a right-click menu that does
// what a right-click on a song does anywhere else.
//
// The one real difference is that its songs may not be in the library yet, and
// the list is built out of `Track`s. Each song is drawn as its library row when
// there is one and as a provisional row (`OnlineTrack.asTrack`) when there
// isn't, and every action that needs a library row — favouriting, filing under
// a playlist, downloading — either saves the song first or says why it can't.

import SwiftUI
import Combine

struct MixDetailPage: View {

    let mix: PersonalMix
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onShuffle: () -> Void

    /// The track whose stream is being resolved, if any. The page itself never
    /// waits for anything — see above — but the thing you press on it does, and
    /// these are the same rows the landing draws.
    var resolvingID: String? = nil

    /// Open Mixtape's own profile, from the owner name in the byline.
    var onOpenMixtape: (() -> Void)? = nil
    /// Open the profile of whoever the mix was made for. Both nil leaves the
    /// byline inert, which is what it was before either page existed.
    var onOpenProfile: ((UserProfile) -> Void)? = nil
    /// Open one of the artists named in the header. Nil leaves them plain text.
    var onOpenArtist: ((String) -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    /// Observed directly: `engine.queue` doesn't republish through the engine,
    /// so the shuffle button lagged behind the state it shows.
    @EnvironmentObject private var queueService: QueueService
    #if os(macOS)
    @EnvironmentObject private var appState:    MacAppState
    #endif

    @State private var saveError: String?

    /// What the list is showing, and in what order — the same pair the library's
    /// playlist page carries, driving the same controls.
    @State private var trackQuery = ""
    @State private var trackSort  = TrackSort()

    /// Cover bytes for the songs that aren't in the library yet, keyed by online
    /// id. See `loadArtwork`.
    @State private var artwork: [String: Data] = [:]

    /// The first cover's bytes, purely so the page can tint itself the way every
    /// other detail page does.
    @State private var washData: Data?

    /// See `MixListingMemo`. A reference type in `@State` so the cache outlives
    /// the rebuilding of this struct, which is the whole point of it.
    @State private var memo = MixListingMemo()

    /// Songs on their way to the "add to playlist" sheet. They're saved into the
    /// library first — see `chooseAPlaylist`.
    @State private var tracksForAddToPlaylist: [Track] = []

    #if os(macOS)
    /// Selection is the page's own, not `MacAppState`'s: the window-wide
    /// selection is what ⌘⌫ deletes from the library, and half of these rows
    /// aren't in the library to delete.
    @State private var selectedIDs: Set<Track.ID> = []
    #else
    @State private var listWidth: CGFloat = 0
    #endif

    /// DownloadManager's changes don't travel through `deps`, so the download
    /// button — and now the ring on it — would sit at whatever it read on the
    /// first frame. Bumping this on its notification keeps it live, the same
    /// way the playlist page does it.
    @State private var downloadTick = 0

    /// The signed-in user's profile, for the "Made for" name and the page behind
    /// it. Loaded rather than read off `currentUser` because that falls back to
    /// the email address when no name is set, and "Made for mike@gmail.com" is
    /// not a sentence anyone wants under a playlist title.
    @State private var me: UserProfile?

    // MARK: - Saved state

    /// This mix's playlist in the library, once it's been saved.
    ///
    /// Looked up by the mix's own derived id rather than by name: two mixes can
    /// share a title across weeks, and matching on one would have a new mix
    /// claim an old snapshot's downloads.
    private var savedPlaylist: Playlist? {
        guard let p = deps.libraryService.playlist(id: mix.savedPlaylistID), !p.isDeleted else { return nil }
        return p
    }

    /// Set the instant the button is pressed, cleared only if the save fails.
    ///
    /// The library's answer to "is this saved?" is only true once every song has
    /// been written, and the press hands the checkmark its state before any of
    /// that starts — so without this the button sits in its unpressed state for
    /// the whole write and then snaps, which reads as the app ignoring the tap.
    @State private var optimisticallySaved = false

    private var isSaved: Bool { optimisticallySaved || savedPlaylist != nil }

    /// Who the mix was made for. Nil rather than "you" — signed out there is no
    /// *you* to have made it for, and the byline is better one item shorter than
    /// vaguely addressed.
    ///
    /// Paints from `currentUser` on the first frame and upgrades to the profile
    /// as soon as it lands, so the name is right immediately and better shortly
    /// after. Only the profile version carries an id, so the name becomes
    /// pressable at the same moment there's a page behind it.
    private var madeForMember: BylineMember? {
        if let me {
            return BylineMember(id: me.id, name: me.name, avatarURL: me.avatarURL)
        }
        guard let user = deps.authService.currentUser,
              !user.displayName.isEmpty else { return nil }
        return BylineMember(id: user.id, name: user.displayName, avatarURL: user.avatarURL)
    }

    var body: some View {
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
        // macOS raises the corner panel instead — same list, no window over the
        // app. Handing it off here rather than at each menu item keeps the
        // menus' `tracksForAddToPlaylist = …` meaning one thing on both
        // platforms.
        .onChange(of: tracksForAddToPlaylist) { _, tracks in
            guard !tracks.isEmpty else { return }
            deps.savedInPanel.show(tracks: tracks, isSavedIn: false)
            tracksForAddToPlaylist = []
        }
        #endif
    }

    // MARK: - The page, per platform

    #if os(macOS)
    /// The hero, then the table. The page does the scrolling so the hero can
    /// leave the screen as you go down the songs — see `fitsContent`.
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
            // Both the menu items and the clickable names in the rows, and both
            // go to the Discover page rather than the library one: half these
            // songs aren't in the library, so a library artist page would open
            // on nothing.
            onGoToArtist:        { appState.openDiscoverArtist(named: $0) },
            onGoToAlbum:         { appState.openDiscoverAlbum(for: $0) },
            onOpenArtistLink:    { appState.openDiscoverArtist(named: $0) },
            onOpenAlbumLink:     { appState.openDiscoverAlbum(for: $0) },
            // Nothing on this page removes anything: the mix is Mixtape's list,
            // and a song you don't want in it is a song you don't play.
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
        let listing = self.listing   // updates the memo; `visibleRows` reads it
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
                    trackRow(row, index: index + 1, in: shown, savedIDs: listing.savedIDs)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The list gives up its own background so the page can paint one; the
        // Mac side inherits Discover's, which is already `mixBackground`.
        .background(Color.mixBackground.ignoresSafeArea())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { listWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in listWidth = width }
            }
        }
    }

    private var columns: TrackColumns { TrackColumns(width: listWidth) }

    private func trackRow(_ row: MixRow, index: Int,
                          in shown: [MixRow], savedIDs: Set<UUID>) -> some View {
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
            // Not a heart: half this list isn't in the library, and the
            // question a mix row asks is "keep this?".
            onSaveToLibrary:   { addToLibrary([row.track]) }
        )
        .listRowInsets(TrackColumns.rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { trackMenu(row, in: shown, savedIDs: savedIDs) }
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

    /// "Travis Scott, Future, Metro Boomin and more" — the same names the card's
    /// subtitle prints, but one tap target each.
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

    /// Everything you can do to the mix, and the two things you can do to the
    /// *list* — laid out exactly as the playlist page lays them out, for the
    /// same reason: play, shuffle, save and the overflow menu are a cluster on
    /// the left, and searching and sorting change what you're being shown
    /// rather than changing the mix.
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

    /// Where a tapped byline name goes: Mixtape to its own profile, anyone else
    /// to theirs. Nil when neither destination was wired, which leaves the names
    /// as plain text rather than as buttons that do nothing.
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

    /// "24 songs, 1 hr 38 min" — the same shape the library's playlists use,
    /// plus "1 save" once it's been kept.
    ///
    /// Counted locally, and correctly: a mix is built from one person's
    /// listening and exists for them alone, so the only saver it can ever have
    /// is the person reading this. Asking a server how many people saved *your*
    /// Travis Scott Mix would be asking a question with no meaning.
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

            // Only once it's in the library. Downloading acts on library rows —
            // there is nothing to keep offline until the mix is something the
            // library holds, and a button that silently saves first would make
            // "download" mean two different things.
            if isSaved { downloadButton }

            Menu { overflowMenu } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            #if os(macOS)
            // Left alone a Menu draws itself as a bordered pop-up button with a
            // chevron — the wrong shape entirely next to a circle.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .frame(width: 40, height: 40)
            .help("More actions for \u{201C}\(mix.title)\u{201D}")
        }
    }

    /// Add the whole mix to the library. Turns into a settled checkmark once
    /// it's there rather than disappearing — a control that vanishes on success
    /// leaves you wondering whether you pressed it.
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
        // Kept is the user's choice; complete is whether the songs have actually
        // landed. The same two-part reading as the playlist page's button, which
        // this one sits next to in a user's head even though the two screens
        // never meet.
        let savedIDs   = deps.libraryService.playlist(id: id)?.trackIDs ?? []
        let isKept     = deps.downloadManager.isPlaylistOffline(id)
        // Complete is a fact about the disk, not about the opt-in — a mix whose
        // songs are all here already has nothing left to download, and offering
        // an empty disc for work that doesn't exist is what this fixes.
        // Same reading as the playlist page: kept, with nothing fetchable in it,
        // is finished rather than forever at 0%.
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

        // The whole mix in one call, not a loop over the single-song version:
        // that one warms each song's cache before appending it, so the last row
        // of a two-dozen-song mix landed minutes after the click.
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
    /// The same list of actions the Mac table builds in AppKit, in SwiftUI.
    @ViewBuilder
    private func trackMenu(_ row: MixRow, in shown: [MixRow], savedIDs: Set<UUID>) -> some View {
        Button("Play Now", systemImage: MixtapeIcons.play) { play(row.track, in: shown) }
        Button("Play Next")   { withOnline(row.track) { await coordinator.playNext($0) } }
        Button("Add to Queue") { withOnline(row.track) { await coordinator.addToQueue($0) } }
        Divider()
        if !savedIDs.contains(row.track.id) {
            Button("Add to Library", systemImage: MixtapeIcons.add) {
                addToLibrary([row.track])
            }
        }
        Button(deps.libraryService.isFavourited(trackID: row.track.id)
               ? "Remove from Liked Songs" : "Add to Liked Songs",
               systemImage: deps.libraryService.isFavourited(trackID: row.track.id)
               ? "heart.slash" : "heart") {
            toggleFavourite(row.track)
        }
        Button("Add to Playlist\u{2026}", systemImage: "text.badge.plus") {
            chooseAPlaylist([row.track])
        }
        Divider()
        ShareMenuItems(.track(row.online))
    }
    #endif

    // MARK: - Rows

    /// One song of the mix: the row the list draws, and the online track behind
    /// it that playback and saving both need.
    struct MixRow: Identifiable {
        let online: OnlineTrack
        let track:  Track
        var id: UUID { track.id }
    }

    /// The mix's songs as rows, plus which of them the library already holds.
    ///
    /// Both answers come out of a single pass over the library. The obvious
    /// version — look each song up as you build its row — is one full scan per
    /// song, and a mix is twenty-five songs against a library that can be ten
    /// thousand.
    fileprivate struct MixListing {
        var rows: [MixRow] = []
        var savedIDs: Set<UUID> = []
    }

    /// This page's cache of the derived listing, and of the rows the list draws.
    ///
    /// The sibling of `TrackListMemo`, with the same contract: keep the answer
    /// alongside everything it depends on, and rebuild only when one of those
    /// actually moved.
    ///
    /// `covers` is the count of fetched cover blobs, and a count is enough
    /// because the artwork dictionary is only ever *added* to — its one mutation
    /// is a merge guarded on the key being absent. If that ever becomes a
    /// replacing merge, this key stops noticing and stand-in rows keep their old
    /// cover; use an explicit version counter then.
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

        /// `compute` and `filter` are passed in rather than held, so this keeps
        /// no reference to the page or the library and cannot go stale behind
        /// its own key.
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

    /// The listing, computed at most once per change to anything it depends on.
    ///
    /// It is a full pass over the library — every library track, then a
    /// recording-index match for every mix song the first pass missed — and it
    /// was a *computed property read from `body`*, so it ran again on every
    /// re-render of this page. Measured: 445 ms across 173 calls for one visit,
    /// with a 365 ms main-thread hang attributed to it. Nothing about the mix or
    /// the library changed across those 173 calls; SwiftUI simply re-evaluated
    /// the body, which it is free to do for reasons that have nothing to do with
    /// this list.
    ///
    /// Same shape as the playlist page's `TrackListMemo`, and keyed on
    /// `trackRevision` rather than `revision` for the same reason — see its doc
    /// comment. Playing a song is a playlist write, and keying on the shared
    /// revision would put a full library scan in front of every press.
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

    /// What the list draws — the memo's filtered, sorted rows.
    private var visibleRows: [MixRow] { memo.visible }

    private func computeListing() -> MixListing {
        let wanted = Set(mix.tracks.map(\.stableTrackID))
        var saved: [UUID: Track] = [:]
        for track in deps.libraryService.tracks where wanted.contains(track.id) {
            saved[track.id] = track
        }
        // A song the user already owns under some *other* id — an imported file,
        // or the same recording saved from a catalogue that spells it
        // differently. Saving the mix matches on exactly this, so a list that
        // only knew about `stableTrackID` showed four such songs as unsaved and
        // then correctly saved none of them, leaving the count short of what
        // the page had implied.
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
        // Both ids for every song the library holds. The keys are the mix's own
        // `stableTrackID`s, but a song matched by recording is drawn as the
        // library's row and every reader here asks `savedIDs.contains(row.track.id)`
        // — so a row could show a real date added and an unchecked box at the
        // same time, and the save would then correctly skip a song the page had
        // just called missing.
        listing.savedIDs = Set(saved.keys).union(saved.values.map(\.id))
        listing.rows = mix.tracks.map { online in
            // The library's own row when there is one — it carries real artwork,
            // a download state and a date added, none of which a stand-in has.
            if let row = saved[online.stableTrackID] {
                return MixRow(online: online, track: row)
            }
            return MixRow(online: online,
                          track: online.asTrack(artworkData: artwork[online.id],
                                                deviceID: deviceID))
        }
        return listing
    }

    /// What the list is showing: the search field applied, then the sort menu —
    /// filter first, then order what survived.
    private func visible(_ listing: MixListing) -> [MixRow] {
        guard !trackQuery.isEmpty || !trackSort.isDefault else { return listing.rows }
        let ordered = listing.rows.map(\.track).matching(query: trackQuery).sorted(by: trackSort)
        var byID: [UUID: MixRow] = [:]
        for row in listing.rows where byID[row.track.id] == nil { byID[row.track.id] = row }
        return ordered.compactMap { byID[$0.id] }
    }

    /// Which row is the one playing.
    ///
    /// The player answers in online ids during a Discover session and in library
    /// ids the rest of the time — after this mix has been saved and reopened
    /// from the library, say — and both land on the same derived UUID here.
    private var currentTrackID: UUID? {
        if let nowPlaying = coordinator.nowPlayingID { return OnlineTrack.stableID(for: nowPlaying) }
        return engine.queue.currentTrack?.id
    }

    /// Songs with a spinner over the cover: whatever the engine is routing, plus
    /// the one this page was told about (the click may not have reached the
    /// engine yet).
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

    /// Play a row, in the order the list is currently being read in: a searched
    /// or re-sorted list plays as it looks, not as the mix was written.
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

    /// Favouriting a song the library doesn't have has to save it first — a
    /// favourite is a flag on a library row, and there's no row to flag.
    private func toggleFavourite(_ track: Track) {
        if deps.libraryService.track(id: track.id) != nil {
            deps.toggleFavourite(trackID: track.id)
            return
        }
        Task {
            let ids = await ensureSaved([track])
            guard let id = ids.first else { return }
            // Always an add: a mix song that needed saving first was, by
            // definition, not a favourite a moment ago.
            deps.toggleFavourite(trackID: id)
        }
    }

    /// Filing a mix song under a playlist saves it on the way, for the same
    /// reason favouriting does: a playlist holds library rows.
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

    /// This song's library row, by id and then by name.
    ///
    /// The id isn't always the one the save lands on: `importOnlineTrack` hashes
    /// the resolved file first, and a hash the library already holds keeps the
    /// older row and its id. `SaveToLibraryButton` falls back the same way.
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

    /// Cover bytes for the songs the library doesn't hold.
    ///
    /// The rows are library rows now, and a library row wears the artwork it
    /// carries rather than fetching a URL — right for a library, and it would
    /// leave an unsaved mix as a column of grey squares. So the page fetches the
    /// covers once and hands them to the provisional rows. Saved songs are
    /// skipped: their own artwork is already there and already better.
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

    /// Whether the player is inside this mix right now, so Play can offer to
    /// pause rather than restart from the top.
    private var isPlayingThisMix: Bool {
        guard engine.state.isPlaying, let nowPlaying = coordinator.nowPlayingID else { return false }
        return mix.tracks.contains { $0.id == nowPlaying }
    }

    /// Synchronous on purpose. Everything this needs is already in hand — the
    /// mix's songs came down with the page — so the playlist can exist before
    /// the press finishes, and the covers can arrive afterwards.
    private func save() {
        guard !isSaved else { return }

        // Flip first, write second. The write below is synchronous, so nothing
        // would be drawn between the two without yielding the main actor for a
        // frame — which is the whole point: the checkmark animates in, and the
        // songs land under it.
        withMixAnimation(.snappy(duration: 0.2)) { optimisticallySaved = true }

        Task { @MainActor in
            await Task.yield()
            performSave()
        }
    }

    private func performSave() {
        let saved = deps.importService.saveOnlinePlaylist(
            id:          mix.savedPlaylistID,
            name:        mix.title,
            description: mix.subtitle,
            coverURLs:   mix.covers,
            origin:      .mix,
            ownerName:   BylineMember.mixtape.name,
            tracks:      mix.tracks,
            // The covers this page fetched to draw its own list. Handing them
            // over is what stops every row going grey the moment it becomes a
            // library row.
            coverBytes:  artwork,
            coverBand:   .init(title: mix.title, rgb: MixCoverStyle.rgb(for: mix.id))
        )

        if saved == nil {
            optimisticallySaved = false
            saveError = "None of the songs in this mix could be saved. Check your connection and try again."
        }
    }

    // MARK: - Cover

    private func mosaic(side: CGFloat) -> some View {
        let half = (side - 2) / 2
        return Group {
            if mix.covers.count >= 4 {
                VStack(spacing: 2) {
                    HStack(spacing: 2) { tile(mix.covers[0], side: half); tile(mix.covers[1], side: half) }
                    HStack(spacing: 2) { tile(mix.covers[2], side: half); tile(mix.covers[3], side: half) }
                }
            } else {
                tile(mix.covers.first, side: side)
            }
        }
        .frame(width: side, height: side)
        .overlay(MixCoverBand(title: mix.title,
                              accent: MixCoverStyle.color(for: mix.id),
                              side: side))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// "4 hr 44 min", "38 min". Hours only when there are some — "0 hr 38 min"
    /// is how a computer says it.
    static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total   = Int(seconds.rounded())
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(max(minutes, 1)) min"
    }
}

// MARK: - Saved identity

extension PersonalMix {

    /// The playlist id this mix takes once it's in the library.
    ///
    /// Derived from the mix *and its contents*, which settles two things at
    /// once. Saving the same mix twice is idempotent — same id, so the second
    /// press finds the first save rather than making a duplicate. And next
    /// week's rebuild from the same seed artist is a genuinely different list,
    /// so it gets its own id and saves alongside the old one instead of
    /// silently redefining a snapshot the user chose to keep.
    var savedPlaylistID: UUID {
        OnlineTrack.stableID(for: "mix:\(id)|" + tracks.map(\.id).joined(separator: ","))
    }
}
