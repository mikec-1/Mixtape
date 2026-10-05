// Search songs/artists/albums online and stream them. Drill-down uses a manual
// `path` stack: a NavigationStack inside the Mac split view locks the detail column.

#if os(macOS)
import SwiftUI
import Combine

struct OnlineDiscoverView: View {

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var appState:    MacAppState

    /// The toolbar search box drives Discover. `activeSearchText`, so typing alone stays
    /// on the landing until Return; the searches run off raw `searchText` so results are warm.
    private var query: String { appState.activeSearchText }

    /// In the store, since MacContentRouter swaps this column out on section change.
    @ObservedObject private var store = DiscoverSessionStore.shared

    /// People search, on its own debounce so songs don't wait for it.
    @StateObject private var people = PeopleSearch()

    private var results: DiscoverResults { store.results }
    private var browse: BrowseLanding { store.browse }
    private var isSearching: Bool { store.isSearching }
    private var browseLoading: Bool { store.browseLoading }

    /// Written straight through to the store.
    private var path: [DiscoverDestination] {
        get { store.path }
        nonmutating set { store.path = newValue }
    }

    @ObservedObject private var washTint = ArtworkWashTint.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No header on the landing (the greeting is the title) or on a bare results page.
            if !isLanding && !isBareHeader {
                header
                Divider().padding(.top, 12)
            }
            content
        }
        .background(MixPageBackground())
        .onAppear {
            consumePendingDeepLink()
            store.loadBrowseIfNeeded(using: deps.itunesClient)
            loadPersonal()
            // Called even when empty: this view is rebuilt when the field empties, and
            // `search("")` tells the store its results are stale.
            scheduleSearch(appState.searchText)
        }
        // First launch appears before the library loads, so retry once songs exist.
        // `dropFirst` since `$tracks` replays on resubscribe; deferred a tick since it fires in `willSet`.
        .onReceive(deps.libraryService.$tracks.map(\.isEmpty).removeDuplicates().dropFirst()) { _ in
            DispatchQueue.main.async { loadPersonal() }
        }
        .sheet(isPresented: $showGenerateMix) {
            GenerateMixSheet().environmentObject(deps)
        }
        .onChange(of: appState.pendingDiscover) { _, _ in consumePendingDeepLink() }
        .onChange(of: appState.searchText) { _, newValue in
            // Typing doesn't pop the stack. The search runs so results are ready when Return commits.
            scheduleSearch(newValue)
            // A new result set opens collapsed.
            showsAllResultSongs   = false
            showsAllResultAlbums  = false
            showsAllResultArtists = false
        }
        // Return commits the query, so the stack unwinds.
        .onChange(of: store.searchCommitToken) { _, _ in
            path.removeAll()
        }
        // The object debounces and drops stale replies; the task id cancels the call in flight.
        .task(id: query) {
            await people.search(query, using: deps.authService)
        }
    }

    // MARK: - Deep link (now-playing online artist/album -> Discover)

    /// Resolves a pending deep link (now-playing artist/album) and pushes its page.
    private func consumePendingDeepLink() {
        guard let link = appState.pendingDiscover else { return }
        appState.pendingDiscover = nil
        Task { @MainActor in
            switch link {
            case let .artist(name, trackID):
                let resolved = await deps.itunesClient.resolveArtist(name: name, trackID: trackID)
                defer { appState.resolvingDiscoverLink = nil }
                if let artist = resolved {
                    appState.searchText = ""
                    path = [.artist(artist)]
                } else {
                    // Nothing resolved: search the name so the near misses show.
                    fallBackToSearch(name)
                }
            case let .album(title, artistName, trackID):
                let probe = OnlineTrack(title: "", artistName: artistName, albumTitle: title,
                                        duration: 0, artworkURL: nil, sourceID: trackID)
                let resolved = await deps.itunesClient.resolveAlbum(for: probe)
                defer { appState.resolvingDiscoverLink = nil }
                if let album = resolved {
                    appState.searchText = ""
                    path = [.album(album)]
                } else {
                    fallBackToSearch("\(title) \(artistName)".trimmingCharacters(in: .whitespaces))
                }
            case let .artistRadio(name):
                let station = await StationBuilder.artistRadio(name: name, using: deps.itunesClient)
                defer { appState.resolvingDiscoverLink = nil }
                if let station {
                    appState.searchText = ""
                    path = [.mix(station)]
                } else {
                    fallBackToSearch(name)
                }
            case let .songRadio(title, artistName):
                let station = await StationBuilder.songRadio(title: title,
                                                             artistName: artistName,
                                                             using: deps.itunesClient)
                defer { appState.resolvingDiscoverLink = nil }
                if let station {
                    appState.searchText = ""
                    path = [.mix(station)]
                } else {
                    // Not in the catalogue, or offline. The search at least shows the song.
                    fallBackToSearch("\(title) \(artistName)".trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }

    /// Shows `query` in the search field for a link that couldn't resolve to a page.
    @MainActor
    private func fallBackToSearch(_ query: String) {
        guard !query.isEmpty else { return }
        path.removeAll()
        // Emptying the field returns to where the link was clicked.
        appState.discoverLinkActive = false
        appState.searchText = query
        // Committed, so it arrives showing results like the page would have.
        appState.showSearchResults()
    }

    // MARK: - Header

    /// Nothing typed, nothing drilled into.
    private var isLanding: Bool {
        path.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Nil on results pages: the query is already in the field.
    private var headerTitle: String? {
        // The artist page writes its own name across the banner.
        if case .artist = path.last { return nil }
        // The liked page has its own hero title and back button.
        if case .likedSongs = path.last { return nil }
        if case .librarySongs = path.last { return nil }
        guard path.isEmpty else { return pageTitle }
        return query.isEmpty ? "Discover" : nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !path.isEmpty {
                BackButton { path.removeLast() }
            }

            if let headerTitle {
                Text(headerTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Results page only. Inside a drill-down it would read as the page loading.
            if isSearching && path.isEmpty { ProgressView().controlSize(.small) }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, isBareHeader ? 0 : 16)
        .frame(height: isBareHeader ? 0 : nil)
        .opacity(isBareHeader ? 0 : 1)
        // Carry the page's wash up through the header band, like the sidebar.
        .background(alignment: .top) {
            ArtworkWashGradient(colors: washTint.stops, intensity: washTint.chromeIntensity)
        }
    }

    /// No back button, title or spinner. Kept in the tree so starting a search doesn't shift the results.
    private var isBareHeader: Bool {
        // Full-bleed with its own back button.
        if case .artist = path.last { return true }
        if case .likedSongs = path.last { return true }
        if case .librarySongs = path.last { return true }
        return path.isEmpty && headerTitle == nil && !isSearching
    }

    /// What the current drill-down page is called.
    private var pageTitle: String {
        switch path.last {
        case .artist(let artist):     return artist.name
        case .likedSongs(let artist): return "Liked · \(artist.name)"
        case .librarySongs:           return "In your library"
        case .album(let album):       return album.title
        case .genre(let genre):       return genre.name
        case .mix(let mix):           return mix.title
        case .mixtapeProfile:         return "Mixtape"
        case .profile(let profile):   return profile.name
        case .post:                   return "Post"
        case .none:                   return "Discover"
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch path.last {
        case .artist(let artist):
            DiscoverArtistPage(
                artist: artist,
                onOpenAlbum: { path.append(.album($0)) },
                onOpenArtist: { path.append(.artist($0)) },
                onOpenLiked: { path.append(.likedSongs(artist)) },
                onPlay: { track, context in Task { await play(track, context: context) } },
                onPrefetch: { coordinator.prefetch($0) },
                onBack: { path.removeLast() }
            )
        case .likedSongs(let artist):
            DiscoverLikedSongsPage(artist: artist, onBack: { path.removeLast() })
        case .librarySongs(let query):
            LibraryMatchesPage(query: query, onBack: { path.removeLast() })
        case .album(let album):
            DiscoverAlbumPage(
                album: album,
                onPlay: { track, context in Task { await play(track, context: context) } },
                onPrefetch: { coordinator.prefetch($0) },
                onOpenArtist: { path.append(.artist($0)) }
            )
        case .genre(let genre):
            DiscoverGenrePage(
                genre: genre,
                onOpenArtist: { path.append(.artist($0)) }
            )
        case .mix(let mix):
            MixDetailPage(
                mix: mix,
                onPlay: { track, context in Task { await play(track, context: context) } },
                onShuffle: {
                    guard let first = mix.tracks.shuffled().first else { return }
                    Task { await play(first, context: mix.tracks.shuffled()) }
                },
                resolvingID: coordinator.resolvingID,
                onOpenMixtape: { path.append(.mixtapeProfile) },
                onOpenProfile: { path.append(.profile($0)) },
                onOpenArtist: { openArtist(named: $0) }
            )
        case .mixtapeProfile:
            MixtapeProfilePage(
                onOpenMix: { path.append(.mix($0)) },
                onPlayMix: { mix in
                    guard let first = mix.tracks.first else { return }
                    Task { await play(first, context: mix.tracks) }
                },
                // Saved mixes are library playlists, so this leaves Discover.
                onOpenSavedMix: { appState.showPlaylist($0) },
                resolvingID: coordinator.resolvingID
            )
        case .profile(let profile):
            ProfilePageView(profile: profile, onOpenPost: { path.append(.post($0)) },
                            onOpenProfile: { path.append(.profile($0)) })
        case .post(let code):
            PostPageView(code: code, onOpenProfile: { path.append(.profile($0)) },
                         onClose: { path.removeLast() })
        case .none:
            // A link still resolving. Without this the landing flashes before the page.
            if let name = appState.resolvingDiscoverLink {
                DiscoverLinkLoading(name: name)
            } else {
                searchResults
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        // Decided by the query, not the results: the view watching `searchText` is torn down
        // when the field empties, so the store can still be holding old results.
        // Not gated on `browse` either; each landing band shows its own placeholder.
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            browseLanding
        } else if results.isEmpty && people.results.isEmpty {
            emptyState
        } else if let hero = results.topSong {
            songCentricResults(hero: hero)
        } else {
            // One column: who or what this is, then songs, then the catalogue. Spacing separates sections.
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    localMatchesSection
                    topResultBanner.id("top")
                    if !results.songs.isEmpty { songsSection.id("songs") }
                    if !results.lyricMatches.isEmpty { lyricMatchesSection.id("lyrics") }
                    if !results.albums.isEmpty { albumsSection.id("albums") }
                    if !results.artists.isEmpty { artistsSection.id("artists") }
                    peopleSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $store.resultsAnchor)
        }
    }

    // MARK: - Song-centric results (a specific song was searched)

    /// Song query: wide hero, then the artists on it, then more of their songs.
    private func songCentricResults(hero: OnlineTrack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                localMatchesSection
                heroRow(hero: hero)
                if !results.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            sectionHeader(moreSongsTitle)
                            Spacer(minLength: 8)
                            showAllToggle(total: results.songs.count,
                                          cap: Self.collapsedResultSongs,
                                          isExpanded: $showsAllResultSongs)
                        }
                        songList(showsAllResultSongs
                                 ? results.songs
                                 : Array(results.songs.prefix(Self.collapsedResultSongs)))
                    }
                    .id("songs")
                }
                if !results.lyricMatches.isEmpty { lyricMatchesSection.id("lyrics") }
                if !results.albums.isEmpty { albumsSection.id("albums") }
                peopleSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $store.resultsAnchor)
    }

    /// Hero and artists share one row, artists in a fixed lane on the right.
    /// Narrow windows stack them instead.
    @ViewBuilder
    private func heroRow(hero: OnlineTrack) -> some View {
        Group {
            if results.songArtists.isEmpty || songResultsWidth < Self.heroRowMinimum {
                VStack(alignment: .leading, spacing: 26) {
                    songHero(hero)
                    if !results.songArtists.isEmpty { songArtistsSection }
                }
            } else {
                HStack(alignment: .top, spacing: Self.heroRowGutter) {
                    songHero(hero)
                    songArtistsSection
                        .frame(width: Self.artistColumnWidth, alignment: .leading)
                }
            }
        }
        .background(songResultsWidthReader)
        .id("hero")
    }

    private func songHero(_ hero: OnlineTrack) -> some View {
        WideSongHero(
            song: hero,
            isCurrent: coordinator.nowPlayingID == hero.id,
            isPlaying: engine.state.isPlaying,
            isResolving: coordinator.resolvingID == hero.id,
            onPlay: {
                if coordinator.nowPlayingID == hero.id {
                    engine.togglePlayPause()
                } else {
                    Task { await play(hero) }
                }
            },
            onPlayNext: { Task { await coordinator.playNext(hero) } },
            onAddToQueue: { Task { await coordinator.addToQueue(hero) } },
            onAdd: { Task { await coordinator.addToLibrary(hero) } },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(hero, context: [hero]) } },
            onOpenAlbum: { openAlbum(for: hero) },
            onOpenArtist: { openArtist(named: $0, from: hero) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var songResultsWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    songResultsWidth = width
                }
        }
    }

    /// Two 120pt artist bubbles plus spacing, so a feature fits on one line.
    private static let artistColumnWidth: CGFloat = 264
    private static let heroRowGutter: CGFloat = 24
    /// The hero stops reading as a hero much below this once the lane is taken.
    private static let heroRowMinimum: CGFloat = 720

    /// Artist row under the song hero: main artist and features.
    private var songArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(results.songArtists.count > 1 ? "Artists" : "Artist")
            artistGrid(results.songArtists)
        }
    }

    private var moreSongsTitle: String {
        if let name = results.songArtists.first?.name { return "More by \(name)" }
        return "More songs"
    }

    /// The best answer to the query, as a full-width strip across the top.
    @ViewBuilder
    private var topResultBanner: some View {
        if let top = topResult {
            TopResultBanner(
                top: top,
                onOpenArtist: { path.append(.artist($0)) },
                onPlay: { track in Task { await play(track) } }
            )
        }
    }

    /// Five rows collapsed, the rest behind Show all.
    private var songsSection: some View {
        let songs = resultSongs
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // Deezer's raw hits when the relevance filter came back empty.
                sectionHeader(results.songsMatched ? "Songs" : "Closest matches")
                Spacer(minLength: 8)
                showAllToggle(total: results.songs.count,
                              cap: Self.collapsedResultSongs,
                              isExpanded: $showsAllResultSongs)
            }
            songList(songs)
        }
    }

    private var artistsSection: some View {
        let shown = showsAllResultArtists
            ? results.artists
            : Array(results.artists.prefix(Self.collapsedResultArtists))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Fans also like")
                Spacer(minLength: 8)
                showAllToggle(total: results.artists.count,
                              cap: Self.collapsedResultArtists,
                              isExpanded: $showsAllResultArtists)
            }
            artistGrid(shown)
        }
    }

    /// People, last: they arrive late and would push the songs down. A failed lookup draws nothing.
    @ViewBuilder
    private var peopleSection: some View {
        if !people.results.isEmpty {
            sectionRule
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("People")
                VStack(spacing: 0) {
                    ForEach(Array(people.results.enumerated()), id: \.element.id) { index, profile in
                        Button { appState.showProfile(profile) } label: {
                            PersonResultRow(profile: profile)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .mixHoverCursor { _ in }
                        if index < people.results.count - 1 {
                            Divider().background(Color.mixSeparator).padding(.leading, 56)
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
        }
    }

    /// Songs whose lyrics match the query, each tagged with a "Lyrics match" pill.
    private var lyricMatchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Matching that lyric")
            VStack(spacing: 8) {
                ForEach(results.lyricMatches) { song in
                    VStack(alignment: .leading, spacing: 2) {
                        lyricsMatchBadge
                        songRow(song)
                    }
                }
            }
        }
    }

    private var lyricsMatchBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "quote.bubble.fill").font(.system(size: 8, weight: .bold))
            Text("Lyrics match").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Color.mixOnAccent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.mixAccentFill, in: Capsule())
        .padding(.leading, 4)
    }

    /// Wrapped, not scrolled: the album you searched for may be the ninth.
    private var albumsSection: some View {
        let shown = showsAllResultAlbums
            ? results.albums
            : Array(results.albums.prefix(Self.collapsedResultAlbums))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Albums")
                Spacer(minLength: 8)
                showAllToggle(total: results.albums.count,
                              cap: Self.collapsedResultAlbums,
                              isExpanded: $showsAllResultAlbums)
            }
            // Tighter than the landing shelves, about six per row on a wide window.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124, maximum: 150), spacing: 16)],
                      alignment: .leading,
                      spacing: 18) {
                ForEach(shown) { album in
                    AlbumCard(album: album, onOpenArtist: { openArtist(named: $0) }) { path.append(.album(album)) }
                        .contextMenu { OnlineCollectionMenu(.album(album)) }
                }
            }
        }
    }

    /// Song rows with a hairline from 56pt, aligned with the text column.
    private func songList(_ songs: [OnlineTrack]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                songRow(song)
                if index < songs.count - 1 {
                    Divider()
                        .background(Color.mixSeparator)
                        .padding(.leading, 56)
                }
            }
        }
    }

    private func songRow(_ song: OnlineTrack) -> some View {
        SongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: {
                // Played from the results, so it becomes a recent search.
                if let recent = SearchSuggestion(track: song) {
                    SearchSuggestionsStore.shared.remember(recent)
                }
                Task { await play(song) }
            },
            onPlayNext: { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd: { Task { await coordinator.addToLibrary(song) } },
            onPrefetch: { coordinator.prefetch(song) },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: [song]) } },
            onOpenAlbum: { openAlbum(for: song) },
            onOpenArtist: { openArtist(named: $0, from: song) }
        )
    }

    // MARK: - Result partitioning

    /// The anchor artist when the query named one, otherwise the best song.
    /// `results.anchorIsArtist` decides, not the query text ("wknd" -> The Weeknd).
    private var topResult: TopResult? {
        if results.anchorIsArtist, let artist = results.artists.first {
            return .artist(artist)
        }
        if let song = results.songs.first { return .song(song) }
        if let artist = results.artists.first { return .artist(artist) }
        return nil
    }

    /// Everything the search returned minus the top result, collapsed to five.
    private var resultSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return showsAllResultSongs ? pool : Array(pool.prefix(Self.collapsedResultSongs))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Empty state

    /// Spinner while searching, otherwise `EmptyStateView`.
    @ViewBuilder
    private var emptyState: some View {
        if (query.isEmpty && browseLoading) || isSearching {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty {
            EmptyStateView(icon: "sparkle.magnifyingglass",
                           title: "Search Mixtape",
                           message: "Find a song, an artist, or an album.")
                .frame(maxHeight: .infinity)
        } else {
            EmptyStateView(icon: "magnifyingglass",
                           title: "No Results",
                           message: "No matches for \u{201C}\(query)\u{201D}. Check the spelling, or try fewer words.")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Browse landing (pre-search content)

    /// The merged Home/Discover landing in one scroll: you, for you, the catalogue, your shelves, stats.
    /// Each section guards its own visibility, so an outage removes a band instead of blanking the page.
    private var browseLanding: some View {
        landingScroll {
            // 1. Greeting and a shelf of things to resume.
            MacHomeSurface(bands: .top).id("home")

            // 2. Recommendations, then smart playlists (also made from your listening).
            sectionRule
            forYouBody

            if HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                sectionRule
                MacHomeSurface(bands: .smart).id("smart")
            }

            // 3. The catalogue. New releases last since it's the longest grid.
            if !browse.artists.isEmpty {
                sectionRule
                popularArtistsSection.id("artists")
            }
            if !browse.genres.isEmpty {
                sectionRule
                browseAllSection.id("genres")
            }
            if !newReleaseAlbums.isEmpty {
                sectionRule
                newReleasesGrid.id("releases")
            }

            // 4. Your own shelves.
            if HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                sectionRule
                MacHomeSurface(bands: .library).id("library")
            }

            // 5. Stats.
            sectionRule
            HomeStatsCard()

            // Nothing cached yet: one spinner for the whole page.
            if browse.isEmpty && store.personal.isEmpty {
                landingPlaceholder
            }
        }
    }

    // MARK: - Collapsed grids
    // The catalogue grids show about two rows each and offer the rest.

    @State private var songResultsWidth: CGFloat = 0
    /// The "+" tile at the end of "Your mixes".
    @State private var showGenerateMix = false
    @State private var showsAllReleases = false
    @State private var showsAllArtists  = false
    @State private var showsAllGenres   = false
    /// Reset whenever a new search lands.
    @State private var showsAllResultSongs   = false
    @State private var showsAllResultAlbums  = false
    @State private var showsAllResultArtists = false

    private static let collapsedReleases = 12
    private static let collapsedArtists  = 10
    private static let collapsedGenres   = 10
    private static let collapsedResultSongs   = 5
    private static let collapsedResultAlbums  = 6
    private static let collapsedResultArtists = 6

    /// Nil when the section is too short to collapse.
    @ViewBuilder
    private func showAllToggle(total: Int, cap: Int, isExpanded: Binding<Bool>) -> some View {
        if total > cap {
            MixPillButton(title: isExpanded.wrappedValue ? "Show less" : "Show all") {
                withMixAnimation(.easeInOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            }
        }
    }

    /// Divides unrelated bands on the landing.
    private var sectionRule: some View {
        Divider()
            .background(Color.mixSeparator)
            .padding(.vertical, 2)
    }

    private func landingScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content() }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
        }
        .scrollPosition(id: $store.browseAnchor)
    }

    /// Per section, so one failed fetch doesn't blank the rest.
    private var landingPlaceholder: some View {
        VStack(spacing: 12) {
            if browseLoading || store.personalLoading {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.mixTextTertiary)
                Text("Couldn't load this right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - For You

    @ViewBuilder
    private var forYouBody: some View {
        if store.personal.isEmpty {
            if store.personalLoading {
                landingPlaceholder
            } else if !browse.trending.isEmpty {
                // Nothing played yet: the global chart is the only signal, with the reason shown.
                coldStartNotice.id("coldstart")
                trendingSection.id("trending")
            }
        } else {
            personalHeader.id("foryou")
            PersonalLandingSections(landing: store.personal,
                                    roll: store.recommendedRoll,
                                    actions: landingActions,
                                    resolvingID: coordinator.resolvingID,
                                    shelvesLoading: store.shelvesLoading)
                .id("personal")
            if deps.isAuthenticated {
                BlendShelf(blends: deps.blends, deps: deps, resolvingID: coordinator.resolvingID,
                           onOpen: landingActions.openMix, onPlay: landingActions.playMix)
                    .id("blends")
            }
            if !browse.trending.isEmpty {
                sectionRule
                trendingSection.id("trending")
            }
        }
    }

    /// One line with a hard cap so it stays in its lane beside the hero.
    private var personalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Made for you")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
                .mixTightened()
            Text(store.personal.builtFromSubtitle(limit: 3)
                 ?? "Picked from what you've been playing.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: PersonalLandingSections.personalHeaderReserve, alignment: .leading)
    }

    private var coldStartNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trending now")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
                .mixTightened()
            Text("Play a few songs and this page starts building itself around them.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
        }
    }

    private var landingActions: DiscoverLandingActions {
        DiscoverLandingActions(
            playMix: { mix in
                guard let first = mix.tracks.first else { return }
                Task { await play(first, context: mix.tracks) }
            },
            playTrack: { track, context in
                Task { await play(track, context: context) }
            },
            openMix:    { path.append(.mix($0)) },
            openArtist: { path.append(.artist($0)) },
            openAlbum:  { path.append(.album($0)) },
            refreshRecommended: { store.rollRecommended() },
            playNext:     { song in Task { await coordinator.playNext(song) } },
            addToQueue:   { song in Task { await coordinator.addToQueue(song) } },
            // Awaited so the hero's play button spins for exactly as long as this runs.
            playAlbum:    { album in await playAlbum(album) },
            generateMix:  { showGenerateMix = true },
            openArtistNamed: { name, song in openArtist(named: name, from: song) },
            openAlbumFor:    { openAlbum(for: $0) }
        )
    }

    /// Your seed artists' releases first, then the editorial feed, deduped by album id.
    private var newReleaseAlbums: [OnlineAlbum] {
        var seen = Set<Int>()
        return (store.personal.freshReleases + browse.newReleases)
            .filter { seen.insert($0.id).inserted }
    }

    private var newReleasesGrid: some View {
        let albums = newReleaseAlbums
        let shown = showsAllReleases
            ? albums
            : Array(albums.prefix(Self.collapsedReleases))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("New releases")
                Spacer(minLength: 8)
                showAllToggle(total: albums.count,
                              cap: Self.collapsedReleases,
                              isExpanded: $showsAllReleases)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 166), spacing: 16)],
                      alignment: .leading, spacing: 18) {
                ForEach(shown) { album in
                    MixAlbumCard(album: album, onOpenArtist: { openArtist(named: $0) }) { path.append(.album(album)) }
                        .contextMenu { OnlineCollectionMenu(.album(album)) }
                }
            }
        }
    }

    /// "Trending now": a row of large play-on-tap song cards.
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Trending now")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(browse.trending) { song in
                        BrowseSongCard(
                            song: song,
                            isCurrent: coordinator.nowPlayingID == song.id,
                            isPlaying: engine.state.isPlaying,
                            isResolving: coordinator.resolvingID == song.id,
                            onPlay: {
                                let ctx = engine.queue.shuffleEnabled ? [song] : browse.trending
                                Task { await play(song, context: ctx) }
                            },
                            onPrefetch: { coordinator.prefetch(song) }
                        )
                        .contextMenu { onlineSongMenu(song, context: browse.trending) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// The song verbs for landing cards, same order as every other track menu.
    @ViewBuilder
    private func onlineSongMenu(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        OnlineSongMenu(
            song: song,
            onPlay: {
                let ctx = engine.queue.shuffleEnabled ? [song] : context
                Task { await play(song, context: ctx) }
            },
            onPlayNext:   { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            // No resolved album here, so ask for one by name like a player-bar link.
            onOpenAlbum: song.albumTitle.isEmpty ? nil : {
                appState.showOnlineAlbum(title: song.albumTitle,
                                         artistName: song.artistName,
                                         trackID: song.sourceID)
            },
            onOpenArtist: { name in
                appState.showOnlineArtist(name: name,
                                          trackID: name == song.artistName ? song.sourceID : nil)
            }
        )
    }

    /// "Popular artists": a wrapping grid of artist circles.
    private var popularArtistsSection: some View {
        let shown = showsAllArtists
            ? browse.artists
            : Array(browse.artists.prefix(Self.collapsedArtists))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Popular artists")
                Spacer(minLength: 8)
                showAllToggle(total: browse.artists.count,
                              cap: Self.collapsedArtists,
                              isExpanded: $showsAllArtists)
            }
            artistGrid(shown)
        }
    }

    /// Artists wrap rather than scroll: you scan for a name you already have in mind.
    private func artistGrid(_ artists: [OnlineArtist]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 152), spacing: 16)],
                  alignment: .leading,
                  spacing: 18) {
            ForEach(artists) { artist in
                ArtistCircle(artist: artist) { path.append(.artist(artist)) }
                    .contextMenu { OnlineCollectionMenu(.artist(artist)) }
            }
        }
    }

    /// "New releases": a horizontal row of album cards.
    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("New releases")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(browse.newReleases) { album in
                        AlbumCard(album: album, onOpenArtist: { openArtist(named: $0) }) { path.append(.album(album)) }
                            .frame(width: 150)
                            .contextMenu { OnlineCollectionMenu(.album(album)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// "Browse all": colourful genre/mood tiles.
    private var browseAllSection: some View {
        let shown = showsAllGenres
            ? browse.genres
            : Array(browse.genres.prefix(Self.collapsedGenres))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Browse all")
                Spacer(minLength: 8)
                showAllToggle(total: browse.genres.count,
                              cap: Self.collapsedGenres,
                              isExpanded: $showsAllGenres)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 240), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, genre in
                    GenreTile(genre: genre, index: idx) { path.append(.genre(genre)) }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.mixTextPrimary)
    }

    // MARK: - Local matches

    /// Library matches, above the online ones. Empty for most queries.
    @ViewBuilder
    private var localMatchesSection: some View {
        let matches = LocalMatchesSection.matches(for: query, in: deps.libraryService)
        if !matches.isEmpty {
            LocalMatchesSection(
                query: query,
                tracks: matches,
                onPlay: { track, context in Task { await engine.play(track: track, in: context, source: .named("Discover")) } },
                onShowAll: { path.append(.librarySongs(query)) }
            )
            .id("local")
        }
    }

    // MARK: - Recommendations

    /// Seeds are computed here since the store holds no dependencies. The store's TTL and
    /// seed fingerprint decide whether anything is fetched.
    private func loadPersonal() {
        let seeds = RecommendationEngine.seeds(stats: deps.statsService,
                                               library: deps.libraryService)
        store.loadPersonalIfNeeded(seeds: seeds,
                                   radarSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService),
                                   genreSeeds: RecommendationEngine.radarSeeds(
                                       library: deps.libraryService,
                                       limit: RecommendationEngine.maxGenreSeeds),
                                   genreTitles: RecommendationEngine.seedTitles(library: deps.libraryService),
                                   known: RecommendationEngine.knownKeys(library: deps.libraryService),
                                   using: deps.itunesClient)
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String, immediate: Bool = false) {
        store.search(text, using: deps.itunesClient, immediate: immediate)
    }

    // MARK: - Play

    /// A pick plays alone, so autoplay's recommendations follow it rather than the other results.
    private func play(_ track: OnlineTrack, context: [OnlineTrack]? = nil) async {
        store.noteSearchPick()
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context ?? [track], artworkData: artworkData)
    }

    /// Plays a record from its first track, through the album page's session cache.
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

    /// Resolve the track's artist (Deezer) and push the artist page.
    private func openArtist(for track: OnlineTrack) {
        openArtist(named: track.artistName, from: track)
    }

    /// By name alone: the mix header credits artists, not tracks.
    private func openArtist(named name: String) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                await MainActor.run { path.append(.artist(artist)) }
            }
        }
    }

    /// `trackID` only helps for the credited act; a guest resolves by name alone.
    private func openArtist(named name: String, from track: OnlineTrack) {
        let trackID = name == track.artistName ? track.sourceID : nil
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: trackID) {
                await MainActor.run { path.append(.artist(artist)) }
            }
        }
    }

    /// Resolve the track's album/EP (Deezer) and push the album page.
    private func openAlbum(for track: OnlineTrack) {
        Task {
            if let album = await deps.itunesClient.resolveAlbum(for: track) {
                await MainActor.run { path.append(.album(album)) }
            }
        }
    }
}

