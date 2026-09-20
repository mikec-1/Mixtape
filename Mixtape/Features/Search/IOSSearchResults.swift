// IOSSearchResults.swift
// Mixtape — Features/Search
//
// The catalogue half of the iOS search page, in the shape macOS reads in:
// the answer first (an artist, or the song you named), then that artist's
// songs, their albums, and finally who else sounds like them.
//
// This layout used to live inside IOSDiscoverView, drawing results Home no
// longer produces. It is here now because the Search tab is the only thing on
// iOS that searches, and a page-shaped answer beats the flat list of rows it
// replaced: a query naming an artist should open with the artist, not with
// forty songs that happen to mention them.

#if os(iOS)
import SwiftUI

/// The pills over the results. All is the page; the rest are one list each.
enum IOSSearchFilter: String, CaseIterable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums"
}

struct IOSSearchResults: View {

    let query: String
    @Binding var filter: IOSSearchFilter
    let onOpen: (DiscoverDestination) -> Void

    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator

    @ObservedObject private var store = DiscoverSessionStore.shared

    /// All shows this many songs; the Songs pill shows the rest.
    private static let collapsedSongs = 5

    /// The stations on the featured artist's page, shown here as "Featuring".
    @State private var stations: [PersonalMix] = []

    private var results: DiscoverResults { store.results }

    var body: some View {
        content
            .task(id: featuredArtist?.id) {
                stations = []
                guard let artist = featuredArtist else { return }
                // The store's cache, so opening the artist next costs nothing.
                let catalogue = await store.artistCatalogue(for: artist, using: deps.itunesClient)
                guard !Task.isCancelled else { return }
                stations = StationBuilder.artistStations(artist, catalogue: catalogue)
            }
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            if store.isSearching {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        } else {
            switch filter {
            case .all:
                if let hero = results.topSong {
                    songCentricResults(hero: hero)
                } else {
                    // One column, no rules: sections are separated by space
                    // alone, which is the iOS grouping idiom.
                    VStack(alignment: .leading, spacing: 26) {
                        topResultBanner
                        featuringSection
                        if !results.albums.isEmpty       { albumsSection }
                        if !results.songs.isEmpty        { songsSection }
                        if !results.lyricMatches.isEmpty { lyricMatchesSection }
                        if !results.artists.isEmpty      { artistsSection }
                    }
                }
            case .songs:
                if allSongs.isEmpty { noMatches("songs") } else { songList(allSongs) }
            case .artists:
                if allArtists.isEmpty { noMatches("artists") } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(allArtists) { artist in
                            entityRow(url: artist.imageURL, circle: true,
                                      title: artist.name, subtitle: "Artist") {
                                onOpen(.artist(artist))
                            }
                        }
                    }
                }
            case .albums:
                if results.albums.isEmpty { noMatches("albums") } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(results.albums) { album in
                            entityRow(url: album.coverURL, circle: false, title: album.title,
                                      subtitle: [album.recordTypeLabel ?? "Album", album.artistName]
                                          .filter { !$0.isEmpty }.joined(separator: " • ")) {
                                onOpen(.album(album))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filtered lists

    /// The named song first, then everything else the search found.
    private var allSongs: [OnlineTrack] {
        guard let hero = results.topSong else { return results.songs }
        return [hero] + results.songs.filter { $0.id != hero.id }
    }

    /// The song's own artists lead when a song was the answer.
    private var allArtists: [OnlineArtist] {
        let lead = Set(results.songArtists.map(\.id))
        return results.songArtists + results.artists.filter { !lead.contains($0.id) }
    }

    private func entityRow(url: URL?, circle: Bool, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                discoverArtwork(url: url, circle: circle, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func noMatches(_ noun: String) -> some View {
        Text("No \(noun) for \u{201C}\(query)\u{201D}")
            .font(.mixSubtext)
            .foregroundStyle(Color.mixTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: - Song-centric results (a specific song was searched)

    private func songCentricResults(hero: OnlineTrack) -> some View {
        VStack(alignment: .leading, spacing: 26) {
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
                onPlayNext:   { Task { await coordinator.playNext(hero) } },
                onAddToQueue: { Task { await coordinator.addToQueue(hero) } },
                onAdd:        { Task { await coordinator.addToLibrary(hero) } },
                onOpenAlbum:  { openAlbum(for: hero) },
                onOpenArtist: { openArtist(named: $0, from: hero) },
                onWrongVersion: {
                    let ctx = [hero] + results.songs.filter { $0.id != hero.id }
                    Task { await coordinator.reResolveAndPlay(hero, context: ctx) }
                }
            )

            if !results.songArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    discoverSectionHeader(results.songArtists.count > 1 ? "Artists" : "Artist")
                    artistShelf(results.songArtists)
                }
            }

            featuringSection

            if !results.songs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        discoverSectionHeader(moreSongsTitle)
                        Spacer(minLength: 8)
                        seeAllSongs(total: results.songs.count)
                    }
                    songList(Array(results.songs.prefix(Self.collapsedSongs)))
                }
            }

            if !results.lyricMatches.isEmpty { lyricMatchesSection }
            if !results.albums.isEmpty       { albumsSection }
            if !results.artists.isEmpty      { artistsSection }
        }
    }

    private var moreSongsTitle: String {
        if let name = results.songArtists.first?.name { return "More by \(name)" }
        return "More songs"
    }

    // MARK: - Generic sections

    /// The answer, as one row across the top. Its own subtitle already reads
    /// "Artist" or "Song · …", so nothing has to announce it as the top result.
    @ViewBuilder
    private var topResultBanner: some View {
        if let top = topResult {
            IOSTopResultCard(
                top: top,
                onOpenArtist: { onOpen(.artist($0)) },
                onPlay: { track in
                    let ctx = engine.queue.shuffleEnabled ? [track] : results.songs
                    Task { await play(track, context: ctx) }
                }
            )
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // Says which it is: matches, or the closest thing the catalogue
                // had. See `DiscoverResults.songsMatched`.
                discoverSectionHeader(results.songsMatched ? songsTitle : "Closest matches")
                Spacer(minLength: 8)
                seeAllSongs(total: results.songs.count)
            }
            songList(resultSongs)
        }
    }

