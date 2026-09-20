// PlaylistDetailView.swift
// Mixtape — Features/Library/Detail

import SwiftUI
import Combine

public struct PlaylistDetailView: View {

    let playlist: Playlist
    /// A smart playlist dressed as this one by `SmartPlaylistDetailView`: not a
    /// library row, so nothing here that writes to or publishes the stored
    /// playlist applies — downloads, profile, sharing, and delete goes to the
    /// smart playlist service instead.
    var isSmart = false

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    /// Directly, not through `deps` — a nested ObservableObject doesn't
    /// republish, and the + button has to flip the moment it is pressed.
    @EnvironmentObject private var smartService: SmartPlaylistService
    /// Observed directly: `engine.queue` doesn't republish through the engine,
    /// so the shuffle button lagged behind the state it shows.
    @EnvironmentObject private var queueService: QueueService
    /// A header's shuffle button is this list's own setting, not the queue's
    /// live mode — see `ShufflePreferences`.
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    @Environment(\.dismiss) private var dismiss

    // Rename
    /// Confirming a press that would delete downloaded audio.
    @State private var resolvedCover: Data?
    @State private var showRemoveDownloadsConfirm = false
    /// Stopping a Liked Songs sync asks what to do with the songs it imported.
    @State private var showStopLikedSongs = false
    /// How many songs the Liked Songs link put in Favourites, counted when the
    /// dialog is asked for rather than on every redraw. SwiftUI evaluates a
    /// `confirmationDialog`'s actions and message whether or not it is showing,
    /// and that count is a scan of every favourite against every imported id.
    @State private var likedContributions = 0
    /// Why a manual "Sync Now" didn't work, for the alert that says so.
    @State private var syncError: String?
    /// Set once a sync has been running long enough to be worth mentioning.
    @State private var syncIsSlow = false
    @ObservedObject private var throttle = SpotifyThrottle.shared
    @State private var showEditSheet     = false
    // Delete
    @State private var showDeleteConfirm = false
    /// The "and 47 songs" number, counted on the press. It walks every playlist
    /// in the library looking for songs nothing else holds, and the dialog's
    /// message is rebuilt on every body pass whether or not it is showing.
    @State private var songsLostWithPlaylist = 0
    /// The songs awaiting a "really delete?" answer. Non-empty is what presents
    /// the prompt, so the dialog can name the row it was opened on — or count
    /// the selection it was opened over.
    @State private var tracksPendingDeletion: [Track] = []
    // Add to Playlist sheet
    @State private var tracksForAddToPlaylist: [Track] = []
    // Collaborative share sheet
    @State private var showCollabShare = false
    @State private var showSpotifyExport = false
    /// Whether this playlist appears on the owner's public profile. Separate from
    /// collaborative sharing on purpose: handing a friend a join code and putting
    /// a playlist on your profile are two different intentions, and until now the
    /// first silently did the second as well.
    @State private var isPublic = false
    @State private var isTogglingPublic = false
    @State private var publicError: String?
    /// Guards the cover repair, which is a long run of network calls and should
    /// not be started twice from two taps on the menu.
    @State private var isRefetchingCovers = false
    /// DownloadManager's changes don't propagate through `deps`, so the offline
    /// badges and the header's download button would show stale state until
    /// something else redrew the view. Bumping this on its change notification
    /// keeps them live.
    @State private var downloadTick = 0
    /// Width of the track list, measured so the table can drop columns it can't
    /// fit rather than squeezing them into an unreadable smudge.
    @State private var listWidth: CGFloat = 0
    /// Whose playlist this is, for the header. Empty for the ordinary case — a
    /// playlist you made yourself and nobody else has touched — where the answer
    /// is "yours" and saying so is noise.
    @State private var byline: [BylineMember] = []
    /// The profiles behind the byline names, keyed by member id, so a tapped
    /// name can open a page without a second round trip. Only names with an
    /// entry here are pressable — see `bylineTapHandler`.
    @State private var bylineProfiles: [UUID: UserProfile] = [:]
    /// How many people are holding this playlist, or nil when there's no such
    /// number to show — see `loadSaveCount`.
    @State private var saveCount: Int?
    /// The signed-in user's profile, for the "Made for" name on a mix.
    @State private var me: UserProfile?
    #if os(iOS)
    /// iOS has no content column to route a profile into, so it opens as a sheet
    /// — the same treatment `ProfileMenuButton` gives your own.
    @State private var profileSheet: UserProfile?
    #endif
    /// What the header's search field is holding. Empty — the ordinary case —
    /// shows the playlist whole.
    @State private var trackQuery = ""
    /// The order the list is drawn in. Seeded from — and written back to —
    /// `PlaylistTrackSortService`, so a playlist you sorted by Date Added is
    /// still sorted that way tomorrow, and on your other device. On macOS the
    /// table's column headers write back into this too, so the menu and the
    /// column arrow are the same fact stated twice.
    @State private var trackSort = TrackSort()
    /// Observed so a sort adopted from the account (sign-in on another device)
    /// lands on a page that is already open. The equality guards on both sides
    /// stop this and `setSort` chasing each other.
    @ObservedObject private var trackSorts = PlaylistTrackSortService.shared

    /// The resolved / filtered / sorted rows, computed once per real change.
    /// See `TrackListMemo`.
    @State private var memo = TrackListMemo()
    /// Set when the server says a saved playlist's original is no longer public.
    /// Only ever set from a real answer, never from a failed request: telling
    /// someone their friend unpublished a playlist because the wifi dropped is
    /// worse than saying nothing.
    @State private var sourceUnavailable = false

    private var columns: TrackColumns { TrackColumns(width: listWidth) }

    // MARK: - Editability

    /// A mix, or someone else's playlist you saved. It's genuinely in the library
    /// — it plays, it downloads, it's searchable — but its contents aren't yours
    /// to change, so every control that would change them is taken out rather
    /// than left to fail silently against the guards in `LibraryService`.
    private var isReadOnly: Bool { !livePlaylist.isEditable }

    /// "Made for mike", on a mix. Nothing on anything else: a playlist someone
    /// published wasn't made for you, and saying so would be a small lie in
    /// somebody else's byline.
    ///
    /// Paints from `currentUser` in the first frame and upgrades to the fetched
    /// profile when it lands — which is also the moment the name becomes
    /// pressable, since that's when there is a page behind it.
    private var madeForMember: BylineMember? {
        guard livePlaylist.origin == .mix else { return nil }
        if let me {
            return BylineMember(id: me.id, name: me.name, avatarURL: me.avatarURL)
        }
        guard let user = deps.authService.currentUser, !user.displayName.isEmpty else { return nil }
        return BylineMember(id: user.id, name: user.displayName, avatarURL: user.avatarURL)
    }

    /// Routes a tapped name in the byline.
    ///
    /// Nil — leaving every name as plain text — whenever there is nothing here
    /// worth opening, so the header never offers a press that goes nowhere. A
    /// single unresolved name inside an otherwise live byline does nothing,
    /// which is the one case this can't express any better.
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

    /// Mixtape's profile lives in Discover on both platforms — that's where
    /// mixes are made and where the page already renders — so this is a section
    /// change plus a push rather than a second copy of the page over here.
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

    /// Always fetches the freshest version of this playlist from the live library,
    /// falling back to the captured `let playlist` only if the library hasn't loaded yet.
    private var livePlaylist: Playlist {
        deps.libraryService.playlist(id: playlist.id) ?? playlist
    }

    /// Brings `memo` up to date, cheaply, and hands it back.
    ///
    /// Every derived list on this page goes through here rather than
    /// recomputing, so a body evaluation triggered by something unrelated —
    /// a hover, a sheet, the player bar — costs one `Key` comparison instead
    /// of resolving, filtering and sorting a few thousand rows.
    private var lists: TrackListMemo {
        // `trackRevision`, not `revision`: see its doc comment. This page calls
        // `refreshPlaylists()` on every play, and keying on the shared revision
        // put a full re-resolve of the playlist in front of every press.
        memo.update(revision:   deps.libraryService.trackRevision,
                    ids:        livePlaylist.trackIDs,
                    query:      trackQuery,
                    sort:       trackSort,
                    // `track(id:)`, never the display accessor: a playlist
                    // opened offline showed as empty, which reads as lost data.
                    // Undownloaded rows are drawn grey instead — see
                    // `offlineUnavailable(_:)`.
                    resolve:    { deps.libraryService.track(id: $0) },
                    isPlayable: { $0.canResolveAudio })
        return memo
    }

    private var tracks: [Track] { lists.tracks }

    /// The rows actually on screen: the playlist, filtered by whatever is in the
    /// header's search field and in whatever order the header's menu asks for.
    ///
    /// Everything that reasons about the playlist as a thing — its song count,
    /// its total time, whether it's fully downloaded — deliberately keeps
    /// reading `tracks`. A filter is a view of the playlist, not an edit to it.
    private var visibleTracks: [Track] { lists.visible }

    /// Everything on screen that can be *attempted*.
    ///
    /// A shared playlist lists songs the other collaborators own, and this
    /// device holds those as metadata-only placeholders. They belong in the
    /// list — that's the point of showing the playlist as everyone else sees
    /// it — but a row with nothing to play would stop playback dead partway
    /// through and look like a bug in the player.
    ///
    /// "Nothing to play" is a much smaller set than it used to be: a
    /// placeholder that knows its own title is resolved online on the way to
    /// playing it (see `AudioLocator.locate`), so it is a real song here, not
    /// a hole. Only a row that can't even name itself is left out.
    ///
    /// Built from the visible rows, so Play plays what you are looking at: sort
    /// by title and it starts at the top of the list you can see, filter to one
    /// artist and it plays that artist. A Play button that ignored both would be
    /// the only control on the page that did.
    private var playableTracks: [Track] { lists.playable }

    /// The picture this page wears, and what it takes its colour from.
    ///
    /// `coverData(for:)` is the same rule the sidebar and every list use — the
    /// user's own cover, else the first song's, else the 2×2 once four
    /// different ones exist — so the hero can't disagree with the row you
    /// clicked to get here.
    ///
    /// Nil for All Songs and Favourites: their hero is a glyph, and the wash
    /// comes from `washFallback` instead.
    private var displayCover: Data? { resolvedCover }

