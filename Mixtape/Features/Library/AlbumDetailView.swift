import SwiftUI

public struct AlbumDetailView: View {

    let album: Album

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    /// The header shuffle is this list's setting. See `ShufflePreferences`.
    @ObservedObject private var shufflePrefs = ShufflePreferences.shared

    private var tracks: [Track] {
        deps.libraryService.tracks(in: album)
    }

    private var totalDuration: String {
        let secs = Int(tracks.map(\.duration).reduce(0, +))
        if secs >= 3600 {
            return "\(secs / 3600) hr \((secs % 3600) / 60) min"
        }
        return "\(secs / 60) min"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                trackList
            }
            .padding(.bottom, 24)
        }
        // On the container so it stays put while scrolling, and tints the titlebar.
        .artworkWash(source: album.displayArtwork)
        .background(MixPageBackground())
        .miniPlayerSafeArea()
        // Prewarm the first rows; albums are usually played from the top.
        .task(id: album.id) {
            deps.onlineCoordinator.prefetchResolvable(tracks)
        }
        .navigationTitle(album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        DetailHero(
            eyebrow: "Album",
            title: album.title,
            subtitle: album.artistName,
            subtitleIsProminent: true,
            metadata: metadataLine
        ) { size in
            ArtworkThumbnail(
                data: album.artworkData, artworkRef: .album(album.id),
                size: size,
                cornerRadius: 14,
                placeholder: MixtapeIcons.album
            )
        } actions: {
            actionButtons
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.trackCount) song\(album.trackCount == 1 ? "" : "s")")
        if !tracks.isEmpty { parts.append(totalDuration) }
        return parts.joined(separator: " · ")
    }

    /// Playing from this album, asked of the queue's source. See
    /// `PlaylistDetailView.isPlayingThisPlaylist`.
    private var isPlayingThisAlbum: Bool {
        engine.state.isPlaying && queueService.source == .named(album.title)
    }

    private var isPausedInThisAlbum: Bool {
        engine.state == .paused && queueService.source == .named(album.title)
    }

    private var shuffleKey: ShufflePreferences.Key { .album(album.id) }

    private var actionButtons: some View {
        HeroActionBar(
            isPlaying: isPlayingThisAlbum,
            isShuffling: shufflePrefs.shuffles(shuffleKey),
            isEmpty: tracks.isEmpty,
            onPlay: {
                // Playing: pause. Paused here: resume. Otherwise start (shuffled if on).
                if isPlayingThisAlbum {
                    engine.pause()
                } else if isPausedInThisAlbum {
                    engine.resume()
                } else {
                    let shuffles = shufflePrefs.shuffles(shuffleKey)
                    engine.queue.setShuffle(shuffles)
                    guard let first = shuffles
                            ? tracks.randomElement() : tracks.first else { return }
                    Task { await engine.play(track: first, in: tracks, source: .named(album.title)) }
                }
            },
            onShuffle: { shufflePrefs.toggle(shuffleKey) }
        ) {
            AlbumSaveButton(title: album.title, artistName: album.artistName)
            AlbumDownloadButton(ids: album.trackIDs, downloads: deps.downloadManager, library: deps.libraryService)
            ShareHeroButton(.album(album))

            // Same overflow menu as the playlist page.
            Menu { AlbumActionsMenu(album: album, showsShare: false) } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            #if os(macOS)
            // Otherwise a Menu draws as a bordered pop-up with a chevron.
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .frame(width: 40, height: 40)
            .help("More actions for \u{201C}\(album.title)\u{201D}")
        }
    }

    // MARK: - Track List

    private var trackList: some View {
        VStack(spacing: 0) {
            Divider().background(Color.mixSeparator)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                AlbumTrackRow(
                    track:     track,
                    index:     index + 1,
                    isCurrent: engine.queue.currentTrack?.id == track.id,
                    isPlaying: engine.state.isPlaying
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await engine.play(track: track, in: tracks, source: .named(album.title)) }
                }
                // No "Go to Album" on the album's own page.
                .contextMenu {
                    LibrarySongMenu(targets: [track], onPlay: {
                        Task { await engine.play(track: track, in: tracks, source: .named(album.title)) }
                    }, showsGoToAlbum: false)
                }

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 56)
            }
        }
    }
}

// MARK: - Album Track Row

/// Compact row with the track number instead of artwork.
private struct AlbumTrackRow: View {
    let track:     Track
    let index:     Int
    var isCurrent: Bool = false
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Track number / waveform
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                        .mixVariableColor(isActive: isPlaying)
                } else {
                    Text("\(index)")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.mixBodyBold)
                        .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if track.isExplicit { MixExplicitBadge() }
                }
                if track.artistName != track.albumTitle {
                    Text(track.artistName)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(track.formattedDuration)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview
// Guarded because `previewAlbums` is DEBUG-only; Release would fail to build.

#if DEBUG
#Preview {
    NavigationStack {
        AlbumDetailView(album: Album.previewAlbums[0])
            .environmentObject(AppDependencies())
            .environmentObject(PlaybackEngine(
                queue: QueueService(),
                fileStorage: SupabaseFileStorageService(client: SupabaseConfig.client),
                equalizer: AudioEqualizer()
            ))
    }
}
#endif
