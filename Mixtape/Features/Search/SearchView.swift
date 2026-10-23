import SwiftUI
import Combine

public struct SearchView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    #if os(iOS)
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator
    @Environment(IOSAppState.self) private var iosAppState
    #endif

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    // Filtered, ranked results cached here so body doesn't re-filter.
    @State private var matchingTracks:  [Track]  = []
    @State private var matchingAlbums:  [Album]  = []
    @State private var matchingArtists: [Artist] = []
    @State private var isFiltering = false

    /// Server-side people search, on its own debounce.
    @StateObject private var people = PeopleSearch()

    #if os(iOS)
    /// The catalogue half of the field, shared with Discover. Observed here because this
    /// view decides whether there are any results.
    private var catalogue: DiscoverSessionStore { .shared }
    #endif

    // Recent searches persisted across launches (newline-delimited, newest first).

    /// Past searches, shared with the Mac's dropdown. See `SearchSuggestionsStore`.
    private var history: SearchSuggestionsStore { .shared }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @State private var resultFilter: IOSSearchFilter = .all

    /// Focused or holding a query: hides the title, shows Cancel.
    private var isActive: Bool { isSearchFocused || isSearching }

    /// Completions while typing; losing focus shows the results.
    private var showsSuggestions: Bool {
        isSearchFocused && !history.isDismissed && !history.suggestions.isEmpty
    }

    /// Spotify's landing field is a white slab on the dark page.
    private var fieldIsBright: Bool { !isActive && colorScheme == .dark }
    #endif

    /// Collapse state of the library section, reset per query.
    @State private var libraryExpanded = false

    /// One real library cover per browse card, filled by a `.task` rather than in `body`.
    @State private var browseArtwork: [BrowseCategory: ArtworkRef?] = [:]

    /// Untyped: it carries library values and, on iOS, catalogue destinations.
    @State private var discoverPath = NavigationPath()

    // MARK: - Body

    /// Bumped on download manager publishes, since `body` reads download state without observing it.
    @State private var downloadTick = 0

    public var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        NavigationStack(path: $discoverPath) {
            ZStack {
                MixPageBackground()

                VStack(spacing: 0) {
                    #if os(iOS)
                    // Drawn here rather than as a large nav title, which re-measures on every keystroke.
                    // Hidden while the field is in use.
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
                        // Focused and empty: past searches. Layered, not branched, so focusing doesn't
                        // tear down the browse tree while the keyboard animates.
                        ZStack {
                            SearchBrowseSection(artwork: browseArtwork,
                                                onOpen: { discoverPath.append($0) })
                                .opacity(isSearchFocused ? 0 : 1)
                                .allowsHitTesting(!isSearchFocused)
                                .accessibilityHidden(isSearchFocused)

                            if isSearchFocused {
                                historyPanel
                                    .background(MixPageBackground())
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
            .navigationDestination(for: Album.self)  { AlbumDetailView(album: $0).environment(deps) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).environment(deps) }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0).environment(deps)
            }
            .navigationDestination(for: UserProfile.self) { profile in
                ProfilePageView(profile: profile)
                    .environment(deps)
                    .miniPlayerSafeArea()
            }
            #if os(iOS)
            .navigationDestination(for: DiscoverDestination.self) { dest in
                discoverPage(dest)
            }
            #endif
            .navigationDestination(for: BrowseCategory.self) { category in
                SearchCategoryListView(category: category)
                    .environment(deps)
                    .environment(engine)
                    .miniPlayerSafeArea()
            }
        }
        .task(id: deps.libraryService.revision) { loadBrowseArtwork() }
        // Recompute only when the query changes, not on unrelated publishes.
        .task(id: queryTaskID) {
            await updateResults()
        }
        #if os(iOS)
        // Tapping the Search tab again raises the field, back on the root page since a pushed one hides it.
        // A task, so a request made before this appeared is still picked up.
        .task(id: iosAppState.searchFocusRequested) {
            guard iosAppState.searchFocusRequested else { return }
            if !discoverPath.isEmpty { discoverPath = NavigationPath() }
            // Right after the tab appears the field can't take focus yet, so keep asking for a moment.
            // The flag clears after, since clearing it restarts this task.
            for _ in 0..<30 where !isSearchFocused {
                isSearchFocused = true
                try? await Task.sleep(for: .milliseconds(50))
            }
            iosAppState.searchFocusRequested = false
        }
        // Catalogue search runs here: the results view only draws when the library matched.
        .task(id: query) {
            catalogue.search(query, using: deps.itunesClient)
            history.update(query: query, using: deps.itunesClient, library: deps.libraryService)
        }
        #endif
        .task(id: queryTaskID) {
            await people.search(query, using: deps.authService, limit: 8)
        }
    }

    private var queryTaskID: String { query }

    // MARK: - Filtering

    /// Debounced, off the render path: snapshot the library, fuzzy-match, rank.
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


        // Scoring runs off the main actor. SwiftData models aren't Sendable, so their
        // strings go out and ranked indices come back.
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

    /// Score, drop misses, sort by relevance, cap. Returns indices, not values.
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

    /// Nothing from the catalogue and nothing in flight. Always true off iOS.
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
        // Empty means empty everywhere, not just the library.
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
                            .listRowBackground(MixRowBackground())
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
                            .listRowBackground(MixRowBackground())
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
    /// Catalogue answer first under sticky filter pills; your copies and people follow on All only.
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

    /// A catalogue page the user opened, kept as a recent.
    private func remember(_ dest: DiscoverDestination) {
        switch dest {
        case .artist(let artist): history.remember(SearchSuggestion(artist: artist))
        case .album(let album):   history.remember(SearchSuggestion(album: album))
        default: break
        }
    }

    /// Collapsed by default: your own copies match nearly every query and would push the catalogue down.
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
                        #if os(iOS)
                        if matchingTracks.count > LocalMatchesSection.limit {
                            NavigationLink(value: DiscoverDestination.librarySongs(query)) {
                                Text("See all")
                                    .font(.mixCaption.weight(.semibold))
                                    .foregroundStyle(Color.mixAccent)
                            }
                            .buttonStyle(.plain)
                        }
                        #endif
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

    /// Last, so people don't push songs off the screen.
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

    /// Last, and only the first few under All.
    @ViewBuilder
    private var peopleSection: some View {
        if !people.results.isEmpty {
            Section(header: sectionHeader("People")) {
                ForEach(people.results) { profile in
                    NavigationLink(value: profile) {
                        PersonResultRow(profile: profile, showsChevron: false)
                    }
                    .listRowBackground(MixRowBackground())
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
                .listRowBackground(MixRowBackground())
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
        .listRowBackground(MixRowBackground())
        .listRowSeparatorTint(Color.mixSeparator)
        .contentShape(Rectangle())
        // Alone, so autoplay's recommendations follow the song.
        .onTapGesture {
            Haptics.play(.light)
            Task { await engine.play(track: track, in: [track], source: .named("Search results")) }
        }
        .contextMenu {
            LibrarySongMenu(targets: [track], onPlay: {
                Task { await engine.play(track: track, in: [track], source: .named("Search results")) }
            })
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
        .contentShape(Rectangle())
        .contextMenu { AlbumActionsMenu(album: album) }
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
        .contentShape(Rectangle())
        .contextMenu { ArtistActionsMenu(name: artist.name) }
    }

    // MARK: - History (focused, nothing typed)

    /// Past searches with real artwork, title and type. Only kept for rows that have all three.
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
    /// Completions while typing: terms first, then the artists, albums and songs.
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
        .background(MixPageBackground())
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

    /// Rows with a catalogue id open their page; a term goes back in the field.
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

    /// 56pt so the cover is recognisable.
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
    /// One pushed catalogue page, same switch as the Discover tab.
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
        case .librarySongs(let query):
            LibraryMatchesPage(query: query).miniPlayerSafeArea()
        case .genre(let genre):
            IOSDiscoverGenrePage(genre: genre) { discoverPath.append(DiscoverDestination.artist($0)) }
                .miniPlayerSafeArea()
        default:
            // Profiles are only reachable from Discover.
            EmptyView()
        }
    }

    /// Fetch the cover first so the mini player has it when audio starts.
    private func playOnline(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }
    #endif

    // MARK: - Helpers

    /// Picks each browse card's cover: the newest in each bucket, so the grid follows the library.
    private func loadBrowseArtwork() {
        let library = deps.libraryService
        var picked: [BrowseCategory: ArtworkRef?] = [:]

        let newestTrack = library.tracks.max { $0.dateImported < $1.dateImported }
        picked[.songs]  = newestTrack.map { ArtworkRef.track($0.id) }
        picked[.albums] = library.albums.first.map  { ArtworkRef.album($0.id)  }
        // Skip artists without a photo.
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
    // `.online` is iOS-only in practice, but exists on both to keep one type.
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

/// Split out so typing doesn't re-diff the browse tree; its inputs don't change while you type.
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
    case favorites = "Liked Songs"
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

/// A browse tile: the category's colour with a library cover tilted into the corner.
/// Decoration only, so a missing cover is fine.
private struct BrowseCategoryCard: View {

    let category: BrowseCategory
    /// Nil draws the glyph.
    var artwork: ArtworkRef?

    private var height: CGFloat { 104 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            category.color

            corner
                .frame(width: 68, height: 68)
                .rotationEffect(.degrees(22))
                .mixShadow(color: .black.opacity(0.35), radius: 8, x: -2, y: 4)
                // Past the edge on two sides so the clip cuts it.
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

    /// Fallback when the library has nothing for this card.
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

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine

    /// Bumped on download manager publishes, since `body` reads download state without observing it.
    @State private var downloadTick = 0

    var body: some View {
        // Read so the bump below redraws; an unread @State never does.
        let _ = downloadTick
        bodyContent
            .onReceive(deps.downloadManager.didChangeThrottled) { _ in
                downloadTick &+= 1
            }
    }

    private var bodyContent: some View {
        ZStack {
            MixPageBackground()
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
                    .listRowBackground(MixRowBackground())
                    .listRowSeparatorTint(Color.mixSeparator)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.play(.light)
                        Task { await engine.play(track: track, in: [track], source: .named("Search results")) }
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
                    .listRowBackground(MixRowBackground())
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
                    .listRowBackground(MixRowBackground())
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
                    .listRowBackground(MixRowBackground())
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
        .environment(AppDependencies())
        .environment(PlaybackEngine(
            queue:       QueueService(),
            fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
            equalizer:   AudioEqualizer()
        ))
}
