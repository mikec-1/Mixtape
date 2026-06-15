// SearchView.swift
// Mixtape — Features/Search

import SwiftUI

public struct SearchView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var scope: SearchScope = .all

    // Filtered + relevance-ranked results, computed off the hot render path and
    // stored here so the List reads cached arrays instead of re-filtering on
    // every body eval.
    @State private var matchingTracks:  [Track]  = []
    @State private var matchingAlbums:  [Album]  = []
    @State private var matchingArtists: [Artist] = []
    @State private var isFiltering = false

    // Recent searches persisted across launches (newline-delimited, newest first).
    @AppStorage("search.recentQueries") private var recentQueriesRaw: String = ""

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var recentQueries: [String] {
        recentQueriesRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    if isSearching {
                        scopePicker
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }

                    Divider().background(Color.mixSeparator)

                    if isSearching {
                        searchResults
                    } else {
                        browseSection
                    }
                }
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .navigationDestination(for: Album.self)  { AlbumDetailView(album: $0).environmentObject(deps) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).environmentObject(deps) }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0).environmentObject(deps)
            }
            .navigationDestination(for: BrowseCategory.self) { category in
                SearchCategoryListView(category: category)
                    .environmentObject(deps)
                    .environmentObject(engine)
            }
        }
        // Debounce the query and recompute results only when the (trimmed) query
        // or active scope changes — not on unrelated @Published changes like
        // engine.state.isPlaying.
        .task(id: queryTaskID) {
            await updateResults()
        }
    }

    // Combine query + scope so changing either re-runs the debounced filter.
    private var queryTaskID: String { "\(scope.rawValue)\u{1}\(query)" }

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
        let tracks  = deps.libraryService.tracks
        let albums  = deps.libraryService.albums
        let artists = deps.libraryService.artists

        let wantTracks  = scope == .all || scope == .songs
        let wantAlbums  = scope == .all || scope == .albums
        let wantArtists = scope == .all || scope == .artists

        let rankedTracks: [Track] = wantTracks ? rank(tracks, cap: 60) {
            SearchFuzzyMatch.bestScore(needle: needle, fields: [$0.title, $0.artistName, $0.albumTitle])
        } : []

        let rankedAlbums: [Album] = wantAlbums ? rank(albums, cap: 40) {
            SearchFuzzyMatch.bestScore(needle: needle, fields: [$0.title, $0.artistName])
        } : []

        let rankedArtists: [Artist] = wantArtists ? rank(artists, cap: 40) {
            SearchFuzzyMatch.score(needle: needle, in: $0.name)
        } : []

        if Task.isCancelled { return }
        matchingTracks  = rankedTracks
        matchingAlbums  = rankedAlbums
        matchingArtists = rankedArtists
        isFiltering = false
    }

    /// Score every element, drop misses, sort by descending relevance, cap.
    private func rank<T>(_ items: [T], cap: Int, score: (T) -> Int?) -> [T] {
        items
            .compactMap { item -> (T, Int)? in score(item).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(cap)
            .map { $0.0 }
    }

    // MARK: - Recent searches

    private func recordRecentSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        var list = recentQueries.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentQueriesRaw = list.prefix(8).joined(separator: "\n")
    }

    private func clearRecentSearches() { recentQueriesRaw = "" }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: MixtapeIcons.search)
                .foregroundStyle(Color.mixTextTertiary)
                .font(.system(size: 15))

            TextField("Songs, artists, albums…", text: $query)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { recordRecentSearch() }

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: MixtapeIcons.closeCircle)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .padding(12)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var scopePicker: some View {
        Picker("Filter", selection: $scope) {
            ForEach(SearchScope.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResults: some View {
        let tracks  = matchingTracks
        let albums  = matchingAlbums
        let artists = matchingArtists
        let empty   = tracks.isEmpty && albums.isEmpty && artists.isEmpty

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
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Rows

    private func trackRow(_ track: Track) -> some View {
        TrackRowView(
            track:          track,
            isCurrent:      engine.queue.currentTrack?.id == track.id,
            isPlaying:      engine.state.isPlaying,
            downloadStatus: deps.downloadManager.status(for: track.id)
        )
        .listRowBackground(Color.mixBackground)
        .listRowSeparatorTint(Color.mixSeparator)
        .contentShape(Rectangle())
        .onTapGesture {
            // Play in full library context so queue continues.
            Haptics.play(.light)
            Task { await engine.play(track: track, in: deps.libraryService.tracks) }
        }
        .contextMenu {
            Button("Play Now") {
                Task { await engine.play(track: track, in: deps.libraryService.tracks) }
            }
            Button("Play Next") { engine.queue.insertNext(track) }
            Button("Add to Queue") { engine.queue.append(track) }
            Divider()
            let favoured = deps.libraryService.isFavourited(trackID: track.id)
            Button(favoured ? "Remove from Favourites" : "Add to Favourites", systemImage: favoured ? "heart.fill" : "heart") {
                deps.libraryService.toggleFavourite(trackID: track.id)
            }
            let targetPlaylists = deps.libraryService.playlists.filter { !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id) }
            if !targetPlaylists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(targetPlaylists) { pl in
                        Button(pl.name) {
                            deps.libraryService.addTrack(id: track.id, toPlaylist: pl.id)
                        }
                    }
                }
            }
            if deps.downloadManager.status(for: track.id) != .notDownloaded {
                Divider()
                Button("Remove Download", systemImage: "xmark.circle") {
                    deps.downloadManager.removeDownload(for: track.id)
                }
            }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                data: album.artworkData, size: 44,
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
                data: artist.artworkData, size: 44,
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

    // MARK: - Browse (no active search)

    private var browseSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                if !recentQueries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent searches")
                                .font(.mixTitle2)
                                .foregroundStyle(Color.mixTextPrimary)
                            Spacer()
                            Button("Clear") { clearRecentSearches() }
                                .font(.mixLabel)
                                .foregroundStyle(Color.mixPrimary)
                        }
                        ForEach(recentQueries, id: \.self) { term in
                            Button {
                                query = term
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: MixtapeIcons.clock)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.mixTextTertiary)
                                    Text(term)
                                        .font(.mixBody)
                                        .foregroundStyle(Color.mixTextPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.mixTextTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Text("Browse")
                    .font(.mixTitle2)
                    .foregroundStyle(Color.mixTextPrimary)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(BrowseCategory.allCases) { category in
                        NavigationLink(value: category) {
                            BrowseCategoryCard(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .textCase(nil)
    }
}

// MARK: - Search Scope

enum SearchScope: String, CaseIterable, Identifiable {
    case all, songs, artists, albums
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:     return "All"
        case .songs:   return "Songs"
        case .artists: return "Artists"
        case .albums:  return "Albums"
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

private struct BrowseCategoryCard: View {
    let category: BrowseCategory

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(category.color.opacity(0.25))
                .frame(height: 90)

            HStack {
                Text(category.rawValue)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                Image(systemName: category.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(category.color)
                    .rotationEffect(.degrees(8))
                    .offset(x: 8, y: -8)
            }
            .padding(12)
        }
    }
}

// MARK: - Browse Category List (destination for a tapped browse card)

struct SearchCategoryListView: View {

    let category: BrowseCategory

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    var body: some View {
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
        case .songs:     trackList(deps.libraryService.tracks)
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
                        downloadStatus: deps.downloadManager.status(for: track.id)
                    )
                    .listRowBackground(Color.mixBackground)
                    .listRowSeparatorTint(Color.mixSeparator)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.play(.light)
                        Task { await engine.play(track: track, in: tracks) }
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
                            ArtworkThumbnail(data: album.artworkData, size: 44, cornerRadius: 6, placeholder: MixtapeIcons.album)
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
                            ArtworkThumbnail(data: artist.artworkData, size: 44, cornerRadius: 22, placeholder: MixtapeIcons.artist)
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
                            ArtworkThumbnail(data: playlist.artworkData, size: 44, cornerRadius: 6, placeholder: MixtapeIcons.playlist)
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