// MARK: - Navigation destinations

/// Internal so DiscoverSessionStore can hold the stack. iOS has its own copy in IOSDiscoverComponents.
enum DiscoverDestination: Hashable {
    case artist(OnlineArtist)
    case album(OnlineAlbum)
    case genre(BrowseGenre)
    /// Your liked library tracks by this artist, the only local page in the stack.
    case likedSongs(OnlineArtist)
    /// Every library song matching a search ("Show all" on the results).
    case librarySongs(String)
    /// Carries its tracks, already fetched for the card, so the page opens instantly.
    case mix(PersonalMix)
    /// Mixtape's own profile. Reads the mixes from the session store.
    case mixtapeProfile
    /// Someone's profile, usually whoever a mix was made for.
    case profile(UserProfile)
    /// A community post, by share code.
    case post(String)
}

private enum TopResult {
    case artist(OnlineArtist)
    case song(OnlineTrack)
}

// MARK: - Link placeholder

/// Placeholder naming what was clicked while a link resolves.
private struct DiscoverLinkLoading: View {
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Explicit badge

/// The small "E" label shown next to tracks with explicit lyrics.
private struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.mixTextSecondary)
            .frame(width: 14, height: 14)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Explicit")
    }
}

// MARK: - Wide song hero (song-centric top result)

