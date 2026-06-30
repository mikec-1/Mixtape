// OnlineDiscoverView.swift
// Mixtape — Features/Online
//
// Search songs/artists/albums online and stream them. Drill-down uses a manual
// `path` stack instead of a NavigationStack — nesting one inside the Mac
// NavigationSplitView locks the detail column (see MacContentRouter).

#if os(macOS)
import SwiftUI

struct OnlineDiscoverView: View {

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var appState:    MacAppState

    @State private var query:   String = ""
    @State private var results: DiscoverResults = DiscoverResults()
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil

    /// Pre-search landing content (charts, popular artists, new releases, genres).
    /// Loaded once on first appear so the tab is lively before any query.
    @State private var browse: BrowseLanding = BrowseLanding()
    @State private var browseLoading = false

    /// Dropped after submit / on play so the global spacebar shortcut goes back to
    /// play/pause instead of typing a space into the field.
    @FocusState private var searchFocused: Bool

    /// Drill-down stack. Empty = search results; last element = current page.
    @State private var path: [DiscoverDestination] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.top, 12)
            if let error = coordinator.errorMessage {
                banner(error, system: "exclamationmark.circle.fill")
            } else if let status = coordinator.statusMessage {
                banner(status, system: "arrow.triangle.2.circlepath", tint: Color.mixPrimary)
            }
            content
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.errorMessage)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.statusMessage)
        .background(Color.mixBackground)
        .onDisappear { searchTask?.cancel() }
        .onAppear { consumePendingDeepLink(); loadBrowseIfNeeded() }
        .onChange(of: appState.pendingDiscover) { _, _ in consumePendingDeepLink() }
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
                if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: trackID) {
                    query = ""
                    path = [.artist(artist)]
                }
            case let .album(title, artistName, trackID):
                let probe = OnlineTrack(title: "", artistName: artistName, albumTitle: title,
                                        duration: 0, artworkURL: nil, sourceID: trackID)
                if let album = await deps.itunesClient.resolveAlbum(for: probe) {
                    query = ""
                    path = [.album(album)]
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !path.isEmpty {
                Button { path.removeLast() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .buttonStyle(.plain)
            }
            Text("Discover")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.mixTextSecondary)
                TextField("Songs, artists, or albums…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onChange(of: query) { _, newValue in
                        path.removeAll()                 // typing returns to results
                        scheduleSearch(newValue)
                    }
                    .onSubmit {
                        scheduleSearch(query, immediate: true)
                        searchFocused = false            // hand the spacebar back to play/pause
                    }
                if !query.isEmpty {
                    Button {
                        query = ""; results = DiscoverResults(); path.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
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
                onPlay: { track, context in Task { await play(track, context: context) } },
                onPrefetch: { coordinator.prefetch($0) }
            )
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
        case .none:
            searchResults
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty && !browse.isEmpty {
                browseLanding
            } else {
                emptyState
            }
        } else if let hero = results.topSong {
            songCentricResults(hero: hero)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    topRow
                    if !results.albums.isEmpty { albumsSection }
                    if !restSongs.isEmpty { songsSection }
                    if !results.artists.isEmpty { artistsSection }
                }
                .padding(24)
            }
        }
    }

    // MARK: - Song-centric results (a specific song was searched)

    /// Layout for a song query: a wide full-width hero for the searched song,
    /// then the artist(s) on it (main + features), then more songs by the artist.
    private func songCentricResults(hero: OnlineTrack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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
                    onOpenArtist: { openArtist(for: hero) }
                )
                if !results.songArtists.isEmpty { songArtistsSection }
                if !results.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(moreSongsTitle)
                        VStack(spacing: 2) {
                            ForEach(results.songs) { song in songRow(song) }
                        }
                    }
                }
                if !results.lyricMatches.isEmpty { lyricMatchesSection }
                if !results.albums.isEmpty { albumsSection }
            }
            .padding(24)
        }
    }

    /// "Artist" / "Artists" row beneath the song hero — the main artist and any
    /// featured artists, side by side and navigable.
    private var songArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(results.songArtists.count > 1 ? "Artists" : "Artist")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(results.songArtists) { artist in
                        ArtistCircle(artist: artist) { path.append(.artist(artist)) }
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

    /// The hero "Top result" beside a compact songs list (Spotify's top layout).
    @ViewBuilder
    private var topRow: some View {
        if let top = topResult {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Top result")
                    TopResultCard(
                        top: top,
                        onOpenArtist: { path.append(.artist($0)) },
                        onPlay: { track in
                            let ctx = engine.queue.shuffleEnabled ? [track] : results.songs
                            Task { await play(track, context: ctx) }
                        }
                    )
                    .frame(width: 320)
                }
                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Songs")
                        VStack(spacing: 2) {
                            ForEach(topSongs) { song in songRow(song) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("More songs")
            VStack(spacing: 2) {
                ForEach(restSongs) { song in songRow(song) }
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Fans also like")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(results.artists) { artist in
                        ArtistCircle(artist: artist) { path.append(.artist(artist)) }
                    }
                }
                .padding(.bottom, 4)
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
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.mixPrimary, in: Capsule())
        .padding(.leading, 4)
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(results.albums) { album in
                        AlbumCard(album: album) { path.append(.album(album)) }
                    }
                }
                .padding(.bottom, 4)
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
            onOpenArtist: { openArtist(for: song) }
        )
    }

    // MARK: - Result partitioning

    /// Top result: the matching artist when their name closely matches the query
    /// (Spotify shows the artist), otherwise the most popular song.
    private var topResult: TopResult? {
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

    /// Songs shown next to the top result (skip the one promoted to top result).
    private var topSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return Array(pool.prefix(4))
    }

    /// Remaining songs below the fold.
    private var restSongs: [OnlineTrack] {
        let shown = Set(topSongs.map(\.id)).union(promotedSongID.map { [$0] } ?? [])
        return Array(results.songs.filter { !shown.contains($0.id) }.prefix(6))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            if query.isEmpty && browseLoading {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.mixTextTertiary)
                Text(query.isEmpty ? "Search for a song, artist, or album."
                                   : (isSearching ? "Searching…" : "No results."))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Browse landing (pre-search content)

    /// Loads the Discover landing content once. Cheap to call repeatedly — it
    /// no-ops once content is present or a load is already running.
    private func loadBrowseIfNeeded() {
        guard browse.isEmpty, !browseLoading else { return }
        browseLoading = true
        Task { @MainActor in
            defer { browseLoading = false }
            let landing = await deps.itunesClient.browseLanding()
            browse = landing
        }
    }

    private var browseLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !browse.trending.isEmpty { trendingSection }
                if !browse.artists.isEmpty { popularArtistsSection }
                if !browse.newReleases.isEmpty { newReleasesSection }
                if !browse.genres.isEmpty { browseAllSection }
            }
            .padding(24)
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
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// "Popular artists" — horizontal row of artist circles.
    private var popularArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Popular artists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(browse.artists) { artist in
                        ArtistCircle(artist: artist) { path.append(.artist(artist)) }
                    }
                }
                .padding(.bottom, 4)
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
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// "Browse all" — colourful genre/mood tiles, Spotify-style.
    private var browseAllSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Browse all")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)],
                      alignment: .leading, spacing: 16) {
                ForEach(Array(browse.genres.enumerated()), id: \.element.id) { idx, genre in
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
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String, immediate: Bool = false) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = DiscoverResults(); isSearching = false; return
        }
        // Set synchronously so the debounce window shows "Searching…" rather than
        // flashing "No results."
        isSearching = true
        searchTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            isSearching = true            // survived the debounce
            defer { isSearching = false }
            let grouped = await deps.itunesClient.discoverSearch(query: trimmed)
            if Task.isCancelled { return }
            results = grouped

            // Lyric search runs after so the main results show instantly.
            let lyricHits = await deps.itunesClient.searchByLyrics(trimmed)
            if Task.isCancelled || query.trimmingCharacters(in: .whitespaces) != trimmed { return }
            results.lyricMatches = lyricHits
        }
    }

    // MARK: - Play

    private func play(_ track: OnlineTrack, context: [OnlineTrack]) async {
        searchFocused = false            // playing a result hands the spacebar back to play/pause
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }

    // MARK: - Navigate from a track to its artist / album

    /// Resolve the track's artist (Deezer) and push the artist page.
    private func openArtist(for track: OnlineTrack) {
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: track.artistName, trackID: track.sourceID) {
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

private enum DiscoverDestination: Hashable {
    case artist(OnlineArtist)
    case album(OnlineAlbum)
    case genre(BrowseGenre)
}

private enum TopResult {
    case artist(OnlineArtist)
    case song(OnlineTrack)
}

// MARK: - Explicit badge

/// The small "E" label shown next to tracks with explicit lyrics.
private struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.mixTextSecondary)
            .frame(width: 14, height: 14)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 3))
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
    var onOpenArtist: (() -> Void)? = nil

    @State private var hovering = false

    /// This specific track is the one playing right now.
    private var isThisPlaying: Bool { isCurrent && isPlaying }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            artworkView(url: song.artworkURL, circle: false, size: 180)
                .overlay {
                    if isResolving {
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.45))
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
                ClickableText(text: song.title,
                              font: .system(size: 40, weight: .bold),
                              color: Color.mixTextPrimary,
                              action: onOpenAlbum)
                ClickableText(text: song.artistName,
                              font: .system(size: 15, weight: .semibold),
                              color: Color.mixTextSecondary,
                              action: onOpenArtist)
                Button(action: onPlay) {
                    Label(isThisPlaying ? "Pause" : "Play",
                          systemImage: isThisPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Color.mixPrimary, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)   // clicking anywhere on the hero plays it
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: isThisPlaying)
        .animation(.easeInOut(duration: 0.12), value: isResolving)
        .contextMenu {
            Button(isThisPlaying ? "Pause" : "Play",
                   systemImage: isThisPlaying ? "pause.fill" : "play.fill", action: onPlay)
            if let onPlayNext {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
            }
            if let onAddToQueue {
                Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
            }
            if let onAdd {
                Divider()
                Button("Add to Library", systemImage: "plus", action: onAdd)
            }
            if let onWrongVersion {
                Divider()
                Button("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath", action: onWrongVersion)
            }
        }
    }
}

