import SwiftUI
import Combine

public struct PlaylistDetailView: View {

    let playlist: Playlist
    /// A smart playlist shown by `SmartPlaylistDetailView`. Not a library row, so
    /// downloads, profile and sharing don't apply, and delete goes to the smart playlist service.
    var isSmart = false

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    /// Observed directly so the + button flips the moment it's pressed.
    @EnvironmentObject private var smartService: SmartPlaylistService
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    /// The header shuffle is this list's setting. See `ShufflePreferences`.
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    @Environment(\.dismiss) private var dismiss

    // Rename
    /// Confirming a press that would delete downloaded audio.
    @State private var resolvedCover: Data?
    @State private var coverLoaded = false
    @State private var showRemoveDownloadsConfirm = false
    /// Stopping a Liked Songs sync asks what to do with the songs it imported.
    @State private var showStopLikedSongs = false
    /// Songs the Liked Songs link added to Favourites. Counted when the dialog is
    /// asked for, since dialog content is evaluated on every redraw.
    @State private var likedContributions = 0
    /// Why a manual "Sync Now" didn't work, for the alert that says so.
    @State private var syncError: String?
    /// Set once a sync has been running long enough to be worth mentioning.
    @State private var syncIsSlow = false
    @ObservedObject private var throttle = SpotifyThrottle.shared
    @State private var showEditSheet     = false
    // Delete
    @State private var showDeleteConfirm = false
    /// Songs only this playlist holds, counted on the press for the same reason.
    @State private var songsLostWithPlaylist = 0
    /// Songs awaiting delete confirmation. Non-empty presents the prompt.
    @State private var tracksPendingDeletion: [Track] = []
    // Add to Playlist sheet
    @State private var tracksForAddToPlaylist: [Track] = []
    // Collaborative share sheet
    @State private var showCollabShare = false
    @State private var showDubSheet = false
    @State private var showLinerNotes = false
    @State private var showSpotifyExport = false
    /// Whether this playlist shows on the owner's public profile. Separate from collaborative sharing.
    @State private var isPublic = false
    @State private var isTogglingPublic = false
    @State private var publicError: String?
    /// Stops the cover repair being started twice.
    @State private var isRefetchingCovers = false
    /// Bumped on DownloadManager changes, which don't propagate through `deps`.
    @State private var downloadTick = 0
    /// Measured so the table can drop columns that don't fit.
    @State private var listWidth: CGFloat = 0
    /// Whose playlist this is. Empty for your own unshared playlist.
    @State private var byline: [BylineMember] = []
    /// Profiles behind byline names, so a tapped name opens without another fetch.
    /// Only names with an entry are tappable.
    @State private var bylineProfiles: [UUID: UserProfile] = [:]
    /// How many people hold this playlist, nil when there's nothing to show. See `loadSaveCount`.
    @State private var saveCount: Int?
    /// The signed-in user's profile, for the "Made for" name on a mix.
    @State private var me: UserProfile?
    #if os(iOS)
    /// iOS has no content column for a profile, so it opens as a sheet.
    @State private var profileSheet: UserProfile?
    #endif
    @State private var trackQuery = ""
    /// Display order, synced through `PlaylistTrackSortService`. On macOS the
    /// table's column headers write here too.
    @State private var trackSort = TrackSort()
    /// Observed so a sort changed on another device lands on an open page.
    /// Equality guards stop this and `setSort` looping.
    @ObservedObject private var trackSorts = PlaylistTrackSortService.shared
    @ObservedObject private var transitions = PlaylistTransitionService.shared

    /// Resolved/filtered/sorted rows, recomputed only on real changes. See `TrackListMemo`.
    @State private var memo = TrackListMemo()
    /// Set when the server says a saved playlist's original is no longer public.
    /// Never set from a failed request.
    @State private var sourceUnavailable = false
    /// An empty shared or followed playlist fetching its tracks. Shows a skeleton, not the empty state.
    @State private var refreshing = false
    /// The side being renamed, and the name being typed.
    @State private var renamingSide: SideGroup?
    @State private var sideName = ""

    private var columns: TrackColumns { TrackColumns(width: listWidth) }

    // MARK: - Editability

    /// A mix or a saved playlist: in the library, but not yours to edit, so editing controls are hidden.
    private var isReadOnly: Bool { !livePlaylist.isEditable }

    /// "Made for <name>" on a mix, nil otherwise. Uses `currentUser` until the
    /// profile loads, which also makes the name tappable.
    private var madeForMember: BylineMember? {
        guard livePlaylist.origin == .mix else { return nil }
        if let me {
            return BylineMember(id: me.id, name: me.name, username: me.username, avatarURL: me.avatarURL)
        }
        guard let user = deps.authService.currentUser, !user.displayName.isEmpty else { return nil }
        return BylineMember(id: user.id, name: user.displayName, username: user.username, avatarURL: user.avatarURL)
    }

    /// Handles taps on byline names. Nil when there's nothing to open, so names render as plain text.
    private var bylineTapHandler: ((BylineMember) -> Void)? {
        let openable = byline.contains { $0.isApp || bylineProfiles[$0.id] != nil }
            || madeForMember.map { bylineProfiles[$0.id] != nil } == true
        guard openable else { return nil }
        return { member in
            if member.isApp {
                openMixtapeProfile()
            } else if let profile = bylineProfiles[member.id] {
                openProfile(profile)
            }
        }
    }

    /// Mixtape's profile lives in Discover on both platforms, so this switches section and pushes.
    private func openMixtapeProfile() {
        #if os(macOS)
        appState.showMixtapeProfile()
        #else
        iosAppState.openMixtapeProfile()
        #endif
    }

    private func openProfile(_ profile: UserProfile) {
        #if os(macOS)
        appState.showProfile(profile)
        #else
        profileSheet = profile
        #endif
    }

    /// The live library copy, falling back to `playlist` if the library hasn't loaded.
    private var livePlaylist: Playlist {
        deps.libraryService.playlist(id: playlist.id) ?? playlist
    }

    /// Brings `memo` up to date. Unrelated redraws cost one key comparison
    /// instead of a full resolve, filter and sort.
    private var lists: TrackListMemo {
        // `trackRevision`, not `revision`: every play calls `refreshPlaylists()`, which bumps the shared one.
        memo.update(revision:   deps.libraryService.trackRevision,
                    ids:        livePlaylist.trackIDs,
                    query:      trackQuery,
                    sort:       trackSort,
                    // `track(id:)`, not the display accessor, so an offline playlist isn't empty.
                    // Undownloaded rows are greyed instead.
                    resolve:    { deps.libraryService.track(id: $0) },
                    isPlayable: { $0.canResolveAudio })
        return memo
    }

    private var tracks: [Track] { lists.tracks }

    /// Rows on screen: filtered by the search field and sorted. Counts, duration
    /// and download state read `tracks` instead.
    private var visibleTracks: [Track] { lists.visible }

    /// Visible rows that can be played, so Play follows the sort and filter.
    /// Placeholders with a title resolve online (see `AudioLocator.locate`); only
    /// rows that can't name themselves are dropped.
    private var playableTracks: [Track] { lists.playable }

    /// The hero cover and wash source, same rule as `coverData(for:)`. Nil for
    /// All Songs and Favourites, which use a glyph and `washFallback`.
    private var displayCover: Data? {
        guard !isSmart else { return nil }
        // Until `loadCover` runs, read the stored cover directly so it's there on the first frame.
        return coverLoaded ? resolvedCover : livePlaylist.displayArtwork
    }

    /// What the cover is built from, as a value that changes when it should.
    private var coverIdentity: String {
        "\(livePlaylist.id)|\(livePlaylist.displayArtwork?.count ?? 0)|\(tracks.count)|\(livePlaylist.coverKind.rawValue)"
    }

    /// This page's smart rule, read live so the + button tracks membership.
    private var smartRule: SmartPlaylist? {
        guard isSmart else { return nil }
        return smartService.playlists.first { $0.id == playlist.id }
    }

    /// Builds the hero cover. Tile reads need the main actor; the 2x2 composition runs in the background.
    private func loadCover() async {
        defer { coverLoaded = true }
        // Smart playlists use their rule's icon, like everywhere else.
        guard !isSmart else { resolvedCover = nil; return }
        if let own = livePlaylist.displayArtwork {
            resolvedCover = own
            return
        }
        // "No cover" is a choice, so don't fall through to `borrowedCover`.
        guard livePlaylist.coverKind != PlaylistCoverKind.none else {
            resolvedCover = nil
            return
        }
        // System playlists use a glyph and take the wash from `washFallback`.
        guard !livePlaylist.isSystem else {
            resolvedCover = nil
            return
        }

        var tiles: [Data] = []
        // Dedupe by a sample of each image so a one-album playlist doesn't tile the same cover.
        var seen = Set<Int>()
        let refs = isSmart
            ? deps.libraryService.coverRefs(forTrackIDs: livePlaylist.trackIDs)
            : deps.libraryService.coverRefs(forPlaylistID: livePlaylist.id)
        for ref in refs {
            guard let art = ArtworkProvider.shared.data(for: ref),
                  seen.insert(art.count ^ art.prefix(64).hashValue).inserted else { continue }
            tiles.append(art)
            if tiles.count == 4 { break }
        }

        guard let first = tiles.first else {
            resolvedCover = borrowedCover
            return
        }
        guard tiles.count >= 4 else {
            resolvedCover = first
            return
        }

        let composed = await Task.detached(priority: .userInitiated) {
            MixCoverArt.compose(tiles: tiles, side: 512)
        }.value
        resolvedCover = composed ?? first
    }

    private var washSource: Data? { displayCover }

    /// The brand orange for the two glyph playlists, so they match their cover.
    private var washFallback: [Color] {
        if let smart = smartRule {
            let accent = SmartPlaylistCover.accent(for: smart)
            return [accent, accent.opacity(0.55)]
        }
        return livePlaylist.isSystem ? ArtworkColors.brandGradient : []
    }

    /// The first song cover that exists, skipping untagged songs.
    private var borrowedCover: Data? {
        tracks.lazy.compactMap(\.displayArtwork).first
    }

    /// Wash strength. iOS keeps the full ramp; macOS tones it down but keeps some colour.
    #if os(macOS)
    private static let washIntensity: Double = 0.72
    #else
    private static let washIntensity: Double = 1.0
    #endif

    private var totalDuration: String {
        let secs = Int(tracks.map(\.duration).reduce(0, +))
        if secs >= 3600 { return "\(secs / 3600) hr \((secs % 3600) / 60) min" }
        return "\(secs / 60) min"
    }

    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    /// For switching tabs: "Find in Discover" leaves the Library tab, which a push can't do.
    @EnvironmentObject private var iosAppState: IOSAppState
    /// "Go to Artist/Album" targets. macOS swaps the content column; iOS pushes onto the NavigationStack.
    @State private var navAlbum:  Album?  = nil
    @State private var navOnlineAlbum: OnlineAlbum? = nil
    #endif