/// Full-width hero for a searched song: artwork, title, "Song · artist" and Play.
private struct WideSongHero: View {
    let song: OnlineTrack
    /// True when this hero's track is the one currently loaded in the player.
    var isCurrent: Bool = false
    /// True when the player is actively playing (vs paused).
    var isPlaying: Bool = false
    /// Resolving the stream or saving: shows a spinner over the artwork.
    var isResolving: Bool = false
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onWrongVersion: (() -> Void)? = nil
    var onOpenAlbum: (() -> Void)? = nil
    var onOpenArtist: ((String) -> Void)? = nil

    @State private var hovering = false

    /// This specific track is the one playing right now.
    private var isThisPlaying: Bool { isCurrent && isPlaying }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            artworkView(url: song.artworkURL, circle: false, size: 180)
                .overlay {
                    if isResolving {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45))
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isResolving && (hovering || isThisPlaying) {
                        Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.mixPrimary)
                            .background(Circle().fill(.black.opacity(0.2)))
                            .padding(12)
                            .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Song")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                    if song.isExplicit { ExplicitBadge() }
                }
                ClickableText(text: song.displayTitle,
                              font: .system(size: 40, weight: .bold),
                              color: Color.mixTextPrimary,
                              action: onOpenAlbum)
                ClickableArtistLine(names: song.displayArtists,
                                    font: .system(size: 15, weight: .semibold),
                                    color: Color.mixTextSecondary,
                                    onOpen: onOpenArtist)
                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        Label(isThisPlaying ? "Pause" : "Play",
                              systemImage: isThisPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.mixAccentFill, in: Capsule())
                            .foregroundStyle(Color.mixOnAccent)
                    }
                    .buttonStyle(.plain).mixHandCursor()

                    if let onAdd {
                        SaveToLibraryButton(trackID: song.stableTrackID,
                                            identity: (song.title, song.artistName, song.duration),
                                            action: onAdd)
                            .scaleEffect(1.25)
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .mixTapAction(onPlay)   // clicking anywhere on the hero plays it
        .onHover { hovering = $0 }
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
        .mixAnimation(.easeInOut(duration: 0.12), value: isThisPlaying)
        .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
        .contextMenu {
            OnlineSongMenu(song: song,
                           onPlay: onPlay, isPlaying: isThisPlaying,
                           onPlayNext: onPlayNext,
                           onAddToQueue: onAddToQueue,
                           onWrongVersion: onWrongVersion,
                           onOpenAlbum: onOpenAlbum, onOpenArtist: onOpenArtist)
        }
    }
}

