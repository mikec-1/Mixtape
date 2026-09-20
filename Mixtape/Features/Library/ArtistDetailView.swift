// ArtistDetailView.swift
// Mixtape — Features/Library/Detail

import SwiftUI
import Combine

public struct ArtistDetailView: View {

    let artist: Artist

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    /// Observed directly: `engine.queue` doesn't republish through the engine,
    /// so the shuffle button lagged behind the state it shows.
    @EnvironmentObject private var queueService: QueueService
    /// A header's shuffle button is this list's own setting, not the queue's
    /// live mode — see `ShufflePreferences`.
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    private var tracks: [Track] {
        deps.libraryService.tracks(by: artist)
    }

    private var albums: [Album] {
        let ids = Set(artist.albumIDs)
        return deps.libraryService.albums.filter { ids.contains($0.id) }
    }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity)
                if !albums.isEmpty  { albumsSection }
                if !tracks.isEmpty  { tracksSection }
                if albums.isEmpty && tracks.isEmpty { emptyState }
            }
            .padding(.bottom, 24)
        }
        // On the container, not the hero: it stays put while the content scrolls
        // under it, and it feeds the window titlebar tint on macOS.
        .artworkWash(source: artist.displayArtwork)
        .background(Color.mixBackground.ignoresSafeArea())
        .miniPlayerSafeArea()
        // The tracks section leads with this artist's most-played songs, so the
        // top of it is the likeliest next tap.
        .task(id: artist.id) {
            deps.onlineCoordinator.prefetchResolvable(tracks)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: "Artist",
            title: artist.name,
            subtitle: artist.bio,
            metadata: metadataLine,
            coverIsCircular: true
        ) { size in
            // No "Refresh Profile Photo" here any more — the backfill in
            // LibraryService replaces album-cover stand-ins on its own, so the
            // manual re-fetch was only ever a way to redo work already done.
            ArtworkThumbnail(
                data: artist.artworkData, artworkRef: .artist(artist.id),
                size: size,
                cornerRadius: size / 2,
                placeholder: MixtapeIcons.artist
            )
        } actions: {
            HeroActionBar(
                isPlaying: isPlayingThisArtist,
                isShuffling: shufflePrefs.shuffles(shuffleKey),
                isEmpty: tracks.isEmpty,
                onPlay: {
                    if isPlayingThisArtist {
                        engine.pause()
                    } else if isPausedInThisArtist {
                        engine.resume()
                    } else {
                        let shuffles = shufflePrefs.shuffles(shuffleKey)
                        engine.queue.setShuffle(shuffles)
                        guard let first = shuffles
                                ? tracks.randomElement() : tracks.first else { return }
                        Task { await engine.play(track: first, in: tracks, source: .named(artist.name)) }
                    }
                },
                onShuffle: { shufflePrefs.toggle(shuffleKey) }
            ) {
                ShareHeroButton(.artist(artist))
            }
        }
    }

    /// True when the engine is currently playing one of this artist's tracks.
    /// See `PlaylistDetailView.isPlayingThisPlaylist`: asked of the queue's
    /// source, because this artist's songs also sit in the playlists and albums
    /// the user actually pressed play on.
    private var isPlayingThisArtist: Bool {
        engine.state.isPlaying && queueService.source == .named(artist.name)
    }

    private var isPausedInThisArtist: Bool {
        engine.state == .paused && queueService.source == .named(artist.name)
    }

    private var shuffleKey: ShufflePreferences.Key { .artist(artist.name) }

    private var metadataLine: String {
        var parts: [String] = []
        if !albums.isEmpty { parts.append("\(albums.count) album\(albums.count == 1 ? "" : "s")") }
        if !tracks.isEmpty { parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Albums")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnail(
                                    data: album.artworkData, artworkRef: .album(album.id),
                                    size: 130,
                                    cornerRadius: 10,
                                    placeholder: MixtapeIcons.album
                                )
                                Text(album.title)
                                    .font(.mixLabel)
                                    .foregroundStyle(Color.mixTextPrimary)
                                    .lineLimit(1)
                                    .frame(width: 130, alignment: .leading)
                                if let year = album.year {
                                    Text(String(year))
                                        .font(.mixCaption)
                                        .foregroundStyle(Color.mixTextTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Songs Section

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Songs")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().background(Color.mixSeparator)

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRowView(
                    track:          track,
                    isCurrent:      engine.queue.currentTrack?.id == track.id,
                    isPlaying:      engine.state.isPlaying,
                    availability:   deps.downloadManager.status(for: track.id),
                    isResolving:    engine.routingTrackIDs.contains(track.id)
                )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await engine.play(track: track, in: tracks, source: .named(artist.name)) }
                }
                .contextMenu {
                    Button("Play Now") {
                        Task { await engine.play(track: track, in: tracks, source: .named(artist.name)) }
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

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 72)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: MixtapeIcons.artist)
                .font(.system(size: 44))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No tracks found")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Import music by this artist to see it here.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mixTitle2)
            .foregroundStyle(Color.mixTextPrimary)
    }
}

// MARK: - Preview
//
// Guarded because `previewArtists` is itself `#if DEBUG` — without this the
// canvas works all day and only Archive (a Release build) fails, on a line
// nothing ships.

#if DEBUG
#Preview {
    NavigationStack {
        ArtistDetailView(artist: Artist.previewArtists[0])
            .environmentObject(AppDependencies())
            .environmentObject(PlaybackEngine(
                queue: QueueService(),
                fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
                equalizer: AudioEqualizer()
            ))
    }
}
#endif