    /// What the cover is built from, as a value that changes when it should.
    private var coverIdentity: String {
        "\(livePlaylist.id)|\(livePlaylist.displayArtwork?.count ?? 0)|\(tracks.count)|\(livePlaylist.coverKind.rawValue)"
    }

    /// The rule this page is drawing, when it is a smart playlist. Read live so
    /// the + button reflects the current membership.
    private var smartRule: SmartPlaylist? {
        guard isSmart else { return nil }
        return smartService.playlists.first { $0.id == playlist.id }
    }

    /// Builds the hero cover without composing a mosaic on the render path.
    ///
    /// `LibraryService.coverData(for:)` answers the same question, but it draws
    /// the 2×2 while the view is being laid out — which is the pause between
    /// tapping a playlist and seeing it. Reading the tiles needs the main actor
    /// (the `ModelContext` lives there); *drawing* them does not, so only the
    /// reads happen here and the composition goes to a background task.
    private func loadCover() async {
        // A smart playlist wears its rule's icon on every other surface —
        // `PlaylistArtwork` has always routed it to `SmartPlaylistCover`. Only
        // this page composed a 2×2 of its songs instead, which is why the
        // custom cover vanished on the way in.
        guard !isSmart else { resolvedCover = nil; return }
        if let own = livePlaylist.displayArtwork {
            resolvedCover = own
            return
        }
        // "No cover" is a decision, not an absence. `coverRefs` already returns
        // nothing for `.none`, but every path below it falls through to
        // `borrowedCover`, which asks the tracks directly and so never heard
        // about the decision — which is why clearing a cover left the row blank
        // in the list and still showed the first song's artwork on the page.
        guard livePlaylist.coverKind != PlaylistCoverKind.none else {
            resolvedCover = nil
            return
        }
        // All Songs and Favourites wear a glyph, and the page takes its colour
        // from that glyph — see `washFallback` — never from whichever song
        // happens to be first.
        guard !livePlaylist.isSystem else {
            resolvedCover = nil
            return
        }

        var tiles: [Data] = []
        // Enough of each cover to tell it apart without hashing the whole
        // image — a playlist that is one album must not tile the same picture
        // four times.
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
            let accent = MixCoverStyle.color(for: smart.id.uuidString)
            return [accent, accent.opacity(0.55)]
        }
        return livePlaylist.isSystem ? ArtworkColors.brandGradient : []
    }

    /// The first song's cover, skipping songs that don't have one — a playlist
    /// that opens with an untagged local file shouldn't be a grey page when the
    /// nine songs under it all have artwork.
    private var borrowedCover: Data? {
        tracks.lazy.compactMap(\.displayArtwork).first
    }

    /// iOS keeps the full detail-page ramp — its rows are still the tinted,
    /// rounded ones the strong wash was drawn for. macOS pulls it back, but only
    /// part way: a plain table under a flat grey page had none of the playlist's
    /// colour in it, which is most of what made the old header worth looking at.
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
    /// Only for switching tabs — "Find in Discover" has to leave the Library
    /// tab entirely, which a NavigationStack push can't do.
    @EnvironmentObject private var iosAppState: IOSAppState
    /// "Go to Artist"/"Go to Album" destinations. macOS swaps the content column
    /// through `MacAppState`; iOS pushes onto the enclosing NavigationStack, so
    /// the targets have to be held here.
    @State private var navAlbum:  Album?  = nil
    @State private var navOnlineAlbum: OnlineAlbum? = nil
    #endif

    public var body: some View {
        // Counts body passes, not just their cost. `download-summary` still ran
        // 74 times in one play-start window after the DownloadManager firehose
        // was throttled to 4 Hz, which means a *different* publisher is now
        // driving the invalidations — most likely one of the environment
        // objects this view observes wholesale. The span says how many passes
        // and how expensive each is; without it the only visible symptom is a
        // string of unlabelled 100-190 ms hangs, because iOS hangs carry no stack.
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
            // Playlist detail is rendered flat on macOS (no NavigationStack), so
            // the page carries its own back control. It floats over the hero's
            // top corner instead of sitting in a bar, which would slice a stripe
            // across the top of the page.
            .pageBack {
                if isSmart { appState.selectedSmartPlaylist = nil } else { appState.selectedPlaylist = nil }
            }
            #endif
            // Pull the latest shared track list when opening a collaborative playlist.
            // No-op for non-shared playlists.
            .task(id: playlist.id) {
                if livePlaylist.followsRemoteSource {
                    // The owner's copy is the truth, so this is the whole update
                    // path for a saved playlist — and the only thing that can tell
                    // us it has stopped being public.
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
                // A followed Spotify playlist checks its source on open, the
                // same way a saved playlist does. `snapshot_id` makes the
                // unchanged case one cheap request.
                if deps.spotifyFollowService.isFollowing(playlistID: playlist.id) {
                    await deps.spotifyFollowService.sync(playlistID: playlist.id)
                }
                await loadByline()
                // Only ever about a playlist of your own: the toggle it backs puts
                // *your* playlist on *your* profile, and asking for anything else is
                // a round trip whose answer is always no.
                if !isReadOnly { await loadPublicState() }
                await loadSaveCount()
                // After the refresh, not before: a playlist just joined has no local
                // rows at all until `refreshSharedPlaylist` writes them, so prefetching
                // first would find nothing to warm.
                deps.onlineCoordinator.prefetchResolvable(tracks)
            }
            // Only a mix says who it was made for, so only a mix pays for the
            // lookup. Keyed on the account so switching users doesn't leave the
            // previous one's name under a mix rebuilt for somebody else.
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
            // A filter belongs to the playlist you set it on — macOS reuses this
            // view for the next playlist you click in the sidebar — but it
            // belongs to that playlist for as long as the app is open, not just
            // for the visit: leaving a playlist and coming back finds the search
            // you left in it, the same way the sort does.
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
            // What's left up here acts on the *selection* or on the playlist's
            // standing as an object — never on playback, which all lives in the hero
            // row beside the cover.
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
        // The wash sits on the whole screen rather than on the list, so it also
        // runs behind the back bar — and its top colour is handed to the window
        // titlebar, so the tint carries on up through the chrome.
        //
        // Half strength on macOS. The rows underneath are a plain table now, and
        // at full detail-page strength the colour stopped being a hint of which
        // playlist you're in and became the thing you looked at.
        .artworkWash(source: washSource, intensity: Self.washIntensity, fallback: washFallback)
        .task(id: coverIdentity) { await loadCover() }
        .background(Color.mixBackground.ignoresSafeArea())
        .miniPlayerSafeArea()
        // Cover / name / description editor — reached from the cover art in the
        // header on both platforms, and from the "…" menu on iOS.
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
            // The rate-limit sentence wins when there is one: it is the whole
            // explanation, and it is the case people otherwise read as Mixtape
            // being broken.
            Text(throttle.sentence ?? syncError ?? "")
        }
        // "Syncing…" that never becomes anything else is what a hang looks
        // like, so after a few seconds it admits to being slow.
        .task(id: isSyncing) {
            syncIsSlow = false
            guard isSyncing else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { syncIsSlow = true }
        }
        .confirmationDialog(
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
                    // The import is gone, so "Imported" must stop standing over
                    // it in the picker — otherwise the way back is a badge that
                    // says it already happened.
                    deps.spotifyImportLedger.forget(playlistID: playlist.id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(likedContributions > 0
                 ? "Removes only the \(likedContributions) songs that came from Spotify. Nothing on Spotify changes."
                 : "Nothing here came from Spotify, so nothing will be removed.")
        }
        .confirmationDialog(
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
                // Take the published row down with it. Deleting only the local
                // copy is what left published playlists stranded on profiles
                // with nothing left on the device able to reach them — the page
                // could offer to restore them, but never to remove them.
                //
                // Detached from the dismissal below rather than awaited: the
                // playlist is already gone locally, and holding the view open on
                // a network round trip would make a local delete feel like one.
                // Owners only. A collaborator deleting their copy is leaving the
                // playlist, not ending it — the row isn't theirs to take down,
                // and the server would refuse anyway.
                if let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id),
                   link.role == PlaylistSharingService.Roles.owner {
                    Task { try? await PlaylistSharingService.shared.deletePublished(sharedPlaylistID: link.sharedPlaylistID) }
                }
                // Unsaving also drops the link to the playlist it was following,
                // so saving it again later starts clean rather than reconciling
                // into a playlist that isn't there any more.
                // Deleting a followed playlist should also stop following it,
                // or the next sync would resurrect a playlist that was just
                // thrown away.
                if livePlaylist.followsSpotify {
                    deps.spotifyFollowService.unlink(playlistID: playlist.id)
                }
                if livePlaylist.followsRemoteSource {
                    PlaylistSharingService.shared.unsavePublicPlaylist(
                        localPlaylistID: playlist.id,
                        libraryService: deps.libraryService
                    )
                } else {
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
        // A saved playlist whose original went private. Deliberately not a
        // silent removal: the owner may well switch it back on, and the copy is
        // still here and still plays whatever was already downloaded.
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
        // Removing songs from the library — context menu and swipe both land
        // here, so there's one prompt rather than one per gesture.
        .confirmsTrackDeletion($tracksPendingDeletion) { pending in
            for track in pending { engine.stopIfPlaying(trackID: track.id) }
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
        // macOS raises the corner panel instead — same list, no window over the
        // app. Handing it off here rather than at each menu item keeps the
        // menus' `tracksForAddToPlaylist = …` meaning one thing on both
        // platforms.
        .onChange(of: tracksForAddToPlaylist) { _, tracks in
            guard !tracks.isEmpty else { return }
            deps.savedInPanel.show(tracks: tracks, isSavedIn: false, sourcePlaylistID: playlist.id)
            tracksForAddToPlaylist = []
        }
        #endif
        // Invite collaborators. Opening this publishes the playlist if it has
        // never been shared, so it's the only entry point that needs the live
        // track list — the shared row carries a metadata snapshot of it.
        .sheet(isPresented: $showSpotifyExport) {
            // No `.frame(minWidth:)` here. MixSheet already sizes itself on
            // macOS, and a min-width wrapper around it sets the sheet window to
            // *its* number while the chrome inside stays at the size class's —
            // so the content drew 580pt wide inside a 520pt window and spilled
            // off both edges. The sheet owns its width; presenters don't.
            SpotifyExportView(playlistName: playlist.name, tracks: tracks, playlistID: playlist.id)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showCollabShare) {
            InviteCollaboratorsSheet(playlist: livePlaylist, tracks: tracks)
                .environmentObject(deps)
        }
        #if os(iOS)
        // A name in the byline opens as a sheet rather than a push: this page
        // can be reached from more than one tab's stack, and a profile is a
        // detour from the playlist rather than somewhere deeper inside it.
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
    /// The hero, then the same AppKit table Songs, Albums and Artists use.
    ///
    /// It replaced a hand-built SwiftUI list, and the reasons are the reasons a
    /// list of songs anywhere else in the app is this table: the column dividers
    /// are draggable and the columns are the ones the rest of the app shows.
    ///
    /// The page — not the table — does the scrolling, which is what lets the
    /// hero slide away as you go down the list instead of holding a third of the
    /// window for a cover you've already looked at. The table sizes itself to its
    /// rows and hands the wheel back up (see `fitsContent`); the artist page is
    /// built the same way.
    private var macTrackPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if tracks.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if visibleTracks.isEmpty {
                    noMatchesState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    trackTable
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rows selected here shouldn't still be selected — and still deletable
        // with ⌘⌫ — after the page has been left, the same as Songs.
        .onDisappear { appState.clearTrackSelection() }
    }

    private var trackTable: some View {
        NativeTrackTable(
            tracks:              visibleTracks,
            currentTrackID:      engine.queue.currentTrack?.id,
            isPlaying:           engine.state.isPlaying,
            selectedIDs:         Binding(
                get: { appState.selectedTrackIDs },
                set: { appState.selectedTrackIDs = $0 }
            ),
            onPlay:              { track, context in playAndMark(track, within: context) },
            onPlayNext:          { engine.queue.insertNext($0) },
            onAddToQueue:        { engine.queue.append($0) },
            onGetInfo:           { appState.showInspector(for: $0) },
            onDragTracksChanged: { appState.isDraggingTracks = $0 },
            onGoToArtist:        { openArtist(named: $0) },
            onGoToAlbum:         { openAlbum(for: $0) },
            onOpenArtistLink:    { appState.openDiscoverArtist(named: $0) },
            onOpenAlbumLink:     { appState.openDiscoverAlbum(for: $0) },
            // Only offered on All Songs, and the table has already asked — it
            // raises the same prompt as ⌘⌫ before it calls this.
            onRemove:            { selection in
                for track in selection { engine.stopIfPlaying(trackID: track.id) }
                deps.libraryService.deleteTracks(ids: selection.map(\.id))
                appState.clearTrackSelection()
            },
            onToggleFavourite:   { deps.toggleFavourite(trackID: $0.id) },
            onAddToPlaylist:     { selection, playlistID in
                deps.addTracks(ids: selection.map(\.id), toPlaylist: playlistID)
            },
            onRemoveFromPlaylist: canRemoveFromPlaylist ? { selection in
                deps.libraryService.removeTracks(ids: selection.map(\.id),
                                                 fromPlaylist: playlist.id)
                appState.clearTrackSelection()
            } : nil,
            removeFromPlaylistTitle: { count in
                let place = livePlaylist.isFavourites ? "Liked Songs" : "Playlist"
                return count > 1 ? "Remove \(count) Songs from \(place)"
                                 : "Remove from \(place)"
            },
            // On any other playlist "remove" means remove from this list, and
            // offering both removals a divider apart is how a song gets deleted
            // from the library by someone who meant to take it off a playlist.
            showsRemoveFromLibrary: playlist.isAllSongs,
            excludedPlaylistID:  playlist.id,
            onFindInDiscover:    { findInDiscover($0) },
            onChoosePlaylist:    { tracksForAddToPlaylist = $0 },
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
            // The rows arrive already sorted, so the table stops sorting on its
            // own and its column headers drive the header's menu instead.
            sort:                $trackSort,
            // One playlist, not the whole library: the rows get the height and
            // the type size they had before this page moved to the table.
            metrics:             .roomy,
            // A playlist is an ordered thing; the number is how you refer to a
            // song in it.
            showsIndex:          true,
            resolvingIDs:        engine.routingTrackIDs
        )
    }

    /// All Songs deletes from the library instead, and a mix or somebody else's
    /// playlist isn't ours to edit.
    private var canRemoveFromPlaylist: Bool {
        !playlist.isAllSongs && !isReadOnly
    }
    #else
    /// iOS keeps the SwiftUI list: `List` is what makes `.swipeActions` fire, and
    /// there are no draggable column dividers on a touch screen to want.
    private var iosTrackList: some View {
        List {
            // ── Header (artwork + title + action buttons) ─────────────────────
            header
                .listRowInsets(EdgeInsets())
                // Clear, not mixBackground: the artwork wash is painted behind
                // this whole screen so it can run past the header and under the
                // first rows. An opaque row background would cut it off at the
                // header's edge.
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // ── Column header ─────────────────────────────────────────────────
            // Only once there's something to label, and only at widths where
            // the extra columns actually appear on the rows below it.
            if !tracks.isEmpty, columns.isTable {
                TrackListHeader(columns: columns)
                    .listRowInsets(EdgeInsets(top: 0, leading: TrackColumns.rowLeading,
                                              bottom: 0, trailing: TrackColumns.rowTrailing))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // ── Track rows (or empty state) ───────────────────────────────────
            if tracks.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if visibleTracks.isEmpty {
                noMatchesState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                // Identified by the track, not by its position. With `\.offset`,
                // reordering or filtering the list renamed every row from the
                // first change downwards, so SwiftUI rebuilt them all — and the
                // per-row `@State` (hover, in particular) stayed behind on the
                // index it was attached to and reappeared on whatever song moved
                // into that slot.
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index + 1, isSelected: false)
                }
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

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: isSmart ? "Smart Playlist" : "Playlist",
            title: livePlaylist.name,
            subtitle: livePlaylist.description,
            // The byline carries the counts itself when there is one, so they
            // aren't printed twice on two lines that disagree about spacing.
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

    /// Everything you can do to the playlist, and the two things you can do to
    /// the *list*.
    ///
    /// They're deliberately at the far end from the rest: play, shuffle, keep
    /// offline and the overflow menu are already a tight cluster on the left,
    /// and searching and sorting don't act on the playlist at all — they change
    /// what you're being shown of it.
    @ViewBuilder
    private var actionRow: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            actionButtons
            if !tracks.isEmpty { trackTools }
        }
        #else
        // No room for a fifth control beside two full-width pills, so on iOS
        // they take the line underneath, still on the trailing side.
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
            // What "the order it's already in" means depends on the list: All
            // Songs has no running order of its own, it has whatever the library
            // hands over.
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
        // Any linked playlist says so, not only a read-only mirror: a playlist
        // that pushes to Spotify is just as linked, and the "…" menu was the
        // only place that admitted it.
        // Favourites counts too: once Liked Songs is mirrored into it, it is a
        // linked list like any other and the header should say so.
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

    /// Which way this playlist's changes travel, in the header.
    ///
    /// Three arrangements, three sentences — "Synced with Spotify" for a
    /// playlist that is genuinely kept the same at both ends, and something
    /// one-directional for the two that aren't, because a one-way playlist that
    /// claimed to be "synced" would be lying about half of it.
    private static func syncLabel(for direction: SpotifyFollowService.Link.Direction) -> String {
        switch direction {
        case .both: return "Synced with Spotify"
        case .push: return "Sending to Spotify"
        case .pull: return "Following Spotify"
        }
    }

    /// How many people are holding this playlist.
    ///
    /// Three different questions with one answer each. A mix is yours alone, so
    /// the count is simply whether it's here — asking a server would be asking
    /// about a playlist only you have. Anything with a shared row (your own
    /// published playlist, or someone else's you saved) has a real total, which
    /// only the server can add up. Everything else — a private playlist of your
    /// own — has nobody to count, and shows nothing rather than "0 saves".
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
                // The playlist's own custom icon always wins; the first
                // track's cover is only a fallback. (Reversed, adding a song
                // silently replaced the user's chosen icon with album art.)
                data: displayCover,
                size: size,
                cornerRadius: 14,
                placeholder: PlaylistArtwork.placeholder(for: livePlaylist),
                placeholderTint: PlaylistArtwork.tint(for: livePlaylist),
                placeholderBackground: PlaylistArtwork.background(for: livePlaylist)
            )
        }
    }

    /// The cover. For user-created playlists it doubles as the edit affordance,
    /// so the cover can be changed from inside the playlist rather than only
    /// from the playlists list.
    @ViewBuilder
    private func coverArt(size: CGFloat) -> some View {
        // Read-only playlists get the picture without the pencil. A mix's mosaic
        // and a saved playlist's cover both belong to whoever made them, and the
        // editor behind this button changes the name and description too.
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
            // A playlist of nothing but other people's songs has nothing to
            // play, and an enabled button that does nothing is worse than a
            // disabled one that explains itself by being disabled.
            isEmpty: playableTracks.isEmpty,
            onPlay: {
                if isPlayingThisPlaylist {
                    engine.pause()
                } else if isPausedInThisPlaylist {
                    engine.resume()
                } else {
                    // This playlist's own stored choice, applied to the queue as
                    // it starts. Shuffle on means starting anywhere; off means
                    // starting at the top. The queue honours the mode from there.
                    let shuffles = shufflePrefs.shuffles(shuffleKey)
                    engine.queue.setShuffle(shuffles)
                    guard let first = shuffles
                            ? playableTracks.randomElement() : playableTracks.first else { return }
                    playAndMark(first)
                }
            },
            onShuffle: { shufflePrefs.toggle(shuffleKey) }
        ) {
            // Downloading sits beside Play rather than up in the toolbar: it acts
            // on this playlist and nothing else, and it's the one control here
            // people go looking for. Profile visibility stays in the toolbar —
            // that one is a property of the playlist, not something you do to it.
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
            // Left alone a Menu draws itself as a bordered pop-up button with a
            // chevron — the wrong shape entirely next to a circle.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .frame(width: 40, height: 40)
            .help("More actions for \u{201C}\(playlist.name)\u{201D}")
        }
    }

    /// The offline-download toggle, in the hero row on both platforms, wearing
    /// the same disc as the shuffle and overflow controls beside it.
    private var downloadButton: some View {
        // The button's *state* is the user's standing choice, not a tally of
        // what happens to be on disk — that's what makes it safe for it to also
        // mean "and download whatever gets added later". A playlist imported
        // from songs already downloaded therefore arrives switched off, which
        // is the honest answer: nobody asked for it to be kept.
        let isKept     = deps.downloadManager.isPlaylistOffline(playlist.id)
        // One walk of the track list for all five questions below. Asked here
        // and handed down rather than re-asked per computed property: each of
        // those was its own pass over a list that can hold thousands of rows,
        // on a page that redraws whenever anything about downloads moves.
        let summary    = downloadSummary
        // Complete is a fact about the disk, not about the opt-in. A playlist
        // whose every song is already here — imported, or downloaded one by one,
        // or kept as part of another playlist — has nothing left to download, so
        // showing it an empty "download" disc offered work that doesn't exist.
        // Pressing it while it's already complete still signs up for the
        // standing choice, which is the only thing left that the press can mean.
        // A kept playlist with nothing fetchable in it — empty, or nothing but
        // unresolvable shares — has no outstanding work either. Without this it
        // fell through to the stalled branch and sat there as an orange "try
        // again" disc for a download that never had anything to do. Gated on
        // `isKept` so an empty playlist nobody asked to keep still shows the
        // plain disc rather than claiming to be fully downloaded.
        let isComplete = summary.isOffline || (isKept && summary.nothingToDownload)
        // A ring that isn't moving is the thing this state exists to stop. Kept,
        // incomplete, and nothing queued, downloading or waiting to retry means
        // nothing is ever going to finish it on its own — so the button says so
        // and becomes "try again" rather than quietly sitting at a third.
        // No connection counts as stalled too. The queue survives going offline
        // intact, so `hasWorkInFlight` stays true and the ring went on filling
        // for a playlist that had stopped dead — the tooltip said "paused" while
        // the button said "downloading".
        let isStalled  = isKept && !isComplete
            && (!summary.hasWorkInFlight || !deps.downloadManager.isConnectedForDownload)
        let isFetching = isKept && !isComplete && !isStalled
        // A download in progress wears a stop square, not an arrow. The ring
        // already says "downloading"; the glyph inside it is the control, and it
        // should say what pressing does rather than repeat what the ring says.
        // Shown unconditionally — it was briefly hover-only, which meant the one
        // affordance for calling off a 2,000-song download was invisible until
        // you happened to point at it, and invisible on touch entirely.
        let showsStop = isFetching
        return Button {
            // Pressing a stalled button must not un-keep the playlist: it would
            // delete the songs that *did* land, which is the one outcome
            // someone staring at a half-finished download can't afford.
            if isStalled {
                deps.downloadManager.resumeDownloads(tracks: tracks)
            } else if isKept {
                // Every "off" press destroys audio — mid-download it also throws
                // away the part that finished. Ask first.
                showRemoveDownloadsConfirm = true
            } else {
                deps.downloadManager.togglePlaylistOffline(playlist.id)
            }
        } label: {
            // Four looks, one glance: a solid green disc means kept and every
            // song is here, a filling green ring means kept and still arriving,
            // an orange ring means kept and stuck, and the plain disc means it
            // isn't kept.
            //
            // The arrow loses its own circle while the ring is up. Two
            // concentric rings a couple of points apart is one ring too many,
            // and it's the outer one that's saying something.
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
        .confirmationDialog(
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
            // Says what is lost, not what the button is called. Mid-download the
            // honest answer includes the part that already landed, because
            // switching keeping off deletes that too.
            Text(removeDownloadsMessage(isFetching: isFetching, summary: summary))
        }
        // While the button means "try again", the press that normally switches
        // keeping off has nowhere else to go — without this a playlist that
        // can't finish could never be un-kept.
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
    /// Exports the selected songs as files. macOS only: it works off the list
    /// selection, which iOS's list doesn't have — there the same item lives on
    /// the row's own long-press menu, acting on the row you pressed.
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

    /// The profile visibility toggle, in the toolbar on both platforms. The tint
    /// IS the state — it's lit only while the playlist is actually public.
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

    /// Every download fact about the songs on screen, from a single walk.
    ///
    /// Asked of the songs this view is showing rather than of the stored
    /// playlist, so a mix — which isn't in the library's playlist list at all —
    /// answers the same questions the same way.
    ///
    /// Timed, because it is asked from `body` on a page that can hold thousands
    /// of rows: it replaced five separate whole-list walks, and this span is how
    /// we'd notice if a sixth ever grew back beside it.
    private var downloadSummary: DownloadManager.ListDownloadSummary {
        mixMainActivity("playlist-page/download-summary") {
            deps.downloadManager.downloadSummary(tracks: tracks)
        }
    }

    /// What stopping actually costs, in songs.
    ///
    /// Nothing downloaded yet is its own sentence rather than "the 0 songs
    /// already downloaded will be removed" — a zero in a warning about losing
    /// things is a sentence that talks the user out of an action that costs
    /// them nothing.
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
                // Nothing to fetch, and the button is green to say so. The press
                // is still worth offering: it's what makes the promise cover
                // songs added later.
                return "Every song here is already on this device — keep it that way for songs added later"
            }
            // Says what pressing it signs you up for, since that now includes
            // songs the playlist doesn't have yet.
            return "Keep for offline listening — songs added later download too"
        }
        guard summary.isOffline else {
            // The number the ring is drawing, for the people the ring is too
            // small for — and for VoiceOver, which can't see it at all. In
            // songs, not percent: "3 of 240" is a fact about your library,
            // where "1%" is a fact about arithmetic.
            let counts = (done: summary.offlineCount, total: summary.downloadableCount)
            let saved  = "\(counts.done) of \(counts.total) songs"
            // Connectivity first, because losing it does NOT empty the queue —
            // `processDownloadQueue` just returns and leaves every id sitting
            // there. Asked in the other order, `hasWorkInFlight` was still true
            // whenever this mattered, so the paused message was unreachable and
            // a playlist that had stopped dead went on claiming to be
            // downloading.
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
            // The glyph is a stop square now, so the tooltip describes the
            // control rather than only the progress.
            return "Downloading — \(saved) saved. Click to stop and remove."
        }
        if summary.hasRemovableDownloads { return "Stop keeping offline and remove downloads" }
        #if os(macOS)
        return "Kept on your Mac"
        #else
        return "Kept on this device"
        #endif
    }

    /// True when the engine is currently playing a track from this playlist.
    /// Whether *this* playlist is the one playing.
    ///
    /// Asked of the queue's source, not of the track list: "does this playlist
    /// contain the playing song?" is true of every playlist a popular song sits
    /// in, so All Songs, Favourites and a two-song playlist all showed a pause
    /// button at once. The playlist that started playback is the one that gets
    /// to claim it.
    private var isPlayingThisPlaylist: Bool {
        engine.state.isPlaying && queueService.sourcePlaylistID == playlist.id
    }

    /// Paused, and this playlist is what is loaded — so Play resumes rather
    /// than starting the list again from the top.
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

    /// The playlist isn't empty, the search is just too narrow. Says so rather
    /// than reusing the empty state above, which would read as "this playlist
    /// has nothing in it" over a playlist that plainly does.
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

    // MARK: - The "…" menu

    /// One menu, both platforms — the ellipsis in the iOS navigation bar and the
    /// one in the macOS toolbar are the same list of actions, because there's no
    /// reason for a playlist to be able to do different things depending on which
    /// screen you opened it on.
    ///
    /// The bottom section is repair. Those actions exist elsewhere already, buried
    /// in Settings and scoped to the whole library, which is the wrong shape twice
    /// over: you notice a playlist full of grey squares while you're looking at
    /// that playlist, and the fix you want is for the twenty songs in front of you
    /// rather than a sweep of two thousand. They only appear when there's actually
    /// something wrong, so the menu doesn't grow a permanent maintenance section.
    ///
    /// Share hands out a mixtaped.tech link anyone can open in a browser;
    /// inviting someone to edit it is a separate item.
    /// The Spotify sync controls, offered on any linked playlist whichever way
    /// it was set up.
    ///
    /// Imported playlists and sent ones used to be different animals: one could
    /// be re-synced and unlinked from this menu, the other was a copy that
    /// started drifting the moment it landed. They are the same thing — a
    /// library playlist with a Spotify counterpart — so they get the same two
    /// switches, and which way it started out is just their initial position.
    @ViewBuilder
    private var spotifySyncMenu: some View {
        if let link = deps.spotifyFollowService.link(forPlaylist: playlist.id) {
            let isLiked = link.kind == .likedSongs

            // Buttons with an explicit icon rather than `Toggle`s. A menu
            // toggle draws its checkmark only when it's on, and only some menus
            // reserve the space when it's off — so switching one shifted both
            // labels sideways and left them out of line with every other item
            // in the menu. An icon that is always there can't do that.
            Button {
                setSyncDirection(pushes: !link.direction.pushes, pulls: link.direction.pulls)
            } label: {
                // Worded differently for Liked Songs because it *does*
                // something different: a playlist push replaces Spotify's copy,
                // while this one only ever adds. Promising "send changes" and
                // then never removing anything would be a lie in the other
                // direction.
                Label(isLiked ? "Add New Likes to Spotify" : "Send Changes to Spotify",
                      systemImage: link.direction.pushes ? "checkmark.circle.fill" : "circle")
            }

            Button {
                setSyncDirection(pushes: link.direction.pushes, pulls: !link.direction.pulls)
            } label: {
                Label(isLiked ? "Bring Liked Songs from Spotify" : "Bring Changes from Spotify",
                      systemImage: link.direction.pulls ? "checkmark.circle.fill" : "circle")
            }

            // The two directions are a setting; everything below is an action.
            // Ruled apart so the checkmarks read as a pair of switches rather
            // than as two more things to press.
            Divider()

            Button {
                // `sync` swallows its errors into `failures` so the timer can
                // keep going, which meant a manual press had no way to fail:
                // the menu closed, nothing happened, and nothing said why.
                // Pressing it is a question, so it gets an answer.
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

            // Liked Songs isn't a playlist and has no playlist URL; it lives
            // at the collection route instead.
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
                // A playlist unlink leaves a playlist behind, which the user can
                // then delete in one gesture. Liked Songs has no such playlist —
                // it poured two thousand songs into Favourites — so stopping has
                // to offer to undo that too, or the only way back is by hand.
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
            // The way back. Every control above only exists while the link
            // does, so losing one took its own repair with it — and Favourites
            // is the one list the import picker can't rebuild, because
            // importing Liked Songs again means walking two thousand songs it
            // already has just to arrive where it started.
            Button {
                linkLikedSongs()
            } label: {
                Label("Sync with Liked Songs", systemImage: "heart.circle")
            }

            // Unlinking drops the link but not the songs it brought, and every
            // control that removes them used to live on the link. Stopping the
            // sync first therefore stranded them here for good.
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

    /// Links Favourites to Spotify's Liked Songs.
    ///
    /// No `lastSyncedAt` and no contributed list on purpose: this link has
    /// never run, so the first sync reads both sides as additions and takes
    /// nothing away from either — the same safe footing a link gets when its
    /// direction changes. See `SpotifyFollowService.setDirection`.
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

    /// Both switches off means there is nothing left to sync, which is what
    /// unlinking is — so the last one turning off does that rather than leaving
    /// a link that has been told to do nothing. Nothing is deleted either way:
    /// both copies stay exactly as they are.
    private var isSyncing: Bool {
        deps.spotifyFollowService.syncing.contains(playlist.id)
    }

    /// What the header says about the link right now.
    ///
    /// A check that is running says so, and one that has been running a while
    /// says *that*, because the two look identical from outside and the second
    /// is the one people read as broken. A check that failed says so too,
    /// rather than leaving "updated 5 hours ago" standing as if nothing had
    /// been tried since.
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

    /// How many of the songs in this playlist right now were put there by the
    /// Spotify link — the size of the undo the dialog is offering.
    private var spotifyContributions: Int {
        deps.spotifyFollowService.contributionCount(playlistID: playlist.id)
    }

    private func setSyncDirection(pushes: Bool, pulls: Bool) {
        let service = deps.spotifyFollowService
        switch (pushes, pulls) {
        case (true, true):   service.setDirection(.both, forPlaylist: playlist.id)
        case (true, false):  service.setDirection(.push, forPlaylist: playlist.id)
        case (false, true):  service.setDirection(.pull, forPlaylist: playlist.id)
        case (false, false): service.unlink(playlistID: playlist.id)
        }
    }

    @ViewBuilder
    private var playlistMenu: some View {
        // Same item, same words, same behaviour as the one on a Discover mix's
        // page. A playlist you saved and a mix you haven't are the same thing to
        // the person looking at them, so "Add to Queue" can't be a thing only
        // one of them can do. Songs without audio behind them are left out for
        // the same reason Play leaves them out: a queue that stops dead partway
        // through reads as a broken player.
        Button {
            deps.onlineCoordinator.addToQueue(localTracks: playableTracks)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(playableTracks.isEmpty)

        Divider()

        spotifySyncMenu

        // Read-only playlists skip the whole first section. Publishing someone
        // else's playlist to your profile, inviting people to it, or renaming it
        // are all things only its owner may do — and a mix has no owner to ask.
        // What's offered instead is the one edit that is legitimately yours to
        // make: take a copy and do as you like with that.
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

            // The one way in. The code and the link used to be copyable straight
            // from here, which meant two routes to the same thing that could
            // disagree — this one always shows what's actually being handed out.
            Button {
                showCollabShare = true
            } label: {
                Label("Invite Collaborators", systemImage: "person.badge.plus")
            }
            PlaylistShareMenuItems(playlist: playlist)

            Divider()

            Button {
                showEditSheet = true
            } label: {
                Label("Edit Details", systemImage: "pencil")
            }
        }

        // Offered on every playlist, including read-only ones: sending a copy
        // to Spotify takes nothing away from the source and isn't an edit of it.
        // Hidden only when there is no Spotify account to send it to.
        // Not offered once the playlist is already linked: "Send to Spotify"
        // would make a *second* copy over there, next to the one this playlist
        // is being kept in step with. The link's own section says what is
        // happening and how to change it.
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

        // Always offered, not just when something is visibly blank. A cover can
        // be present and wrong — a stale placeholder, art from the wrong record —
        // and an item that only appears when a square is grey can't fix that.
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
                // "Delete" overstates it for something you saved: the original is
                // untouched, and on a mix there is nothing to delete but your own
                // copy of it.
                Label(isReadOnly && !isSmart ? "Remove from Library" : "Delete Playlist",
                      systemImage: "trash")
            }
        }
    }

    /// Songs the playlist still holds an id for but can't show.
    ///
    /// Cheap, and wrong to offer a repair from: an id counts here whether the
    /// track behind it was buried by mistake, deleted on purpose, or never
    /// arrived on this device at all. Only the first of those can be put back.
    /// It earns its keep as the gate in front of `restorableTrackIDs`, which
    /// asks the store the real question — this is zero almost always, and when
    /// it is there is nothing to ask about.
    private var hiddenTrackCount: Int {
        max(0, livePlaylist.trackIDs.count - tracks.count)
    }

    /// The hidden songs a restore would genuinely bring back — the only number
    /// the menu is allowed to say out loud.
    private var restorableTrackIDs: [UUID] {
        guard hiddenTrackCount > 0 else { return [] }
        let visible = Set(tracks.map(\.id))
        return deps.libraryService.resurrectableTrackIDs(
            among: livePlaylist.trackIDs.filter { !visible.contains($0) })
    }

    // MARK: - Repair

    /// Re-fetches cover art for every song in this playlist, blank or not.
    ///
    /// Your own published covers first, then the catalogue Discover searches.
    /// Results are written to the track, so this is a repair rather than a fetch
    /// that has to happen on every launch, and whatever it finds goes up on the
    /// next sync — other devices get it without running this themselves.
    ///
    /// Songs it can't find keep the cover they already had; the only outcome of
    /// a miss is that nothing changes.
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

        // Nothing written is the good case as often as the bad one — it usually
        // means every cover here was already the right one.
        deps.showToast(updated == 0
                       ? "Covers are up to date"
                       : "Updated \(updated) cover\(updated == 1 ? "" : "s")")
    }

    /// Brings back songs a bad re-sync hid, by undoing deletions the server
    /// replayed onto rows that are newer than the deletion itself.
    ///
    /// Scoped to the songs the menu just counted, so the toast can't contradict
    /// the button that opened it. The library-wide sweep still exists behind
    /// Settings, for damage spread across playlists you'd never think to open.
    private func restoreMissingSongs() {
        let restored = deps.libraryService.restoreTracks(ids: restorableTrackIDs)
        // Zero is now a race rather than a disagreement: a sync in the second
        // between opening the menu and tapping can prune the id out from under it.
        deps.showToast(restored == 0
                       ? "Nothing to restore — those songs were deleted on purpose"
                       : "Restored \(restored) song\(restored == 1 ? "" : "s")")
    }

    // MARK: - Byline

    private var unavailableMessage: String {
        let who = livePlaylist.ownerName.map { "@\($0)" } ?? "The owner"
        return "\(who) has made this playlist private, so it can't update any more. You can keep it in your library in case it comes back, or remove it."
    }

    /// Works out whose playlist this is, for the line under the title.
    ///
    /// Three answers, and only the third costs a request:
    /// • a mix belongs to Mixtape, and says who it was made for;
    /// • a saved playlist belongs to the person it was saved from, whose name
    ///   was stored at save time so the header paints in the first frame;
    /// • your own playlist has no byline at all until somebody else is on it —
    ///   "mike" under a playlist in mike's library is an answer to a question
    ///   nobody asked. Once it's collaborative the names matter, and that's the
    ///   only case that goes to the network.
    ///
    /// Savers never appear here, which is the point of the whole design: saving
    /// writes nothing to the server, so there is nothing for this to find. Only
    /// people who were actually invited are in the byline.
    private func loadByline() async {
        switch livePlaylist.origin {
        case .mix:
            byline = [.mixtape]
            return
        case .subscribed:
            // The stored name paints first — the header shouldn't wait on the
            // network to say whose playlist this is. The lookup that follows
            // only decides whether that name is also a way in.
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
            // The mirror says so on the metadata line, where the sync time
            // belongs next to it. A byline would be claiming Spotify as a
            // *person* on the playlist, which it isn't.
            byline = []
            return
        case .owned:
            break
        }

        guard let link = PlaylistSharingService.shared.linkedShare(forLocalPlaylist: playlist.id),
              let rows = try? await PlaylistSharingService.shared
                  .collaborators(sharedPlaylistID: link.sharedPlaylistID),
              // Invited-but-not-yet-joined isn't a collaborator, it's a pending
              // question. Counting one would put a name on a playlist they may
              // still say no to.
              case let joined = rows.filter({ $0.status == .joined }),
              !joined.isEmpty
        else {
            byline = []
            return
        }

        var members: [BylineMember] = []

        // You first, and by profile rather than by `currentUser.displayName`,
        // which falls back to the email address when no name is set — everyone
        // else here is an @username, and one "mike@gmail.com" among them reads
        // as a different kind of thing entirely.
        if let user = deps.authService.currentUser {
            let profile = try? await deps.authService.fetchProfile(id: user.id)
            members.append(BylineMember(id: user.id,
                                        name: profile?.name ?? user.displayName,
                                        avatarURL: profile?.avatarURL ?? user.avatarURL))
            // Kept so the name can open the page. Nothing is recorded when the
            // fetch failed, which is exactly when there'd be nothing to open.
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

    /// Turns a read-only playlist into one of your own.
    ///
    /// Local and instant — the songs are already here, so this is a new playlist
    /// pointed at the same rows, not an import. The copy is detached by
    /// construction: `.owned`, no link, so nothing ever pulls the original's
    /// changes onto it, which is exactly what makes it editable.
    /// A second, independent copy of this playlist, opened in place of it.
    ///
    /// Deliberately not linked to anything the original is: a duplicate is a
    /// starting point for a different playlist, and inheriting a Spotify link
    /// would have two local playlists writing to one remote one.
    private func duplicatePlaylist() {
        guard let copy = deps.libraryService.duplicatePlaylist(id: playlist.id) else { return }
        deps.showToast("Duplicated as \u{201C}\(copy.name)\u{201D}")
    }

    private func makeEditableCopy() {
        let source = livePlaylist
        guard !source.trackIDs.isEmpty else { return }

        let copy = deps.libraryService.createPlaylist(name: source.name,
                                                      description: source.description,
                                                      artworkData: source.displayArtwork)
        deps.libraryService.setTracks(source.trackIDs, inPlaylist: copy.id)
        deps.showToast("Copied \u{201C}\(source.name)\u{201D} to your library")
    }

    // MARK: - Profile visibility

    /// Draws the toggle immediately from the local cache, then corrects it from
    /// the server — another device may have published or hidden this playlist
    /// since we last looked, and a switch that lies is worse than a slow one.
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

    /// Plays `track`, with the rest of the playlist queued behind it.
    ///
    /// `selection` narrows that queue to a chosen set of rows — "Play 12 Songs"
    /// should play those twelve and stop, not use them as a starting point for
    /// the whole playlist.
    /// Offline and not on this device: the row is greyed and a tap says so
    /// rather than starting a resolve that can only time out.
    private func offlineUnavailable(_ track: Track) -> Bool {
        deps.libraryService.offlineOnly
            && !deps.downloadManager.downloadedTrackIDs.contains(track.id)
    }

    private func playAndMark(_ track: Track, within selection: [Track]? = nil) {
        guard !offlineUnavailable(track) else {
            deps.showToast("\u{201C}\(track.displayTitle)\u{201D} isn't downloaded — you're offline.")
            return
        }
        // Deliberately no placeholder guard here. A placeholder has no local file
        // and no remote key, which is exactly the condition the engine already
        // treats as "resolve this online" — so handing it straight to `play` is
        // what gives it a chance of producing audio. An earlier version answered
        // the tap with a toast and a jump to Discover instead, and in doing so
        // intercepted the one path that could have played the song.
        PlaylistMetadataService.shared.markPlayed(playlistID: playlist.id)
        mixMainActivity("playlist-page/mark-played-refresh") {
            deps.libraryService.refreshPlaylists()
        }
        // play() resets the source playlist, so mark it after playback starts.
        // The clicked song is played. Not "the clicked song if it survived the
        // filter, otherwise whatever happens to be first" — that line is what
        // made clicking the second row start the first one, silently, with the
        // playlist's own top song as the substitute. If the row isn't in the
        // playable list, the answer is a wider context, never a different song.
        let filtered = selection.map { $0.filter(\.canResolveAudio) } ?? playableTracks
        let context  = filtered.contains { $0.id == track.id }
                     ? filtered
                     : (selection ?? visibleTracks)
        Task {
            await engine.play(track: track, in: context,
                              source: .playlist(id: playlist.id, name: playlist.name))
        }
    }

    /// Opens Discover with this song's title and artist already searched, so a
    /// placeholder can be turned into the real thing in two taps.
    ///
    /// The query is filed with the session store *and* fired directly rather
    /// than left to the Discover view's `onChange`. On iOS that view may not
    /// exist yet — a tab never opened this launch has nothing to observe the
    /// change — and the search would arrive at a view that isn't there.
    private func findInDiscover(_ track: Track) {
        let query = [track.title, track.artistName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return }

        let store = DiscoverSessionStore.shared
        // Land on the results rather than on whatever page Discover was last
        // drilled into.
        store.path.removeAll()

        #if os(macOS)
        // Order matters: `searchText` writes into whichever corpus the current
        // selection names, so selecting Discover first is what stops the query
        // being filed under — and applied to — the library's search box.
        appState.selection  = .discover
        appState.searchText = query
        // The user asked for this search by name, so it lands committed —
        // writing the text alone would only arm the suggestions panel.
        appState.showSearchResults()
        #else
        store.iosQuery = query
        iosAppState.selectedTab = .discover
        #endif

        store.search(query, using: deps.itunesClient, immediate: true)
    }

    /// Downloads `track` from Supabase (or uses the playback cache) and exports it
    /// to the user's chosen folder with proper filename and embedded ID3 metadata.
    /// On macOS, if no export folder is configured, opens the folder picker first.
    private func saveToDisk(_ track: Track) { saveToDisk([track]) }

    /// The same export for a selection: one folder prompt, then the songs in
    /// order. A failure part-way is reported and the rest still go — a single
    /// unreachable song shouldn't cancel the other forty.
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

            // Finding the audio — cached, downloaded, imported, on Supabase, or
            // only resolvable from the internet — is the download manager's job,
            // and it is the same job here. Said once, before the run: a toast per
            // song would be a stack of them for a selection.
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
                        deps.showToast(error.localizedDescription)
                        return
                    }
                }
            }

            let saved = targets.count - failures
            if targets.count == 1 {
                deps.showToast("Saved \"\(targets[0].title)\"")
            } else if failures == 0 {
                deps.showToast("Saved \(saved) songs")
            } else {
                deps.showToast("Saved \(saved) of \(targets.count) songs")
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(for track: Track) -> some View {
        // Every item below acts on `targets`: the row that was right-clicked, or
        // the whole selection when that row is inside it. One song reads exactly
        // as it always did; several are counted, so nothing ever acts on more
        // rows than the wording admits to.
        let targets  = menuTargets(for: track)
        let playable = targets.filter(\.canResolveAudio)

        // A collaborator's own file, which this device can't get hold of. Play is
        // still offered — the engine sends anything with no local audio to the
        // online resolver, and a song someone ripped is often a song that also
        // exists online — but queueing it isn't, because a queue that stops dead
        // partway through reads as a broken player rather than a missing song.
        // Favourite, download and file-copy have nothing to act on at all.
        Button(label("Play Now", targets, plural: "Play \(targets.count) Songs"),
               systemImage: MixtapeIcons.play) {
            playAndMark(track, within: targets.count > 1 ? targets : nil)
        }
        if targets.count == 1, !track.canResolveAudio {
            Button("Find in Discover", systemImage: "sparkle.magnifyingglass") {
                findInDiscover(track)
            }
        } else if !playable.isEmpty {
            Button(label("Play Next", playable, plural: "Play \(playable.count) Next")) {
                // Reversed: each insert goes directly after the current song, so
                // pushing them in back-to-front is what leaves the selection in
                // the queue in the order it appears on screen.
                for song in playable.reversed() { engine.queue.insertNext(song) }
            }
            Button(label("Add to Queue", playable, plural: "Add \(playable.count) to Queue")) {
                for song in playable { engine.queue.append(song) }
            }
        }
        Divider()

        if !playable.isEmpty {
            // "Remove" only when every one of them is already a favourite —
            // otherwise the item fills the gaps, which is the wish behind
            // favouriting a mixed selection.
            let favoured = playable.allSatisfy { deps.libraryService.isFavourited(trackID: $0.id) }
            let verb     = favoured ? "Remove from Liked Songs" : "Add to Liked Songs"
            Button(label(verb, playable,
                         plural: favoured ? "Remove \(playable.count) from Liked Songs"
                                          : "Add \(playable.count) to Liked Songs")) {
                // Straight through the service, then one card: routing a
                // selection through `deps.toggleFavourite` would stack twenty
                // identical cards for one menu tap.
                let changed = playable.filter {
                    deps.libraryService.isFavourited(trackID: $0.id) == favoured
                }
                for song in changed { deps.libraryService.toggleFavourite(trackID: song.id) }
                if !favoured, !changed.isEmpty {
                    deps.showSavedToast(.favourites, count: changed.count)
                }
            }
        }

        // Mixes and saved playlists are excluded as *targets* as well: they're in
        // the list like any other playlist, and an "Add to Playlist" that quietly
        // did nothing would be the worst version of read-only. A playlist already
        // holding every selected song drops out for the same reason.
        let targetIDs = Set(targets.map(\.id))
        let targetPlaylists = deps.libraryService.playlists.filter { pl in
            !pl.isAllSongs && !pl.isDeleted && pl.isEditable
                && !targetIDs.isSubset(of: Set(pl.trackIDs))
        }
        if !targetPlaylists.isEmpty {
            Menu {
                ForEach(targetPlaylists) { pl in
                    Button(pl.name) {
                        deps.addTracks(ids: targets.map(\.id), toPlaylist: pl.id)
                    }
                }
                Divider()
                // The full sheet, which is the only way to reach a playlist that
                // doesn't exist yet — and on a selection, the only place that
                // shows which playlists already hold part of it.
                Button("Choose Playlist\u{2026}") { tracksForAddToPlaylist = targets }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        // Navigation and Get Info answer a question about one song, so they only
        // appear when there is one song to ask about.
        if targets.count == 1 {
            Divider()
            goToItems(for: track)
            ShareMenuItems(.track(track))
        }
        if !playable.isEmpty {
            Divider()
            // Two separate wishes, two separate items: "Download" keeps the song
            // playable with no network, "file copy" puts a real file in the export
            // folder. Neither implies the other.
            downloadItems(for: playable)
        }
        // A read-only playlist loses exactly one item here. Everything above acts
        // on the song — play it, favourite it, download it, put it in a playlist
        // of your own — and none of that is editing someone else's playlist. Only
        // removing from *this* playlist is, so only that disappears (along with
        // its divider, so the menu doesn't end on a rule).
        if playlist.isAllSongs {
            // Asks first. This is the same permanent, syncing delete that ⌘⌫
            // and the table's right-click menu both confirm — it shouldn't be
            // the one path where a mis-click loses the song silently.
            Divider()
            Button(label("Remove from Library", targets,
                         plural: "Remove \(targets.count) Songs from Library"),
                   role: .destructive) {
                tracksPendingDeletion = targets
            }
        } else if !isReadOnly {
            Divider()
            Button(label("Remove from Playlist", targets,
                         plural: "Remove \(targets.count) Songs from Playlist"),
                   role: .destructive) {
                deps.libraryService.removeTracks(ids: targets.map(\.id),
                                                 fromPlaylist: playlist.id)
                #if os(macOS)
                appState.clearTrackSelection()
                #endif
            }
        }
    }

    /// Picks the singular or counted wording for a menu item.
    private func label(_ singular: String, _ targets: [Track], plural: String) -> String {
        targets.count > 1 ? plural : singular
    }

    // MARK: - Download / file copy

    /// The offline and file-copy items for one track.
    ///
    /// Kept apart deliberately. "Download" means the song plays with the network
    /// off; a file copy means there's an audio file sitting in the user's export
    /// folder. Conflating the two is what made the old Download button write a
    /// folder full of files nobody asked for.
    @ViewBuilder
    private func downloadItems(for targets: [Track]) -> some View {
        if targets.count == 1, let track = targets.first {
            DownloadMenuItems(track: track, downloads: deps.downloadManager)

            if deps.downloadManager.isExported(track.id) {
                Button("Delete File Copy", systemImage: "trash") {
                    deps.downloadManager.deleteFileCopy(for: track.id)
                }
            } else {
                Button("Save a File Copy\u{2026}", systemImage: "square.and.arrow.down") {
                    saveToDisk(track)
                }
            }
        } else {
            BulkDownloadMenuItems(tracks: targets, downloads: deps.downloadManager)
            Button("Save \(targets.count) File Copies\u{2026}",
                   systemImage: "square.and.arrow.down") {
                saveToDisk(targets)
            }
        }
    }

    // MARK: - Go to Artist / Go to Album

    /// The two navigation items every track row offers. Features are split, so a
    /// track credited to "A feat. B" offers both artists rather than guessing.
    @ViewBuilder
    private func goToItems(for track: Track) -> some View {
        let credits = ImportService.creditedArtists(from: track.artistName)
        if credits.count > 1 {
            Menu("Go to Artist") {
                ForEach(credits, id: \.self) { name in
                    Button(name) { openArtist(named: name) }
                }
            }
        } else if let name = credits.first, !name.isEmpty {
            Button("Go to Artist", systemImage: "music.mic") { openArtist(named: name) }
        }
        if !track.albumTitle.isEmpty {
            Button("Go to Album", systemImage: "square.stack") { openAlbum(for: track) }
        }
    }

    private func openArtist(named name: String) {
        #if os(macOS)
        appState.openDiscoverArtist(named: name)
        #else
        // The Discover artist page, the same as macOS and the same as tapping
        // the name in a row: the local page only holds what you saved.
        iosAppState.openOnlineArtist(name: name)
        #endif
    }

    private func openAlbum(for track: Track) {
        #if os(macOS)
        appState.openDiscoverAlbum(for: track)
        #else
        // The whole record from the catalogue, like Spotify — the local album
        // only holds the songs you happen to have. Offline, that's all there is.
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
    //
    // Arrow keys, Return, ⌘A and Escape used to be handled here with
    // `.onMoveCommand`/`.onKeyPress`. The macOS table is an NSTableView now and
    // does all four itself, so the hand-rolled versions are gone.

    /// iOS has no pointer selection, so a row's menu is always about that row.
    /// (On macOS the table builds its own menu against the real selection.)
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
        // Rows paint their own hover/selection pill, so the list row itself is
        // transparent and edge-to-edge — see `TrackColumns` for the geometry.
        .listRowInsets(TrackColumns.rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            trackContextMenu(for: track)
        }
        // ── Swipe left: delete / remove ──────────────────────────
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if playlist.isAllSongs {
                // Confirms, unlike most swipe-to-delete. Mail's swipe puts the
                // message in a bin you can open again; this one takes the song
                // off every device the account is signed into.
                Button(role: .destructive) {
                    tracksPendingDeletion = [track]
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if !isReadOnly {
                Button(role: .destructive) {
                    deps.libraryService.removeTrack(id: track.id, fromPlaylist: playlist.id)
                } label: {
                    Label(
                        playlist.isFavourites ? "Unlike" : "Remove",
                        systemImage: playlist.isFavourites ? "heart.slash" : "minus.circle"
                    )
                }
            }
            // Read-only: no trailing action at all. An empty builder leaves the
            // row un-swipeable, which is the right answer — a swipe that opens
            // onto nothing is worse than one that doesn't open.
        }
        // ── Swipe right: add to playlist ─────────────────────────
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

// MARK: - Track Table Columns

/// Which columns the playlist table shows, and how wide they are.
///
/// The header and every row are laid out from the same values, which is the
/// only thing keeping them lined up — there's no real table here, just two
/// HStacks that have agreed on their geometry.
///
/// Columns are chosen by measured width rather than by platform: a Mac window
/// dragged narrow deserves the same treatment as an iPhone, and an iPad in
/// landscape is wide enough to earn the full table.
struct TrackColumns {

    var showsAlbum = false
    var showsDate  = false
    /// Zero when the album column is hidden.
    var albumWidth: CGFloat = 0

    /// True once at least one extra column is showing — below this the row is
    /// the plain artwork/title/heart layout and a header would be labelling
    /// columns that aren't there.
    var isTable: Bool { showsAlbum || showsDate }

    static let date:     CGFloat = 96
    static let heart:    CGFloat = 32
    static let duration: CGFloat = 44
    /// Artwork (44) plus the gap before the title inside `TrackRowView` — how
    /// far the header's "Title" has to be pushed to sit over the song titles.
    static let titleInset: CGFloat = 56

    // MARK: Row geometry
    //
    // Read by both `PlaylistTrackRow` and `TrackListHeader` — the two only line
    // up because they measure from the same numbers.
    //
    // iOS runs tight at the leading edge. A Mac window has chrome to sit inboard
    // of and a phone doesn't, so every point spent on a gutter there is a point
    // the song title never gets; the index sits almost on the edge and the row
    // reads as the full width of the screen. The trailing side keeps more, since
    // that's where the duration and the heart are.

    #if os(iOS)
    /// Four digits of 12pt monospaced digits (~7.2pt each) plus a hair. A
    /// playlist runs to whatever length you make it, and at 20pt every
    /// position past 99 rendered as "1…".
    static let index:      CGFloat = 32
    /// Between the index, the title block and each trailing column.
    static let gutter:     CGFloat = 8
    /// Inside the row's own selection/hover pill.
    static let rowPadding: CGFloat = 6
    static let rowLeading:  CGFloat = 4
    static let rowTrailing: CGFloat = 8
    /// Air above and below each row. Zero on the Mac: that table is meant to be
    /// dense, and tight rows are what make a hundred of them readable at once.
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

/// The grey `#  Title  Album  Date added  ⏱` strip above the songs.
///
/// Internal rather than private to this file because a mix page is a playlist
/// page — it draws the same header over the same rows, from the same
/// `TrackColumns`, which is the only reason the two line up.
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

            // Nothing to label above the heart, but the space still has to be
            // reserved or every column to its left drifts.
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
//
// The playlist's own row treatment: a leading track number that turns into a
// play triangle on hover, an inset hover/selection pill, and single-click
// select (double-click still plays). Rows used to start flush against the
// window edge with no hover feedback at all.

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
    /// Non-nil outside the library: the row saves rather than favourites.
    /// See `TrackRowView.onSaveToLibrary`.
    var onSaveToLibrary: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: TrackColumns.gutter) {
            indexColumn

            // In table mode the heart moves out to its own column so it sits
            // under nothing rather than in the middle of the row.
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

    /// The narrow gutter that gives the row its Spotify-style position number.
    /// Right-aligned so double digits grow leftwards and every artwork below
    /// still starts on the same line.
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
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
                    // Belt and braces: the column is sized for four digits, and
                    // anything past that shrinks rather than becoming "1…".
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: TrackColumns.index, alignment: .trailing)
    }

    /// Only shown in table mode — otherwise `TrackRowView` draws the heart in
    /// its own trailing slot.
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
        // An unfavourited song only offers its heart while the pointer is on
        // the row, so the column isn't a wall of grey outlines.
        .opacity(isFavourited || isHovered ? 1 : 0)
        #endif
    }

    /// "2 days ago", "Last week" — see `AddedDateText`, which the macOS table
    /// draws from too so the two lists never word the same song differently.
    private var dateAdded: String { AddedDateText.relative(track.dateImported) }
}

// MARK: - Add to Playlist Sheet

/// Pick playlists for one song.
///
/// Modelled on Spotify's sheet, and for the same reasons: you can see at a
/// glance which playlists the song is *already* in, you can add it to several in
/// one visit, and the sheet doesn't slam shut on the first tap. The old version
/// showed no membership at all and dismissed immediately, so adding a song to
/// three playlists meant opening it three times and guessing each time.
struct AddToPlaylistSheet: View {

    /// Why the sheet was opened, which decides what it leads with.
    enum Purpose {
        /// "File this song somewhere" — opened from a menu.
        case add
        /// "Where is this song?" — opened by tapping the check on a song that is
        /// already saved. Same list, but it has to answer the question that was
        /// asked, so the library itself appears under "Saved in". Without it the
        /// sheet said nothing at all about a song that had just been saved: All
        /// Songs is filtered out of the pickable playlists, so a song in the
        /// library and no playlist looked exactly like a song saved nowhere.
        case savedIn
    }

    /// The songs being filed. Usually one; a multi-row selection on macOS sends
    /// the whole lot, and then every row in the sheet is a decision about all of
    /// them at once.
    let tracks: [Track]
    var purpose: Purpose = .add
    /// The playlist the sheet was opened from, hidden from the list because
    /// "add it to the playlist you're already looking at" isn't an offer. Nil
    /// when opened from the player, where there is no such context — then every
    /// playlist is fair game, including the one the song already sits in.
    var sourcePlaylistID: UUID? = nil

    /// What frame this is wearing. The list is the same either way — only the
    /// chrome around it, and how much room it has, differ.
    enum Chrome {
        /// A modal sheet. Still what iOS gets, and what the Mac gets in the one
        /// place there is no window to hang a panel in.
        case sheet
        /// A small box in the corner of the window, above the player bar, with
        /// the app still live behind it. See `SavedInPanel`.
        case panel
    }

    var chrome: Chrome = .sheet
    /// How to close, when there is no sheet to dismiss. Nil means "you are a
    /// sheet, use the environment".
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

    /// Which playlists hold *every* song in `tracks`, as this sheet sees it.
    ///
    /// Kept here rather than read off `libraryService.playlists` on each redraw,
    /// so the checkmark and the section a row sits in come from one value that
    /// changes on the tap itself. Deriving them separately is what let a row
    /// move up under "Saved in" still wearing an empty ring: the arrays
    /// recomputed, the glyph didn't.
    @State private var membership: Set<UUID> = []

    /// Playlists holding some but not all of the selection. Only ever populated
    /// for a multi-song sheet, where "is this song in here" has three answers
    /// rather than two and a plain ring would be a lie about half of them.
    @State private var partialMembership: Set<UUID> = []

    /// Bumped on the row whose mark was just turned off, to fire the reverse of
    /// the save bounce on it. Keyed by playlist so only that row animates, and a
    /// counter rather than a flag so unfiling two rows in a row is two bounces.
    @State private var unfilePops: [UUID: Int] = [:]

    /// Bumped whenever the library publishes. `deps` doesn't republish for
    /// changes inside `libraryService`, so without this a playlist made from the
    /// "New playlist" row only appeared when something else happened to redraw
    /// the sheet.
    @State private var libraryTick = 0

    /// Stands in for the "New playlist" row in `hoveredID`, which is otherwise
    /// keyed by playlist.
    private static let newRowID = UUID()

    // Every playlist a song can be filed under: user playlists plus Favourites.
    // All Songs is excluded — it's auto-managed, and "add to All Songs" isn't a
    // choice anyone gets to make. Mixes and saved playlists are excluded for the
    // opposite reason: every row here is a toggle, and there's nothing to toggle
    // on a playlist this user can't edit. It also keeps "Saved in" honest — that
    // list answers "where did you file this", and a song appearing in someone
    // else's playlist isn't an answer to that.
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

    /// Already contains the song — or all of them.
    private var containing: [Playlist] {
        matching.filter { membership.contains($0.id) }
    }

    /// Doesn't yet — most recently updated first, so the playlist someone is
    /// actively building is the one at the top. A playlist holding part of the
    /// selection belongs here: there is still something to add to it.
    private var available: [Playlist] {
        matching
            .filter { !membership.contains($0.id) }
            .sorted { $0.sync.localModifiedAt > $1.sync.localModifiedAt }
    }

    /// What the library currently says, used to seed `membership` when the sheet
    /// opens. Full membership first, then the playlists holding only part of a
    /// multi-song selection.
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

    /// The corner panel. No footer, no window chrome: the title says what this
    /// is, the close button is the only control that isn't a playlist, and
    /// clicking anywhere else in the app closes it too.
    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheetTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
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

    /// Inset for everything in the list. The panel is far narrower than the
    /// sheet, and the sheet's margins inside it would leave the covers crowding
    /// the names.
    private var hPad: CGFloat { chrome == .panel ? 14 : 20 }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var sheetBody: some View {
        // This sheet had already worked out that a nav title inside a Mac sheet
        // renders as a large heading with a great deal of air above it, and
        // hand-built a title bar and button row to avoid it. That reasoning is
        // now the shared chrome's job, so both platforms get the same answer
        // instead of this one file getting it right alone.
        //
        // `scroll: false` — the playlist list owns its own scrolling, and the
        // search field has to stay put above it.
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

    /// Both platforms' heading. `.savedIn` answers the question that was asked
    /// by tapping the check; you can still file the song elsewhere from here,
    /// but that isn't what the sheet is for at that point.
    private var sheetTitle: String {
        purpose == .savedIn ? "Saved In" : "Add to Playlist"
    }

    /// One song names itself; a selection is counted. Listing five titles in a
    /// subtitle would truncate to something less useful than the number.
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
                .font(.system(size: 13))
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

    /// A plain scroller, not a `List`. The list's own row backgrounds, inset
    /// separators and selection styling were all fighting the palette — every
    /// row carried a full-width hairline, including under the section headings,
    /// which is what made this look assembled rather than designed.
    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                newPlaylistRow

                Divider()
                    .overlay(Color.mixSeparator)
                    .padding(.leading, hPad)

                // One flat ForEach rather than a ForEach per section. With two of
                // them a playlist that crossed from "Recently updated" to "Saved
                // in" kept the identity — and the view — it had in the other
                // loop, so it arrived in its new section still drawn the old way.
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
                        .font(.system(size: 13))
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

    /// A heading, a playlist, or the library itself, so all three can live in
    /// one `ForEach`.
    private enum Entry: Identifiable {
        case header(String)
        case playlist(Playlist)
        /// The library row. Not a `.playlist` even though All Songs is one
        /// underneath: it is named differently, it is never a target to add to,
        /// and pressing it deletes the song rather than unfiling it.
        case library(Playlist)

        var id: String {
            switch self {
            case .header(let title):    return "h:\(title)"
            case .playlist(let list):   return "p:\(list.id.uuidString)"
            case .library:              return "library"
            }
        }
    }

    /// All Songs, which every saved track belongs to. Shown only in `.savedIn`,
    /// and not while a search is running — the field filters playlists, and a
    /// row that ignores it would read as a result that doesn't match.
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
        // Library first: it's the broadest answer to "where is this", and the
        // playlists underneath narrow it down.
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
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mixTextSecondary)
            .padding(.horizontal, hPad)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    // MARK: - Rows

    /// A playlist and whether the song is in it. Tapping toggles — and the sheet
    /// stays open, because the next tap is usually another playlist.
    ///
    /// Purpose-built rather than reusing `PlaylistRowView`: that row carries a
    /// now-playing equaliser and tints its title, both of which are answers to a
    /// question nobody is asking here. What matters in this sheet is whether the
    /// song is filed under this playlist.
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
                            .font(.system(size: 14, weight: .medium))
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
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                }

                Spacer(minLength: 8)

                // A filled mark for in, a thin ring for out, a dash for a
                // playlist that already holds part of the selection. Light
                // weight keeps the empty state a hairline outline instead of a
                // heavy blob.
                Image(systemName: isIn ? "checkmark.circle.fill"
                                       : (isPartial ? "minus.circle.fill" : "circle"))
                    .font(.system(size: 19, weight: isIn || isPartial ? .regular : .light))
                    .foregroundStyle(isIn ? Color.mixPrimary
                                          : (isPartial ? Color.mixPrimary.opacity(0.55)
                                                       : Color.mixTextTertiary))
                    .mixSymbolReplace()
                    .mixAnimation(.snappy(duration: 0.22), value: isIn)
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

    /// "Your Library" — and, like every other row in this sheet, the way back
    /// out of it.
    ///
    /// This was deliberately inert once, on the grounds that a song leaving the
    /// library can take a downloaded file with it and that belonged in the
    /// library rather than in a sheet about playlists. The row read as a
    /// control anyway: a name with a filled check beside it, in a list where
    /// every other filled check unfiles the song when pressed. A control that
    /// does nothing isn't restraint, it's a bug — so it now does the thing it
    /// looks like it does. The delete is the soft one the rest of the app uses:
    /// the songs go to Recently Deleted and come back whole.
    private func libraryRowView(_ playlist: Playlist) -> some View {
        Button {
            removeFromLibrary()
        } label: {
            HStack(spacing: 12) {
                artwork(for: playlist)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Library")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("\(playlist.trackCount) song\(playlist.trackCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
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

    /// Leaves the library entirely — which also means leaving every playlist in
    /// it, and giving back any downloaded file. The sheet closes afterwards
    /// because none of what it was showing is true any more: the playlists it
    /// listed no longer hold the song, and the row that was just pressed no
    /// longer has anything to describe.
    private func removeFromLibrary() {
        unfilePops[Playlist.allSongsID, default: 0] += 1
        Haptics.play(.success)
        deps.libraryService.deleteTracks(ids: tracks.map(\.id))
        deps.showRemovedToast(.library, count: tracks.count)
        // Long enough for the mark to bounce before the sheet goes; short
        // enough that it still reads as one gesture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { close() }
    }

    /// 44pt tile. Deliberately no tinted fill behind the glyphs — the orange
    /// wash behind Favourites and "New playlist" was reading as a glow.
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

    /// Inline "New playlist" — the whole reason to leave this sheet was usually
    /// that the right playlist didn't exist yet.
    @ViewBuilder
    private var newPlaylistRow: some View {
        if isNamingNewPlaylist {
            HStack(spacing: 12) {
                newPlaylistTile

                TextField("Playlist name", text: $newPlaylistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mixTextPrimary)
                    .focused($newNameFocused)
                    .onSubmit { createAndAdd() }

                Button("Create") { createAndAdd() }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canCreate ? Color.mixPrimary : Color.mixTextTertiary)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, 7)
        } else {
            Button {
                // A search that found nothing is usually a playlist that doesn't
                // exist yet, so it seeds the name.
                newPlaylistName = matching.isEmpty ? query : ""
                isNamingNewPlaylist = true
                newNameFocused = true
            } label: {
                HStack(spacing: 12) {
                    newPlaylistTile

                    Text("New playlist")
                        .font(.system(size: 14, weight: .medium))
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

    /// Flips `membership` first, then writes it through. The mark and the section
    /// both read from that set, so they change together on the tap instead of
    /// waiting on a publisher.
    private func toggle(_ playlist: Playlist) {
        let ids = tracks.map(\.id)
        if membership.contains(playlist.id) {
            membership.remove(playlist.id)
            partialMembership.remove(playlist.id)
            deps.libraryService.removeTracks(ids: ids, fromPlaylist: playlist.id)
            unfilePops[playlist.id, default: 0] += 1
            Haptics.play(.success)
            // The card, not the wide toast: this is the mirror of the "Added to
            // \u{2026}" the same gesture shows on the way in, and the two reading
            // differently made unfiling feel like a warning.
            deps.showRemovedToast(destination(for: playlist), count: tracks.count)
        } else {
            // A partial playlist fills up rather than emptying: the row was
            // showing "some of these are here", and the obvious next wish is
            // for the rest to join them.
            membership.insert(playlist.id)
            partialMembership.remove(playlist.id)
            deps.addTracks(ids: ids, toPlaylist: playlist.id)
        }
    }

    /// The card's own idea of where a playlist is: Favourites and the library
    /// are system rows and name themselves, everything else is itself.
    private func destination(for playlist: Playlist) -> SaveDestination {
        if playlist.isFavourites { return .favourites }
        if playlist.isAllSongs   { return .library }
        return .playlist(id: playlist.id, name: playlist.name)
    }

    /// Empty for one song — "Added to Roadtrip" — and a count for a selection,
    /// which is the only case where the number tells you anything. Carries its
    /// own trailing space so the one-song sentence doesn't grow a double one.
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

/// The search term left in each playlist, for as long as the app is running.
/// Not persisted: a filter is where you got to in a browsing session, and one
/// restored from three days ago reads as a playlist that has lost its songs.
enum PlaylistSearchMemory {
    private static var queries: [UUID: String] = [:]

    static func query(for playlistID: UUID) -> String { queries[playlistID] ?? "" }

    static func set(_ query: String, for playlistID: UUID) {
        if query.isEmpty { queries[playlistID] = nil } else { queries[playlistID] = query }
    }
}