// MARK: - Top result banner

/// The best answer to a search as one full-width row. Opening and playing are
/// separate controls; hover shows a soft wash like Finder rows.
private struct TopResultBanner: View {
    let top: TopResult
    let onOpenArtist: (OnlineArtist) -> Void
    let onPlay: (OnlineTrack) -> Void

    @State private var hovering = false

    private var isArtist: Bool { if case .artist = top { return true }; return false }

    private var title: String {
        switch top {
        case .artist(let a): return a.name
        case .song(let s):   return s.displayTitle
        }
    }

    private var subtitle: String {
        switch top {
        case .artist:      return "Artist"
        case .song(let s): return "Song · \(s.displayArtistName)"
        }
    }

    private var imageURL: URL? {
        switch top {
        case .artist(let a): return a.imageURL
        case .song(let s):   return s.artworkURL
        }
    }

    private func open() {
        switch top {
        case .artist(let a): onOpenArtist(a)
        case .song(let s):   onPlay(s)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: open) {
                HStack(spacing: 16) {
                    artworkView(url: imageURL, circle: isArtist, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .mixHoverCursor { _ in }

            if case .song(let song) = top {
                Button { onPlay(song) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixOnAccent)
                        .frame(width: 40, height: 40)
                        .background(Color.mixAccentFill, in: Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .mixHoverCursor { _ in }
                .accessibilityLabel("Play \(song.displayTitle)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mixSurface2)
                .opacity(hovering ? 1 : 0)
        )
        // Horizontal only: a vertical inset would let the wash reach into the heading below.
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
        .mixAnimation(.easeInOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top result: \(title), \(subtitle)")
    }
}

// MARK: - Song row

private struct SongRow: View {

    /// Fits a 12pt monospaced "12:54", wider than the waveform that replaces it.
    private static let trailingWidth: CGFloat = 38

    let song: OnlineTrack
    let isResolving: Bool
    /// This row is the current online track.
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAdd: () -> Void
    let onPrefetch: () -> Void
    /// "Wrong version": forget the cached source and re-resolve. Nil hides the item.
    var onWrongVersion: (() -> Void)? = nil
    /// Title opens the album, artist opens the artist. Nil leaves the text inert.
    var onOpenAlbum: (() -> Void)? = nil
    var onOpenArtist: ((String) -> Void)? = nil

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                artworkView(url: song.artworkURL, circle: false, size: 40)
                if isResolving {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.45))
                        .frame(width: 40, height: 40)
                    ProgressView().controlSize(.small).tint(.white)
                } else if isCurrent {
                    // Now-playing indicator on top of the album cover.
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.mixPrimary)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .mixTapAction(onPlay)   // single click on the artwork plays
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ClickableText(text: song.displayTitle,
                                  font: .system(size: 13, weight: .medium),
                                  color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary,
                                  action: onOpenAlbum)
                    if song.isExplicit { ExplicitBadge() }
                }
                ClickableArtistLine(names: song.displayArtists,
                                    font: .system(size: 12),
                                    color: Color.mixTextSecondary,
                                    onOpen: onOpenArtist)
            }
            Spacer()
            // Dimmed when not hovered so a column of plus signs isn't loud. A saved song keeps
            // its check at full strength.
            SaveToLibraryButton(trackID: song.stableTrackID,
                                identity: (song.title, song.artistName, song.duration),
                                dimmed: !hovering,
                                action: onAdd)
            // Fixed width so the save button doesn't shift when the waveform replaces the duration.
            Group {
                if isCurrent {
                    // Animated waveform at the very right, like the offline player.
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                        .mixVariableColor(isActive: isPlaying)
                } else if song.duration > 0 {
                    Text(Self.formatTime(song.duration))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.mixSurface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)   // double click anywhere on the row plays
        .onHover { isHovering in
            hovering = isHovering
            hoverTask?.cancel()
            if isHovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onPrefetch()
                }
            }
        }
        .contextMenu {
            OnlineSongMenu(song: song,
                           onPlay: onPlay, onPlayNext: onPlayNext,
                           onAddToQueue: onAddToQueue,
                           onWrongVersion: onWrongVersion,
                           onOpenAlbum: onOpenAlbum, onOpenArtist: onOpenArtist)
        }
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Artist circle

private struct ArtistCircle: View {
    let artist: OnlineArtist
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            artworkView(url: artist.imageURL, circle: true, size: 112)
                .overlay {
                    if hovering {
                        Circle().stroke(Color.mixPrimary, lineWidth: 2)
                    }
                }
            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
        }
        .frame(width: 120)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
    }
}

