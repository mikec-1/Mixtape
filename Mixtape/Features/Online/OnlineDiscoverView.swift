// OnlineDiscoverView.swift
// Mixtape — Features/Online
//
// Search songs/artists/albums online and stream them. Drill-down uses a manual
// `path` stack instead of a NavigationStack — nesting one inside the Mac
// NavigationSplitView locks the detail column (see MacContentRouter).

#if os(macOS)
import SwiftUI
import Combine

struct OnlineDiscoverView: View {

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var appState:    MacAppState

    /// Discover has no search field of its own — the window's single toolbar
    /// search box drives it. Two visible search bars (one in the toolbar, one
    /// in this header) was the most confusing thing on the screen.
    ///
    /// `activeSearchText`, so a query that has only been typed leaves this on
    /// the landing page: the panel under the search field is all typing gets
    /// until Return commits it. The searches below still run off the raw
    /// `searchText`, so the results are already warm the moment it does.
    private var query: String { appState.activeSearchText }

    /// Results, landing content and the drill-down stack all live outside the
    /// view: MacContentRouter swaps this whole column out when you change
    /// section, so anything held in @State here dies the moment you look at
    /// Home. See DiscoverSessionStore.
    @ObservedObject private var store = DiscoverSessionStore.shared

    /// People. This used to belong to the library results page, which was where
    /// every non-Discover search landed; now that the one search field lands
    /// here instead, finding someone by handle has to work here or it doesn't
    /// work at all. Its own object because it's a network round trip with its
    /// own debounce — songs appear on the keystroke and people drop in
    /// underneath a moment later, rather than the fast half waiting for the slow.
    @StateObject private var people = PeopleSearch()

    private var results: DiscoverResults { store.results }
    private var browse: BrowseLanding { store.browse }
    private var isSearching: Bool { store.isSearching }
    private var browseLoading: Bool { store.browseLoading }

    /// The drill-down stack. Written straight through to the store — the setter
    /// is nonmutating because the storage is the store, not this struct.
    private var path: [DiscoverDestination] {
        get { store.path }
        nonmutating set { store.path = newValue }
    }

