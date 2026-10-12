// IOSDiscoverView.swift
// Mixtape - iOS/Online
//
// iOS port of OnlineDiscoverView. On iOS the coordinator resolves audio through
// the Mac/server RemoteResolverService, then plays the downloaded .m4a. Uses a
// native NavigationStack where the Mac needs a manual path stack.

#if os(iOS)
import SwiftUI
import Combine

struct IOSDiscoverView: View {

    /// Opens Settings, which MainTabView owns. Optional for pushed pages and previews without a tab bar.
    var onOpenSettings: (() -> Void)? = nil

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var iosAppState:  IOSAppState

    /// All state lives in the store so the tab comes back as it was left (on macOS, MacContentRouter destroys
    /// Discover on every section switch). A typed path because NavigationPath can't be persisted.
    @ObservedObject private var store = DiscoverSessionStore.shared

    private var results: DiscoverResults { store.results }
    private var browse: BrowseLanding { store.browse }
    private var browseLoading: Bool { store.browseLoading }

    /// Writes straight through to the store.
    private var path: [DiscoverDestination] {
        get { store.path }
        nonmutating set { store.path = newValue }
    }

    var body: some View {
        NavigationStack(path: $store.path) {
            ScrollView {
                content
                    .padding(.bottom, 24)
            }
            // Spotify-style header: avatar and filters pinned above the page, no large title.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
            .mixPullToRefresh(deps) {
                // The landing belongs to the store, not the library, so a sync alone wouldn't refresh it.
                await store.reloadBrowse(using: deps.itunesClient)
            }
            .background(MixPageBackground())
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
                    case .librarySongs(let query):
                        LibraryMatchesPage(query: query)
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
                            // Saved mixes are library playlists, so this switches tabs rather than pushing.
                            onOpenSavedMix: { iosAppState.openLibraryPlaylist($0) },
                            resolvingID: coordinator.resolvingID
                        )
                        .navigationTitle("Mixtape")
                        .navigationBarTitleDisplayMode(.inline)
                    case .profile(let profile):
                        ProfilePageView(profile: profile, onOpenPost: { path.append(DiscoverDestination.post($0)) },
                                        onOpenProfile: { path.append(DiscoverDestination.profile($0)) })
                            .navigationBarTitleDisplayMode(.inline)
                    case .post(let code):
                        PostPageView(code: code, onOpenProfile: { path.append(DiscoverDestination.profile($0)) })
                    case .smart(let playlist):
                        SmartPlaylistDetailView(playlist: playlist, service: deps.smartPlaylistService)
                            .environmentObject(deps)
                            .environmentObject(engine)
                    case .downloads(let title, let ids):
                        OfflineMixPage(title: title, ids: ids)
                    }
                }
                .miniPlayerSafeArea()
            }
        }
        // Tapping Home while on it unwinds to the landing. Search lives in the Search tab.
        .onChange(of: iosAppState.homeResetToken) { _, _ in
            path.removeAll()
        }
        .onChange(of: store.resultsQuery) { _, _ in warmTopResults() }
        // First launch appears before the library loads, and an empty library can't seed a personal landing,
        // so retry once songs exist. `dropFirst`: `onReceive` resubscribes on every redraw and `$tracks` replays;
        // `onAppear` covers the first load. Deferred a tick: `$tracks` fires in `willSet`.
        .onReceive(deps.libraryService.$tracks.map(\.isEmpty).removeDuplicates().dropFirst()) { _ in
            DispatchQueue.main.async { loadPersonal() }
        }
        .sheet(isPresented: $showGenerateMix) {
            GenerateMixSheet().environmentObject(deps)
        }
        .onAppear {
            store.loadBrowseIfNeeded(using: deps.itunesClient)
            // Seeds need main-actor services the store doesn't hold, so they're computed here. Cheap: the store's
            // TTL and seed fingerprint decide whether anything is fetched.
            loadPersonal()
        }
        // No cancel on disappear: the search task belongs to the store and finishes.
        // Cross-tab request to open an online artist by name: resolve it to a Deezer artist and push.
        .onChange(of: iosAppState.pendingDiscoverArtistName) { _, name in
            guard let name else { return }
            iosAppState.pendingDiscoverArtistName = nil
            Task {
                if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                    await MainActor.run { path.append(DiscoverDestination.artist(artist)) }
                }
            }
        }
        .onChange(of: iosAppState.pendingDiscoverAlbum) { _, probe in
            guard let probe else { return }
            iosAppState.pendingDiscoverAlbum = nil
            openAlbum(for: probe)
        }
        // A station seeded by one song ("Go to Song Radio").
        .onChange(of: iosAppState.pendingSongRadio) { _, seed in
            guard let seed else { return }
            iosAppState.pendingSongRadio = nil
            Task {
                let station = await StationBuilder.songRadio(title: seed.title,
                                                             artistName: seed.artistName,
                                                             using: deps.itunesClient)
                guard let station else { return }
                await MainActor.run { path.append(DiscoverDestination.mix(station)) }
            }
        }
        // Mixtape's profile from another tab, e.g. the byline on a saved mix.
        .onChange(of: iosAppState.pendingMixtapeProfile) { _, wanted in
            guard wanted else { return }
            iosAppState.pendingMixtapeProfile = false
            path.append(DiscoverDestination.mixtapeProfile)
        }
        .onChange(of: iosAppState.pendingPost) { _, code in
            guard let code else { return }
            iosAppState.pendingPost = nil
            path.append(DiscoverDestination.post(code))
        }
        .onChange(of: iosAppState.pendingProfile) { _, profile in
            guard let profile else { return }
            iosAppState.pendingProfile = nil
            path.append(DiscoverDestination.profile(profile))
        }
        // "Open your tape" at the end of a recap.
        .onReceive(NotificationCenter.default.publisher(for: .mixOpenSmartPlaylist)) { note in
            guard let playlist = note.object as? SmartPlaylist else { return }
            iosAppState.selectedTab = .home
            path.append(DiscoverDestination.smart(playlist))
        }
    }

    // MARK: - Header

    private enum HomeFilter: String, CaseIterable {
        case all = "All", mixes = "Mixes", discover = "Discover", library = "Library"
        /// Only what plays offline. Chosen automatically when the network drops, see `OfflineWatcher`.
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
            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: MixtapeIcons.settings)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .tint(Color.mixPrimary)
                .accessibilityLabel("Settings")
                // The target's empty edge sits over the pills' fade, so the icon ends up close to them.
                .padding(.leading, -14)
            }
        }
        .padding(.horizontal, 16)
        // Out of the row: even at zero size it would take a gap.
        .background {
            OfflineWatcher(downloads: deps.downloadManager, auth: deps.authService) { offline in
                // Back online, the landing comes back with it.
                if offline != isOffline { filter = offline ? .downloaded : .all }
                isOffline = offline
            }
        }
        .background(MixPageBackground())
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        // Always the landing: results belong to the Search tab.
        browseLanding
    }

    // MARK: - Landing

    /// One scroll of cards and shelves: bold titles, horizontal shelves, no wrapping grids.
    /// The header pills narrow it to one kind of thing.
    private var browseLanding: some View {
        VStack(alignment: .leading, spacing: 30) {
            if filter == .downloaded {
                // Nothing else here works offline, so this pill replaces the landing.
                IOSOfflineHome(downloads: deps.downloadManager)
            } else {
            // Jump back in: the two-column tiles, and the library's own shelves.
            if shows(.library) { homeSections(bands: .top) }

            if shows(.mixes) { madeForYou }

            // Made from your listening too, so they sit with the mixes.
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

    /// The shared Home content wired to this tab's navigation. See `HomeBands` for why it's two pieces.
    private func homeSections(bands: HomeBands) -> some View {
        HomeSections(
            onQuickLink: { _ in iosAppState.selectedTab = .library },
            onPlay: { track, context, origin in
                Task {
                    if deps.onlineCoordinator.isStandaloneOnline(track) {
                        await deps.onlineCoordinator.playStandaloneOnline(track, context: context)
                    } else {
                        // These are Home's rows, so they're named for Home.
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

            if deps.isAuthenticated {
                section("Blends") {
                    BlendShelf(blends: deps.blends, deps: deps, showsHeader: false,
                               resolvingID: coordinator.resolvingID,
                               onOpen: { path.append(DiscoverDestination.mix($0)) },
                               onPlay: { playMix($0) })
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

            // Two on "All"; the Mixes pill shows the rest.
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
            OnlineCollectionMenu(.mix(mix))
        }
    }

    /// The 2x2 of covers Spotify's Daily Mix wears, or the one cover there is.
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
                OnlineCollectionMenu(.album(album))
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
                    .contextMenu { OnlineCollectionMenu(.mix(mix)) }
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
                            .contextMenu { OnlineCollectionMenu(.album(album)) }
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

    /// Your seed artists' releases before the editorial feed, deduped by album id. Same as the Mac.
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

    /// Bold 22pt title, optional kicker above it ("Because you listened to") and a trailing control.
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
    private func onlineSongMenu(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        OnlineSongMenu(
            song: song,
            onPlay: {
                let ctx = engine.queue.shuffleEnabled ? [song] : context
                Task { await play(song, context: ctx) }
            },
            onPlayNext:     { Task { await coordinator.playNext(song) } },
            onAddToQueue:   { Task { await coordinator.addToQueue(song) } },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: context) } },
            // No resolved album or artist here, so both are looked up by name. Same as the Mac.
            onOpenAlbum:  song.albumTitle.isEmpty ? nil : { openAlbum(for: song) },
            onOpenArtist: { openArtist(named: $0) }
        )
    }

    // MARK: - Personal landing

    private func loadPersonal() {
        store.loadPersonalIfNeeded(
            seeds: RecommendationEngine.seeds(stats: deps.statsService,
                                              library: deps.libraryService),
            radarSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService),
            genreSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService,
                                                        limit: RecommendationEngine.maxGenreSeeds),
            genreTitles: RecommendationEngine.seedTitles(library: deps.libraryService),
            known: RecommendationEngine.knownKeys(library: deps.libraryService),
            using: deps.itunesClient
        )
    }

    /// Start resolving the likeliest taps as soon as a search returns, since iOS has no hover-prefetch.
    /// `warm` is one HTTP request and no audio on this device.
    private func warmTopResults() {
        var seen = Set<String>()
        let candidates = ([results.topSong].compactMap { $0 } + results.songs)
            .filter { seen.insert($0.id).inserted }
        // Each takes a box slot. Past the iOS cap they're skipped, not queued.
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

    /// Start an album from its first track via the album page's session cache, so opening it later is free.
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

    /// By name: the mix header credits artists, not tracks.
    private func openArtist(named name: String) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                await MainActor.run { path.append(DiscoverDestination.artist(artist)) }
            }
        }
    }

    private func openAlbum(for song: OnlineTrack) {
        Task {
            if let album = await deps.itunesClient.resolveAlbum(for: song) {
                await MainActor.run { path.append(DiscoverDestination.album(album)) }
            }
        }
    }
}
#endif