// MARK: - Album card

private struct AlbumCard: View {
    let album: OnlineAlbum
    var onOpenArtist: ((String) -> Void)? = nil
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fills the column: the results grid can be narrower than 150.
            albumArtwork(url: album.coverURL)
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.mixPrimary)
                            .padding(8)
                    }
                }
            Text(album.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            ClickableArtistLine(names: ImportService.creditedArtists(from: album.artistName),
                                font: .system(size: 11), color: Color.mixTextSecondary,
                                onOpen: onOpenArtist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
    }

    /// Square cover sized by the column it lands in.
    private func albumArtwork(url: URL?) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.mixSurface2
                        Image(systemName: "music.note")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Artist detail page

private struct DiscoverArtistPage: View {
    let artist: OnlineArtist
    let onOpenAlbum: (OnlineAlbum) -> Void
    let onOpenArtist: (OnlineArtist) -> Void
    let onOpenLiked: () -> Void
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onPrefetch: (OnlineTrack) -> Void
    let onBack: () -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @ObservedObject private var store = DiscoverSessionStore.shared

    @State private var topTracks: [OnlineTrack]  = []
    @State private var albums:    [OnlineAlbum]  = []
    @State private var related:   [OnlineArtist] = []
    @State private var stations:  [PersonalMix]  = []
    @State private var fanCount:  Int?
    @State private var loading = true

    /// Section expansion toggles.
    @State private var albumsExpanded = false

    private let albumColumns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    /// Collapsed limits (Spotify-style: show a few, expand for the rest).
    private let expandedTrackCount = 10
    private let collapsedAlbumCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Full-bleed banner; padding goes back on everything below.
                DiscoverArtistBanner(artist: artist, fanCount: fanCount,
                                     onOpenLiked: onOpenLiked,
                                     accessory: AnyView(playRow))
                    .overlay(alignment: .topLeading) {
                        BackButton(action: onBack).padding(.leading, 20).padding(.top, 14)
                    }
                VStack(alignment: .leading, spacing: 28) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        // Popular and the artist facts side by side at the top.
                        if !topTracks.isEmpty { popularSection }
                        if !albums.isEmpty { albumsGrid }
                        if !stations.isEmpty { featuringSection }
                        if !related.isEmpty { similarArtistsSection }
                        DiscoverArtistAbout(artist: artist,
                                            songCount: albums.compactMap(\.trackCount).reduce(0, +),
                                            releaseCount: albums.count,
                                            fanCount: fanCount,
                                            onOpenLiked: onOpenLiked)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(DiscoverArtistWash(artist: artist))
        .task(id: artist.id) { await load() }
    }

    /// Just the play control; the identity is in the banner.
    @ViewBuilder
    private var playRow: some View {
        HStack(spacing: 12) {
            if let first = topTracks.first {
                Button {
                    onPlay(first, topTracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color.mixAccentFill, in: Capsule())
                        .foregroundStyle(Color.mixOnAccent)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
            ShareHeroButton(.artist(artist))
            // The card's right-click menu, for anyone who's already on the page.
            Menu { OnlineCollectionMenu(.artist(artist), showsShare: false) } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            .frame(width: 40, height: 40)
        }
    }

    private var popularSection: some View {
        // Ten when expanded; Deezer's top runs to fifty.
        let shown = Array(topTracks.prefix(expandedTrackCount))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Popular").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            // Two columns, each reading top to bottom, so the rank order holds.
            HStack(alignment: .top, spacing: 24) {
                trackColumn(Array(shown.prefix(5)), startingAt: 1)
                trackColumn(Array(shown.dropFirst(5)), startingAt: 6)
            }
        }
    }

    /// One numbered column of the Popular section.
    private func trackColumn(_ songs: [OnlineTrack], startingAt first: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { offset, song in
                HStack(spacing: 12) {
                    Text("\(first + offset)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(coordinator.nowPlayingID == song.id
                                         ? Color.mixPrimary : Color.mixTextTertiary)
                        .frame(width: 22, alignment: .trailing)
                    songRow(song, context: topTracks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plays into the list it was drawn from.
    private func songRow(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        SongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: { onPlay(song, context) },
            onPlayNext: { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd: { Task { await coordinator.addToLibrary(song) } },
            onPrefetch: { onPrefetch(song) },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: context) } },
            onOpenAlbum: {
                Task {
                    if let al = await deps.itunesClient.resolveAlbum(for: song) {
                        await MainActor.run { onOpenAlbum(al) }
                    }
                }
            },
            onOpenArtist: { name in
                Task {
                    if let a = await deps.itunesClient.resolveArtist(
                        name: name,
                        trackID: name == song.artistName ? song.sourceID : nil) {
                        await MainActor.run { onOpenArtist(a) }
                    }
                }
            }
        )
    }

    /// Spotify's "Featuring <name>" shelf. See `StationBuilder.artistStations`.
    private var featuringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists with \(artist.name)").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            HStack(alignment: .top, spacing: 18) {
                ForEach(stations) { station in
                    MixMosaicCard(
                        mix: station,
                        isResolving: station.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
                        onOpen: { store.path.append(.mix(station)) },
                        onPlay: {
                            guard let first = station.tracks.first else { return }
                            onPlay(first, station.tracks)
                        })
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var albumsGrid: some View {
        let shown = albumsExpanded ? albums : Array(albums.prefix(collapsedAlbumCount))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Albums").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 18) {
                ForEach(shown) { album in
                    AlbumCard(album: album) { onOpenAlbum(album) }
                }
            }
            if albums.count > collapsedAlbumCount {
                expandButton(expanded: $albumsExpanded)
            }
        }
    }

    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fans also like").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(related) { artist in
                        ArtistCircle(artist: artist) { onOpenArtist(artist) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// Small "Show more"/"Show less" toggle styled like a secondary control.
    private func expandButton(expanded: Binding<Bool>) -> some View {
        Button {
            withMixAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
        } label: {
            Label(expanded.wrappedValue ? "Show less" : "Show more",
                  systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .buttonStyle(.plain).mixHandCursor()
        .padding(.top, 4)
    }

    private func load() async {
        // A still-fresh cached catalogue comes back synchronously.
        if let cached = store.cachedArtistCatalogue(for: artist) {
            apply(cached)
            return
        }
        loading = true
        apply(await store.artistCatalogue(for: artist, using: deps.itunesClient))
    }

    private func apply(_ catalogue: DiscoverSessionStore.ArtistCatalogue) {
        topTracks = catalogue.top
        albums    = catalogue.albums
        related   = catalogue.related
        stations  = StationBuilder.artistStations(artist, catalogue: catalogue)
        fanCount  = catalogue.fanCount
        loading = false
    }
}

// MARK: - Album detail page

private struct DiscoverAlbumPage: View {
    let album: OnlineAlbum
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onPrefetch: (OnlineTrack) -> Void
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @ObservedObject private var store = DiscoverSessionStore.shared

    @State private var tracks: [OnlineTrack] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    artworkView(url: album.coverURL, circle: false, size: 160)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Album").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                        Text(album.title).font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.mixTextPrimary).lineLimit(3)
                        ClickableArtistLine(names: ImportService.creditedArtists(from: album.artistName),
                                            font: .system(size: 14), color: Color.mixTextSecondary,
                                            onOpen: { name in
                                                Task {
                                                    if let a = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                                                        onOpenArtist(a)
                                                    }
                                                }
                                            })
                        HStack(spacing: 10) {
                            AlbumSaveButton(title: album.title, artistName: album.artistName,
                                            onSave: { Task { await coordinator.addAlbumToLibrary(tracks) } })
                            AlbumDownloadButton(ids: tracks.map(\.stableTrackID), downloads: deps.downloadManager,
                                                library: deps.libraryService) {
                                SavedAlbumsService.shared.setSaved(true, title: album.title, artistName: album.artistName)
                                await coordinator.addAlbumToLibrary(tracks)
                            }
                            .disabled(tracks.isEmpty)
                            ShareHeroButton(.album(album))
                            // The card's right-click menu, for anyone who's already on the page.
                            Menu { OnlineCollectionMenu(.album(album), showsShare: false) } label: {
                                HeroCircleLabel(systemImage: "ellipsis")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain).mixHandCursor()
                            .menuIndicator(.hidden)
                            .frame(width: 40, height: 40)
                        }
                        .padding(.top, 4)
                    }
                    Spacer()
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, song in
                            let isCurrent = coordinator.nowPlayingID == song.id
                            HStack(spacing: 12) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextTertiary)
                                    .frame(width: 22, alignment: .trailing)
                                SongRow(
                                    song: song,
                                    isResolving: coordinator.resolvingID == song.id,
                                    isCurrent: isCurrent,
                                    isPlaying: engine.state.isPlaying,
                                    onPlay: { onPlay(song, tracks) },
                                    onPlayNext: { Task { await coordinator.playNext(song) } },
                                    onAddToQueue: { Task { await coordinator.addToQueue(song) } },
                                    onAdd: { Task { await coordinator.addToLibrary(song) } },
                                    onPrefetch: { onPrefetch(song) },
                                    onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: tracks) } },
                                    onOpenArtist: { name in
                                        Task {
                                            if let a = await deps.itunesClient.resolveArtist(
                                                name: name,
                                                trackID: name == song.artistName ? song.sourceID : nil) {
                                                await MainActor.run { onOpenArtist(a) }
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: album.id) {
            if let cached = store.cachedAlbumTracks(for: album) {
                tracks = cached; loading = false; return
            }
            loading = true
            tracks = await store.albumTracks(for: album, using: deps.itunesClient)
            loading = false
        }
    }
}