    public var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        // Counts body passes and their cost. iOS hangs carry no stack, so this shows what's redrawing.
        mixMainActivity("playlist-page/body") {
        VStack(spacing: 0) {
            Group {
                #if os(macOS)
                macTrackPage
                #else
                iosTrackList
                #endif
            }
            #if os(macOS)
            // macOS has no NavigationStack here, so the page carries its own back control over the hero.
            .pageBack {
                if isSmart { appState.selectedSmartPlaylist = nil } else { appState.selectedPlaylist = nil }
            }
            #endif
            // Pull the latest shared track list. No-op for non-shared playlists.
            .task(id: playlist.id) {
                refreshing = tracks.isEmpty
                    && (livePlaylist.followsRemoteSource
                        || PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id) != nil
                        || deps.spotifyFollowService.isFollowing(playlistID: playlist.id))
                defer { refreshing = false }
                if livePlaylist.followsRemoteSource {
                    // The owner's copy is the truth. This also tells us if it stopped being public.
                    let status = await PlaylistSharingService.shared.refreshSubscription(
                        localPlaylistID: playlist.id,
                        libraryService:  deps.libraryService
                    )
                    sourceUnavailable = status == .unavailable
                } else {
                    await PlaylistSharingService.shared.refreshSharedPlaylist(
                        localPlaylistID:  playlist.id,
                        libraryService:   deps.libraryService
                    )
                }
                // Followed Spotify playlists check their source on open. `snapshot_id` keeps the unchanged case cheap.
                if deps.spotifyFollowService.isFollowing(playlistID: playlist.id) {
                    await deps.spotifyFollowService.sync(playlistID: playlist.id)
                }
                // After the refresh: a just-joined playlist has no local rows until then.
                deps.onlineCoordinator.prefetchResolvable(tracks)
            }
            // The header's reads, alongside the refresh so the byline doesn't wait for it.
            .task(id: playlist.id) {
                await loadByline()
                // Only for your own playlists: the toggle puts yours on your profile.
                if !isReadOnly { await loadPublicState() }
                await loadSaveCount()
            }
            // Only mixes show "made for". Keyed on the account so switching users refreshes it.
            .task(id: deps.authService.currentUser?.id) {
                guard livePlaylist.origin == .mix,
                      let id = deps.authService.currentUser?.id
                else { me = nil; return }
                me = try? await deps.authService.fetchProfile(id: id)
                if let me { bylineProfiles[me.id] = me }
            }
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
            // Search is remembered per playlist for the app session. macOS reuses this view across playlists.
            .onChange(of: playlist.id) { _, id in
                trackQuery = PlaylistSearchMemory.query(for: id)
                trackSort  = trackSorts.sort(for: id)
            }
            .onChange(of: trackQuery) { _, q in
                PlaylistSearchMemory.set(q, for: playlist.id)
            }
            .onAppear {
                trackQuery = PlaylistSearchMemory.query(for: playlist.id)
                trackSort  = trackSorts.sort(for: playlist.id)
            }
            .onChange(of: trackSort) { _, sort in
                trackSorts.setSort(sort, for: playlist.id)
            }
            .onChange(of: trackSorts.sorts) { _, _ in
                let remote = trackSorts.sort(for: playlist.id)
                if remote != trackSort { trackSort = remote }
            }
            .navigationTitle(playlist.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $navAlbum)  { AlbumDetailView(album: $0).environmentObject(deps) }
            .navigationDestination(item: $navOnlineAlbum) { album in
                IOSDiscoverAlbumPage(
                    album: album,
                    onPlay: { t, ctx in Task { await deps.onlineCoordinator.play(t, context: ctx, artworkData: nil) } },
                    onOpenArtist: { iosAppState.openOnlineArtist(name: $0.name) }
                )
                .miniPlayerSafeArea()
            }
            #endif
            // Selection and playlist-level actions. Playback lives in the hero row.
            .toolbar {
                #if os(iOS)
                if !playlist.isSystem, !isSmart {
                    ToolbarItem(placement: .topBarTrailing) { profileToolbarButton }
                }
                #else
                if !playlist.isSystem, !isSmart {
                    ToolbarItem(placement: .primaryAction) { profileToolbarButton }
                }
                ToolbarItem(placement: .primaryAction) { saveToDiskToolbarButton }
                #endif
            }
        }
        // The wash covers the whole screen and tints the titlebar. Half strength on macOS.
        .artworkWash(source: washSource, intensity: Self.washIntensity, fallback: washFallback)
        .task(id: coverIdentity) { await loadCover() }
        .background(MixPageBackground())
        .miniPlayerSafeArea()
        // Cover/name/description editor: from the header cover, and the "..." menu on iOS.
        .sheet(isPresented: $showEditSheet) {
            PlaylistEditorSheet(editingPlaylist: livePlaylist)
                .environmentObject(deps)
        }
        .alert("Couldn't change visibility",
               isPresented: Binding(get: { publicError != nil },
                                    set: { if !$0 { publicError = nil } })) {
            Button("OK", role: .cancel) { publicError = nil }
        } message: {
            Text(publicError ?? "")
        }
        .alert("Couldn't sync with Spotify",
               isPresented: Binding(get: { syncError != nil },
                                    set: { if !$0 { syncError = nil } })) {
            Button("OK", role: .cancel) { syncError = nil }
        } message: {
            // The rate-limit message wins, since otherwise it reads as Mixtape being broken.
            Text(throttle.sentence ?? syncError ?? "")
        }
        // After a few seconds "Syncing..." admits it's slow.
        .task(id: isSyncing) {
            syncIsSlow = false
            guard isSyncing else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { syncIsSlow = true }
        }
        .mixConfirmationDialog(
            isFollowing ? "Stop syncing with Spotify's Liked Songs?"
                        : "Remove the songs Spotify put here?",
            isPresented: $showStopLikedSongs,
            titleVisibility: .visible
        ) {
            if isFollowing {
                Button("Stop Syncing and Keep Songs") {
                    deps.spotifyFollowService.unlink(playlistID: playlist.id)
                }
            }
            if likedContributions > 0 {
                Button("Remove the \(likedContributions) Imported Songs",
                       role: .destructive) {
                    deps.spotifyFollowService.unlinkRemovingImports(playlistID: playlist.id)
                    // The import is gone, so drop its "Imported" badge in the picker.
                    deps.spotifyImportLedger.forget(playlistID: playlist.id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(likedContributions > 0
                 ? "Removes only the \(likedContributions) songs that came from Spotify. Nothing on Spotify changes."
                 : "Nothing here came from Spotify, so nothing will be removed.")
        }
        .mixConfirmationDialog(
            PlaylistDeletionPrompt.title(name: playlist.name, isReadOnly: isReadOnly && !isSmart),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(PlaylistDeletionPrompt.confirmLabel(isReadOnly: isReadOnly && !isSmart),
                   role: .destructive) {
                if isSmart {
                    deps.smartPlaylistService.delete(id: playlist.id)
                    #if os(macOS)
                    appState.selectedSmartPlaylist = nil
                    #endif
                    dismiss()
                    return
                }
                // Owners also take the published row down, in the background. A collaborator
                // deleting their copy is just leaving.
                if let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id),
                   link.role == PlaylistSharingService.Roles.owner {
                    Task { try? await PlaylistSharingService.shared.deletePublished(sharedPlaylistID: link.sharedPlaylistID) }
                }
                // Stop following, or the next sync would bring it back.
                if livePlaylist.followsSpotify {
                    deps.spotifyFollowService.unlink(playlistID: playlist.id)
                }
                if livePlaylist.followsRemoteSource {
                    PlaylistSharingService.shared.unsavePublicPlaylist(
                        localPlaylistID: playlist.id,
                        libraryService: deps.libraryService
                    )
                } else {
                    SupabaseSyncService.allowBulk("delete-playlists")
                    deps.libraryService.deletePlaylist(id: playlist.id)
                }
                #if os(macOS)
                appState.selectedPlaylist = nil
                #endif
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isSmart
                 ? "Only the rule is deleted. Every song in it stays in your library."
                 : PlaylistDeletionPrompt.message(songCount: songsLostWithPlaylist,
                                                  isReadOnly: isReadOnly))
        }
        // A saved playlist whose original went private. Kept, not removed: the owner
        // may re-publish, and downloads still play.
        .alert("Playlist is unavailable", isPresented: $sourceUnavailable) {
            Button("Keep", role: .cancel) { sourceUnavailable = false }
            Button("Remove from Library", role: .destructive) {
                PlaylistSharingService.shared.unsavePublicPlaylist(
                    localPlaylistID: playlist.id,
                    libraryService: deps.libraryService
                )
                #if os(macOS)
                appState.selectedPlaylist = nil
                #endif
                dismiss()
            }
        } message: {
            Text(unavailableMessage)
        }
        .alert("Rename \(renamingSide?.title ?? "Side")",
               isPresented: Binding(get: { renamingSide != nil },
                                    set: { if !$0 { renamingSide = nil } })) {
            TextField("Name", text: $sideName)
            Button("Rename") {
                if let side = renamingSide?.side {
                    editSides { $0.renameSide(startingAt: side.start, to: sideName) }
                }
                renamingSide = nil
            }
            Button("Cancel", role: .cancel) { renamingSide = nil }
        } message: {
            Text("Leave it empty to show just the letter.")
        }
        // Context menu and swipe share one library-delete prompt.
        .confirmsTrackDeletion($tracksPendingDeletion) { pending in
            for track in pending { engine.stopIfPlaying(trackID: track.id) }
            SupabaseSyncService.allowBulk("user-remove")
            deps.libraryService.deleteTracks(ids: pending.map(\.id))
            #if os(macOS)
            appState.clearTrackSelection()
            #endif
        }
        // Add to Playlist sheet
        #if !os(macOS)
        .sheet(isPresented: Binding(get: { !tracksForAddToPlaylist.isEmpty },
                                    set: { if !$0 { tracksForAddToPlaylist = [] } })) {
            AddToPlaylistSheet(tracks: tracksForAddToPlaylist, sourcePlaylistID: playlist.id)
                .environmentObject(deps)
        }
        #else
        // macOS shows the corner panel instead of a sheet.
        .onChange(of: tracksForAddToPlaylist) { _, tracks in
            guard !tracks.isEmpty else { return }
            deps.savedInPanel.show(tracks: tracks, isSavedIn: false, sourcePlaylistID: playlist.id)
            tracksForAddToPlaylist = []
        }
        #endif
        .sheet(isPresented: $showSpotifyExport) {
            // No `.frame(minWidth:)`: MixSheet sizes itself, and a wrapper makes the window narrower than its content.
            SpotifyExportView(playlistName: playlist.name, tracks: tracks, playlistID: playlist.id)
                .environmentObject(deps)
        }
        // Opening this publishes the playlist if it was never shared.
        .sheet(isPresented: $showCollabShare) {
            InviteCollaboratorsSheet(playlist: livePlaylist, tracks: tracks)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showDubSheet) {
            DubSheet(playlist: livePlaylist, tracks: tracks)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showLinerNotes) {
            LinerNotesSheet(playlist: livePlaylist, tracks: tracks)
                .environmentObject(deps)
        }
        #if os(iOS)
        // A sheet, not a push: this page lives in several tabs' stacks.
        .sheet(item: $profileSheet) { profile in
            NavigationStack {
                ProfilePageView(profile: profile)
                    .environmentObject(deps)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { profileSheet = nil }
                                .foregroundStyle(Color.mixPrimary)
                        }
                    }
            }
        }
        #endif
        }
    }

    // MARK: - The page, per platform

    #if os(macOS)
    /// The hero plus the shared AppKit track table. The page scrolls, not the
    /// table, so the hero scrolls away (see `fitsContent`).
    private var macTrackPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if tracks.isEmpty, refreshing {
                    TrackListSkeleton()
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                } else if tracks.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if visibleTracks.isEmpty {
                    noMatchesState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let groups = sideGroups {
                    // One table per side. They share the selection, see `suppressSelectionSync`.
                    ForEach(groups) { group in
                        sideHeader(group)
                        trackTable(group.tracks)
                    }
                } else {
                    trackTable(visibleTracks)
                }
                if !livePlaylist.notes.isEmpty {
                    linerNotes
                        .padding(.horizontal, 22)
                        .padding(.top, 28)
                        .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clear the selection on leave so ⌘⌫ can't act on it later.
        .onDisappear { appState.clearTrackSelection() }
    }

    private func trackTable(_ rows: [Track]) -> some View {
        NativeTrackTable(
            tracks:              rows,
            currentTrackID:      engine.queue.currentTrack?.id,
            isPlaying:           engine.state.isPlaying,
            selectedIDs:         Binding(
                get: { appState.selectedTrackIDs },
                set: { appState.selectedTrackIDs = $0 }
            ),
            // A double-click passes the whole table, which on a side is one side: play the playlist.
            onPlay:              { track, context in
                playAndMark(track, within: context.count == rows.count ? nil : context)
            },
            onPlayNext:          { engine.queue.insertNext($0) },
            onAddToQueue:        { engine.queue.append($0) },
            onGetInfo:           { appState.showInspector(for: $0) },
            onEditMetadata:      { appState.enqueueReview(MetadataReviewItem(editing: $0)) },
            onEditSong:          { appState.editTrack = $0 },
            onPostSong:          { appState.postTrack = $0 },
            onDragTracksChanged: { appState.isDraggingTracks = $0 },
            onGoToArtist:        { openArtist(named: $0) },
            onGoToAlbum:         { openAlbum(for: $0) },
            onSongRadio:         deps.downloadManager.isConnected
                                 ? { appState.openSongRadio(for: $0) } : nil,
            onOpenArtistLink:    { appState.openDiscoverArtist(named: $0) },
            onOpenAlbumLink:     { appState.openDiscoverAlbum(for: $0) },
            // All Songs only. The table has already confirmed.
            onRemove:            { selection in
                for track in selection { engine.stopIfPlaying(trackID: track.id) }
                SupabaseSyncService.allowBulk("user-remove")
                deps.libraryService.deleteTracks(ids: selection.map(\.id))
                appState.clearTrackSelection()
            },
            onToggleFavourite:   { deps.toggleFavourite(trackID: $0.id) },
            onAddToPlaylist:     { selection, playlistID in
                deps.addTracks(ids: selection.map(\.id), toPlaylist: playlistID)
            },
            onRemoveFromPlaylist: canRemoveFromPlaylist ? { selection in
                deps.removeTracks(ids: selection.map(\.id), fromPlaylist: playlist.id)
                appState.clearTrackSelection()
            } : nil,
            removeFromPlaylistTitle: { count in
                let place = livePlaylist.isFavourites ? "Liked Songs" : "Playlist"
                return count > 1 ? "Remove \(count) Songs from \(place)"
                                 : "Remove from \(place)"
            },
            // Elsewhere "remove" means from this playlist; offering both invites deleting from the library by mistake.
            showsRemoveFromLibrary: playlist.isAllSongs,
            excludedPlaylistID:  playlist.id,
            onFindInDiscover:    { findInDiscover($0) },
            onChoosePlaylist:    { tracksForAddToPlaylist = $0 },
            onStartSide:         canEditSides ? { track in editSides { $0.startSide(at: track.id) } } : nil,
            canStartSide:        { canStartSide(at: $0) },
            isFavourited:        { deps.libraryService.isFavourited(trackID: $0) },
            playlists:           deps.libraryService.playlists,
            availability:        { deps.downloadManager.status(for: $0) },
            onDownload:          { deps.downloadManager.download($0) },
            onRemoveDownload:    { deps.downloadManager.removeDownload(for: $0) },
            onSaveToDisk:        { saveToDisk($0) },
            onLinkCopied:        { deps.showToast(ShareSheet.copiedMessage) },
            canDownload:         { deps.downloadManager.downloadUnavailableReason(for: $0) == nil },
            scale:               appState.uiScale,
            // Scrolled by the page, so the hero above it can leave the screen.
            fitsContent:         true,
            // Rows arrive sorted; the column headers drive `trackSort`.
            sort:                $trackSort,
            // Roomier rows than the library-wide table.
            metrics:             .roomy,
            showsIndex:          true,
            resolvingIDs:        engine.routingTrackIDs
        )
    }

    /// All Songs deletes from the library instead, and read-only playlists can't be edited.
    private var canRemoveFromPlaylist: Bool {
        !playlist.isAllSongs && !isReadOnly
    }
    #else
    /// iOS keeps the SwiftUI list, which is what makes `.swipeActions` work.
    private var iosTrackList: some View {
        List {
            // Header (artwork + title + action buttons)
            header
                .listRowInsets(EdgeInsets())
                // Clear so the wash behind the screen shows through.
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // Column header, only when the rows actually show extra columns.
            if !tracks.isEmpty, columns.isTable {
                TrackListHeader(columns: columns)
                    .listRowInsets(EdgeInsets(top: 0, leading: TrackColumns.rowLeading,
                                              bottom: 0, trailing: TrackColumns.rowTrailing))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Track rows (or empty state)
            if tracks.isEmpty, refreshing {
                TrackListSkeleton()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if tracks.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if visibleTracks.isEmpty {
                noMatchesState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if let groups = sideGroups {
                ForEach(groups) { group in
                    sideHeader(group)
                        .listRowInsets(TrackColumns.rowInsets)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(track: track, index: index + 1, isSelected: false)
                    }
                }
            } else {
                // Keyed by track id, not offset, so a reorder doesn't move per-row state onto other songs.
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index + 1, isSelected: false)
                }
            }

            if !livePlaylist.notes.isEmpty {
                linerNotes
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                    .listRowInsets(TrackColumns.rowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { listWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in listWidth = width }
            }
        }
    }
    #endif

    /// Numbered by running order, whatever the sort.
    private var linerNotes: some View {
        LinerNotesView(notes: livePlaylist.notes,
                       songs: tracks.map { ($0.id, $0.displayTitle) })
    }

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: eyebrow,
            title: livePlaylist.name,
            subtitle: livePlaylist.description,
            // The byline carries the counts when there is one.
            metadata: byline.isEmpty ? metadataLine : nil
        ) {
            if !byline.isEmpty {
                PlaylistByline(members: byline,
                               metadata: metadataLine,
                               madeFor: madeForMember,
                               onOpenMember: bylineTapHandler)
            }
        } cover: { size in
            coverArt(size: size)
        } actions: {
            actionRow
        }
    }

    /// Search and sort, kept apart from the playback cluster since they only change what's shown.
    @ViewBuilder
    private var actionRow: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            actionButtons
            if !tracks.isEmpty { trackTools }
        }
        #else
        // No room beside the pills on iOS, so these go on the next line.
        VStack(spacing: 10) {
            actionButtons
            if !tracks.isEmpty {
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
            listOrderTitle: livePlaylist.isAllSongs ? "Library Order" : "Playlist Order",
            searchPrompt: "Search in \(livePlaylist.name)"
        )
    }

    /// "updated 3 minutes ago" under a followed playlist.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var metadataLine: String {
        let count = livePlaylist.trackCount
        let songs = "\(count) song\(count == 1 ? "" : "s")"
        var line = tracks.isEmpty ? songs : "\(songs) · \(totalDuration)"
        if let saves = saveCount, saves > 0 {
            line += " · \(saves) save\(saves == 1 ? "" : "s")"
        }
        // Any linked playlist says so, including Favourites mirroring Liked Songs.
        if let link = deps.spotifyFollowService.link(forPlaylist: playlist.id) {
            line += " · \(Self.syncLabel(for: link.direction))"
            if let status = syncStatus {
                line += " · \(status)"
            } else if let at = deps.spotifyFollowService.lastSynced[playlist.id] {
                line += " · updated \(Self.relativeFormatter.localizedString(for: at, relativeTo: .now))"
            }
        }
        return line
    }

    /// Header label for the sync direction. Only two-way links say "Synced".
    private static func syncLabel(for direction: SpotifyFollowService.Link.Direction) -> String {
        switch direction {
        case .both: return "Synced with Spotify"
        case .push: return "Sending to Spotify"
        case .pull: return "Following Spotify"
        }
    }

    /// How many people hold this playlist. A mix is yours alone, a shared row
    /// gets its total from the server, and a private playlist shows nothing.
    private func loadSaveCount() async {
        if livePlaylist.origin == .mix, !isSmart {
            saveCount = 1
            return
        }
        guard let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id) else {
            saveCount = nil
            return
        }
        saveCount = await PlaylistSharingService.shared.saveCount(sharedPlaylistID: link.sharedPlaylistID)
    }

    @ViewBuilder
    private func coverImage(size: CGFloat) -> some View {
        if let smart = smartRule {
            SmartPlaylistCover(playlist: smart, size: size)
        } else if livePlaylist.isFavourites || livePlaylist.isAllSongs {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.mixPrimary.opacity(0.15))
                Image(systemName: livePlaylist.isFavourites ? "heart.fill" : "music.note.list")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Color.mixPrimary)
            }
            .frame(width: size, height: size)
        } else {
            ArtworkThumbnail(
                // A custom cover always wins over the first track's.
                data: displayCover,
                size: size,
                cornerRadius: 14,
                placeholder: PlaylistArtwork.placeholder(for: livePlaylist),
                placeholderTint: PlaylistArtwork.tint(for: livePlaylist),
                placeholderBackground: PlaylistArtwork.background(for: livePlaylist)
            )
        }
    }

    /// The cover, which doubles as the edit button on user playlists.
    @ViewBuilder
    private func coverArt(size: CGFloat) -> some View {
        // Read-only playlists get the picture without the pencil.
        if livePlaylist.isSystem || isReadOnly {
            coverImage(size: size)
        } else {
            Button { showEditSheet = true } label: {
                coverImage(size: size)
                        .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.mixOnAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.mixAccentFill, in: Circle())
                            .padding(8)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .help("Edit cover, name and description")
        }
    }

    private var actionButtons: some View {
        HeroActionBar(
            isPlaying: isPlayingThisPlaylist,
            isShuffling: shufflePrefs.shuffles(shuffleKey),
            // Disabled when nothing is playable.
            isEmpty: playableTracks.isEmpty,
            onPlay: {
                if isPlayingThisPlaylist {
                    engine.pause()
                } else if isPausedInThisPlaylist {
                    engine.resume()
                } else {
                    // This playlist's stored shuffle choice, applied as playback starts.
                    let shuffles = shufflePrefs.shuffles(shuffleKey)
                    engine.queue.setShuffle(shuffles)
                    guard let first = shuffles
                            ? playableTracks.randomElement() : playableTracks.first else { return }
                    playAndMark(first)
                }
            },
            onShuffle: { shufflePrefs.toggle(shuffleKey) }
        ) {
            // Download sits beside Play since it acts on this playlist. Profile visibility stays in the toolbar.
            if isSmart {
                if let smart = smartRule {
                    Button {
                        deps.smartPlaylistService.setInLibrary(id: smart.id, !smart.inLibrary)
                        if !smart.inLibrary { deps.showSavedToast(.library) }
                    } label: {
                        HeroCircleLabel(systemImage: smart.inLibrary ? "checkmark" : "plus",
                                        foreground: smart.inLibrary ? .mixOnAccent : .mixTextSecondary,
                                        fill: smart.inLibrary ? .mixPrimary : .mixSurface)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .frame(width: 40, height: 40)
                    .help(smart.inLibrary ? "Remove from Your Library" : "Add to Your Library")
                    .accessibilityLabel(smart.inLibrary ? "Remove from Library" : "Add to Library")
                }
                AlbumDownloadButton(ids: playlist.trackIDs, downloads: deps.downloadManager, library: deps.libraryService)
            } else {
                downloadButton
            }

            Menu { playlistMenu } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            #if os(macOS)
            // Otherwise a Menu draws as a bordered pop-up with a chevron.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .frame(width: 40, height: 40)
            .help("More actions for \u{201C}\(playlist.name)\u{201D}")
        }
    }

    /// The offline-download toggle in the hero row.
    private var downloadButton: some View {
        // The state is the user's opt-in, not what's on disk, so it also covers songs added later.
        let isKept     = deps.downloadManager.isPlaylistOffline(playlist.id)
        // One walk of the track list for everything below.
        let summary    = downloadSummary
        // Complete is about the disk, not the opt-in. A kept playlist with nothing
        // fetchable counts too, so it doesn't sit on "try again".
        let isComplete = summary.isOffline || (isKept && summary.nothingToDownload)
        // Kept, incomplete, and nothing in progress (or offline): nothing will
        // finish it, so the button becomes "try again".
        let isStalled  = isKept && !isComplete
            && (!summary.hasWorkInFlight || !deps.downloadManager.isConnectedForDownload)
        let isFetching = isKept && !isComplete && !isStalled
        // Always a stop square while downloading, including on touch.
        let showsStop = isFetching
        return Button {
            // A stalled press retries. Un-keeping would delete what did download.
            if isStalled {
                deps.downloadManager.resumeDownloads(tracks: tracks)
            } else if isKept {
                // Turning it off deletes audio, so confirm first.
                showRemoveDownloadsConfirm = true
            } else {
                deps.downloadManager.keepPlaylistOffline(playlist.id)
            }
        } label: {
            // Solid green: kept and complete. Green ring: downloading. Orange ring:
            // stalled. Plain disc: not kept. The arrow drops its circle while a ring shows.
            HeroCircleLabel(systemImage: showsStop ? "stop.fill"
                                        : (isStalled ? "arrow.clockwise" : (isComplete ? "arrow.down.circle.fill"
                                                    : (isFetching ? "arrow.down" : "arrow.down.circle"))),
                            foreground: isStalled ? .orange
                                                  : (isComplete ? .black : (isFetching ? .green : .mixTextSecondary)),
                            fill: isStalled ? Color.orange.opacity(0.18)
                                            : (isComplete ? .green
                                             : (isFetching ? Color.green.opacity(0.18) : .mixSurface)),
                            progress: isFetching || isStalled ? summary.fraction : nil,
                            progressTint: isStalled ? .orange : .green)
        }
        .buttonStyle(.plain).mixHandCursor()
        .animation(.easeInOut(duration: 0.12), value: showsStop)
        .accessibilityAddTraits(isKept ? .isSelected : [])
        .mixConfirmationDialog(
            isFetching ? "Stop downloading and remove downloads?"
                       : "Remove from Downloads?",
            isPresented: $showRemoveDownloadsConfirm,
            titleVisibility: .visible
        ) {
            Button(isFetching ? "Stop and Remove" : "Remove", role: .destructive) {
                deps.downloadManager.togglePlaylistOffline(playlist.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Say what's lost, including anything already downloaded.
            Text(removeDownloadsMessage(isFetching: isFetching, summary: summary))
        }
        // While the button means "try again", un-keeping lives here.
        .contextMenu {
            if isStalled {
                Button("Stop Keeping Offline", role: .destructive) {
                    showRemoveDownloadsConfirm = true
                }
            }
        }
        .help(playlistDownloadHelp(summary))
        .accessibilityLabel(playlistDownloadHelp(summary))
    }

    #if os(macOS)
    /// Exports the selected songs. macOS only; on iOS it's on each row's menu.
    private var saveToDiskToolbarButton: some View {
        Button {
            saveToDisk(tracks.filter { appState.selectedTrackIDs.contains($0.id) })
        } label: {
            Label("Save a File Copy", systemImage: "square.and.arrow.down")
        }
        .disabled(appState.selectedTrackIDs.isEmpty)
        .help(appState.selectedTrackIDs.count > 1
              ? "Save the \(appState.selectedTrackIDs.count) selected songs to disk"
              : "Click a track to select it, then click here to save it to disk")
    }
    #endif

    /// Profile visibility toggle, tinted only while public.
    private var profileToolbarButton: some View {
        Button {
            setPublic(!isPublic)
        } label: {
            Label(isPublic ? "On My Profile" : "Show on My Profile",
                  systemImage: isPublic ? "person.crop.circle.badge.checkmark"
                                        : "person.crop.circle")
                .foregroundStyle(isPublic ? Color.mixPrimary : Color.mixTextSecondary)
        }
        .disabled(isTogglingPublic || deps.authService.currentUser == nil)
        .help(isPublic
              ? "This playlist is on your public profile — click to hide it"
              : "Show this playlist on your public profile")
    }

    /// Every download fact about the visible songs, from one walk. Works for
    /// mixes too, which aren't in the playlist list.
    private var downloadSummary: DownloadManager.ListDownloadSummary {
        mixMainActivity("playlist-page/download-summary") {
            deps.downloadManager.downloadSummary(tracks: tracks)
        }
    }

    /// What stopping costs, in songs. Nothing downloaded gets its own wording.
    private func removeDownloadsMessage(isFetching: Bool,
                                        summary: DownloadManager.ListDownloadSummary) -> String {
        guard isFetching else { return "You won\u{2019}t be able to play this offline." }

        let counts = (done: summary.offlineCount, total: summary.downloadableCount)
        guard counts.done > 0 else {
            return "No songs have finished downloading yet, and the rest won\u{2019}t download."
        }
        let songs = counts.done == 1 ? "1 song" : "\(counts.done) songs"
        return "The \(songs) already downloaded will be removed, and the remaining \(counts.total - counts.done) won\u{2019}t download."
    }

    private func playlistDownloadHelp(_ summary: DownloadManager.ListDownloadSummary) -> String {
        guard deps.downloadManager.isPlaylistOffline(playlist.id) else {
            guard !summary.isOffline else {
                // Already complete; pressing still covers songs added later.
                return "Every song here is already on this device — keep it that way for songs added later"
            }
            return "Keep for offline listening — songs added later download too"
        }
        guard summary.isOffline else {
            // In songs, not percent, for VoiceOver and small rings.
            let counts = (done: summary.offlineCount, total: summary.downloadableCount)
            let saved  = "\(counts.done) of \(counts.total) songs"
            // Check connectivity first: going offline leaves the queue intact, so
            // `hasWorkInFlight` would still be true.
            guard deps.downloadManager.isConnectedForDownload else {
                return deps.downloadManager.downloadOnWifiOnly && deps.downloadManager.isConnected
                    ? "Paused at \(saved) — waiting for Wi‑Fi"
                    : "Paused at \(saved) — waiting for a connection"
            }
            guard summary.hasWorkInFlight else {
                // Stalled with a connection, so it's the songs, not the network.
                let failed = deps.downloadManager.failedCount(tracks: tracks)
                let songs  = failed == 1 ? "1 song" : "\(failed) songs"
                return failed > 0
                    ? "\(songs) didn\u{2019}t download — click to try again"
                    : "Stopped at \(saved) — click to finish downloading"
            }
            return "Downloading — \(saved) saved. Click to stop and remove."
        }
        if summary.hasRemovableDownloads { return "Stop keeping offline and remove downloads" }
        #if os(macOS)
        return "Kept on your Mac"
        #else
        return "Kept on this device"
        #endif
    }

    /// Whether this playlist started playback, asked of the queue's source.
    /// Checking membership would light up every playlist containing the song.
    private var isPlayingThisPlaylist: Bool {
        engine.state.isPlaying && queueService.sourcePlaylistID == playlist.id
    }

    /// Paused with this playlist loaded, so Play resumes instead of restarting.
    private var isPausedInThisPlaylist: Bool {
        engine.state == .paused && queueService.sourcePlaylistID == playlist.id
    }

    private var shuffleKey: ShufflePreferences.Key { .playlist(playlist.id) }

    // MARK: - Empty State

    private var emptyState: some View {
        let (icon, title, message): (String, String, String) = {
            if playlist.isAllSongs {
                return ("music.note.list",
                        "No Songs Yet",
                        "Import music to fill your library. Every song you add will appear here automatically.")
            } else if playlist.isFavourites {
                return ("heart",
                        "No Liked Songs Yet",
                        "Tap ♥ on any song to like it. Your hearted songs will appear here.")
            } else if isSmart {
                return ("wand.and.stars",
                        "No Matching Songs",
                        "Nothing in your library fits this smart playlist yet. It fills itself as you import and play music.")
            } else {
                return (MixtapeIcons.playlist,
                        "Playlist is Empty",
                        "Swipe right on any song and tap \"Add to Playlist\" to add songs here.")
            }
        }()
        return VStack(spacing: 16) {
            Spacer(minLength: 40)
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(message)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Search found nothing, as opposed to an empty playlist.
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
    }

    // MARK: - The "..." menu

    /// Spotify sync controls for any linked playlist, however it was set up.
    @ViewBuilder
    private var spotifySyncMenu: some View {
        if let link = deps.spotifyFollowService.link(forPlaylist: playlist.id) {
            let isLiked = link.kind == .likedSongs

            // Buttons with icons, not Toggles: a menu toggle only sometimes reserves
            // checkmark space, which shifts the labels.
            Button {
                setSyncDirection(pushes: !link.direction.pushes, pulls: link.direction.pulls)
            } label: {
                // Liked Songs push only adds, so it's worded differently.
                Label(isLiked ? "Add New Likes to Spotify" : "Send Changes to Spotify",
                      systemImage: link.direction.pushes ? "checkmark.circle.fill" : "circle")
            }

            Button {
                setSyncDirection(pushes: link.direction.pushes, pulls: !link.direction.pulls)
            } label: {
                Label(isLiked ? "Bring Liked Songs from Spotify" : "Bring Changes from Spotify",
                      systemImage: link.direction.pulls ? "checkmark.circle.fill" : "circle")
            }

            Divider()

            Button {
                // `sync` records errors in `failures` for the timer, so a manual press reads them back.
                Task {
                    await deps.spotifyFollowService.sync(playlistID: playlist.id,
                                                         force: true)
                    if let why = deps.spotifyFollowService.failures[playlist.id] {
                        syncError = why
                    }
                }
            } label: {
                Label(isSyncing ? "Syncing\u{2026}" : "Sync Now",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)

            // Liked Songs lives at the collection route, not a playlist URL.
            if let url = URL(string: isLiked
                             ? "https://open.spotify.com/collection/tracks"
                             : "https://open.spotify.com/playlist/\(link.sourceID)") {
                Button {
                    SpotifyAppLink.open(url)
                } label: {
                    Label("Open in Spotify", systemImage: "arrow.up.forward.app")
                }
            }

            Button {
                // Liked Songs leaves no playlist behind to delete, so offer to remove the songs it added.
                if isLiked {
                    likedContributions = spotifyContributions
                    showStopLikedSongs = true
                } else {
                    deps.spotifyFollowService.unlink(playlistID: playlist.id)
                }
            } label: {
                Label(isLiked ? "Stop Syncing with Liked Songs" : "Stop Syncing with Spotify",
                      systemImage: "link.badge.plus")
            }

            Divider()
        } else if playlist.isFavourites, deps.spotifyAuth.isAuthorized,
                  !deps.spotifyAuth.needsReauthorization {
            // The way back to a Liked Songs link. Re-importing would walk every song again.
            Button {
                linkLikedSongs()
            } label: {
                Label("Sync with Liked Songs", systemImage: "heart.circle")
            }

            // Unlinking keeps the songs it brought, so offer to remove them here.
            if spotifyContributions > 0 {
                Button(role: .destructive) {
                    likedContributions = spotifyContributions
                    showStopLikedSongs = true
                } label: {
                    Label("Remove Songs Imported from Spotify", systemImage: "trash")
                }
            }

            Divider()
        }
    }

    /// Links Favourites to Spotify's Liked Songs. No `lastSyncedAt`, so the
    /// first sync only adds on both sides. See `SpotifyFollowService.setDirection`.
    private func linkLikedSongs() {
        deps.spotifyFollowService.link(
            .init(sourceID: SpotifyLibraryItem.likedSongsID,
                  kind: .likedSongs,
                  name: "Liked Songs"),
            toPlaylist: playlist.id)
        Task {
            await deps.spotifyFollowService.sync(playlistID: playlist.id, force: true)
            if let why = deps.spotifyFollowService.failures[playlist.id] {
                syncError = why
            }
        }
    }

    private var isSyncing: Bool {
        deps.spotifyFollowService.syncing.contains(playlist.id)
    }

    /// Header status for the link: running, slow, failed, or last updated.
    private var syncStatus: String? {
        if isSyncing {
            return syncIsSlow ? "Still trying to sync\u{2026}" : "Syncing\u{2026}"
        }
        if let throttle = throttleNote { return throttle }
        if deps.spotifyFollowService.failures[playlist.id] != nil {
            return "Couldn't sync"
        }
        return nil
    }

    private var throttleNote: String? {
        deps.spotifyFollowService.failures[playlist.id] == nil ? nil : throttle.phrase
    }

    private var isFollowing: Bool {
        deps.spotifyFollowService.isFollowing(playlistID: playlist.id)
    }

    /// Songs here that the Spotify link added: the size of the undo.
    private var spotifyContributions: Int {
        deps.spotifyFollowService.contributionCount(playlistID: playlist.id)
    }

    /// Both off means unlink. Neither side's copy is deleted.
    private func setSyncDirection(pushes: Bool, pulls: Bool) {
        let service = deps.spotifyFollowService
        switch (pushes, pulls) {
        case (true, true):   service.setDirection(.both, forPlaylist: playlist.id)
        case (true, false):  service.setDirection(.push, forPlaylist: playlist.id)
        case (false, true):  service.setDirection(.pull, forPlaylist: playlist.id)
        case (false, false): service.unlink(playlistID: playlist.id)
        }
    }

    /// The "..." menu, the same on both platforms. Repair items at the bottom
    /// only appear when something is wrong.
    @ViewBuilder
    private var playlistMenu: some View {
        // Same item as on a Discover mix page. Songs without audio are skipped, as with Play.
        Button {
            deps.onlineCoordinator.addToQueue(localTracks: playableTracks)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(playableTracks.isEmpty)

        // How this playlist's songs run into each other while it plays. Default follows Settings.
        Picker(selection: Binding(
            get: { transitions.modes[playlist.id] },
            set: { transitions.setMode($0, for: playlist.id) }
        )) {
            Text("Default").tag(CrossfadeMode?.none)
            ForEach(CrossfadeMode.allCases) { Text($0.title).tag(Optional($0)) }
        } label: {
            Label("Transitions", systemImage: "wand.and.rays")
        }
        .pickerStyle(.menu)

        Divider()

        spotifySyncMenu

        // Read-only playlists only offer a copy. Publishing, inviting and renaming are owner-only.
        if isReadOnly {
            Button {
                makeEditableCopy()
            } label: {
                Label("Make a Copy", systemImage: "doc.on.doc")
            }
            .disabled(tracks.isEmpty)
            if !isSmart { PlaylistShareMenuItems(playlist: playlist) }

            Divider()
        } else if !playlist.isSystem {
            Button {
                duplicatePlaylist()
            } label: {
                Label("Duplicate Playlist", systemImage: "doc.on.doc")
            }

            Button {
                setPublic(!isPublic)
            } label: {
                Label(isPublic ? "Hide from My Profile" : "Show on My Profile",
                      systemImage: isPublic ? "eye.slash" : "person.crop.circle")
            }
            .disabled(isTogglingPublic || deps.authService.currentUser == nil)

            // Share hands out a mixtaped.tech link. Inviting editors is a separate item.
            Button {
                showCollabShare = true
            } label: {
                Label("Invite Collaborators", systemImage: "person.badge.plus")
            }
            PlaylistShareMenuItems(playlist: playlist)
            Button {
                showDubSheet = true
            } label: {
                Label("Dub for Someone\u{2026}", systemImage: "recordingtape")
            }
            .disabled(deps.authService.currentUser == nil || tracks.isEmpty)

            Divider()

            Button {
                showEditSheet = true
            } label: {
                Label("Edit Details", systemImage: "pencil")
            }
            Button {
                showLinerNotes = true
            } label: {
                Label("Liner Notes\u{2026}", systemImage: "text.quote")
            }
        }

        // Hidden without a Spotify account, and once linked, since it would make a second copy.
        if deps.spotifyAuth.isAuthorized, !tracks.isEmpty,
           deps.spotifyFollowService.link(forPlaylist: playlist.id) == nil {
            Divider()
            Button {
                showSpotifyExport = true
            } label: {
                Label("Send to Spotify", systemImage: "arrow.up.forward.square")
            }
        }

        Divider()

        // Always offered: a cover can be present and still wrong.
        Button {
            Task { await refetchCovers() }
        } label: {
            Label("Refetch All Covers", systemImage: "photo.badge.arrow.down")
        }
        .disabled(isRefetchingCovers || tracks.isEmpty)

        let restorable = restorableTrackIDs
        if !restorable.isEmpty {
            Button {
                restoreMissingSongs()
            } label: {
                Label("Restore \(restorable.count) Missing Song\(restorable.count == 1 ? "" : "s")",
                      systemImage: "arrow.uturn.backward.circle")
            }
        }

        if !playlist.isSystem {
            Divider()
            Button(role: .destructive) {
                songsLostWithPlaylist = isSmart ? 0
                    : deps.libraryService.songCountRemovedWithPlaylist(id: playlist.id)
                showDeleteConfirm = true
            } label: {
                // "Delete" overstates it for a saved playlist or mix; the original is untouched.
                Label(isReadOnly && !isSmart ? "Remove from Library" : "Delete Playlist",
                      systemImage: "trash")
            }
        }
    }

    /// Ids the playlist holds but can't show. A cheap gate in front of `restorableTrackIDs`.
    private var hiddenTrackCount: Int {
        max(0, livePlaylist.trackIDs.count - tracks.count)
    }

    /// Hidden songs a restore would actually bring back.
    private var restorableTrackIDs: [UUID] {
        guard hiddenTrackCount > 0 else { return [] }
        let visible = Set(tracks.map(\.id))
        return deps.libraryService.resurrectableTrackIDs(
            among: livePlaylist.trackIDs.filter { !visible.contains($0) })
    }

    // MARK: - Repair

    /// Re-fetches cover art for every song here: your published covers first,
    /// then the catalogue. Results are saved and synced; a miss changes nothing.
    private func refetchCovers() async {
        let ids = tracks.map(\.id)
        guard !ids.isEmpty, !isRefetchingCovers else { return }
        isRefetchingCovers = true
        defer { isRefetchingCovers = false }

        deps.showToast("Refetching \(ids.count) cover\(ids.count == 1 ? "" : "s")…")

        let updated = await deps.libraryService.backfillPlaceholderArtwork(
            trackIDs:          ids,
            publishedBy:       deps.authService.currentUser?.id,
            using:             deps.itunesClient,
            replacingExisting: true
        )

        deps.showToast(.done(updated == 0
                             ? "Covers are up to date"
                             : "Updated \(updated) cover\(updated == 1 ? "" : "s")"))
    }

    /// Restores songs a bad re-sync hid, scoped to what the menu counted. The
    /// library-wide version is in Settings.
    private func restoreMissingSongs() {
        let restored = deps.libraryService.restoreTracks(ids: restorableTrackIDs)
        // Zero here means a sync pruned the ids between menu and tap.
        deps.showToast(restored == 0
                       ? Toast("Nothing to restore. Those songs were deleted on purpose.")
                       : .done("Restored \(restored) song\(restored == 1 ? "" : "s")"))
    }

    // MARK: - Byline

    private var unavailableMessage: String {
        let who = livePlaylist.ownerName.map { "@\($0)" } ?? "The owner"
        return "\(who) has made this playlist private, so it can't update any more. You can keep it in your library in case it comes back, or remove it."
    }

    /// The byline: a mix belongs to Mixtape, a saved playlist to its stored
    /// owner, and your own lists collaborators once it has any. Savers never appear.
    private func loadByline() async {
        switch livePlaylist.origin {
        case .mix:
            byline = [.mixtape]
            return
        case .subscribed:
            // Paint the stored name first; the lookup only makes it tappable.
            let name = livePlaylist.ownerName ?? "Unknown"
            byline = [BylineMember(name: name)]
            guard livePlaylist.ownerName != nil,
                  let owner = try? await deps.authService
                      .searchUsers(matching: name, limit: 5)
                      .first(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            byline = [BylineMember(id: owner.id, name: owner.name, avatarURL: owner.avatarURL)]
            bylineProfiles[owner.id] = owner
            return
        case .spotifyMirror:
            // A Spotify mirror says so on the metadata line instead.
            byline = []
            return
        case .owned:
            break
        }

        guard let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id),
              let rows = try? await PlaylistSharingService.shared
                  .collaborators(sharedPlaylistID: link.sharedPlaylistID),
              // Only joined members count, not pending invites.
              case let joined = rows.filter({ $0.status == .joined }),
              !joined.isEmpty
        else {
            byline = []
            return
        }

        var members: [BylineMember] = []

        // You first, from your profile, since `displayName` can fall back to the email.
        if let user = deps.authService.currentUser {
            let profile = try? await deps.authService.fetchProfile(id: user.id)
            members.append(BylineMember(id: user.id,
                                        name: profile?.name ?? user.displayName,
                                        avatarURL: profile?.avatarURL ?? user.avatarURL))
            if let profile { bylineProfiles[profile.id] = profile }
        }

        for row in joined where row.userID != deps.authService.currentUser?.id {
            guard let profile = try? await deps.authService.fetchProfile(id: row.userID) else { continue }
            members.append(BylineMember(id: profile.id,
                                        name: profile.name,
                                        avatarURL: profile.avatarURL))
            bylineProfiles[profile.id] = profile
        }

        byline = members.count > 1 ? members : []
    }

    /// Duplicates the playlist without its Spotify link, so two playlists don't write to one remote.
    private func duplicatePlaylist() {
        guard let copy = deps.libraryService.duplicatePlaylist(id: playlist.id) else { return }
        deps.showToast(Toast.done("Duplicated as \u{201C}\(copy.name)\u{201D}").action("View") { Toast.openPlaylist(copy.id) })
    }

    /// Turns a read-only playlist into your own: a local, unlinked `.owned`
    /// playlist pointing at the same rows.
    private func makeEditableCopy() {
        let source = livePlaylist
        guard !source.trackIDs.isEmpty else { return }

        let copy = deps.libraryService.createPlaylist(name: source.name,
                                                      description: source.description,
                                                      artworkData: source.displayArtwork)
        deps.libraryService.setTracks(source.trackIDs, inPlaylist: copy.id)
        deps.showToast(Toast.done("Copied \u{201C}\(source.name)\u{201D} to your library")
            .action("View") { Toast.openPlaylist(copy.id) })
    }

    // MARK: - Profile visibility

    /// Shows the cached public state, then corrects it from the server.
    private func loadPublicState() async {
        isPublic = PlaylistSharingService.shared.isPublicCached(localPlaylistID: playlist.id)

        guard let userID = deps.authService.currentUser?.id else { return }
        guard let visibility = try? await deps.profileStatsService
            .fetchMyPlaylistVisibility(userID: userID) else { return }

        // Absent from the map means never published, which is private.
        let truth = visibility[playlist.id]?.isPublic ?? false
        isPublic = truth
        PlaylistSharingService.shared.cachePublic(truth, localPlaylistID: playlist.id)
    }

    private func setPublic(_ value: Bool) {
        guard !isTogglingPublic else { return }
        isTogglingPublic = true

        Task {
            defer { isTogglingPublic = false }
            do {
                try await PlaylistSharingService.shared.setPublic(
                    value,
                    playlist: livePlaylist,
                    tracks: tracks,
                    deviceID: AppDependencies.deviceID
                )
                isPublic = value
            } catch {
                publicError = error.localizedDescription
            }
        }
    }

    /// Offline and not downloaded: the row is greyed and a tap says so.
    private func offlineUnavailable(_ track: Track) -> Bool {
        deps.libraryService.offlineOnly
            && !deps.downloadManager.downloadedTrackIDs.contains(track.id)
    }

    /// Plays `track` with the playlist queued behind it. `selection` limits the queue to those rows.
    private func playAndMark(_ track: Track, within selection: [Track]? = nil) {
        guard !offlineUnavailable(track) else {
            deps.showToast(.failed("\u{201C}\(track.displayTitle)\u{201D} isn't downloaded — you're offline."))
            return
        }
        // No placeholder guard: the engine resolves placeholders online.
        PlaylistMetadataService.shared.markPlayed(playlistID: playlist.id)
        mixMainActivity("playlist-page/mark-played-refresh") {
            deps.libraryService.refreshPlaylists()
        }
        // Play the clicked song. If it isn't in `filtered`, widen the context, never substitute.
        let filtered = selection.map { $0.filter(\.canResolveAudio) } ?? playableTracks
        let context  = filtered.contains { $0.id == track.id }
                     ? filtered
                     : (selection ?? visibleTracks)
        Task {
            await engine.play(track: track, in: context,
                              source: .playlist(id: playlist.id, name: playlist.name))
        }
    }

    // MARK: - Sides

    /// Visible rows split by side, or nil for one plain list. Sides follow the
    /// running order, so any other sort hides them.
    private var sideGroups: [SideGroup]? {
        guard trackSort.isDefault else { return nil }
        let layout = livePlaylist.sideLayout
        guard !layout.isEmpty else { return nil }
        let numbers = livePlaylist.sideNumbers()
        var rows = Array(repeating: [Track](), count: layout.count)
        for track in visibleTracks { rows[numbers[track.id] ?? 0].append(track) }
        return layout.indices.compactMap { i in
            rows[i].isEmpty ? nil : SideGroup(index: i, side: layout[i].side, tracks: rows[i])
        }
    }

    /// "Tape · Sides A, B" once a playlist has sides.
    private var eyebrow: String {
        if isSmart { return "Smart Playlist" }
        let count = livePlaylist.sideLayout.count
        guard count > 1 else { return "Playlist" }
        return "Tape \u{00B7} Sides " + (0..<count).map { PlaylistSide.letter($0) }.joined(separator: ", ")
    }

    private var canEditSides: Bool {
        !isReadOnly && !isSmart && !livePlaylist.isSystem && trackSort.isDefault
    }

    /// Not the first song, and not one that already starts a side.
    private func canStartSide(at track: Track) -> Bool {
        guard canEditSides, livePlaylist.trackIDs.first != track.id else { return false }
        return !livePlaylist.sides.contains { $0.start == track.id }
    }

    private func editSides(_ body: (inout Playlist) -> Void) {
        deps.libraryService.editSides(ofPlaylist: playlist.id, body)
    }

    private func sideHeader(_ group: SideGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .foregroundStyle(Color.mixTextPrimary)
            if !group.side.name.isEmpty {
                Text(group.side.name)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu { sideMenu(group) } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .foregroundStyle(Color.mixTextSecondary)
            .accessibilityLabel("\(group.title) options")
        }
        .font(.mixTitle2)
        #if os(macOS)
        .padding(.horizontal, 22)
        #else
        .padding(.horizontal, TrackColumns.rowPadding)
        #endif
        .padding(.top, 20)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu { sideMenu(group) }
    }

    @ViewBuilder
    private func sideMenu(_ group: SideGroup) -> some View {
        Button("Play \(group.title)", systemImage: MixtapeIcons.play) {
            // Auto-reverse plays on through the other sides; otherwise just this one.
            // ponytail: turning it on mid-side still loops that side until the next play.
            if let first = group.tracks.first(where: \.canResolveAudio) ?? group.tracks.first {
                playAndMark(first, within: engine.queue.repeatMode == .all ? nil : group.tracks)
            }
        }
        if canEditSides {
            Divider()
            Button("Rename Side\u{2026}", systemImage: "pencil") {
                sideName = group.side.name
                renamingSide = group
            }
            // Not destructive: the songs join the side before.
            if let start = group.side.start {
                Button("Remove Side", systemImage: "minus.circle") {
                    editSides { $0.removeSide(startingAt: start) }
                }
            }
        }
    }

    /// Opens Discover searching this song. The search fires directly since on
    /// iOS the Discover view may not exist yet.
    private func findInDiscover(_ track: Track) {
        let query = [track.title, track.artistName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return }

        let store = DiscoverSessionStore.shared
        store.path.removeAll()

        #if os(macOS)
        // Select Discover first, or the query lands in the library's search box.
        appState.selection  = .discover
        appState.searchText = query
        // Commit the search. Setting the text alone only shows suggestions.
        appState.showSearchResults()
        #else
        store.iosQuery = query
        iosAppState.selectedTab = .discover
        #endif

        store.search(query, using: deps.itunesClient, immediate: true)
    }

    /// Exports `track` to the export folder with tags. On macOS, asks for a folder if none is set.
    private func saveToDisk(_ track: Track) { saveToDisk([track]) }

    /// Same for a selection. A failed song is reported and the rest continue.
    private func saveToDisk(_ targets: [Track]) {
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            #if os(macOS)
            if ExportManager.shared.exportURL == nil {
                let picked: URL? = await withCheckedContinuation { cont in
                    FolderPickerHelper.show { url in cont.resume(returning: url) }
                }
                guard let folder = picked else { return }   // user cancelled
                guard (try? ExportManager.shared.setExportURL(folder)) != nil else { return }
            }
            #endif

            // Fetching is the download manager's job. One toast for the whole run.
            let fetching = targets.filter { !deps.downloadManager.status(for: $0).isAvailableOffline }
            if let first = fetching.first {
                deps.showToast(fetching.count == 1
                               ? "Fetching \"\(first.title)\"…"
                               : "Fetching \(fetching.count) songs…")
            }

            var failures = 0
            for track in targets {
                do {
                    try await deps.downloadManager.saveFileCopy(of: track)
                } catch {
                    failures += 1
                    if targets.count == 1 {
                        deps.showToast(.failed(error.localizedDescription))
                        return
                    }
                }
            }

            let saved = targets.count - failures
            if targets.count == 1 {
                deps.showToast(.done("Saved \"\(targets[0].title)\""))
            } else if failures == 0 {
                deps.showToast(.done("Saved \(saved) songs"))
            } else {
                deps.showToast(.failed("Saved \(saved) of \(targets.count) songs"))
            }
        }
    }

    /// The shared song menu. Read-only playlists only lose "Remove from Playlist".
    private func trackContextMenu(for track: Track) -> some View {
        let targets    = menuTargets(for: track)
        let removeFrom = playlist.isAllSongs ? "Library" : (isReadOnly ? nil : "Playlist")
        return LibrarySongMenu(
            targets: targets,
            onPlay:  { playAndMark(track, within: targets.count > 1 ? targets : nil) },
            onChoosePlaylist: { tracksForAddToPlaylist = $0 },
            removeFrom: removeFrom,
            onRemove: removeFrom == nil ? nil : { rows in
                // All Songs confirms like ⌘⌫, since this deletes everywhere.
                guard !playlist.isAllSongs else { tracksPendingDeletion = rows; return }
                deps.removeTracks(ids: rows.map(\.id), fromPlaylist: playlist.id)
                #if os(macOS)
                appState.clearTrackSelection()
                #endif
            },
            onSaveToDisk: { saveToDisk($0) },
            onOpenAlbum:  { openAlbum(for: track) }
        )
    }

    // MARK: - Go to Artist / Go to Album

    private func openArtist(named name: String) {
        #if os(macOS)
        appState.openDiscoverArtist(named: name)
        #else
        // Artist opens in Discover, same as macOS.
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    private func openAlbum(for track: Track) {
        #if os(macOS)
        appState.openDiscoverAlbum(for: track)
        #else
        // The full album from the catalogue; offline, the local one.
        let local = deps.libraryService.album(title: track.albumTitle, artistName: track.artistName, containing: track.id)
        guard deps.downloadManager.isConnected, !track.albumTitle.isEmpty else { navAlbum = local; return }
        Task {
            let artist = ImportService.creditedArtists(from: track.artistName).first ?? track.artistName
            let probe = OnlineTrack(title: "", artistName: artist, albumTitle: track.albumTitle,
                                    duration: 0, artworkURL: nil, sourceID: nil)
            if let online = await deps.itunesClient.resolveAlbum(for: probe) { navOnlineAlbum = online }
            else { navAlbum = local }
        }
        #endif
    }

    // MARK: - Row menus

    /// iOS has no pointer selection, so a row's menu acts on that row.
    private func menuTargets(for track: Track) -> [Track] { [track] }

    #if os(iOS)
    @ViewBuilder
    private func trackRow(track: Track, index: Int, isSelected: Bool) -> some View {
        PlaylistTrackRow(
            track:             track,
            index:             index,
            columns:           columns,
            isSelected:        isSelected,
            isCurrent:         engine.queue.currentTrack?.id == track.id,
            isPlaying:         engine.state.isPlaying,
            isFavourited:      deps.libraryService.isFavourited(trackID: track.id),
            onToggleFavourite: { deps.toggleFavourite(trackID: track.id) },
            availability:      deps.downloadManager.status(for: track.id),
            isResolving:       engine.routingTrackIDs.contains(track.id),
            isOfflineUnavailable: offlineUnavailable(track),
            onPlay:            { playAndMark(track) },
            onSelect:          {}
        )
        // Rows draw their own hover pill. See `TrackColumns`.
        .listRowInsets(TrackColumns.rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            trackContextMenu(for: track)
            if canStartSide(at: track) {
                Divider()
                Button("Start New Side Here", systemImage: "rectangle.split.1x2") {
                    editSides { $0.startSide(at: track.id) }
                }
            }
        }
        // Swipe left: delete / remove
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if playlist.isAllSongs {
                // Confirms: this deletes from every device.
                Button(role: .destructive) {
                    tracksPendingDeletion = [track]
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if !isReadOnly {
                Button(role: .destructive) {
                    deps.removeTracks(ids: [track.id], fromPlaylist: playlist.id)
                } label: {
                    Label(
                        playlist.isFavourites ? "Unlike" : "Remove",
                        systemImage: playlist.isFavourites ? "heart.slash" : "minus.circle"
                    )
                }
            }
            // Read-only: no swipe action.
        }
        // Swipe right: add to playlist
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                tracksForAddToPlaylist = [track]
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .tint(Color.mixPrimary)
        }
    }
    #endif
}

/// One side's visible rows on the playlist page.
private struct SideGroup: Identifiable {
    let index: Int
    let side: PlaylistSide
    let tracks: [Track]
    var id: Int { index }
    var title: String { "Side \(PlaylistSide.letter(index))" }
}

// MARK: - Track Table Columns

/// Which columns the track list shows, and their widths. Header and rows
/// share these values to line up. Chosen by width, not platform.
struct TrackColumns {

    var showsAlbum = false
    var showsDate  = false
    /// Zero when the album column is hidden.
    var albumWidth: CGFloat = 0

    /// True once any extra column is showing.
    var isTable: Bool { showsAlbum || showsDate }

    static let date:     CGFloat = 96
    static let heart:    CGFloat = 32
    static let duration: CGFloat = 44
    /// Artwork (44) plus the gap before the title, so the header's "Title" lines up.
    static let titleInset: CGFloat = 56

    // MARK: Row geometry
    // iOS runs tight at the leading edge to give titles room; the trailing side keeps more.

    #if os(iOS)
    /// Room for four digits at 12pt monospaced.
    static let index:      CGFloat = 32
    /// Between the index, the title block and each trailing column.
    static let gutter:     CGFloat = 8
    /// Inside the row's own selection/hover pill.
    static let rowPadding: CGFloat = 6
    static let rowLeading:  CGFloat = 4
    static let rowTrailing: CGFloat = 8
    /// Row padding. Zero on the Mac for a dense table.
    static let rowVertical: CGFloat = 8
    #else
    /// See the iOS note: sized for four digits, not two.
    static let index:      CGFloat = 32
    static let gutter:     CGFloat = 10
    static let rowPadding: CGFloat = 8
    static let rowLeading:  CGFloat = 10
    static let rowTrailing: CGFloat = 10
    static let rowVertical: CGFloat = 0
    #endif

    /// The insets every row and the column header above them share.
    static var rowInsets: EdgeInsets {
        EdgeInsets(top: rowVertical, leading: rowLeading,
                   bottom: rowVertical, trailing: rowTrailing)
    }

    init(width: CGFloat) {
        showsAlbum = width >= 640
        showsDate  = width >= 860
        albumWidth = showsAlbum ? min(max(width * 0.24, 130), 280) : 0
    }
}

// MARK: - Column Header

/// The column header strip. Internal so mix pages can reuse it over the same rows.
struct TrackListHeader: View {

    let columns: TrackColumns

    var body: some View {
        HStack(spacing: TrackColumns.gutter) {
            Text("#")
                .frame(width: TrackColumns.index, alignment: .trailing)

            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TrackColumns.titleInset)

            if columns.showsAlbum {
                Text("Album")
                    .frame(width: columns.albumWidth, alignment: .leading)
            }

            if columns.showsDate {
                Text("Date added")
                    .frame(width: TrackColumns.date, alignment: .leading)
            }

            // Reserve the heart column so the others don't drift.
            Color.clear
                .frame(width: TrackColumns.heart, height: 1)

            Image(systemName: "clock")
                .frame(width: TrackColumns.duration, alignment: .trailing)
        }
        .font(.mixCaption)
        .foregroundStyle(Color.mixTextTertiary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Playlist Track Row
// A playlist row: the number turns into a play button on hover, with an inset
// hover/selection pill. Single-click selects, double-click plays.

struct PlaylistTrackRow: View {

    let track:  Track
    let index:  Int
    let columns: TrackColumns
    let isSelected: Bool
    let isCurrent:  Bool
    let isPlaying:  Bool
    let isFavourited: Bool
    let onToggleFavourite: () -> Void
    let availability: TrackAvailability
    let isResolving: Bool
    /// See `TrackRowView.isOfflineUnavailable`.
    var isOfflineUnavailable: Bool = false
    let onPlay:   () -> Void
    let onSelect: () -> Void
    /// Non-nil outside the library: the row saves instead of liking. See `TrackRowView.onSaveToLibrary`.
    var onSaveToLibrary: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: TrackColumns.gutter) {
            indexColumn

            // In table mode the heart gets its own column.
            TrackRowView(
                track:             track,
                isCurrent:         isCurrent,
                isPlaying:         isPlaying,
                isFavourited:      columns.isTable ? nil : isFavourited,
                onToggleFavourite: columns.isTable ? nil : onToggleFavourite,
                availability:      availability,
                showsTrailing:     !columns.isTable,
                onSaveToLibrary:   columns.isTable ? nil : onSaveToLibrary,
                isResolving:       isResolving,
                isOfflineUnavailable: isOfflineUnavailable
            )

            if columns.showsAlbum {
                Text(track.albumTitle.isEmpty ? "—" : track.albumTitle)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                    .frame(width: columns.albumWidth, alignment: .leading)
            }

            if columns.showsDate {
                Text(dateAdded)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
                    .frame(width: TrackColumns.date, alignment: .leading)
                    // The column rounds; the exact stamp is one hover away.
                    .help(AddedDateText.exact(track.dateImported))
                    .accessibilityLabel(AddedDateText.accessibleLabel(track.dateImported))
            }

            if columns.isTable {
                if let save = onSaveToLibrary {
                    SaveToLibraryButton(trackID:  track.id,
                                        identity: (track.title, track.artistName, track.duration),
                                        size:     15,
                                        action:   save)
                        .frame(width: TrackColumns.heart)
                } else {
                    favouriteButton
                }
                Text(track.formattedDuration)
                    .font(.mixCaption.monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
                    .frame(width: TrackColumns.duration, alignment: .trailing)
            }
        }
        .padding(.horizontal, TrackColumns.rowPadding)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovered = $0 }
        #else
        .onTapGesture { onPlay() }
        #endif
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var background: Color {
        if isSelected { return Color.mixPrimary.opacity(0.20) }
        if isHovered  { return Color.primary.opacity(0.07) }
        return .clear
    }

    /// The position number, right-aligned so the artwork lines up.
    private var indexColumn: some View {
        Group {
            if isHovered {
                Image(systemName: MixtapeIcons.play)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
            } else if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
            } else {
                Text("\(index)")
                    .font(.system(size: MixFontScale.size(12), weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: TrackColumns.index, alignment: .trailing)
    }

    /// Table mode only; otherwise `TrackRowView` draws the heart.
    private var favouriteButton: some View {
        Button(action: onToggleFavourite) {
            Image(systemName: isFavourited ? "heart.fill" : "heart")
                .font(.system(size: 15))
                .foregroundStyle(isFavourited ? Color.mixPrimary : Color.mixTextTertiary)
                .frame(width: TrackColumns.heart, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        #if os(macOS)
        // Unliked hearts only show on hover.
        .opacity(isFavourited || isHovered ? 1 : 0)
        #endif
    }

    /// Shares `AddedDateText` with the macOS table so both word dates the same.
    private var dateAdded: String { AddedDateText.relative(track.dateImported) }
}

// MARK: - Add to Playlist Sheet

/// Pick playlists for a song. Shows current membership and stays open for several adds.
struct AddToPlaylistSheet: View {

    /// Why the sheet was opened, which decides what it leads with.
    enum Purpose {
        /// Opened from a menu.
        case add
        /// Opened from the check on a saved song. Also lists the library under "Saved in".
        case savedIn
    }

    /// The songs being filed. With several, each row applies to all of them.
    let tracks: [Track]
    var purpose: Purpose = .add
    /// Hidden from the list. Nil from the player, where every playlist is offered.
    var sourcePlaylistID: UUID? = nil

    /// Same list, different chrome.
    enum Chrome {
        /// A modal sheet: iOS, and the Mac where there's no window for a panel.
        case sheet
        /// A corner panel above the player bar. See `SavedInPanel`.
        case panel
    }

    var chrome: Chrome = .sheet
    /// Close action when not a sheet. Nil uses the environment's dismiss.
    var onClose: (() -> Void)? = nil

    init(track: Track,
         purpose: Purpose = .add,
         sourcePlaylistID: UUID? = nil,
         chrome: Chrome = .sheet,
         onClose: (() -> Void)? = nil) {
        self.init(tracks: [track], purpose: purpose, sourcePlaylistID: sourcePlaylistID,
                  chrome: chrome, onClose: onClose)
    }

    init(tracks: [Track],
         purpose: Purpose = .add,
         sourcePlaylistID: UUID? = nil,
         chrome: Chrome = .sheet,
         onClose: (() -> Void)? = nil) {
        self.tracks           = tracks
        self.purpose          = purpose
        self.sourcePlaylistID = sourcePlaylistID
        self.chrome           = chrome
        self.onClose          = onClose
    }

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var meta = PlaylistMetadataService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var newPlaylistName = ""
    @State private var isNamingNewPlaylist = false
    @FocusState private var newNameFocused: Bool
    /// Which row the pointer is over. Nil on iOS, where there's no pointer.
    @State private var hoveredID: UUID?

    /// Playlists holding every song, kept as state so the checkmark and section change together on tap.
    @State private var membership: Set<UUID> = []

    /// Playlists holding some of the selection (multi-song only).
    @State private var partialMembership: Set<UUID> = []

    /// Per-row counter that fires the unfile bounce.
    @State private var unfilePops: [UUID: Int] = [:]

    /// Bumped when the library publishes, since `deps` doesn't republish `libraryService` changes.
    @State private var libraryTick = 0

    /// Stands in for the "New playlist" row in `hoveredID`.
    private static let newRowID = UUID()

    // Playlists you can file into: your own plus Favourites. Not All Songs
    // (automatic), mixes or saved playlists (read-only).
    private var candidates: [Playlist] {
        deps.libraryService.playlists.filter {
            $0.id != sourcePlaylistID && !$0.isDeleted && !$0.isAllSongs && $0.isEditable
        }
    }

    private var matching: [Playlist] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Already holds the song, or all of them.
    private var containing: [Playlist] {
        matching.filter { membership.contains($0.id) }
    }

    /// Doesn't yet, most recently updated first. Partial matches go here.
    private var available: [Playlist] {
        matching
            .filter { !membership.contains($0.id) }
            .sorted { $0.sync.localModifiedAt > $1.sync.localModifiedAt }
    }

    /// Membership from the library, used to seed `membership` on open.
    private func storedMembership() -> (full: Set<UUID>, partial: Set<UUID>) {
        var full    = Set<UUID>()
        var partial = Set<UUID>()
        let ids     = Set(tracks.map(\.id))
        for playlist in deps.libraryService.playlists {
            let held = ids.filter(playlist.trackIDs.contains)
            if held.count == ids.count      { full.insert(playlist.id) }
            else if !held.isEmpty           { partial.insert(playlist.id) }
        }
        return (full, partial)
    }

    var body: some View {
        platformBody
            .task(id: tracks.map(\.id)) {
                (membership, partialMembership) = storedMembership()
            }
            .onReceive(deps.libraryService.objectWillChange) { _ in
                libraryTick &+= 1
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        switch chrome {
        case .sheet: sheetBody
        case .panel: panelBody
        }
    }

    /// The corner panel: title, close button, list. Clicking elsewhere closes it.
    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheetTitle)
                        .font(.system(size: MixFontScale.size(14), weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(subtitle)
                        .font(.system(size: MixFontScale.size(11)))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Close")
            }
            .padding(.horizontal, hPad)
            .padding(.top, 12)

            searchField
            listBody
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.mixSeparator, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
    }

    /// Tighter inset in the narrower panel.
    private var hPad: CGFloat { chrome == .panel ? 14 : 20 }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var sheetBody: some View {
        // `scroll: false`: the list scrolls itself and the search field stays put.
        MixSheet(title: sheetTitle,
                 subtitle: subtitle,
                 size: .large,
                 scroll: false) {
            VStack(spacing: 0) {
                searchField
                listBody
            }
        }
    }

    private var sheetTitle: String {
        purpose == .savedIn ? "Saved In" : "Add to Playlist"
    }

    /// One song names itself; a selection shows a count.
    private var subtitle: String {
        guard let only = tracks.first, tracks.count == 1 else {
            return "\(tracks.count) songs"
        }
        return "\(only.title) \u{2022} \(only.artistName)"
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextTertiary)

            TextField("Find a playlist", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextPrimary)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.mixSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.mixSeparator, lineWidth: 1)
                )
        )
        .padding(.horizontal, hPad)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - List

    /// A plain scroller, not a `List`, whose separators and row styling fought the palette.
    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                newPlaylistRow

                Divider()
                    .overlay(Color.mixSeparator)
                    .padding(.leading, hPad)

                // One flat ForEach so a playlist moving between sections is redrawn, not reused.
                ForEach(entries) { entry in
                    switch entry {
                    case .header(let title):
                        sectionHeader(title)
                    case .playlist(let playlist):
                        row(for: playlist)
                    case .library(let playlist):
                        libraryRowView(playlist)
                    }
                }

                if matching.isEmpty && !query.isEmpty {
                    Text("No playlist called \u{201C}\(query)\u{201D}.")
                        .font(.system(size: MixFontScale.size(13)))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                }
            }
            .padding(.bottom, 8)
            .mixAnimation(.easeInOut(duration: 0.22), value: membership)
        }
        .scrollContentBackground(.hidden)
    }

    /// A heading, playlist, or the library row, so all fit in one `ForEach`.
    private enum Entry: Identifiable {
        case header(String)
        case playlist(Playlist)
        /// The library row: never an add target, and pressing it deletes the song.
        case library(Playlist)

        var id: String {
            switch self {
            case .header(let title):    return "h:\(title)"
            case .playlist(let list):   return "p:\(list.id.uuidString)"
            case .library:              return "library"
            }
        }
    }

    /// All Songs, shown only in `.savedIn` and not while searching.
    private var libraryRow: Playlist? {
        guard purpose == .savedIn,
              query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return deps.libraryService.playlists.first { playlist in
            playlist.isAllSongs && tracks.allSatisfy { playlist.trackIDs.contains($0.id) }
        }
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        let library = libraryRow
        if library != nil || !containing.isEmpty {
            out.append(.header("Saved in"))
        }
        // Library first, as the broadest answer.
        if let library { out.append(.library(library)) }
        out.append(contentsOf: containing.map(Entry.playlist))
        if !available.isEmpty {
            out.append(.header(query.isEmpty ? "Recently updated" : "Results"))
            out.append(contentsOf: available.map(Entry.playlist))
        }
        return out
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: MixFontScale.size(12), weight: .semibold))
            .foregroundStyle(Color.mixTextSecondary)
            .padding(.horizontal, hPad)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    // MARK: - Rows

    /// A playlist row with its membership mark. Tapping toggles and keeps the sheet open.
    private func row(for playlist: Playlist) -> some View {
        let isIn      = membership.contains(playlist.id)
        let isPartial = !isIn && partialMembership.contains(playlist.id)

        return Button {
            toggle(playlist)
        } label: {
            HStack(spacing: 12) {
                artwork(for: playlist)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(playlist.name)
                            .font(.system(size: MixFontScale.size(14), weight: .medium))
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        if meta.isPinned(playlistID: playlist.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.mixTextTertiary)
                                .rotationEffect(.degrees(45))
                        }
                    }
                    Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                        .font(.system(size: MixFontScale.size(12)))
                        .foregroundStyle(Color.mixTextSecondary)
                }

                Spacer(minLength: 8)

                // Filled check for in, ring for out, dash for partial.
                Image(systemName: isIn ? "checkmark.circle.fill"
                                       : (isPartial ? "minus.circle.fill" : "circle"))
                    .font(.system(size: 19, weight: isIn || isPartial ? .regular : .light))
                    .foregroundStyle(isIn ? Color.mixPrimary
                                          : (isPartial ? Color.mixPrimary.opacity(0.55)
                                                       : Color.mixTextTertiary))
                    .mixSymbolReplace()
                    .mixAnimation(.mixSnappy, value: isIn)
                    .savePop(trigger: unfilePops[playlist.id] ?? 0, direction: .remove)
                    .help(isPartial ? "Holds some of the selected songs" : "")
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredID == playlist.id ? Color.mixTextPrimary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { inside in
            hoveredID = inside ? playlist.id : (hoveredID == playlist.id ? nil : hoveredID)
        }
    }

    /// "Your Library". Pressing it soft-deletes the songs to Recently Deleted.
    private func libraryRowView(_ playlist: Playlist) -> some View {
        Button {
            removeFromLibrary()
        } label: {
            HStack(spacing: 12) {
                artwork(for: playlist)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Library")
                        .font(.system(size: MixFontScale.size(14), weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                        .font(.system(size: MixFontScale.size(12)))
                        .foregroundStyle(Color.mixTextSecondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.mixPrimary)
                    .savePop(trigger: unfilePops[playlist.id] ?? 0, direction: .remove)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredID == playlist.id ? Color.mixTextPrimary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { inside in
            hoveredID = inside ? playlist.id : (hoveredID == playlist.id ? nil : hoveredID)
        }
        .help(tracks.count == 1 ? "Remove from your Library"
                                : "Remove these songs from your Library")
        .accessibilityLabel("Saved in your library. Remove.")
    }

    /// Removes the songs from the library, then closes since nothing shown is true any more.
    private func removeFromLibrary() {
        unfilePops[Playlist.allSongsID, default: 0] += 1
        Haptics.play(.success)
        SupabaseSyncService.allowBulk("user-remove")
        deps.libraryService.deleteTracks(ids: tracks.map(\.id))
        deps.showRemovedToast(.library, count: tracks.count)
        // Let the mark bounce before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { close() }
    }

    /// 44pt tile with no tinted fill behind the glyph.
    @ViewBuilder
    private func artwork(for playlist: Playlist) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.mixSurface2)

            if playlist.isFavourites {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.mixPrimary)
            } else if playlist.isAllSongs {
                Image(systemName: "music.note.list")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.mixTextSecondary)
            } else if let data = deps.libraryService.coverData(for: playlist),
                      let image = mixImage(from: data, displaySize: 44) {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: MixtapeIcons.playlist)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Inline "New playlist" row.
    @ViewBuilder
    private var newPlaylistRow: some View {
        if isNamingNewPlaylist {
            HStack(spacing: 12) {
                newPlaylistTile

                TextField("Playlist name", text: $newPlaylistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: MixFontScale.size(14)))
                    .foregroundStyle(Color.mixTextPrimary)
                    .focused($newNameFocused)
                    .onSubmit { createAndAdd() }

                Button("Create") { createAndAdd() }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: MixFontScale.size(13), weight: .semibold))
                    .foregroundStyle(canCreate ? Color.mixPrimary : Color.mixTextTertiary)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, 7)
        } else {
            Button {
                // No results usually means the playlist doesn't exist yet, so seed the name.
                newPlaylistName = matching.isEmpty ? query : ""
                isNamingNewPlaylist = true
                newNameFocused = true
            } label: {
                HStack(spacing: 12) {
                    newPlaylistTile

                    Text("New playlist")
                        .font(.system(size: MixFontScale.size(14), weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)

                    Spacer()
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hoveredID == Self.newRowID ? Color.mixTextPrimary.opacity(0.05) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .onHover { inside in
                hoveredID = inside ? Self.newRowID : (hoveredID == Self.newRowID ? nil : hoveredID)
            }
        }
    }

    private var newPlaylistTile: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.mixSurface2)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
            )
    }

    private var canCreate: Bool {
        !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    /// Flips `membership` first so the mark and section change together, then writes through.
    private func toggle(_ playlist: Playlist) {
        let ids = tracks.map(\.id)
        if membership.contains(playlist.id) {
            membership.remove(playlist.id)
            partialMembership.remove(playlist.id)
            deps.removeTracks(ids: ids, fromPlaylist: playlist.id)
            unfilePops[playlist.id, default: 0] += 1
            Haptics.play(.success)
        } else {
            // A partial playlist fills up rather than emptying.
            membership.insert(playlist.id)
            partialMembership.remove(playlist.id)
            deps.addTracks(ids: ids, toPlaylist: playlist.id)
        }
    }

    /// Empty for one song, a count for a selection. Includes its own trailing space.
    private var songPhrase: String {
        tracks.count == 1 ? "" : "\(tracks.count) songs "
    }

    private func createAndAdd() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let playlist = deps.libraryService.createPlaylist(name: name)
        membership.insert(playlist.id)
        deps.addTracks(ids: tracks.map(\.id), toPlaylist: playlist.id)
        newPlaylistName = ""
        isNamingNewPlaylist = false
        query = ""
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: Playlist(
            id: Playlist.favouritesID,
            name: "Liked Songs",
            sync: SyncMetadata(deviceID: "preview")
        ))
        .environmentObject(AppDependencies())
        .environmentObject(PlaybackEngine(
            queue: QueueService(),
            fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
            equalizer: AudioEqualizer()
        ))
    }
}

/// The search term per playlist, kept for the app session only.
enum PlaylistSearchMemory {
    private static var queries: [UUID: String] = [:]

    static func query(for playlistID: UUID) -> String { queries[playlistID] ?? "" }

    static func set(_ query: String, for playlistID: UUID) {
        if query.isEmpty { queries[playlistID] = nil } else { queries[playlistID] = query }
    }
}
