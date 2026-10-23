// "Liked Songs by <artist>". Every row is a favourited library track, so
// playback goes straight to the engine, and un-liking removes the row.

import SwiftUI
import Combine

struct DiscoverLikedSongsPage: View {

    /// The whole artist, so the hero can use their photo.
    let artist: OnlineArtist

    /// Pop, for hosts that don't draw their own back button (the Mac).
    var onBack: (() -> Void)? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine

    /// Recomputed on every library publish so un-liking removes a row immediately.
    private var tracks: [Track] {
        DiscoverArtistCounts.likedTracks(by: artist.name, in: deps.libraryService)
    }

    #if os(macOS)
    private let pagePadding: CGFloat = 24
    #else
    private let pagePadding: CGFloat = 20
    #endif

    /// Bumped on download manager publishes, since `body` reads its state without observing it.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let onBack {
                    BackButton(action: onBack)
                }
                hero
                if tracks.isEmpty {
                    emptyState
                } else {
                    trackList
                }
            }
            .padding(pagePadding)
        }
        // Same wash as the artist page it opens from, so the two read as one place.
        .background(DiscoverArtistWash(artist: artist))
        #if os(iOS)
        .navigationTitle("Liked Songs")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 18) {
            artwork
            VStack(alignment: .leading, spacing: 8) {
                Text("Liked Songs")
                    .font(.system(size: MixFontScale.size(12), weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                Text("By \(artist.name)")
                    .font(.system(size: MixFontScale.size(28), weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextSecondary)
                if let first = tracks.first {
                    playButton(first)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The artist photo with a heart badge.
    private var artwork: some View {
        CachedRemoteImage(url: artist.imageURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.mixSurface2
                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "heart.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.mixPrimary)
                .padding(6)
                .background(Color.mixBackground, in: Circle())
        }
    }

    private func playButton(_ first: Track) -> some View {
        Button {
            Task { await engine.play(track: first, in: tracks, source: .named("Liked Songs")) }
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.system(size: MixFontScale.size(13), weight: .bold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Color.mixAccentFill, in: Capsule())
                .foregroundStyle(Color.mixOnAccent)
        }
        .buttonStyle(.plain).mixHandCursor()
        .padding(.top, 2)
    }

    // MARK: - Songs

    private var trackList: some View {
        // Snapshot once so the play context matches the rows drawn.
        let shown = tracks
        return VStack(spacing: 0) {
            ForEach(shown) { track in
                TrackRowView(
                    track:             track,
                    isCurrent:         engine.queue.currentTrack?.id == track.id,
                    isPlaying:         engine.state.isPlaying,
                    isFavourited:      true,
                    onToggleFavourite: { deps.toggleFavourite(trackID: track.id) },
                    availability:      deps.downloadManager.status(for: track.id),
                    isResolving:       engine.routingTrackIDs.contains(track.id)
                )
                .contentShape(Rectangle())
                .mixTapAction {
                    Task { await engine.play(track: track, in: shown, source: .named("Liked Songs")) }
                }
                // Every row is liked, so the shared menu's own Remove covers it.
                .contextMenu {
                    LibrarySongMenu(targets: [track], onPlay: {
                        Task { await engine.play(track: track, in: shown, source: .named("Liked Songs")) }
                    })
                }

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 56)
            }
        }
    }

    // MARK: - Empty

    /// Only reachable by un-liking the last song, so it's phrased as something that just happened.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart")
                .font(.system(size: 34))
                .foregroundStyle(Color.mixTextTertiary)
            Text("Nothing liked by \(artist.name) any more.")
                .font(.system(size: MixFontScale.size(14)))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