// MARK: - Clickable (navigable) text

/// One link per artist, like `TappableArtistRow` but with `ClickableText`'s hover underline.
private struct ClickableArtistLine: View {
    let names: [String]
    var font: Font
    var color: Color
    var onOpen: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                // See `TappableArtistRow`: the credit truncates once at the end.
                ClickableText(text: name, font: font, color: color,
                              action: onOpen.map { open in { open(name) } })
                    .layoutPriority(Double(names.count - index))
                if index < names.count - 1 {
                    Text(", ").font(font).foregroundStyle(color).fixedSize()
                        .layoutPriority(Double(names.count - index))
                }
            }
        }
        .lineLimit(1)
    }
}

/// Text that underlines and navigates on click when `action` is set, plain text otherwise.
private struct ClickableText: View {
    let text: String
    var font: Font
    var color: Color
    var action: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .underline(hovering && action != nil, pattern: .solid)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onHover { if action != nil { hovering = $0 } }
            .modifier(LinkCursor(enabled: action != nil))
            .onTapGesture { action?() }
    }
}

/// Shows the link/pointing-hand cursor while hovering a clickable element.
private struct LinkCursor: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            content
        }
    }
}

// MARK: - Shared artwork view

/// Square or circular remote artwork with a music-note placeholder.
private func artworkView(url: URL?, circle: Bool, size: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : 6, style: .continuous)
    return CachedRemoteImage(url: url) { image in
        image.resizable().scaledToFill()
    } placeholder: {
        ZStack {
            Color.mixSurface2
            Image(systemName: circle ? "person.fill" : "music.note")
                .font(.system(size: size * 0.3))
                .foregroundStyle(Color.mixTextTertiary)
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}

// MARK: - Browse song card (Trending now)

/// Square song card for "Trending now". Plays on tap, prefetches on hover.
private struct BrowseSongCard: View {
    let song: OnlineTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let isResolving: Bool
    let onPlay: () -> Void
    let onPrefetch: () -> Void

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkView(url: song.artworkURL, circle: false, size: 150)
                .overlay {
                    if isResolving {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Current-but-paused keeps its button too.
                    if !isResolving && (hovering || isCurrent) {
                        Image(systemName: (isCurrent && isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.mixPrimary)
                            .background(Circle().fill(.black.opacity(0.2)))
                            .padding(8)
                            .transition(.opacity)
                    }
                }
            HStack(spacing: 5) {
                Text(song.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                if song.isExplicit { ExplicitBadge() }
            }
            Text(song.displayArtistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            hoverTask?.cancel()
            if isHovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onPrefetch()
                }
            }
        }
        .mixTapAction(onPlay)
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
        .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
    }
}

// MARK: - Genre tile (Browse all)

/// "Browse all" tile: hue by position, artwork tilted into the corner.
private struct GenreTile: View {
    let genre: BrowseGenre
    let index: Int
    let onTap: () -> Void

    @State private var hovering = false

    /// Cycled by position so a tile's colour stays stable across launches.
    private static let palette: [Color] = [
        Color(red: 0.83, green: 0.20, blue: 0.45), Color(red: 0.10, green: 0.45, blue: 0.42),
        Color(red: 0.18, green: 0.22, blue: 0.55), Color(red: 0.55, green: 0.20, blue: 0.80),
        Color(red: 0.90, green: 0.40, blue: 0.15), Color(red: 0.15, green: 0.50, blue: 0.70),
        Color(red: 0.60, green: 0.45, blue: 0.10), Color(red: 0.70, green: 0.15, blue: 0.25),
        Color(red: 0.20, green: 0.55, blue: 0.30), Color(red: 0.40, green: 0.25, blue: 0.60),
    ]

    private var color: Color { Self.palette[index % Self.palette.count] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            color
            Text(genre.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(14)
            CachedRemoteImage(url: genre.pictureURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.clear }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .rotationEffect(.degrees(25))
                .offset(x: 18, y: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .clipped()
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .mixTapAction(onTap)
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Genre page (a Browse all tile opened)

/// The most popular artists in a genre.
private struct DiscoverGenrePage: View {
    let genre: BrowseGenre
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps: AppDependencies

    @ObservedObject private var store = DiscoverSessionStore.shared

    @State private var artists: [OnlineArtist] = []
    @State private var loading = true

    /// Matches `ArtistCircle`'s 120pt frame so tiles don't overflow.
    private let columns = [GridItem(.adaptive(minimum: 138), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(genre.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if artists.isEmpty {
                    Text("Nothing to show for this genre right now.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mixTextSecondary)
                } else {
                    Text("Popular artists")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(artists) { artist in
                            ArtistCircle(artist: artist) { onOpenArtist(artist) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: genre.id) {
            if let cached = store.cachedGenreArtists(for: genre) {
                artists = cached; loading = false; return
            }
            loading = true
            artists = await store.genreArtists(for: genre, using: deps.itunesClient)
            loading = false
        }
    }
}

#endif
