// SearchView.swift
// Mixtape — Features/Search

import SwiftUI
import Combine

public struct SearchView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    #if os(iOS)
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    // Filtered + relevance-ranked results, computed off the hot render path and
    // stored here so the List reads cached arrays instead of re-filtering on
    // every body eval.
    @State private var matchingTracks:  [Track]  = []
    @State private var matchingAlbums:  [Album]  = []
    @State private var matchingArtists: [Artist] = []
    @State private var isFiltering = false

    /// People come from the server, not the library snapshot above, so they run
    /// on their own debounce and land in their own section rather than making
    /// the local results wait on a network call.
    @StateObject private var people = PeopleSearch()

    #if os(iOS)
    /// The catalogue half of this field. Shared with the Discover pages so one
    /// search serves both, and observed here — not just inside
    /// `SearchCatalogueResults` — because this view decides whether there are
    /// any results at all, and it was deciding that from the library alone.
    @ObservedObject private var catalogue = DiscoverSessionStore.shared
    #endif

    // Recent searches persisted across launches (newline-delimited, newest first).

    /// Past searches, shared with the Mac's dropdown. See `SearchSuggestionsStore`.
    @ObservedObject private var history = SearchSuggestionsStore.shared

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @State private var resultFilter: IOSSearchFilter = .all

    /// The field is in use: focused, or holding a query. Hides the page title
    /// and swaps the landing's white field for a grey one with Cancel beside it.
    private var isActive: Bool { isSearchFocused || isSearching }

    /// Completions while typing. Losing focus (Return, a tapped term, a scroll)
    /// shows the results; focusing again brings these back.
    private var showsSuggestions: Bool {
        isSearchFocused && !history.isDismissed && !history.suggestions.isEmpty
    }

    /// Spotify's landing field is a white slab on the dark page.
    private var fieldIsBright: Bool { !isActive && colorScheme == .dark }
    #endif

    /// One real cover per browse card, so the grid is made of this library
    /// rather than six coloured rectangles that would look identical in
    /// everybody's copy of the app.
    ///
    /// Held as state and filled by a `.task` rather than computed in `body`:
    /// picking the covers means reaching into the library for each category,
    /// and the browse screen is the one place in the app someone arrives at
    /// with nothing loaded and nothing to wait for.
    /// Collapse state of the library section, reset per query.
    @State private var libraryExpanded = false

    @State private var browseArtwork: [BrowseCategory: ArtworkRef?] = [:]

    /// The pushed stack. Untyped `NavigationPath` rather than a typed array
    /// because it carries library values (an album, an artist) and — on iOS —
    /// catalogue destinations, which are different types entirely.
    @State private var discoverPath = NavigationPath()

    // MARK: - Body

    /// Bumped whenever the download manager publishes.
    ///
    /// This view reads download state (`status(for:)` and friends) straight off
    /// the manager inside `body`, which is not observation — nothing here holds
    /// the manager, so nothing here hears it change. `AppDependencies` used to
    /// rebroadcast every service's publishes, which covered this by invalidating
    /// all 81 views that hold `deps` on every status transition. The views that
    /// actually draw download state say so themselves now.
    @State private var downloadTick = 0

    public var body: some View {
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        NavigationStack(path: $discoverPath) {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    #if os(iOS)
                    // Drawn here rather than as a large navigation title: that
                    // title re-measures itself against the scroll view on every
                    // keystroke and every keyboard frame, and it cost a whole
                    // band of the screen above a field nobody scrolls past.
                    // Gone while the field is in use, the way Spotify hands the
                    // whole screen to recents and results.
                    if !isActive {
                        HStack(spacing: 10) {
                            ProfileMenuButton(size: 32)
                            Text("Search")
                                .font(.mixHeadline)
                                .foregroundStyle(Color.mixTextPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    #endif

                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                    #if !os(iOS)
                    Divider().background(Color.mixSeparator)
                    #endif

                    if isSearching {
                        #if os(iOS)
                        if showsSuggestions { suggestionsPanel } else { searchResults }
                        #else
                        searchResults
                        #endif
                    } else {
                        // Focused with nothing typed: past searches, the way the
                        // Mac's dropdown answers an empty field.
                        //
                        // Layered rather than branched. Tapping the field used to
                        // tear down the whole browse tree — six artwork cards and
                        // the catalogue shelves — on the same frame the keyboard
                        // is animating in, which is what the lag was. Both stay
                        // mounted and only their opacity changes, so focus costs
                        // nothing.
                        ZStack {
                            SearchBrowseSection(artwork: browseArtwork,
                                                onOpen: { discoverPath.append($0) })
                                .opacity(isSearchFocused ? 0 : 1)
                                .allowsHitTesting(!isSearchFocused)
                                .accessibilityHidden(isSearchFocused)

                            if isSearchFocused {
                                historyPanel
                                    .background(Color.mixBackground)
                            }
                        }
                    }
                }
                #if os(iOS)
                .mixAnimation(.easeInOut(duration: 0.22), value: isActive)
                #endif
            }
            .miniPlayerSafeArea()
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Search")
            #endif
            .navigationDestination(for: Album.self)  { AlbumDetailView(album: $0).environmentObject(deps) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).environmentObject(deps) }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0).environmentObject(deps)
            }
            .navigationDestination(for: UserProfile.self) { profile in
                ProfilePageView(profile: profile)
                    .environmentObject(deps)
                    .miniPlayerSafeArea()
            }
            #if os(iOS)
            .navigationDestination(for: DiscoverDestination.self) { dest in
                discoverPage(dest)
            }
            #endif
            .navigationDestination(for: BrowseCategory.self) { category in
                SearchCategoryListView(category: category)
                    .environmentObject(deps)
                    .environmentObject(engine)
                    .miniPlayerSafeArea()
            }
        }
        // Debounce the query and recompute results only when it changes — not on
        // unrelated @Published changes like engine.state.isPlaying.
        .task(id: deps.libraryService.revision) { loadBrowseArtwork() }
        .task(id: queryTaskID) {
            await updateResults()
        }
        #if os(iOS)
        // Pressing the Search tab while Search is already up raises the field —
        // the same gesture that focuses the bar on Spotify. See
        // `IOSAppState.goToSearch()` for why a token and not the tab itself.
        .onChange(of: iosAppState.searchTapToken) { _, _ in isSearchFocused = true }
        // The field searches the catalogue too. Run from here rather than from
        // the results view: that view is inside the branch that only draws when
        // the *library* matched something, so a song you don't own could never
        // put it on screen to start its own search.
        .task(id: query) {
            catalogue.search(query, using: deps.itunesClient)
            history.update(query: query, using: deps.itunesClient, library: deps.libraryService)
        }
        #endif
        .task(id: queryTaskID) {
            // Last section on the page, so it can afford a few more than the
            // four the old People tab left room for.
            await people.search(query, using: deps.authService, limit: 8)
        }
    }

    private var queryTaskID: String { query }

    // MARK: - Filtering

    /// Debounced, off-render-path filtering. Reads a snapshot of the library
    /// once, fuzzy-matches against a single pre-trimmed query string, and ranks
    /// by relevance so the best matches surface first.
    private func updateResults() async {
        let needle = query.trimmingCharacters(in: .whitespaces)

        guard !needle.isEmpty else {
            isFiltering = false
            matchingTracks  = []
            matchingAlbums  = []
            matchingArtists = []
            return
        }

        isFiltering = true

        // ~250ms debounce; cancelled automatically when the task id changes.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        // Snapshot the library on the main actor.
        let tracks  = deps.libraryService.displayTracks
        let albums  = deps.libraryService.albums
        let artists = deps.libraryService.artists


        // Fuzzy-scoring a five-figure library is tens of milliseconds of string
        // work, and it used to run right here — on the main actor, once per
        // keystroke. That is exactly the budget a frame has, so typing stuttered
        // in proportion to how much music you own.
        //
        // The models can't leave the actor (SwiftData classes aren't Sendable),
        // so what crosses is their text and their position: plain strings out,
        // ranked indices back, and the rows are looked up here afterwards
        // against the same arrays we snapshotted a moment ago.
        let trackFields  = tracks.map { [$0.title, $0.artistName, $0.albumTitle] }
        let albumFields  = albums.map { [$0.title, $0.artistName] }
        let artistNames  = artists.map(\.name)

        let ranked = await Task.detached(priority: .userInitiated) { () -> RankedIndices in
            RankedIndices(
                tracks:  Self.rankIndices(trackFields, cap: 60) {
                    SearchFuzzyMatch.bestScore(needle: needle, fields: $0)
                },
                albums:  Self.rankIndices(albumFields, cap: 40) {
                    SearchFuzzyMatch.bestScore(needle: needle, fields: $0)
                },
                artists: Self.rankIndices(artistNames, cap: 40) {
                    SearchFuzzyMatch.score(needle: needle, in: $0)
                }
            )
        }.value

        if Task.isCancelled { return }
        matchingTracks  = ranked.tracks.map  { tracks[$0]  }
        matchingAlbums  = ranked.albums.map  { albums[$0]  }
        matchingArtists = ranked.artists.map { artists[$0] }
        isFiltering = false
    }

    /// What the off-actor pass hands back: positions, not rows.
    private struct RankedIndices: Sendable {
        var tracks:  [Int]
        var albums:  [Int]
        var artists: [Int]
    }

    /// Score every element, drop misses, sort by descending relevance, cap —
    /// and return where the survivors sat rather than the values themselves.
    private nonisolated static func rankIndices<T>(_ items: [T], cap: Int,
                                                   score: (T) -> Int?) -> [Int] {
        items.enumerated()
            .compactMap { pair -> (Int, Int)? in score(pair.element).map { (pair.offset, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(cap)
            .map(\.0)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: MixtapeIcons.search)
                    .foregroundStyle(fieldIsBright ? Color.black : Color.mixTextSecondary)
                    .font(.system(size: 17, weight: .semibold))

                TextField("", text: $query,
                          prompt: Text("What do you want to listen to?")
                            .foregroundStyle(fieldIsBright ? Color.black.opacity(0.6) : Color.mixTextSecondary))
                    .font(.mixBodyBold)
                    .foregroundStyle(fieldIsBright ? Color.black : Color.mixTextPrimary)
                    .focused($isSearchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { history.rememberTerm(query) }

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: MixtapeIcons.closeCircle)
                            .foregroundStyle(Color.mixTextTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -10)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(fieldIsBright ? Color.white : Color.mixSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            #if os(iOS)
            if isActive {
                Button("Cancel") {
                    query = ""
                    isSearchFocused = false
                    history.clear()
                }
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .frame(minHeight: 44)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            #endif
        }
    }

    #if !os(iOS)
    private var fieldIsBright: Bool { false }
    #endif

    /// True when the catalogue has neither an answer nor a request in flight.
    /// Always true off iOS, where this field searches the library alone.
    private var catalogueIsQuiet: Bool {
        #if os(iOS)
        return catalogue.results.isEmpty && !catalogue.isSearching
        #else
        return true
        #endif
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResults: some View {
        let tracks  = matchingTracks
        let albums  = matchingAlbums
        let artists = matchingArtists
        // People arrive after the library results and must count towards

        // "is there anything here", or a username-only match reads as no results.
        let local   = tracks.isEmpty && albums.isEmpty && artists.isEmpty
                        && people.results.isEmpty && !people.isSearching
        // "Nothing in your library" is not "no results". Deciding this from the
        // library alone is what made the field look local-only: a query only the
        // catalogue could answer fell straight through to the empty state, and
        // the section that would have shown the answer never got to run.
        let empty   = local && catalogueIsQuiet

        if isFiltering && empty {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { _ in
                        TrackRowSkeleton()
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 12)
            }
        } else if empty {
            EmptyStateView(
                icon: MixtapeIcons.search,
                title: "No results for \"\(query)\"",
                message: "Try a different spelling or search term."
            )
            .frame(maxHeight: .infinity)
        } else {
            #if os(iOS)
            iosResults
            #else
            List {
                if !tracks.isEmpty {
                    Section(header: sectionHeader("Songs")) {
                        ForEach(tracks) { track in
                            trackRow(track)
                        }
                    }
                }


                if !albums.isEmpty {
                    Section(header: sectionHeader("Albums")) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                albumRow(album)
                            }
                            .listRowBackground(Color.mixBackground)
                            .listRowSeparatorTint(Color.mixSeparator)
                        }
                    }
                }

                if !artists.isEmpty {
                    Section(header: sectionHeader("Artists")) {
                        ForEach(artists) { artist in
                            NavigationLink(value: artist) {
                                artistRow(artist)
                            }
                            .listRowBackground(Color.mixBackground)
                            .listRowSeparatorTint(Color.mixSeparator)
                        }
                    }
                }


                peopleSection
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .mixPullToRefresh(deps)
            #endif
        }
    }

    #if os(iOS)
    /// Spotify's order: the catalogue answer — the top result, its records, its
    /// songs, its neighbours — under sticky filter pills. Your own copies and
    /// people follow on All only; a filter is a question about the catalogue.
    private var iosResults: some View {
        VStack(spacing: 0) {
            if !catalogue.results.isEmpty {
                IOSFilterPills(filters: IOSSearchFilter.allCases, selection: $resultFilter)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    IOSSearchResults(query: query, filter: $resultFilter) { dest in
                        remember(dest)
                        discoverPath.append(dest)
                    }
                    if resultFilter == .all {
                        libraryMatches
                        peopleRows
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .onChange(of: query) {
            libraryExpanded = false
            resultFilter = .all
        }
    }

    /// A catalogue page the user opened, kept as a recent so tapping it again
    /// goes straight back there instead of retyping the name.
    private func remember(_ dest: DiscoverDestination) {
        switch dest {
        case .artist(let artist): history.remember(SearchSuggestion(artist: artist))
        case .album(let album):   history.remember(SearchSuggestion(album: album))
        default: break
        }
    }

    /// Collapsed by default.
    ///
    /// What you own matches nearly every query, so expanded this section pushed
    /// the catalogue results — the reason you searched instead of scrolling the
    /// library — a screen and a half down. It stays one line until asked.
    @ViewBuilder
    private var libraryMatches: some View {
        let count = matchingTracks.count + matchingAlbums.count + matchingArtists.count
        if count > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { libraryExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        discoverSectionHeader("In your library")
                        Text("\(count)")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextTertiary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.mixTextSecondary)
                            .rotationEffect(.degrees(libraryExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()

                if libraryExpanded {
                    if !matchingTracks.isEmpty {
                        LocalMatchesSection(
                            query: query,
                            tracks: matchingTracks,
                            onPlay: { track, context in
                                Task { await engine.play(track: track, in: context, source: .named("Search results")) }
                            },
                            showsHeader: false
                        )
                    }

                    if !matchingAlbums.isEmpty {
                        ForEach(matchingAlbums.prefix(3)) { album in
                            NavigationLink(value: album) { albumRow(album) }
                                .buttonStyle(.plain).mixHandCursor()
                        }
                    }

                    if !matchingArtists.isEmpty {
                        ForEach(matchingArtists.prefix(3)) { artist in
                            NavigationLink(value: artist) { artistRow(artist) }
                                .buttonStyle(.plain).mixHandCursor()
                        }
                    }
                }
            }
        }
    }

    /// Last, and short: searching here is searching your music almost every
    /// time, and people shouldn't push songs off the screen to prove they exist.
    @ViewBuilder
    private var peopleRows: some View {
        if !people.results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                discoverSectionHeader("People")
                ForEach(people.results) { profile in
                    NavigationLink(value: profile) {
                        PersonResultRow(profile: profile, showsChevron: false)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
            }
        }
    }
    #endif

    // MARK: - People

    /// Last section, and under "All" only the first few — searching here is
    /// searching your music almost every time, and people shouldn't push songs
    /// off the screen to prove they're available.
    @ViewBuilder
    private var peopleSection: some View {
        if !people.results.isEmpty {
            Section(header: sectionHeader("People")) {
                ForEach(people.results) { profile in
                    NavigationLink(value: profile) {
                        PersonResultRow(profile: profile, showsChevron: false)
                    }
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                }

            }
        } else if people.isSearching {
            Section(header: sectionHeader("People")) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .listRowBackground(Color.mixBackground)
            }
        }
    }

    // MARK: - Rows

    private func trackRow(_ track: Track) -> some View {
        TrackRowView(
            track:          track,
            isCurrent:      engine.queue.currentTrack?.id == track.id,
            isPlaying:      engine.state.isPlaying,
            availability: deps.downloadManager.status(for: track.id),
            isResolving:    engine.routingTrackIDs.contains(track.id)
        )
        .listRowBackground(Color.mixBackground)
        .listRowSeparatorTint(Color.mixSeparator)
        .contentShape(Rectangle())
        // The results, not the whole library: handing over every song meant the
        // context lane never ran out, so the suggestion service never got to
        // follow a searched-for song with anything like it — it just played the
        // library in order from wherever that song happened to sit.
        .onTapGesture {
            Haptics.play(.light)
            Task { await engine.play(track: track, in: matchingTracks, source: .named("Search results")) }
        }
        .contextMenu {
            Button("Play Now") {
                Task { await engine.play(track: track, in: matchingTracks, source: .named("Search results")) }
            }
            Button("Play Next") { engine.queue.insertNext(track) }
            Button("Add to Queue") { engine.queue.append(track) }
            Divider()
            let favoured = deps.libraryService.isFavourited(trackID: track.id)
            Button(favoured ? "Remove from Liked Songs" : "Add to Liked Songs", systemImage: favoured ? "heart.fill" : "heart") {
                deps.toggleFavourite(trackID: track.id)
            }
            let targetPlaylists = deps.libraryService.playlists.filter { !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id) }
            if !targetPlaylists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(targetPlaylists) { pl in
                        Button(pl.name) {
                            deps.addTrack(id: track.id, toPlaylist: pl.id)
                        }
                    }
                }
            }
            Divider()
            ShareMenuItems(.track(track))
            Divider()
            DownloadMenuItems(track: track, downloads: deps.downloadManager)
        }
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                data: album.artworkData, artworkRef: .album(album.id), size: 44,
                cornerRadius: 6, placeholder: MixtapeIcons.album
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(album.artistName)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func artistRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                data: artist.artworkData, artworkRef: .artist(artist.id), size: 44,
                cornerRadius: 22, placeholder: MixtapeIcons.artist
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text("\(artist.trackCount) songs")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - History (focused, nothing typed)

    /// Past searches, drawn like the Mac's dropdown: real artwork, the full
    /// title, and what the row actually is underneath it. A recent is only kept
    /// for things that can show all three — a catalogue artist, album or song,
    /// or a term you typed — so the list never fills with grey squares.
    @ViewBuilder
    private var historyPanel: some View {
        if history.recents.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.mixTextTertiary)
                Text("Your recent searches show up here.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("Recent searches")
                        .font(.mixTitle2.bold())
                        .foregroundStyle(Color.mixTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    ForEach(history.recents) { row in
                        historyRow(row)
                    }

                    Button { history.clearRecents() } label: {
                        Text("Clear recent searches")
                            .font(.mixButtonSmall)
                            .foregroundStyle(Color.mixTextPrimary)
                            .padding(.horizontal, 20)
                            .frame(height: 34)
                            .overlay(Capsule().stroke(Color.mixTextTertiary, lineWidth: 1))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .padding(.top, 16)
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    #if os(iOS)
    /// Completions while typing: terms first, the way the catalogue ranks them,
    /// then the artists, albums and songs they point at.
    private var suggestionsPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(history.suggestions) { row in
                    if case .term = row.kind {
                        termRow(row)
                    } else {
                        historyRow(row, removable: false)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.mixBackground)
    }

    /// A completion: tap to search it, ↖ to put it in the field and keep typing.
    private func termRow(_ row: SearchSuggestion) -> some View {
        HStack(spacing: 4) {
            Button {
                query = row.title
                history.rememberTerm(row.title)
                isSearchFocused = false
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 56, height: 48)
                    Text(typedHighlight(row.title))
                        .font(.mixBodyBold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { query = row.title } label: {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill in \(row.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// What you already typed, dimmed, so the eye lands on the completion.
    private func typedHighlight(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        text.foregroundColor = .mixTextPrimary
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let range = text.range(of: typed, options: [.caseInsensitive, .anchored]) {
            text[range].foregroundColor = .mixTextSecondary
        }
        return text
    }
    #endif

    private func historyRow(_ row: SearchSuggestion, removable: Bool = true) -> some View {
        HStack(spacing: 12) {
            Button {
                activate(row)
            } label: {
                HStack(spacing: 12) {
                    thumb(row)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.mixBodyBold)
                                .foregroundStyle(Color.mixTextPrimary)
                                .lineLimit(1)

                            if row.isExplicit {
                                Text("E")
                                    .font(.mixMicro)
                                    .foregroundStyle(Color.mixTextSecondary)
                                    .frame(width: 15, height: 15)
                                    .background(Color.mixSurface2,
                                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                        }

                        Text(row.subtitle?.isEmpty == false ? row.subtitle! : "Search")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()

            // No hover on a phone, so the cross lives here permanently.
            if removable {
                Button { history.hide(row) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Remove \(row.title) from recent searches")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// What tapping a recent does. Anything with a catalogue id behind it opens
    /// its page — that is where the user was last time — and a plain term goes
    /// back in the field and re-runs the search.
    private func activate(_ row: SearchSuggestion) {
        history.remember(row)          // back to the top of the list
        #if os(iOS)
        if let artist = row.onlineArtist {
            isSearchFocused = false
            discoverPath.append(DiscoverDestination.artist(artist))
            return
        }
        if let album = row.onlineAlbum {
            isSearchFocused = false
            discoverPath.append(DiscoverDestination.album(album))
            return
        }
        if let track = row.onlineTrack {
            isSearchFocused = false
            Task { await playOnline(track, context: [track]) }
            return
        }
        #endif
        query = row.title
    }

    /// 56pt: big enough that a cover is recognisable at a glance, which is the
    /// whole reason the row carries one.
    @ViewBuilder
    private func thumb(_ row: SearchSuggestion) -> some View {
        let size: CGFloat = 56
        if case .term = row.kind {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.mixSurface2)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .frame(width: size, height: size)
        } else {
            CachedRemoteImage(url: row.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: row.placeholderIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: row.isCircular ? size / 2 : 6,
                                        style: .continuous))
        }
    }



    #if os(iOS)
    /// One pushed catalogue page. Mirrors the Discover tab's destination
    /// switch — the pages are shared, only the stack they push onto differs.
    @ViewBuilder
    private func discoverPage(_ dest: DiscoverDestination) -> some View {
        switch dest {
        case .album(let album):
            IOSDiscoverAlbumPage(
                album: album,
                onPlay: { track, ctx in Task { await playOnline(track, context: ctx) } },
                onOpenArtist: { discoverPath.append(DiscoverDestination.artist($0)) }
            )
            .miniPlayerSafeArea()
        case .artist(let artist):
            IOSDiscoverArtistPage(
                artist: artist,
                onOpenAlbum: { discoverPath.append(DiscoverDestination.album($0)) },
                onOpenArtist: { discoverPath.append(DiscoverDestination.artist($0)) },
                onOpenLiked: { discoverPath.append(DiscoverDestination.likedSongs(artist)) },
                onPlay: { track, ctx in Task { await playOnline(track, context: ctx) } },
                onOpenMix: { discoverPath.append(DiscoverDestination.mix($0)) }
            )
            .miniPlayerSafeArea()
        case .mix(let mix):
            MixDetailPage(
                mix: mix,
                onPlay: { track, ctx in Task { await playOnline(track, context: ctx) } },
                onShuffle: {
                    let shuffled = mix.tracks.shuffled()
                    guard let first = shuffled.first else { return }
                    Task { await playOnline(first, context: shuffled) }
                },
                resolvingID: coordinator.resolvingID,
                onOpenArtist: { name in
                    Task {
                        if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: nil) {
                            await MainActor.run { discoverPath.append(DiscoverDestination.artist(artist)) }
                        }
                    }
                }
            )
            .navigationTitle(mix.title)
            .navigationBarTitleDisplayMode(.inline)
            .miniPlayerSafeArea()
        case .likedSongs(let artist):
            DiscoverLikedSongsPage(artist: artist).miniPlayerSafeArea()
        case .genre(let genre):
            IOSDiscoverGenrePage(genre: genre) { discoverPath.append(DiscoverDestination.artist($0)) }
                .miniPlayerSafeArea()
        default:
            // Profiles are only reachable from the Discover tab; a
            // stack that cannot produce them needs no page for them.
            EmptyView()
        }
    }

    /// Fetch the cover before starting, so the mini player has something to show
    /// the moment audio begins rather than a grey square that fills in later.
    private func playOnline(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }
    #endif

    // MARK: - Helpers

    /// Picks the cover each browse card wears.
    ///
    /// Deliberately the *newest* thing in each bucket rather than the first:
    /// the grid then changes as the library does, which is the whole reason to
    /// use real artwork instead of a flat colour.
    private func loadBrowseArtwork() {
        let library = deps.libraryService
        var picked: [BrowseCategory: ArtworkRef?] = [:]

        let newestTrack = library.tracks.max { $0.dateImported < $1.dateImported }
        picked[.songs]  = newestTrack.map { ArtworkRef.track($0.id) }
        picked[.albums] = library.albums.first.map  { ArtworkRef.album($0.id)  }
        // An artist without a photo would draw the card's fallback glyph, which
        // is worse than the next artist along who has one.
        picked[.artists] = library.artists.first { $0.artworkData != nil }
            .map { ArtworkRef.artist($0.id) }
        picked[.playlists] = library.playlists
            .first { !$0.isDeleted && !$0.isAllSongs }
            .map { ArtworkRef.playlist($0.id) }
        picked[.favorites] = library.tracks.first { library.isFavourited(trackID: $0.id) }
            .map { ArtworkRef.track($0.id) }
        picked[.recent] = engine.recentlyPlayed.first.map { ArtworkRef.track($0.id) }

        browseArtwork = picked
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .textCase(nil)
    }
}

// MARK: - Search Scope

enum SearchScope: String, CaseIterable, Identifiable {
    // `.online` is iOS-only in practice — the Mac has the Discover window for
    // this — but the case exists on both so the scope type stays one type.
    case all, songs, artists, albums, online, people
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:     return "All"
        case .songs:   return "Songs"
        case .artists: return "Artists"
        case .albums:  return "Albums"
        case .online:  return "Mixtape"
        case .people:  return "People"
        }
    }
}

// MARK: - Browse (no active search)

/// The landing, as its own view.
///
/// Split out for one reason: focusing the field used to re-run `SearchView`'s
/// body, and this tree — six artwork cards plus the catalogue shelves — was
/// re-diffed on every keystroke and every keyboard frame. Its inputs don't
/// change while you type, so SwiftUI now skips it entirely.
private struct SearchBrowseSection: View {

    let artwork: [BrowseCategory: ArtworkRef?]
    let onOpen: (DiscoverDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                Text("Your library")
                    .font(.mixTitle.bold())
                    .foregroundStyle(Color.mixTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(BrowseCategory.allCases) { category in
                        NavigationLink(value: category) {
                            BrowseCategoryCard(category: category,
                                               artwork: artwork[category] ?? nil)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                }
                .padding(.horizontal, 16)

                #if os(iOS)
                SearchDiscoverBrowse(onOpen: onOpen)
                    .padding(.top, 18)
                #endif
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Browse Category

enum BrowseCategory: String, CaseIterable, Identifiable, Hashable {
    case songs     = "Songs"
    case albums    = "Albums"
    case artists   = "Artists"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case recent    = "Recently Played"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .songs:     return MixtapeIcons.track
        case .albums:    return MixtapeIcons.album
        case .artists:   return MixtapeIcons.artist
        case .playlists: return MixtapeIcons.playlist
        case .favorites: return MixtapeIcons.heart
        case .recent:    return MixtapeIcons.clock
        }
    }

    var color: Color {
        switch self {
        case .songs:     return Color(hex: "#6366F1")
        case .albums:    return Color(hex: "#8B5CF6")
        case .artists:   return Color(hex: "#EC4899")
        case .playlists: return Color(hex: "#F59E0B")
        case .favorites: return Color(hex: "#EF4444")
        case .recent:    return Color(hex: "#10B981")
        }
    }
}

/// A browse tile: the category's name on its colour, with a real cover from
/// the library tilted into the corner.
///
/// The tilt and the overhang are doing a specific job — a square sitting flat
/// in the corner reads as a thumbnail attached to a label, where one rotated
/// and pushed past the edge reads as a stack of records the card is a lid on.
/// It also means the card survives a cover that is missing, badly cropped or
/// nearly the same colour as the tile: it is decoration over a solid ground,
/// never the thing carrying the meaning.
private struct BrowseCategoryCard: View {

    let category: BrowseCategory
    /// The cover to tilt into the corner, or nil for the glyph — a library with
    /// no playlists in it has nothing honest to put on the Playlists card.
    var artwork: ArtworkRef?

    private var height: CGFloat { 104 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            category.color

            corner
                .frame(width: 68, height: 68)
                .rotationEffect(.degrees(22))
                .mixShadow(color: .black.opacity(0.35), radius: 8, x: -2, y: 4)
                // Past the card's own edge on two sides, so the clip below cuts
                // it and it reads as coming from underneath.
                .offset(x: 16, y: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            Text(category.rawValue)
                .font(.mixBodyBold)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .padding(12)
                // Never let a long name run under the cover.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.rawValue)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var corner: some View {
        if let artwork {
            AsyncArtworkImage(source: .row(artwork), size: 68) {
                glyph
            }
        } else {
            glyph
        }
    }

    /// The card still has to look like something when the library can't fill
    /// it, so the old icon stays as the empty state rather than a grey square.
    private var glyph: some View {
        ZStack {
            Color.black.opacity(0.22)
            Image(systemName: category.icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - Browse Category List (destination for a tapped browse card)

struct SearchCategoryListView: View {

    let category: BrowseCategory

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    /// Bumped whenever the download manager publishes.
    ///
    /// This view reads download state (`status(for:)` and friends) straight off
    /// the manager inside `body`, which is not observation — nothing here holds
    /// the manager, so nothing here hears it change. `AppDependencies` used to
    /// rebroadcast every service's publishes, which covered this by invalidating
    /// all 81 views that hold `deps` on every status transition. The views that
    /// actually draw download state say so themselves now.
    @State private var downloadTick = 0

    var body: some View {
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()
            content
        }
        .navigationTitle(category.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .songs:     trackList(deps.libraryService.displayTracks)
        case .favorites: trackList(favoriteTracks)
        case .recent:    trackList(engine.recentlyPlayed)
        case .albums:    albumList(deps.libraryService.albums)
        case .artists:   artistList(deps.libraryService.artists)
        case .playlists: playlistList(deps.libraryService.playlists.filter { !$0.isDeleted })
        }
    }

    private var favoriteTracks: [Track] {
        guard let fav = deps.libraryService.playlists.first(where: { $0.isFavourites }) else { return [] }
        return fav.trackIDs.compactMap { deps.libraryService.track(id: $0) }
    }

    // MARK: Lists

    @ViewBuilder
    private func trackList(_ tracks: [Track]) -> some View {
        if tracks.isEmpty {
            emptyState(icon: category.icon, message: "Nothing here yet.")
        } else {
            List {
                ForEach(tracks) { track in
                    TrackRowView(
                        track:          track,
                        isCurrent:      engine.queue.currentTrack?.id == track.id,
                        isPlaying:      engine.state.isPlaying,
                        availability: deps.downloadManager.status(for: track.id),
                        isResolving:    engine.routingTrackIDs.contains(track.id)
                    )
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.play(.light)
                        Task { await engine.play(track: track, in: tracks, source: .named("Search results")) }
                    }
                }
            }
            .styledList()
        }
    }

    @ViewBuilder
    private func albumList(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            emptyState(icon: category.icon, message: "No albums yet.")
        } else {
            List {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(data: album.artworkData, artworkRef: .album(album.id), size: 44, cornerRadius: 6, placeholder: MixtapeIcons.album)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title).font(.mixBodyBold).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
                                Text(album.artistName).font(.mixLabel).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                }
            }
            .styledList()
        }
    }

    @ViewBuilder
    private func artistList(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            emptyState(icon: category.icon, message: "No artists yet.")
        } else {
            List {
                ForEach(artists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(data: artist.artworkData, artworkRef: .artist(artist.id), size: 44, cornerRadius: 22, placeholder: MixtapeIcons.artist)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artist.name).font(.mixBodyBold).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
                                Text("\(artist.trackCount) songs").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                }
            }
            .styledList()
        }
    }

    @ViewBuilder
    private func playlistList(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            emptyState(icon: category.icon, message: "No playlists yet.")
        } else {
            List {
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        HStack(spacing: 12) {
                            PlaylistArtwork(playlist: playlist, size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.mixBodyBold).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
                                Text("\(playlist.trackIDs.count) songs").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                }
            }
            .styledList()
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        EmptyStateView(icon: icon, title: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func styledList() -> some View {
        #if os(iOS)
        self.listStyle(.plain).scrollContentBackground(.hidden)
        #else
        self.listStyle(.inset).scrollContentBackground(.hidden)
        #endif
    }
}

// MARK: - Preview

#Preview {
    SearchView()
        .environmentObject(AppDependencies())
        .environmentObject(PlaybackEngine(
            queue:       QueueService(),
            fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
            equalizer:   AudioEqualizer()
        ))
}