// MARK: - Top result card

private struct TopResultCard: View {
    let top: TopResult
    let onOpenArtist: (OnlineArtist) -> Void
    let onPlay: (OnlineTrack) -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            switch top {
            case .artist(let artist):
                card(imageURL: artist.imageURL, circle: true,
                     title: artist.name, subtitle: "Artist") { onOpenArtist(artist) }
            case .song(let song):
                card(imageURL: song.artworkURL, circle: false,
                     title: song.title, subtitle: "Song · \(song.artistName)") { onPlay(song) }
            }
        }
    }

    private func card(imageURL: URL?, circle: Bool, title: String, subtitle: String,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            artworkView(url: imageURL, circle: circle, size: 92)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.mixPrimary)
                    .background(Circle().fill(.black.opacity(0.2)))
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Song row

private struct SongRow: View {
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
    var onOpenArtist: (() -> Void)? = nil

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                artworkView(url: song.artworkURL, circle: false, size: 40)
                if isResolving {
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45))
                        .frame(width: 40, height: 40)
                    ProgressView().controlSize(.small).tint(.white)
                } else if isCurrent {
                    // Now-playing indicator on top of the album cover.
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.mixPrimary)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)   // single click on the artwork plays
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ClickableText(text: song.title,
                                  font: .system(size: 13, weight: .medium),
                                  color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary,
                                  action: onOpenAlbum)
                    if song.isExplicit { ExplicitBadge() }
                }
                ClickableText(text: song.artistName,
                              font: .system(size: 12),
                              color: Color.mixTextSecondary,
                              action: onOpenArtist)
            }
            Spacer()
            if isCurrent {
                // Animated waveform at the very right, like the offline player.
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            } else if song.duration > 0 {
                Text(Self.formatTime(song.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.mixSurface : .clear, in: RoundedRectangle(cornerRadius: 6))
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
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
            Button("Add to Queue", systemImage: "text.append", action: onAddToQueue)
            Divider()
            Button("Add to Library", systemImage: "plus", action: onAdd)
            if let onWrongVersion {
                Divider()
                Button("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath", action: onWrongVersion)
            }
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
            artworkView(url: artist.imageURL, circle: true, size: 116)
                .overlay {
                    if hovering {
                        Circle().stroke(Color.mixPrimary, lineWidth: 2)
                    }
                }
            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text("Artist")
                .font(.system(size: 11))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .frame(width: 124)
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
            artworkView(url: album.coverURL, circle: false, size: 150)
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
        .frame(width: 150)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Artist detail page

private struct DiscoverArtistPage: View {
    let artist: OnlineArtist
    let onOpenAlbum: (OnlineAlbum) -> Void
    let onOpenArtist: (OnlineArtist) -> Void
    let onPlay: (OnlineTrack, [OnlineTrack]) -> Void
    let onPrefetch: (OnlineTrack) -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine:      PlaybackEngine

    @State private var topTracks: [OnlineTrack]  = []
    @State private var albums:    [OnlineAlbum]  = []
    @State private var related:   [OnlineArtist] = []
    @State private var loading = true

    /// Section expansion toggles.
    @State private var tracksExpanded = false
    @State private var albumsExpanded = false

    private let albumColumns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    /// Collapsed limits (Spotify-style: show a few, expand for the rest).
    private let collapsedTrackCount = 5
    private let collapsedAlbumCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroHeader
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if !topTracks.isEmpty { popularSection }
                    if !albums.isEmpty { albumsGrid }
                    if !related.isEmpty { similarArtistsSection }
                }
            }
            .padding(24)
        }
        .task(id: artist.id) { await load() }
    }

    private var heroHeader: some View {
        HStack(spacing: 20) {
            artworkView(url: artist.imageURL, circle: true, size: 140)
            VStack(alignment: .leading, spacing: 8) {
                Text("Artist").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                Text(artist.name).font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary).lineLimit(2)
                if let first = topTracks.first {
                    Button {
                        onPlay(first, topTracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            .background(Color.mixPrimary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var popularSection: some View {
        let shown = tracksExpanded ? topTracks : Array(topTracks.prefix(collapsedTrackCount))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Popular").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
            VStack(spacing: 2) {
                ForEach(shown) { song in
                    SongRow(
                        song: song,
                        isResolving: coordinator.resolvingID == song.id,
                        isCurrent: coordinator.nowPlayingID == song.id,
                        isPlaying: engine.state.isPlaying,
                        onPlay: { onPlay(song, topTracks) },
                        onPlayNext: { Task { await coordinator.playNext(song) } },
                        onAddToQueue: { Task { await coordinator.addToQueue(song) } },
                        onAdd: { Task { await coordinator.addToLibrary(song) } },
                        onPrefetch: { onPrefetch(song) },
                        onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: topTracks) } },
                        onOpenAlbum: {
                            Task {
                                if let al = await deps.itunesClient.resolveAlbum(for: song) {
                                    await MainActor.run { onOpenAlbum(al) }
                                }
                            }
                        },
                        onOpenArtist: {
                            Task {
                                if let a = await deps.itunesClient.resolveArtist(name: song.artistName, trackID: song.sourceID) {
                                    await MainActor.run { onOpenArtist(a) }
                                }
                            }
                        }
                    )
                }
            }
            if topTracks.count > collapsedTrackCount {
                expandButton(expanded: $tracksExpanded)
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
            withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
        } label: {
            Label(expanded.wrappedValue ? "Show less" : "Show more",
                  systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func load() async {
        loading = true
        async let top = deps.itunesClient.artistTopTracks(artistId: artist.id)
        async let alb = deps.itunesClient.artistAlbums(artistId: artist.id)
        async let rel = deps.itunesClient.relatedArtists(artistId: artist.id)
        topTracks = await top
        albums = await alb
        related = await rel
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
                        Text(album.artistName).font(.system(size: 14))
                            .foregroundStyle(Color.mixTextSecondary)
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
                                    onOpenArtist: {
                                        Task {
                                            if let a = await deps.itunesClient.resolveArtist(name: song.artistName, trackID: song.sourceID) {
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
            loading = true
            tracks = await deps.itunesClient.albumTracks(album: album)
            loading = false
        }
    }
}

// MARK: - Clickable (navigable) text

/// A line of text that acts like a Spotify hyperlink when `action` is non-nil:
/// it underlines and shows the link cursor on hover and navigates on click.
/// With no action it renders as plain text, so callers can pass it everywhere.
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
    let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : 6)
    return AsyncImage(url: url) { image in
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
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
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
                Text(song.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                if song.isExplicit { ExplicitBadge() }
            }
            Text(song.artistName)
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
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: isResolving)
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
            AsyncImage(url: genre.pictureURL) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.clear }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .rotationEffect(.degrees(25))
                .offset(x: 18, y: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .clipped()
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if hovering {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Genre page (a Browse all tile opened)

/// Shows the most popular artists within a genre. Tapping an artist opens their
/// page (which already has play / albums / similar artists).
private struct DiscoverGenrePage: View {
    let genre: BrowseGenre
    let onOpenArtist: (OnlineArtist) -> Void

    @EnvironmentObject private var deps: AppDependencies

    @State private var artists: [OnlineArtist] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 18)]

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
            loading = true
            artists = await deps.itunesClient.genreArtists(genreId: genre.id)
            loading = false
        }
    }
}

#endif
