// IOSDiscoverView.swift
// Mixtape — iOS/Online
//
// iOS port of OnlineDiscoverView. On iOS the coordinator resolves audio through
// the Mac/server RemoteResolverService, then plays the downloaded .m4a. Uses a
// native NavigationStack where the Mac needs a manual path stack.

#if os(iOS)
import SwiftUI
import Combine

struct IOSDiscoverView: View {

    /// Opens the Settings sheet, which MainTabView owns. Optional so the pushed
    /// pages and previews that build this view without a tab bar around it don't
    /// have to invent one.
    var onOpenSettings: (() -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var iosAppState:  IOSAppState

    /// Query, results, landing content and the drill-down stack all live in the
    /// store rather than in @State, so the tab comes back exactly as it was
    /// left. Shared with macOS, where it's load-bearing — MacContentRouter
    /// destroys Discover outright whenever you look at another section.
    ///
    /// The typed path replaces NavigationPath: it's what lets the store persist
    /// the stack (NavigationPath can't be inspected or rebuilt) and it's the
    /// same `[DiscoverDestination]` the Mac side keeps.
    @ObservedObject private var store = DiscoverSessionStore.shared

    private var results: DiscoverResults { store.results }
    private var browse: BrowseLanding { store.browse }
    private var browseLoading: Bool { store.browseLoading }

    /// Written straight through to the store; nonmutating because the storage
    /// is the store, not this struct.
    private var path: [DiscoverDestination] {
        get { store.path }
        nonmutating set { store.path = newValue }
    }

    var body: some View {
        NavigationStack(path: $store.path) {
            ScrollView {
                if let error = coordinator.errorMessage {
                    banner(error)
                }
                content
                    .padding(.bottom, 24)
            }
            // Spotify's header: avatar and filters pinned above the page instead
            // of a large "Home" title the tab bar already says.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
            .mixPullToRefresh(deps) {
                // The landing is the store's, not the library's, so a sync
                // alone would leave the half of this page the user can see
                // exactly as it was.
                await store.reloadBrowse(using: deps.itunesClient)
            }
            .mixAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.errorMessage)
            .background(Color.mixBackground.ignoresSafeArea())
            .miniPlayerSafeArea()
            .navigationTitle("Home")
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: DiscoverDestination.self) { dest in
                Group {
                    switch dest {
                    case .artist(let artist):
                        IOSDiscoverArtistPage(
                            artist: artist,
                            onOpenAlbum: { path.append(DiscoverDestination.album($0)) },
                            onOpenArtist: { path.append(DiscoverDestination.artist($0)) },
                            onOpenLiked: { path.append(DiscoverDestination.likedSongs(artist)) },
                            onPlay: { track, ctx in Task { await play(track, context: ctx) } }
                        )
                    case .likedSongs(let artist):
                        DiscoverLikedSongsPage(artist: artist)
                    case .album(let album):
                        IOSDiscoverAlbumPage(
                            album: album,
                            onPlay: { track, ctx in Task { await play(track, context: ctx) } },
                            onOpenArtist: { path.append(DiscoverDestination.artist($0)) }
                        )
                    case .genre(let genre):
                        IOSDiscoverGenrePage(
                            genre: genre,
                            onOpenArtist: { path.append(DiscoverDestination.artist($0)) }
                        )
                    case .mix(let mix):
                        MixDetailPage(
                            mix: mix,
                            onPlay: { track, ctx in Task { await play(track, context: ctx) } },
                            onShuffle: {
                                let shuffled = mix.tracks.shuffled()
                                guard let first = shuffled.first else { return }
                                Task { await play(first, context: shuffled) }
                            },
                            resolvingID: coordinator.resolvingID,
                            onOpenMixtape: { path.append(DiscoverDestination.mixtapeProfile) },
                            onOpenProfile: { path.append(DiscoverDestination.profile($0)) },
                            onOpenArtist: { openArtist(named: $0) }
                        )
                        .navigationTitle(mix.title)
                        .navigationBarTitleDisplayMode(.inline)
                    case .mixtapeProfile:
                        MixtapeProfilePage(
                            onOpenMix: { path.append(DiscoverDestination.mix($0)) },
                            onPlayMix: { mix in
                                guard let first = mix.tracks.first else { return }
                                Task { await play(first, context: mix.tracks) }
                            },
                            // Saved mixes are library playlists, so this leaves
                            // the Discover tab rather than pushing a library
                            // page onto its stack.
                            onOpenSavedMix: { iosAppState.openLibraryPlaylist($0) },
                            resolvingID: coordinator.resolvingID
                        )
                        .navigationTitle("Mixtape")
                        .navigationBarTitleDisplayMode(.inline)
                    case .profile(let profile):
                        ProfilePageView(profile: profile)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .miniPlayerSafeArea()
            }
        }
        // No search field here any more. Searching is the Search tab's job —
        // one field for the library *and* the catalogue — and a second one on
        // Home meant two doorways sharing one result store, where a search
        // started in either would silently redraw the other.
        //
        // Tapping Home while you're already on it still unwinds to the landing.
        .onChange(of: iosAppState.homeResetToken) { _, _ in
            path.removeAll()
        }
        .onChange(of: store.resultsQuery) { _, _ in warmTopResults() }
        // First launch appears before the library has loaded, and a personal
        // landing built from an empty library is refused — retry once songs
        // exist. Same fix as macOS.
        // `dropFirst`: SwiftUI re-subscribes on every redraw and `$tracks` replays
        // its current value, which re-ran the seed scan (~125ms) each time — the
        // search-bar freeze. `onAppear` already covers the first load.
        // Deferred a tick: `$tracks` fires in `willSet`, so read synchronously the
        // library is still the empty one and the load refuses — Home then stayed
        // on "Trending now" until a tab switch re-ran `onAppear`.
        .onReceive(deps.libraryService.$tracks.map(\.isEmpty).removeDuplicates().dropFirst()) { _ in
            DispatchQueue.main.async { loadPersonal() }
        }
        .sheet(isPresented: $showGenerateMix) {
            GenerateMixSheet().environmentObject(deps)
        }
        .onAppear {
            store.loadBrowseIfNeeded(using: deps.itunesClient)
            // Seeds need the main-actor stats and library services, which the
            // store deliberately doesn't hold — so they're computed here and
            // handed over. Cheap on every appear: the store's TTL and seed
            // fingerprint decide whether anything is actually fetched.
            loadPersonal()
        }
        // No cancel on disappear: the task belongs to the store, so a search
        // still in the air finishes and its results are waiting on the way back
        // instead of having been thrown away halfway.
        // Consume a cross-tab request to open an online artist by name (set when
        // a featured/unmatched artist is tapped in the mini player / now-playing
        // sheet / Home). Resolve the name to a Deezer artist and push its page.
        .onChange(of: iosAppState.pendingDiscoverArtistName) { _, name in
            guard let name else { return }
            iosAppState.pendingDiscoverArtistName = nil
            Task {
                if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                    await MainActor.run { path.append(DiscoverDestination.artist(artist)) }
                }
            }
        }
        // Mixtape's profile, asked for from another tab — the byline on a saved
        // mix in the library.
        .onChange(of: iosAppState.pendingMixtapeProfile) { _, wanted in
            guard wanted else { return }
            iosAppState.pendingMixtapeProfile = false
            path.append(DiscoverDestination.mixtapeProfile)
        }
    }