    /// Named after the artist when the artist is the answer — the songs under a
    /// searched-for name are theirs, and "Songs" says less than "Popular".
    private var songsTitle: String {
        if case .artist = topResult { return "Popular songs" }
        return "Songs"
    }

    private func songList(_ songs: [OnlineTrack]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                songRow(song)
                if index < songs.count - 1 {
                    Divider().background(Color.mixSeparator).padding(.leading, 56)
                }
            }
        }
    }

    /// Whose stations "Featuring" shows: the artist that answered the search,
    /// or the named song's artist.
    private var featuredArtist: OnlineArtist? {
        if results.topSong != nil { return results.songArtists.first }
        if case .artist(let artist) = topResult { return artist }
        return nil
    }

    /// Spotify's "Featuring <name>": the same stations as the artist page's
    /// "Playlists with" row.
    @ViewBuilder
    private var featuringSection: some View {
        if let artist = featuredArtist, !stations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                discoverSectionHeader("Featuring \(artist.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(stations) { station in
                            MixMosaicCard(
                                mix: station,
                                isResolving: station.tracks.first.map { coordinator.resolvingID == $0.id } ?? false,
                                onOpen: { onOpen(.mix(station)) },
                                onPlay: {
                                    guard let first = station.tracks.first else { return }
                                    Task { await play(first, context: station.tracks) }
                                })
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Fans also like")
            artistShelf(results.artists)
        }
    }

    private var lyricMatchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            discoverSectionHeader("Matching that lyric")
            ForEach(results.lyricMatches) { song in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.bubble.fill").font(.system(size: 8, weight: .bold))
                        Text("Lyrics match").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.mixAccentFill, in: Capsule())

                    songRow(song)
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            discoverSectionHeader("Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(results.albums) { album in
                        IOSAlbumCard(album: album) { onOpen(.album(album)) }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func artistShelf(_ artists: [OnlineArtist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(artists) { artist in
                    IOSArtistCircle(artist: artist) { onOpen(.artist(artist)) }
                }
            }
        }
        .scrollClipDisabled()
    }

    /// Jumps to the Songs pill rather than growing the page.
    @ViewBuilder
    private func seeAllSongs(total: Int) -> some View {
        if total > Self.collapsedSongs {
            MixPillButton(title: "See all") {
                Haptics.play(.selection)
                withMixAnimation(.easeInOut(duration: 0.18)) { filter = .songs }
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
            onPlayNext:   { Task { await coordinator.playNext(song) } },
            onAddToQueue: { Task { await coordinator.addToQueue(song) } },
            onAdd:        { Task { await coordinator.addToLibrary(song) } },
            onOpenAlbum:  { openAlbum(for: song) },
            onOpenArtist: { openArtist(named: $0, from: song) },
            onWrongVersion: { Task { await coordinator.reResolveAndPlay(song, context: results.songs) } }
        )
    }

    // MARK: - Result partitioning (mirrors macOS)

    /// The search layer decides artist-vs-song, not the query text. See
    /// `DiscoverResults.anchorIsArtist`.
    private var topResult: IOSTopResult? {
        if results.anchorIsArtist, let artist = results.artists.first { return .artist(artist) }
        if let song = results.songs.first { return .song(song) }
        if let artist = results.artists.first { return .artist(artist) }
        return nil
    }

    private var resultSongs: [OnlineTrack] {
        let pool = promotedSongID.map { id in results.songs.filter { $0.id != id } } ?? results.songs
        return Array(pool.prefix(Self.collapsedSongs))
    }

    private var promotedSongID: String? {
        if case .song(let s) = topResult { return s.id }
        return nil
    }

    // MARK: - Play / navigate

    private func play(_ track: OnlineTrack, context: [OnlineTrack]) async {
        var artworkData: Data? = nil
        if let url = track.artworkURL {
            artworkData = try? await URLSession.shared.data(from: url).0
        }
        await coordinator.play(track, context: context, artworkData: artworkData)
    }

    /// One name out of a credit line. `trackID` only helps for the credited act
    /// — it asks Deezer who *this track's* artist is — so a guest resolves by
    /// name alone.
    private func openArtist(named name: String, from track: OnlineTrack) {
        let trackID = name == track.artistName ? track.sourceID : nil
        Task {
            if let artist = await deps.itunesClient.resolveArtist(name: name, trackID: trackID) {
                await MainActor.run { onOpen(.artist(artist)) }
            }
        }
    }

    private func openAlbum(for track: OnlineTrack) {
        Task {
            if let album = await deps.itunesClient.resolveAlbum(for: track) {
                await MainActor.run { onOpen(.album(album)) }
            }
        }
    }
}
#endif
