// IOSDiscoverView.swift
// Mixtape — iOS/Online
//
// iOS port of OnlineDiscoverView. On iOS the coordinator resolves audio through
// the Mac/server RemoteResolverService, then plays the downloaded .m4a. Uses a
// native NavigationStack where the Mac needs a manual path stack.

#if os(iOS)
import SwiftUI

struct IOSDiscoverView: View {
    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @State private var query = ""
    @State private var results = DiscoverResults()
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var path = NavigationPath()

    /// Pre-search landing content (trending, popular artists, new releases,
    /// genres). Loaded once on first appear so the tab is lively before a query.
    @State private var browse = BrowseLanding()
    @State private var browseLoading = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if let error = coordinator.errorMessage {
                    banner(error)
                }
                content
                    .padding(.bottom, 24)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.errorMessage)
            .background(Color.mixBackground.ignoresSafeArea())
            .navigationTitle("Discover")
            .navigationDestination(for: DiscoverDestination.self) { dest in
                switch dest {
                case .artist(let artist):
                    IOSDiscoverArtistPage(
                        artist: artist,
                        onOpenAlbum: { path.append(DiscoverDestination.album($0)) },
                        onOpenArtist: { path.append(DiscoverDestination.artist($0)) },
                        onPlay: { track, ctx in Task { await play(track, context: ctx) } }
                    )
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
                }
            }
        }
        .searchable(text: $query, prompt: "Songs, artists, or albums")
        .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        .onAppear { loadBrowseIfNeeded() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty && !browse.isEmpty {
                browseLanding
            } else {
                emptyState
            }
        } else if let hero = results.topSong {
            songCentricResults(hero: hero)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                topRow
                if !results.albums.isEmpty { albumsSection }
                if !restSongs.isEmpty { songsSection }
                if !results.lyricMatches.isEmpty { lyricMatchesSection }
                if !results.artists.isEmpty { artistsSection }
            }
            .padding(20)
        }
    }

    // MARK: - Song-centric results

    private func songCentricResults(hero: OnlineTrack) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            IOSWideSongHero(
                song: hero,
                isCurrent: coordinator.nowPlayingID == hero.id,
                isPlaying: engine.state.isPlaying,
                isResolving: coordinator.resolvingID == hero.id,
                onPlay: {
                    if coordinator.nowPlayingID == hero.id {
                        engine.togglePlayPause()
                    } else {
                        let ctx = engine.queue.shuffleEnabled
                            ? [hero]
                            : [hero] + results.songs.filter { $0.id != hero.id }
                        Task { await play(hero, context: ctx) }
                    }
                },
                onPlayNext: { Task { await coordinator.playNext(hero) } },
                onAddToQueue: { Task { await coordinator.addToQueue(hero) } },
                onAdd: { Task { await coordinator.addToLibrary(hero) } },
                onOpenAlbum: { openAlbum(for: hero) },
                onOpenArtist: { openArtist(for: hero) }
            )
            if !results.songArtists.isEmpty { songArtistsSection }
            if !results.songs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    discoverSectionHeader(moreSongsTitle)
                    ForEach(results.songs) { song in songRow(song) }
                }
            }
            if !results.lyricMatches.isEmpty { lyricMatchesSection }
            if !results.albums.isEmpty { albumsSection }
        }
        .padding(20)
    }

    private var songArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader(results.songArtists.count > 1 ? "Artists" : "Artist")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(results.songArtists) { artist in
                        IOSArtistCircle(artist: artist) { path.append(DiscoverDestination.artist(artist)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var moreSongsTitle: String {
        if let name = results.songArtists.first?.name { return "More by \(name)" }
        return "More songs"
    }

    // MARK: - Generic sections

    @ViewBuilder
    private var topRow: some View {
        if let top = topResult {
            VStack(alignment: .leading, spacing: 10) {
                discoverSectionHeader("Top result")
                IOSTopResultCard(
                    top: top,
                    onOpenArtist: { path.append(DiscoverDestination.artist($0)) },
                    onPlay: { track in
                        let ctx = engine.queue.shuffleEnabled ? [track] : results.songs
                        Task { await play(track, context: ctx) }
                    }
                )
                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        discoverSectionHeader("Songs")
                            .padding(.top, 8)
                        ForEach(topSongs) { song in songRow(song) }
                    }
                }
            }
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            discoverSectionHeader("More songs")
            ForEach(restSongs) { song in songRow(song) }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Fans also like")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(results.artists) { artist in
                        IOSArtistCircle(artist: artist) { path.append(DiscoverDestination.artist(artist)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var lyricMatchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            discoverSectionHeader("Matching that lyric")
            ForEach(results.lyricMatches) { song in
                VStack(alignment: .leading, spacing: 2) {
                    lyricsMatchBadge
                    songRow(song)
                }
            }
        }
    }

    private var lyricsMatchBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "quote.bubble.fill").font(.system(size: 8, weight: .bold))
            Text("Lyrics match").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.mixPrimary, in: Capsule())
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(results.albums) { album in
                        IOSAlbumCard(album: album) { path.append(DiscoverDestination.album(album)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func songRow(_ song: OnlineTrack) -> some View {
        IOSSongRow(
            song: song,
            isResolving: coordinator.resolvingID == song.id,
            isCurrent: coordinator.nowPlayingID == song.id,
            isPlaying: engine.state.isPlaying,
            onPlay: {
                let ctx = engine.queue.shuffleEnabled ? [song] : results.songs
                Task { await play(song, context: ctx) }
            },
            onPlayNext: { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd: { Task { await coordinator.addToLibrary(song) } },
            onOpenAlbum: { openAlbum(for: song) },
            onOpenArtist: { openArtist(for: song) }
        )
    }

    // MARK: - Result partitioning (mirrors macOS)

    private var topResult: IOSTopResult? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if let artist = results.artists.first,
           !q.isEmpty,
           artist.name.lowercased() == q || artist.name.lowercased().hasPrefix(q) {
            return .artist(artist)
        }
        if let song = results.songs.first { return .song(song) }
        if let artist = results.artists.first { return .artist(artist) }
        return nil
    }

    private var topSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return Array(pool.prefix(4))
    }

    private var restSongs: [OnlineTrack] {
        let shown = Set(topSongs.map(\.id)).union(promotedSongID.map { [$0] } ?? [])
        return Array(results.songs.filter { !shown.contains($0.id) }.prefix(6))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Browse landing (pre-search)

    /// Loads the Discover landing content once. Cheap to call repeatedly — it
    /// no-ops once content is present or a load is already running.
    private func loadBrowseIfNeeded() {
        guard browse.isEmpty, !browseLoading else { return }
        browseLoading = true
        Task { @MainActor in
            defer { browseLoading = false }
            browse = await deps.itunesClient.browseLanding()
        }
    }

    private var browseLanding: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !browse.trending.isEmpty { trendingSection }
            if !browse.artists.isEmpty { popularArtistsSection }
            if !browse.newReleases.isEmpty { newReleasesSection }
            if !browse.genres.isEmpty { browseAllSection }
        }
        .padding(20)
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Trending now")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
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
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var popularArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Popular artists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(browse.artists) { artist in
                        IOSArtistCircle(artist: artist) { path.append(DiscoverDestination.artist(artist)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("New releases")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(browse.newReleases) { album in
                        IOSAlbumCard(album: album) { path.append(DiscoverDestination.album(album)) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var browseAllSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Browse all")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                      alignment: .leading, spacing: 16) {
                ForEach(Array(browse.genres.enumerated()), id: \.element.id) { idx, genre in
                    IOSGenreTile(genre: genre, index: idx) { path.append(DiscoverDestination.genre(genre)) }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.mixTextTertiary)
            Text(query.isEmpty ? "Search for a song, artist, or album."
                               : (isSearching ? "Searching…" : "No results."))
                .font(.system(size: 14))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mixDestructive)
            Text(text)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mixDestructive.opacity(0.30), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = DiscoverResults(); isSearching = false; return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            isSearching = true
            defer { isSearching = false }
            let grouped = await deps.itunesClient.discoverSearch(query: trimmed)
            if Task.isCancelled { return }
            results = grouped

            let lyricHits = await deps.itunesClient.searchByLyrics(trimmed)
            if Task.isCancelled || query.trimmingCharacters(in: .whitespaces) != trimmed { return }
            results.lyricMatches = lyricHits
        }
    }

    // MARK: - Play

    private func play(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }

    // MARK: - Navigate from a track to its artist / album

    private func openArtist(for track: OnlineTrack) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: track.artistName, trackID: track.sourceID) {
                await MainActor.run { path.append(DiscoverDestination.artist(artist)) }
            }
        }
    }

    private func openAlbum(for track: OnlineTrack) {
        Task {
            if let album = await deps.itunesClient.resolveAlbum(for: track) {
                await MainActor.run { path.append(DiscoverDestination.album(album)) }
            }
        }
    }
}
#endif