    @ObservedObject private var washTint = ArtworkWashTint.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No chrome on the landing. A bar reading "Discover" above a page
            // that opens "Good evening, Mike" was labelling the greeting — the
            // greeting *is* the title, and the bar cost a band of the page to
            // say something the page already said. It comes back the moment
            // there's something to say: a query, or a page you drilled into.
            // `isBareHeader` as well as `isLanding`: a results page has no
            // title, so on it the band and its divider drew a 13pt empty strip
            // above the results — the sliver where "Results for “…”" used to be.
            if !isLanding && !isBareHeader {
                header
                Divider().padding(.top, 12)
            }
            if let error = coordinator.errorMessage {
                banner(error, system: "exclamationmark.circle.fill")
            } else if let status = coordinator.statusMessage {
                banner(status, system: "arrow.triangle.2.circlepath", tint: Color.mixPrimary)
            }
            content
        }
        .mixAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.errorMessage)
        .mixAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.statusMessage)
        .background(Color.mixBackground)
        // No cancel on disappear any more. The task belongs to the store, which
        // outlives this view, so letting a search that's already in the air
        // finish means the results are waiting when you come back rather than
        // having been thrown away halfway.
        .onAppear {
            consumePendingDeepLink()
            store.loadBrowseIfNeeded(using: deps.itunesClient)
            loadPersonal()
            // Arriving with text already in the toolbar field — a library search
            // carried over, or this tab's own query restored. `search` no-ops
            // when the results it's holding already answer that query.
            //
            // Called unconditionally, empty text included: this view is
            // destroyed and rebuilt whenever the field goes from typed to empty
            // (see `searchResults`), so this is the first moment a fresh
            // instance can tell the store that the query it is still holding
            // results for is gone. `search("")` is exactly that instruction.
            scheduleSearch(appState.searchText)
        }
        // First launch reaches `onAppear` before the library has finished
        // loading, and a personal landing built from an empty library is
        // refused outright — which is why the mixes only showed up after
        // navigating away and back. Retry the moment songs exist.
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
        .onChange(of: appState.pendingDiscover) { _, _ in consumePendingDeepLink() }
        .onChange(of: appState.searchText) { _, newValue in
            // Typing used to pop the drill-down stack, which meant starting to
            // search from an artist or album page threw that page away on the
            // first keystroke — you lost your place to a results list you hadn't
            // asked for yet. The query now only feeds the panel under the search
            // field; the search still runs so the results are ready the moment
            // it *is* asked for, which is Return (see `showSearchResults`).
            scheduleSearch(newValue)
            // A new query is a new answer. Collapsing the bands again means the
            // next result set opens at the same, readable height every time
            // rather than inheriting however far the last one had been unfolded.
            showsAllResultSongs   = false
            showsAllResultAlbums  = false
            showsAllResultArtists = false
        }
        // Return commits the query: that's the point at which the user has said
        // they want results rather than a suggestion, so the stack unwinds.
        .onChange(of: store.searchCommitToken) { _, _ in
            path.removeAll()
        }
        // The object debounces and drops stale replies itself; the task id just
        // makes a new keystroke cancel the call in flight.
        .task(id: query) {
            await people.search(query, using: deps.authService)
        }
    }

    // MARK: - Deep link (now-playing online artist/album → Discover)

    /// Resolves a pending Discover deep-link (set when the user clicks an online
    /// now-playing track's artist/album) and pushes the matching page.
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
                    // Nothing resolved — without this the click lands the user on
                    // the Discover landing page with no sign of what they asked
                    // for. Searching the name at least shows the near misses.
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
            }
        }
    }

    /// Show `query` in Discover's search field, as the landing spot for a link
    /// whose artist or album couldn't be resolved to a page.
    @MainActor
    private func fallBackToSearch(_ query: String) {
        guard !query.isEmpty else { return }
        path.removeAll()
        // The link never became a page, so it stops being one: emptying the
        // search field returns to where it was clicked rather than to a Discover
        // stack that has nothing in it.
        appState.discoverLinkActive = false
        appState.searchText = query
        // Committed, not merely typed: nobody typed this one. It stands in for a
        // page that failed to resolve, so it has to arrive showing its results
        // the way that page would have.
        appState.showSearchResults()
    }

    // MARK: - Header

    /// The landing proper: nothing typed, nothing drilled into. The page draws
    /// its own opening in that state, so the view chrome stands down.
    private var isLanding: Bool {
        path.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the header says, or nothing at all.
    ///
    /// A results page has no title. "Results for “…”" only repeated the text
    /// still sitting in the search field an inch above it, and spent a 22pt
    /// bold line — the loudest thing on the page — saying what the user had
    /// just typed. The system's own search surfaces don't caption themselves
    /// either; the top result is the answer, so it should be the first thing
    /// the eye lands on.
    private var headerTitle: String? {
        // The artist page writes its own name across the banner, at four times
        // this size. Repeating it here just pushes the picture down the page.
        if case .artist = path.last { return nil }
        // Same reason: the liked page writes "Liked Songs / By <artist>" across
        // its own hero, and it carries its own back button now.
        if case .likedSongs = path.last { return nil }
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

            // Only while results are what's on screen. Inside a drill-down the
            // search runs in the background for the panel, and a spinner next to
            // an artist's name would read as that page still loading.
            if isSearching && path.isEmpty { ProgressView().controlSize(.small) }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        // Nothing to title and nothing to go back to means no header band: the
        // results should start at the top of the page rather than under an
        // empty 38pt strip.
        .padding(.top, isBareHeader ? 0 : 16)
        .frame(height: isBareHeader ? 0 : nil)
        .opacity(isBareHeader ? 0 : 1)
        // The title band sits above `content`, so the page's own wash starts
        // below it and the bar stayed flat black on washed pages (mixes,
        // Release Radar). Drawing the same ramp from the shared tint carries
        // the colour up through the bar, like the sidebar does.
        .background(alignment: .top) {
            ArtworkWashGradient(colors: washTint.stops, intensity: washTint.chromeIntensity)
        }
    }

    /// True when the header would draw nothing — no back button, no title, and
    /// no spinner. Kept in the tree (rather than removed) so that starting a
    /// search doesn't restructure the stack and slide the results.
    private var isBareHeader: Bool {
        // The artist page is full-bleed and carries its own back button over
        // the picture, so a band above it is a black bar pushing the page down.
        if case .artist = path.last { return true }
        if case .likedSongs = path.last { return true }
        return path.isEmpty && headerTitle == nil && !isSearching
    }

    /// What the current drill-down page is called.
    private var pageTitle: String {
        switch path.last {
        case .artist(let artist):     return artist.name
        case .likedSongs(let artist): return "Liked · \(artist.name)"
        case .album(let album):       return album.title
        case .genre(let genre):       return genre.name
        case .mix(let mix):           return mix.title
        case .mixtapeProfile:         return "Mixtape"
        case .profile(let profile):   return profile.name
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
                // Saved mixes are library playlists, and the library is a
                // different section of the window — this leaves Discover
                // entirely rather than pushing a library page into its stack.
                onOpenSavedMix: { appState.showPlaylist($0) },
                resolvingID: coordinator.resolvingID
            )
        case .profile(let profile):
            ProfilePageView(profile: profile)
        case .none:
            // A link that hasn't landed yet. Without this the page falls through
            // to the landing for the length of the lookup, which is exactly what
            // "clicking a name opens Home first and then jumps" was.
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
        // The query decides this, not the results — and that ordering is the
        // whole fix for "deleting the search never goes back to Home".
        //
        // MacContentRouter renders Discover from two different branches of one
        // if/else chain (once for "something is typed", once for the Home
        // section), which SwiftUI treats as two different views. Emptying the
        // field moves it between them, so the instance carrying
        // `.onChange(of: searchText)` is torn down by the very edit it was
        // watching for and never gets to clear anything. `store` is a singleton
        // and outlives that, so it was still holding the old results, and a
        // results-first test rendered them forever with no way back.
        //
        // Not gated on `browse` having landed either. The landing draws from
        // several sources — Home is entirely local, For You comes from the
        // recommendation build — so an empty chart fetch must not hide the whole
        // page. Each band shows its own placeholder instead.
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            browseLanding
        } else if results.isEmpty && people.results.isEmpty {
            emptyState
        } else if let hero = results.topSong {
            songCentricResults(hero: hero)
        } else {
            // One column, in the order the answer is actually wanted: who or
            // what this is, then the songs, then the catalogue behind them.
            //
            // The rules are gone. Sections here are separated by space alone —
            // a heading plus 26pt of air groups a list perfectly well, and a
            // hairline *as well* is the belt-and-braces look the HIG warns
            // against. `sectionRule` still earns its place on the landing,
            // where it divides bands that have nothing to do with each other.
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    localMatchesSection
                    topResultBanner.id("top")
                    if !results.songs.isEmpty { songsSection.id("songs") }
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

    /// Layout for a song query: a wide full-width hero for the searched song,
    /// then the artist(s) on it (main + features), then more songs by the artist.
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
                        // Same five-row rhythm the artist-anchored branch uses.
                        // A song query is the commoner of the two, and it was
                        // the one still printing twelve rows in a column.
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

    /// Hero and artist(s) share one row, the way "Made for you" shares its row
    /// with "New release from": the artist column is a fixed lane on the right
    /// and the hero takes what's left. A single artist bubble under a 230pt-tall
    /// hero was most of a screen of empty surface for one photo.
    ///
    /// Narrow windows fall back to the old stack — below the threshold the hero
    /// would be squeezing its 40pt title to pay for the lane.
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
            // Hero lives outside results.songs, so prepend it to the context
            // or the coordinator won't find it and falls back to songs[0].
            onPlay: {
                if coordinator.nowPlayingID == hero.id {
                    engine.togglePlayPause()
                } else {
                    // Shuffle on → radio off this one song; off → queue the rest.
                    let ctx = engine.queue.shuffleEnabled
                        ? [hero]
                        : [hero] + results.songs.filter { $0.id != hero.id }
                    Task { await play(hero, context: ctx) }
                }
            },
            onPlayNext: { Task { await coordinator.playNext(hero) } },
            onAddToQueue: { Task { await coordinator.addToQueue(hero) } },
            onAdd: { Task { await coordinator.addToLibrary(hero) } },
            onWrongVersion: {
                let ctx = engine.queue.shuffleEnabled
                    ? [hero]
                    : [hero] + results.songs.filter { $0.id != hero.id }
                Task { await coordinator.reResolveAndPlay(hero, context: ctx) }
            },
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

    /// Two artist bubbles wide (120 each, 18 between) plus a little slack, so a
    /// song with a feature still puts both faces on one line.
    private static let artistColumnWidth: CGFloat = 264
    private static let heroRowGutter: CGFloat = 24
    /// The hero stops reading as a hero much below this once the lane is taken.
    private static let heroRowMinimum: CGFloat = 720

    /// "Artist" / "Artists" row beneath the song hero — the main artist and any
    /// featured artists, side by side and navigable.
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
    ///
    /// This was a 320pt card: a circle, a name and the word "Artist", boxed in
    /// its own surface, with a four-row song list crammed into the column
    /// beside it. It spent the entire first screenful stating one fact, pushed
    /// the songs into half the width they had, and left the albums below the
    /// fold on every window size.
    ///
    /// A strip states the same fact in 92pt: artwork, name, what it is, and a
    /// button that plays it. Everything below then gets the full column. The
    /// section heading is gone with the card — the row leads the page and says
    /// what it is in its own subtitle, so a label above it was naming the
    /// obvious, and the HIG's advice on both counts is to take it out.
    @ViewBuilder
    private var topResultBanner: some View {
        if let top = topResult {
            TopResultBanner(
                top: top,
                onOpenArtist: { path.append(.artist($0)) },
                onPlay: { track in
                    let ctx = engine.queue.shuffleEnabled ? [track] : results.songs
                    Task { await play(track, context: ctx) }
                }
            )
        }
    }

    /// One songs list, not two.
    ///
    /// The page used to print four songs beside the top result and call them
    /// "Songs", then print six more below the album grid and call *those* "More
    /// songs" — one list, split across two headings, with an unrelated section
    /// wedged between them. Nothing about the split was meaningful to a reader
    /// looking for a track; it existed only because the card next to the first
    /// four had a height to fill.
    ///
    /// Five rows collapsed, the rest a click away. That is the same rhythm the
    /// landing's "Show all" bands already use.
    private var songsSection: some View {
        let songs = resultSongs
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // Honest about what it is. When the relevance filter came back
                // empty the search kept Deezer's raw full-text hits so the page
                // wouldn't be blank — those are the best guesses available, not
                // matches, and saying so is the difference between a search
                // that missed and a search that looks broken.
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

    /// People, last. They arrive a beat after everything else — a debounce plus
    /// a round trip to the directory — and a section that appears late at the
    /// top would shove the songs down under the reader's cursor. A failed
    /// lookup draws nothing at all: the results beside it are still good, and a
    /// network error about a corpus the user probably wasn't asking for is not
    /// worth a line of the page.
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

    /// Wrapped, not scrolled — the same treatment the artists below already get.
    ///
    /// A horizontal scroller is right on the landing, where you flick through
    /// new releases without a particular one in mind. In a *result set* it's
    /// wrong: you searched for a name, so the album you want may well be the
    /// ninth, and the ninth is three drags off-screen behind a scrollbar that
    /// gives no hint of how much is left. Stacked, the whole answer is on the
    /// page and the section ends where it ends.
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
            // Tighter than the landing's shelves, and capped. At 150–190pt a
            // full catalogue was a wall of covers that owned the whole fold;
            // at 124–150pt a wide window fits a row of six, which is the whole
            // collapsed section, and the wrapped-not-scrolled decision below
            // still holds — nothing is hidden behind a drag, only behind a
            // labelled control that says how much more there is.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124, maximum: 150), spacing: 16)],
                      alignment: .leading,
                      spacing: 18) {
                ForEach(shown) { album in
                    AlbumCard(album: album) { path.append(.album(album)) }
                        .contextMenu {
                            Button("Open Album", systemImage: MixtapeIcons.album) {
                                path.append(.album(album))
                            }
                            Divider()
                            ShareMenuItems(.album(album))
                        }
                }
            }
        }
    }

    /// Song rows with a hairline between them, the same structure the Liked
    /// Songs page uses.
    ///
    /// These used to be a flat `VStack(spacing: 2)`, which at a glance is one
    /// grey mass rather than a list you can count — the rows only separated
    /// where a cover happened to be light. The rule starts at 56pt so it aligns
    /// with the text column and leaves the artwork uncut.
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
                // Played straight out of the search results — the other half of
                // "recently searched", alongside the rows picked in the dropdown.
                if let recent = SearchSuggestion(track: song) {
                    SearchSuggestionsStore.shared.remember(recent)
                }
                let ctx = engine.queue.shuffleEnabled ? [song] : results.songs
                Task { await play(song, context: ctx) }
            },
            onPlayNext: { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd: { Task { await coordinator.addToLibrary(song) } },
            onPrefetch: { coordinator.prefetch(song) },
            onWrongVersion: {
                let ctx = engine.queue.shuffleEnabled ? [song] : results.songs
                Task { await coordinator.reResolveAndPlay(song, context: ctx) }
            },
            onOpenAlbum: { openAlbum(for: song) },
            onOpenArtist: { openArtist(named: $0, from: song) }
        )
    }

    // MARK: - Result partitioning

    /// Top result: the anchor artist when the query named one, otherwise the
    /// best-matching song.
    ///
    /// `results.anchorIsArtist` decides it, not the query text. The old test
    /// compared `artists.first.name` against the raw string and took a prefix
    /// match — which disagrees with the search layer exactly where it matters:
    /// "wknd" resolves to The Weeknd through a consonant skeleton and is not a
    /// prefix of anything, so the page anchored to that artist's catalogue while
    /// promoting one of their songs to the top slot. `artists.first` IS the
    /// anchor whenever the flag is set; see `DiscoverResults.anchorIsArtist`.
    private var topResult: TopResult? {
        if results.anchorIsArtist, let artist = results.artists.first {
            return .artist(artist)
        }
        if let song = results.songs.first { return .song(song) }
        if let artist = results.artists.first { return .artist(artist) }
        return nil
    }

    /// The songs list: everything the search returned, minus whatever is already
    /// standing at the top of the page, collapsed to five until asked.
    private var resultSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return showsAllResultSongs ? pool : Array(pool.prefix(Self.collapsedResultSongs))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Empty state

    /// `EmptyStateView` — the same `ContentUnavailableView` every other screen
    /// in the app draws when it has nothing, rather than a hand-stacked glyph
    /// and label that had drifted a size and a colour away from all of them.
    /// The search-in-flight case stays a spinner: nothing is missing yet.
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

    /// The merged Home/Discover landing: one page, top to bottom.
    ///
    /// This was five tabs — Home, For You, New, Charts, Genres — and the tabs
    /// were the problem. Four fifths of the page was always hidden behind a
    /// click, so the landing looked identical every time you opened it, and the
    /// two halves that most belonged together (what you've been playing, and
    /// what to play next) were the two furthest apart.
    ///
    /// So it reads in one scroll, in the order you'd actually want it: who you
    /// are and what you were just playing, then what we think you'd like, then
    /// what's out there, then the numbers. Each section still guards its own
    /// visibility, so a genre outage or an empty library removes a band from
    /// the page instead of blanking it.
    private var browseLanding: some View {
        landingScroll {
            // 1 — You, in one band: the greeting and a shelf of things to
            // resume. Everything else about your own library moved down to (4);
            // it used to sit here, which meant five bands of library between the
            // greeting and the recommendations the page is named for.
            MacHomeSurface(bands: .top).id("home")

            // 2 — For you. The recommendations built from all of the above,
            // then the smart playlists: also made from your listening, so they
            // belong beside "Because you listened to…" rather than under the
            // catalogue.
            sectionRule
            forYouBody

            if HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                sectionRule
                MacHomeSurface(bands: .smart).id("smart")
            }

            // 3 — The catalogue at large. New releases sits at the end of it
            // rather than the start: it's the longest of the three grids and
            // the one most worth arriving at, so it stops burying the artists
            // and genres under twelve album covers on the way past.
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

            // 4 — Back to your own shelves, now that the page has shown you
            // what's out there.
            if HomeSections.hasLibraryContent(engine: engine, library: deps.libraryService) {
                sectionRule
                MacHomeSurface(bands: .library).id("library")
            }

            // 5 — The numbers, last, because a summary belongs after the thing
            // it summarises.
            sectionRule
            HomeStatsCard()

            // Nothing has arrived yet and nothing is cached: one spinner for the
            // whole page rather than a stack of empty headings.
            if browse.isEmpty && store.personal.isEmpty {
                landingPlaceholder
            }
        }
    }

    // MARK: - Collapsed grids
    //
    // The three catalogue grids are the page's long tail: eighteen albums,
    // fifteen artists and twenty-odd genres, all of them wrapping, none of them
    // something you scroll *through* on the way somewhere. Each shows about two
    // rows and offers the rest, so reaching the bottom of the page is a scroll
    // rather than an expedition.

    @State private var songResultsWidth: CGFloat = 0
    /// The "+" tile at the end of "Your mixes".
    @State private var showGenerateMix = false
    @State private var showsAllReleases = false
    @State private var showsAllArtists  = false
    @State private var showsAllGenres   = false
    /// Collapsed/expanded state for the three result bands. Reset whenever a new
    /// search lands, so an expanded album grid from the last query doesn't
    /// decide how the next one opens.
    @State private var showsAllResultSongs   = false
    @State private var showsAllResultAlbums  = false
    @State private var showsAllResultArtists = false

    private static let collapsedReleases = 12
    private static let collapsedArtists  = 10
    private static let collapsedGenres   = 10
    private static let collapsedResultSongs   = 5
    private static let collapsedResultAlbums  = 6
    private static let collapsedResultArtists = 6

    /// The "Show all" / "Show less" pill, or nothing when the section is already
    /// short enough that collapsing it would save no rows.
    @ViewBuilder
    private func showAllToggle(total: Int, cap: Int, isExpanded: Binding<Bool>) -> some View {
        if total > cap {
            MixPillButton(title: isExpanded.wrappedValue ? "Show less" : "Show all") {
                withMixAnimation(.easeInOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            }
        }
    }

    /// The line between bands of the page. The landing is one long scroll now,
    /// so it needs the structure the tab strip used to give it for free —
    /// otherwise "Recommended songs" and "New releases" run together into one
    /// undifferentiated column of cards.
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

    /// Shown while a tab's content is still in the air, or if its fetch failed.
    /// Each tab gets its own rather than one for the whole page, so a genre
    /// outage doesn't blank the recommendations that already loaded.
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
                // Nothing played yet, so there is nothing to recommend *from*.
                // Rather than an empty page, this is the one moment where the
                // global chart is genuinely the right answer — it's the only
                // signal available — with the reason stated so it doesn't look
                // like the personalization silently failed.
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
            if !browse.trending.isEmpty {
                sectionRule
                trendingSection.id("trending")
            }
        }
    }

    /// Capped, and the cap is the band's business rather than this view's taste.
    ///
    /// The band beside it lifts its "New release from" heading up out of the
    /// band and into this row, so the two share a line with only a gutter
    /// between their lanes. Left to run, this sentence grows with the artist
    /// names in it — three long ones and it reaches across into the hero. One
    /// line and a hard cap keeps it in its lane at every window width; the band
    /// won't lay itself out side by side unless there's room for both.
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
            addToLibrary: { song in Task { await coordinator.addToLibrary(song) } },
            // Awaited, not fired into a Task: the hero's play button spins for
            // exactly as long as this runs.
            playAlbum:    { album in await playAlbum(album) },
            generateMix:  { showGenerateMix = true }
        )
    }

    /// New releases, your own artists first.
    ///
    /// The tail is the catalogue's editorial feed, which is all this section
    /// used to be — a global list where whatever the label pushed that week
    /// outranked the record your most-played artist actually put out on Friday.
    /// The front is what your seed artists released, the same albums that used
    /// to sit in a corner of the mixes band as "More new releases", where four
    /// of fifteen fit and the section they belonged in was somewhere else on
    /// the page.
    ///
    /// Still both lists rather than only yours: a section called "New releases"
    /// that knows about six artists isn't a browse. Deduped on album id because
    /// the two lists come from the same catalogue and an artist popular enough
    /// to be in your history is popular enough to be in the editorial feed too.
    private var newReleaseAlbums: [OnlineAlbum] {
        var seen = Set<Int>()
        return (store.personal.freshReleases + browse.newReleases)
            .filter { seen.insert($0.id).inserted }
    }

    /// "New" is a grid rather than the landing's horizontal strip: a tab whose
    /// entire job is one row of albums would waste the page it was given.
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
                    MixAlbumCard(album: album) { path.append(.album(album)) }
                        .contextMenu {
                            Button("Open Album", systemImage: MixtapeIcons.album) {
                                path.append(.album(album))
                            }
                            Divider()
                            ShareMenuItems(.album(album))
                        }
                }
            }
        }
    }

    /// "Trending now" — horizontal row of large play-on-tap song cards.
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

    /// The song verbs, for the landing cards that only knew how to be clicked.
    /// Same four in the same order as every other track menu in the app.
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
            // The landing has no resolved artist or album in hand, so it asks
            // for one by name the same way a link from the player bar does —
            // the pending link lands on the stack that is already here.
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

    /// "Popular artists" — a wrapping grid of artist circles.
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

    /// Artists wrap onto as many rows as they need rather than running off the
    /// side of the window.
    ///
    /// A horizontal scroller is the right shape for browsing — you flick through
    /// albums without looking for anything in particular. Artists are the
    /// opposite: you scan the set for a name you already have in mind, and a
    /// name that's three drags off-screen may as well not be listed. Wrapping
    /// costs vertical space on a page that scrolls vertically anyway.
    private func artistGrid(_ artists: [OnlineArtist]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 152), spacing: 16)],
                  alignment: .leading,
                  spacing: 18) {
            ForEach(artists) { artist in
                ArtistCircle(artist: artist) { path.append(.artist(artist)) }
                    .contextMenu {
                        Button("Open Artist", systemImage: MixtapeIcons.artist) {
                            path.append(.artist(artist))
                        }
                        Divider()
                        ShareMenuItems(.artist(artist))
                    }
            }
        }
    }

    /// "New releases" — horizontal row of album cards.
    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("New releases")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(browse.newReleases) { album in
                        AlbumCard(album: album) { path.append(.album(album)) }
                            .frame(width: 150)
                            .contextMenu {
                                Button("Open Album", systemImage: MixtapeIcons.album) {
                                    path.append(.album(album))
                                }
                                Divider()
                                ShareMenuItems(.album(album))
                            }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// "Browse all" — colourful genre/mood tiles, Spotify-style.
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

    private func banner(_ text: String, system: String, tint: Color = Color.mixDestructive) -> some View {
        HStack(spacing: 10) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .mixShadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Local matches

    /// Your own songs, above the online ones. Empty for a query nothing local
    /// answers, which is most of them — so this costs nothing on the way to
    /// Discover's usual results, and turns the toolbar's single field into the
    /// one search box the app should always have had.
    @ViewBuilder
    private var localMatchesSection: some View {
        let matches = LocalMatchesSection.matches(for: query, in: deps.libraryService)
        if !matches.isEmpty {
            LocalMatchesSection(
                query: query,
                tracks: matches,
                onPlay: { track, context in Task { await engine.play(track: track, in: context, source: .named("Discover")) } },
                onShowAll: {
                    // The Library page runs the same query against the whole
                    // library, which is what "show all" has to mean. It's also
                    // the one place a query is allowed to outlive the section
                    // it was typed in, so it goes through `showAllInLibrary`
                    // rather than setting the selection directly.
                    appState.showAllInLibrary()
                }
            )
            .id("local")
        }
    }

    // MARK: - Recommendations

    /// Seeds are computed here rather than in the store: they need the
    /// main-actor stats and library services, and the store deliberately holds
    /// no dependencies. Cheap enough to run on every appear — it's two passes
    /// over the play history, and the store's TTL plus seed fingerprint decides
    /// whether anything is actually fetched.
    private func loadPersonal() {
        let seeds = RecommendationEngine.seeds(stats: deps.statsService,
                                               library: deps.libraryService)
        store.loadPersonalIfNeeded(seeds: seeds,
                                   radarSeeds: RecommendationEngine.radarSeeds(library: deps.libraryService),
                                   genreSeeds: RecommendationEngine.radarSeeds(
                                       library: deps.libraryService,
                                       limit: RecommendationEngine.maxGenreSeeds),
                                   known: RecommendationEngine.knownKeys(library: deps.libraryService),
                                   using: deps.itunesClient)
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String, immediate: Bool = false) {
        store.search(text, using: deps.itunesClient, immediate: immediate)
    }

    // MARK: - Play

    private func play(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }

    /// Start a record from its first track. The list is a fetch, so this goes
    /// through the same session cache the album page uses — opening the album
    /// after pressing play costs nothing the second time.
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

    /// The same, for one name out of a credit line. `trackID` disambiguates by
    /// asking Deezer who this *track's* artist is, so it only helps for the
    /// credited act — a guest has to be resolved by name alone.
    /// By name alone — the mix header credits artists, not tracks.
    private func openArtist(named name: String) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                await MainActor.run { path.append(.artist(artist)) }
            }
        }
    }

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