    // MARK: - Header

    private enum HomeFilter: String, CaseIterable {
        case all = "All", mixes = "Mixes", discover = "Discover", library = "Library"
        /// Only what plays with no network. Chosen for the user when the
        /// network goes — see `OfflineWatcher` in the header.
        case downloaded = "Downloaded"
    }

    @State private var filter: HomeFilter = .all
    @State private var isOffline = false

    private func shows(_ section: HomeFilter) -> Bool { filter == .all || filter == section }

    private var header: some View {
        HStack(spacing: 10) {
            ProfileMenuButton(size: 32)
                .environmentObject(deps)
            IOSFilterPills(filters: isOffline ? [.downloaded] : HomeFilter.allCases, selection: $filter)
            OfflineWatcher(downloads: deps.downloadManager) { offline in
                isOffline = offline
                // Only on the way out: coming back leaves the user where they are.
                if offline { filter = .downloaded }
            }
            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: MixtapeIcons.settings)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .tint(Color.mixPrimary)
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 16)
        .background(Color.mixBackground)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        // Always the landing. Results belong to the Search tab now, and they
        // live in the same shared store — so branching on `results` here would
        // put someone else's search on this page.
        browseLanding
    }

    // MARK: - Landing

    /// One scroll of cards and shelves, Spotify's phone Home rather than the
    /// Mac's page squeezed down: bold section titles, horizontal shelves that
    /// cost one row however long they are, and no wrapping grids. The pills in
    /// the header narrow it to one kind of thing.
    private var offlinePlaylists: [Playlist] {
        deps.libraryService.playlists.filter { !$0.trackIDs.isEmpty && deps.downloadManager.isFullyDownloaded($0.trackIDs) }
    }
    private var offlineAlbums: [Album] {
        deps.libraryService.albums.filter { SavedAlbumsService.shared.isSaved($0) && deps.downloadManager.isFullyDownloaded($0.trackIDs) }
    }

    /// Spotify's offline Home: downloaded things as tiles, local artwork only.
    @ViewBuilder
    private var offlineHome: some View {
        let playlists = offlinePlaylists, albums = offlineAlbums
        if playlists.isEmpty && albums.isEmpty {
            DownloadedSongsView(downloads: deps.downloadManager, embedded: true)
                .environmentObject(deps.libraryService)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(playlists.prefix(8)) { p in
                    offlineTile(p.name) { PlaylistArtwork(playlist: p, size: 52, cornerRadius: 0) } open: { iosAppState.openLibraryPlaylist(p) }
                }
                ForEach(albums.prefix(8)) { a in
                    NavigationLink(value: a) {
                        offlineTileLabel(a.title) { ArtworkThumbnail(data: a.artworkData, artworkRef: .album(a.id), size: 52, cornerRadius: 0, placeholder: MixtapeIcons.album) }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 12) {
                Text("While you're offline").font(.system(size: 22, weight: .bold)).padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(playlists) { p in
                            Button { iosAppState.openLibraryPlaylist(p) } label: {
                                offlineCard(p.name, "Playlist") { PlaylistArtwork(playlist: p, size: 140) }
                            }.buttonStyle(.plain)
                        }
                        ForEach(albums) { a in
                            NavigationLink(value: a) {
                                offlineCard(a.title, a.artistName) { ArtworkThumbnail(data: a.artworkData, artworkRef: .album(a.id), size: 140, cornerRadius: 6, placeholder: MixtapeIcons.album) }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
    }

    private func offlineTile<A: View>(_ title: String, @ViewBuilder art: () -> A, open: @escaping () -> Void) -> some View {
        Button(action: open) { offlineTileLabel(title, art: art) }.buttonStyle(.plain)
    }

    private func offlineTileLabel<A: View>(_ title: String, @ViewBuilder art: () -> A) -> some View {
        HStack(spacing: 8) {
            art().frame(width: 52, height: 52).clipped()
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mixTextPrimary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .background(Color.mixTextPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func offlineCard<A: View>(_ title: String, _ subtitle: String, @ViewBuilder art: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            art()
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }.frame(width: 140, alignment: .leading)
    }

    private var browseLanding: some View {
        VStack(alignment: .leading, spacing: 30) {
            if filter == .downloaded {
                // Nothing else on this page can start without a network, so the
                // pill replaces the landing rather than filtering it.
                offlineHome
            } else {
            // Jump back in: the two-column tiles, and the library's own shelves.
            if shows(.library) { homeSections(bands: .top) }

            if shows(.mixes) { madeForYou }

            // Made from your listening too, so they sit with the mixes rather
            // than below Trending now.
            if shows(.library),
               HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                homeSections(bands: .smart)
            }

            if shows(.discover) { catalogue }

            if shows(.library) {
                if HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                    homeSections(bands: .library)
                }
                HomeStatsCard()
            }

            // Only when there is genuinely nothing to show.
            if browse.isEmpty && store.personal.isEmpty { landingPlaceholder }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The shared Home content, wired to this tab's navigation. Written once and
    /// used twice — see `HomeBands` for why the page is drawn in two pieces.
    private func homeSections(bands: HomeBands) -> some View {
        HomeSections(
            onQuickLink: { _ in iosAppState.selectedTab = .library },
            onPlay: { track, context, origin in
                Task {
                    if deps.onlineCoordinator.isStandaloneOnline(track) {
                        await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
                    } else {
                        // These are Home's rows even though they are drawn
                        // inside Discover, so the row names itself rather than
                        // the tab it happens to be sitting in.
                        await engine.play(track: track, in: context, source: .named(origin))
                    }
                }
            },
            onArtist: { iosAppState.openOnlineArtist(name: $0) },
            // "Made for you" below is the better version of the same idea.
            showsRecommendations: false,
            bands: bands
        )
    }

    // MARK: Made for you

    @State private var showGenerateMix = false
    @State private var showsAllRecommended = false
    @State private var showsAllGenres = false

    private static let collapsedSongs = 4
    private static let collapsedGenres = 6

    @ViewBuilder
    private var madeForYou: some View {
        let landing = store.personal
        let mixes = (landing.releaseRadar.map { [$0] } ?? []) + landing.mixes

        if landing.isEmpty {
            if store.personalLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if filter == .mixes {
                Text("Play a few songs and Mixtape starts building mixes around them.")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
            }
        } else {
            if !mixes.isEmpty {
                section("Made for you", accessory: {
                    Button {
                        Haptics.play(.light)
                        showGenerateMix = true
                    } label: {
                        Label("New mix", systemImage: "plus")
                            .font(.mixButtonSmall)
                            .foregroundStyle(Color.mixTextPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Color.mixSurface2, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }) {
                    carousel(mixes) { mixCard($0) }
                }
            }

            if let release = landing.newRelease { newRelease(release) }

            if !landing.recommendedPool.isEmpty { recommendedSongs(landing) }

            if !landing.genreMixes.isEmpty {
                section("Your genres") { mixShelf(landing.genreMixes) }
            }

            if !landing.stations.isEmpty {
                section("Radios") { mixShelf(landing.stations) }
            }

            // Five of these is five screens-worth of faces on "All"; the Mixes
            // pill shows the rest.
            ForEach(landing.related.prefix(filter == .all ? 2 : .max)) { row in
                section(row.seedArtist, eyebrow: "Because you listened to") {
                    shelf {
                        ForEach(row.artists) { artist in
                            IOSArtistCircle(artist: artist) { path.append(DiscoverDestination.artist(artist)) }
                        }
                    }
                }
            }
        }
    }

    private func mixCard(_ mix: PersonalMix) -> some View {
        IOSFeatureCard(
            title: mix.title,
            byline: "Mixtape",
            detail: ["\(mix.tracks.count) songs", mix.subtitle.isEmpty ? nil : mix.subtitle]
                .compactMap { $0 }.joined(separator: " • "),
            tint: MixCoverStyle.color(for: mix.id),
            isResolving: mix.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
            pill: ("Shuffle", "shuffle", { shuffle(mix) }),
            onOpen: { path.append(DiscoverDestination.mix(mix)) },
            onPlay: { playMix(mix) }
        ) {
            mixCover(mix)
        } actions: {
            Button("Play", systemImage: "play.fill") { playMix(mix) }
            Button("Shuffle", systemImage: "shuffle") { shuffle(mix) }
            Button("Open Mix", systemImage: "square.stack") { path.append(DiscoverDestination.mix(mix)) }
        }
    }

    /// The 2×2 of covers Spotify's Daily Mix wears, or the one cover there is.
    @ViewBuilder
    private func mixCover(_ mix: PersonalMix) -> some View {
        if mix.covers.count >= 4 {
            VStack(spacing: 1) {
                HStack(spacing: 1) { coverTile(mix.covers[0]); coverTile(mix.covers[1]) }
                HStack(spacing: 1) { coverTile(mix.covers[2]); coverTile(mix.covers[3]) }
            }
        } else {
            coverTile(mix.covers.first)
        }
    }

    private func coverTile(_ url: URL?) -> some View {
        Color.mixSurface2
            .overlay {
                CachedRemoteImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            .clipped()
    }

    private func newRelease(_ release: FreshRelease) -> some View {
        let album = release.album
        let openArtist = { path.append(DiscoverDestination.artist(release.artist)) }
        let openAlbum = { path.append(DiscoverDestination.album(album)) }
        return VStack(alignment: .leading, spacing: 12) {
            Button(action: openArtist) {
                HStack(spacing: 12) {
                    discoverArtwork(url: release.artist.imageURL, circle: true, size: 44)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("New release from")
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                        Text(release.artist.name)
                            .font(.mixTitle.bold())
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            IOSFeatureCard(
                title: album.title,
                byline: [album.recordTypeLabel, release.artist.name].compactMap { $0 }.joined(separator: " • "),
                detail: album.releaseDate?.formatted(date: .abbreviated, time: .omitted),
                tint: MixCoverStyle.color(for: "\(album.id)"),
                isResolving: store.cachedAlbumTracks(for: album)?.first.map { coordinator.resolvingID == $0.id } ?? false,
                onOpen: openAlbum,
                onPlay: { Task { await playAlbum(album) } }
            ) {
                coverTile(album.coverURL)
            } actions: {
                Button("Play", systemImage: "play.fill") { Task { await playAlbum(album) } }
                Button("Open Album", systemImage: MixtapeIcons.album, action: openAlbum)
                Button("Go to \(release.artist.name)", systemImage: MixtapeIcons.artist, action: openArtist)
            }
        }
    }

    private func recommendedSongs(_ landing: PersonalLanding) -> some View {
        let songs = landing.recommended(roll: store.recommendedRoll)
        let shown = showsAllRecommended ? songs : Array(songs.prefix(Self.collapsedSongs))
        return section("Recommended songs",
                       eyebrow: landing.seeds.isEmpty ? nil : "From around \(landing.seeds.prefix(2).joined(separator: " and "))",
                       accessory: {
            Button {
                Haptics.play(.light)
                withMixAnimation(.easeInOut(duration: 0.22)) { store.rollRecommended() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New recommendations")
        }) {
            VStack(spacing: 0) {
                ForEach(shown) { song in
                    MixSongRow(song: song,
                               isCurrent: coordinator.nowPlayingID == song.id,
                               isResolving: coordinator.resolvingID == song.id) {
                        Task { await play(song, context: songs) }
                    }
                    .contextMenu { onlineSongMenu(song, context: songs) }
                }
            }
            // The row's own hover inset; line the artwork up with the page.
            .padding(.horizontal, -8)
            if songs.count > Self.collapsedSongs { expandButton($showsAllRecommended) }
        }
    }

    private func mixShelf(_ mixes: [PersonalMix]) -> some View {
        shelf(spacing: 16) {
            ForEach(mixes) { mix in
                MixMosaicCard(mix: mix,
                              isResolving: mix.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
                              onOpen: { path.append(DiscoverDestination.mix(mix)) },
                              onPlay: { playMix(mix) })
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { playMix(mix) }
                        Button("Open Mix", systemImage: "square.stack") { path.append(DiscoverDestination.mix(mix)) }
                    }
            }
        }
    }

    // MARK: Catalogue

    @ViewBuilder
    private var catalogue: some View {
        if !browse.trending.isEmpty {
            section("Trending now") {
                shelf {
                    ForEach(browse.trending) { song in
                        IOSBrowseSongCard(
                            song: song,
                            isCurrent: coordinator.nowPlayingID == song.id,
                            isPlaying: engine.state.isPlaying,
                            isResolving: coordinator.resolvingID == song.id,
                            onPlay: {
                                let ctx = engine.queue.shuffleEnabled ? [song] : browse.trending
                                Task { await play(song, context: ctx) }
                            }
                        )
                        .contextMenu { onlineSongMenu(song, context: browse.trending) }
                    }
                }
            }
        }

        if !newReleaseAlbums.isEmpty {
            section("New releases for you") {
                shelf {
                    ForEach(newReleaseAlbums) { album in
                        IOSAlbumCard(album: album) { path.append(DiscoverDestination.album(album)) }
                            .contextMenu {
                                Button("Play", systemImage: "play.fill") { Task { await playAlbum(album) } }
                                Button("Open Album", systemImage: MixtapeIcons.album) {
                                    path.append(DiscoverDestination.album(album))
                                }
                                Divider()
                                ShareMenuItems(.album(album))
                            }
                    }
                }
            }
        }

        if !browse.artists.isEmpty {
            section("Popular artists") {
                shelf {
                    ForEach(browse.artists) { artist in
                        IOSArtistCircle(artist: artist) { path.append(DiscoverDestination.artist(artist)) }
                    }
                }
            }
        }

        if !browse.genres.isEmpty {
            let shown = showsAllGenres ? browse.genres : Array(browse.genres.prefix(Self.collapsedGenres))
            section("Browse all") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, genre in
                        IOSGenreTile(genre: genre, index: idx) { path.append(DiscoverDestination.genre(genre)) }
                    }
                }
                if browse.genres.count > Self.collapsedGenres { expandButton($showsAllGenres) }
            }
        }
    }

    /// Your seed artists' releases in front of the catalogue's editorial feed,
    /// deduped on album id. Same list the Mac builds.
    private var newReleaseAlbums: [OnlineAlbum] {
        var seen = Set<Int>()
        return (store.personal.freshReleases + browse.newReleases)
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: Chrome

    private func section<Content: View>(_ title: String,
                                        eyebrow: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, eyebrow: eyebrow, accessory: { EmptyView() }, content: content)
    }

    /// A bold 22pt title, an optional small line above it ("Because you
    /// listened to"), and a trailing control.
    private func section<Accessory: View, Content: View>(_ title: String,
                                                         eyebrow: String? = nil,
                                                         @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(.mixTitle.bold())
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
    }

    /// A row that runs off the screen edge, the way every shelf in Spotify does.
    private func shelf<Content: View>(spacing: CGFloat = 14,
                                      @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) { content() }
        }
        .scrollClipDisabled()
    }

    /// Full-width cards that snap one at a time, with the next one peeking in.
    private func carousel<Item: Identifiable, Card: View>(_ items: [Item],
                                                          @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    card(item)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            items.count > 1 ? width - 28 : width
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }

    /// Spotify's centred outline capsule under a collapsed list.
    private func expandButton(_ isExpanded: Binding<Bool>) -> some View {
        Button {
            Haptics.play(.light)
            withMixAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
        } label: {
            Text(isExpanded.wrappedValue ? "Show less" : "Show all")
                .font(.mixButtonSmall)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .overlay(Capsule().stroke(Color.mixTextTertiary, lineWidth: 1))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var landingPlaceholder: some View {
        VStack(spacing: 12) {
            if browseLoading || store.personalLoading {
                ProgressView()
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.mixTextTertiary)
                Text("Couldn't load this right now.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    /// The song verbs, for the landing cards that only knew how to be tapped.
    @ViewBuilder
    private func onlineSongMenu(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        Button("Play", systemImage: "play.fill") {
            let ctx = engine.queue.shuffleEnabled ? [song] : context
            Task { await play(song, context: ctx) }
        }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            Task { await coordinator.playNext(song) }
        }
        Button("Add to Queue", systemImage: "text.append") {
            Task { await coordinator.addToQueue(song) }
        }
        Divider()
        Button("Add to Library", systemImage: "plus") {
            Task { await coordinator.addToLibrary(song) }
        }
        Divider()
        ShareMenuItems(.track(song))
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mixDestructive)
                .accessibilityHidden(true)
            Text(text)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.mixDestructive.opacity(0.30), lineWidth: 0.5)
        )
        .mixShadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Personal landing

    private func loadPersonal() {
        store.loadPersonalIfNeeded(
            seeds: RecommendationEngine.seeds(stats: deps.statsService,
                                              library: deps.libraryService),
            radarSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService),
            genreSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService,
                                                        limit: RecommendationEngine.maxGenreSeeds),
            known: RecommendationEngine.knownKeys(library: deps.libraryService),
            using: deps.itunesClient
        )
    }

    /// Get the resolver started on the songs most likely to be tapped, the
    /// moment a search comes back.
    ///
    /// This is what iOS has instead of the Mac's hover-prefetch — a phone has no
    /// hover, so nothing was ever warmed before a tap and every song was paid
    /// for cold. `warm` costs one HTTP request and no audio on this device; see
    /// its note on why a server-side resolve is the expensive half.
    private func warmTopResults() {
        var seen = Set<String>()
        let candidates = ([results.topSong].compactMap { $0 } + results.songs)
            .filter { seen.insert($0.id).inserted }
        for song in candidates.prefix(3) { coordinator.warm(song) }
    }

    // MARK: - Play

    private func playMix(_ mix: PersonalMix) {
        guard let first = mix.tracks.first else { return }
        Task { await play(first, context: mix.tracks) }
    }

    private func shuffle(_ mix: PersonalMix) {
        let shuffled = mix.tracks.shuffled()
        guard let first = shuffled.first else { return }
        Task { await play(first, context: shuffled) }
    }

    private func play(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }

    /// Start a record from its first track, through the same session cache the
    /// album page uses so opening it afterwards costs nothing.
    private func playAlbum(_ album: OnlineAlbum) async {
        let tracks: [OnlineTrack]
        if let cached = store.cachedAlbumTracks(for: album) {
            tracks = cached
        } else {
            tracks = await store.albumTracks(for: album, using: deps.itunesClient)
        }
        guard let first = tracks.first else { return }
        await play(first, context: tracks)
    }

    // MARK: - Navigate from a track to its artist / album

    /// By name alone — the mix header credits artists, not tracks.
    private func openArtist(named name: String) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                await MainActor.run { path.append(DiscoverDestination.artist(artist)) }
            }
        }
    }
}
#endif