/// Internal rather than private so DiscoverSessionStore can hold the stack.
/// iOS declares its own identical copy in IOSDiscoverComponents; only one of
/// the two is ever compiled.
enum DiscoverDestination: Hashable {
    case artist(OnlineArtist)
    case album(OnlineAlbum)
    case genre(BrowseGenre)
    /// Your favourited library tracks by this artist — the only local page in
    /// the stack. Carries the artist rather than the name so it can wear the
    /// same photo the page it was opened from does.
    case likedSongs(OnlineArtist)
    /// A personalized mix. Carries the whole thing, tracks included, because it
    /// was already fetched to draw the card — so the page opens instantly
    /// instead of spinning through a request the app has the answer to.
    case mix(PersonalMix)
    /// Mixtape's own profile, reached from the owner name on a mix. Carries
    /// nothing: the page reads the mixes straight out of the session store, so
    /// there is no snapshot here that could go stale behind it.
    case mixtapeProfile
    /// Someone's profile — in practice whoever a mix was made for, reached from
    /// the "Made for" name.
    case profile(UserProfile)
}

private enum TopResult {
    case artist(OnlineArtist)
    case song(OnlineTrack)
}

// MARK: - Link placeholder

/// What a linked page shows while its name is being resolved into a real page.
/// Names the thing you clicked, so the wait is visibly about that and not a
/// page that failed to open.
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

/// A full-width hero for a searched song: large artwork beside the title,
/// "Song · artist", and a Play button. Spans the whole content width.
private struct WideSongHero: View {
    let song: OnlineTrack
    /// True when this hero's track is the one currently loaded in the player.
    var isCurrent: Bool = false
    /// True when the player is actively playing (vs paused).
    var isPlaying: Bool = false
    /// True while the stream is being resolved (play) or the track is being
    /// saved to the library — drives the spinner over the artwork.
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
        .onTapGesture(perform: onPlay)   // clicking anywhere on the hero plays it
        .onHover { hovering = $0 }
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
        .mixAnimation(.easeInOut(duration: 0.12), value: isThisPlaying)
        .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
        .contextMenu {
            OnlineSongMenu(song: song,
                           onPlay: onPlay, onPlayNext: onPlayNext,
                           onAddToQueue: onAddToQueue,
                           onWrongVersion: onWrongVersion,
                           onOpenAlbum: onOpenAlbum, onOpenArtist: onOpenArtist)
        }
    }
}

// MARK: - Top result banner

/// The best answer to a search, as one full-width row.
///
/// Design intent: state the answer and get out of the way. What this replaces
/// was a 320pt tile — a surface, a corner radius, and a hover-only play glyph
/// floating in its bottom corner — holding a photo and two words, under a
/// heading that repeated what its own subtitle already said. Every one of those
/// was decoration standing in for information, and between them they owned the
/// first screenful of every search.
///
/// What is left is the information. The artwork identifies it; the name at 20pt
/// semibold is the largest thing below the page title; the subtitle says what
/// kind of thing it is; and playing it is a real, permanent, focusable button
/// rather than something that materialises under the pointer. The row has no
/// fill of its own — it sits on the page and is grouped by the space around it,
/// the way a first-party list row does — and hovering lifts a soft rounded wash
/// behind it, which is the feedback Finder and Mail rows give.
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

    /// Opening it and playing it are two separate intents, so they are two
    /// separate controls. On the card they were one click that meant whichever
    /// the case happened to be.
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
        // Horizontal only. The wash should bleed into the page gutter rather
        // than indent the row away from the headings under it — but a negative
        // *vertical* inset would shrink the row's layout bounds inside the
        // 26pt section spacing, and the wash would then reach into the gap and
        // read as touching the heading below.
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
        .mixAnimation(.easeInOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top result: \(title), \(subtitle)")
    }
}

// MARK: - Song row

private struct SongRow: View {

    /// The width of the slot after the save button. Four digits of the 12pt
    /// monospaced duration ("12:54"), which is longer than any of these rows
    /// and wider than the waveform that replaces it.
    private static let trailingWidth: CGFloat = 38

    let song: OnlineTrack
    let isResolving: Bool
    /// Now-playing treatment: this row is the current online track / it is actively playing.
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAdd: () -> Void
    let onPrefetch: () -> Void
    /// "This is the wrong version" — forgets the cached source and re-resolves.
    /// Nil hides the menu item.
    var onWrongVersion: (() -> Void)? = nil
    /// Tapping the song title opens its album/EP; tapping the artist name opens
    /// the artist. Nil leaves the text non-interactive.
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
            .onTapGesture(perform: onPlay)   // single click on the artwork plays
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
            // One tap to keep the song. Dimmed rather than hidden when the
            // pointer is elsewhere — a control nobody can see is a control
            // nobody finds, and a full-strength column of plus signs down a
            // long result list is too loud. The button ignores this once the
            // song is saved: the check stays at full strength, and tapping it
            // opens the sheet showing where the song is filed.
            SaveToLibraryButton(trackID: song.stableTrackID,
                                identity: (song.title, song.artistName, song.duration),
                                dimmed: !hovering,
                                action: onAdd)
            // One slot, one width, whatever is in it — the waveform is narrower
            // than a duration and a song with no duration at all is narrower
            // still, so without this the save button slides sideways the moment
            // you press play on a row.
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
            // The word "Artist" under a circular photo of a person, on a page
            // whose heading already reads "Popular artists". Dropped: it cost a
            // line on every tile to restate the section it was in.
        }
        .frame(width: 120)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Album card

private struct AlbumCard: View {
    let album: OnlineAlbum
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fills the column rather than a hard 150: the results grid's
            // columns can be narrower than that, and an oversized card
            // overflowed into its neighbour so the covers touched.
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
            Text(album.artistName)
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
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
                // Full-bleed: the banner is the page's top edge, so it gets the
                // padding taken off it and put back on everything below.
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
                        // Popular takes half the width and the facts about the
                        // artist take the other half, so the numbers are at the
                        // top of the page where they're worth reading rather
                        // than at the bottom under everything else.
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

    /// Just the play control now — the identity moved into the banner.
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
        }
    }

    private var popularSection: some View {
        // Ten is the whole list, expanded — Deezer's "top" runs to fifty and
        // the eleventh most played song is nobody's reason for being here.
        let shown = Array(topTracks.prefix(expandedTrackCount))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Popular").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            // Two columns on the Mac, each reading top to bottom — 1-5 on the
            // left, 6-10 on the right. A grid fills across instead, which puts
            // the second-most-played song beside the first and breaks the rank
            // order the numbers are claiming.
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

    /// One row, playing into whichever list it was drawn from — a song in
    /// "Appears on" must not queue up the Popular list behind it.
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

    /// Spotify's "Featuring <name>" shelf, made of the two stations we can
    /// build ourselves — see `StationBuilder.artistStations`.
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
        // Walking back down the drill-down stack shouldn't mean watching the
        // same three requests again — the store hands back a still-fresh
        // catalogue synchronously, so the page comes back populated.
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

    /// Adding an album adds its songs; ones already in the library are skipped.
    private func importAll() async {
        for song in tracks where deps.libraryService.track(id: song.stableTrackID) == nil {
            await coordinator.addToLibrary(song, albumOnly: true)
        }
    }

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
                        Text(album.artistName).font(.system(size: 14))
                            .foregroundStyle(Color.mixTextSecondary)
                        HStack(spacing: 10) {
                            AlbumSaveButton(title: album.title, artistName: album.artistName,
                                            onSave: { Task { await importAll() } })
                            AlbumDownloadButton(ids: tracks.map(\.stableTrackID), downloads: deps.downloadManager,
                                                library: deps.libraryService) {
                                SavedAlbumsService.shared.setSaved(true, title: album.title, artistName: album.artistName)
                                await importAll()
                            }
                            .disabled(tracks.isEmpty)
                            ShareHeroButton(.album(album))
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

/// A line of text that acts like a Spotify hyperlink when `action` is non-nil:
/// it underlines and shows the link cursor on hover and navigates on click.
/// With no action it renders as plain text, so callers can pass it everywhere.
/// The credit line as one link per artist, comma-separated — the same shape the
/// library and the player bar use (`TappableArtistRow`), but drawn with
/// `ClickableText` so a Discover row keeps its hover underline and link cursor.
/// One string for the whole credit made "Drake, Future, Molly Santana" a single
/// link that could only ever open Drake.
private struct ClickableArtistLine: View {
    let names: [String]
    var font: Font
    var color: Color
    var onOpen: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                // See `TappableArtistRow` — the credit trails off once at the
                // end instead of every name giving up letters at once.
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

/// A large square song card for the horizontal "Trending now" row. Plays on tap,
/// prefetches on hover, and shows the now-playing / resolving state like SongRow.
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
                    if !isResolving && (hovering || (isCurrent && isPlaying)) {
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
        .onTapGesture(perform: onPlay)
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
        .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
    }
}

// MARK: - Genre tile (Browse all)

/// Colourful "Browse all" tile — hue picked by position, artwork tucked into the
/// corner at an angle.
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
        .onTapGesture(perform: onTap)
        .mixAnimation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Genre page (a Browse all tile opened)

/// Shows the most popular artists within a genre. Tapping an artist opens their
/// page (which already has play / albums / similar artists).
private struct DiscoverGenrePage: View {
    let genre: BrowseGenre
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps: AppDependencies

    @ObservedObject private var store = DiscoverSessionStore.shared

    @State private var artists: [OnlineArtist] = []
    @State private var loading = true

    /// In step with `ArtistCircle`'s own 120pt frame — a tile wider than its
    /// column overflows into the next one.
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
