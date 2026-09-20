// DiscoverLikedSongsPage.swift
// Mixtape — Features/Online
//
// "Liked Songs by <artist>" — what the liked-songs line on a Discover artist
// page opens.
//
// The odd thing about this page is that nothing on it is online. It is reached
// from a Deezer artist, but every row is a library track you have already
// favourited, so playback goes straight to the engine: there is no source to
// resolve and no download to wait for. That is also why the heart here removes
// the song from the list under your finger — on a page that is *defined* by
// being liked, un-liking has to have somewhere visible to go.
//
// Shared by both platforms. The rows are `TrackRowView`, the same row the
// library uses, because that is what these are.

import SwiftUI
import Combine

struct DiscoverLikedSongsPage: View {

    /// Carried whole rather than as a name so the hero can wear the artist's
    /// photo, the way the artist page you came from does.
    let artist: OnlineArtist

    /// Pop, for a host that doesn't draw chrome of its own. The artist page
    /// this opens from is full-bleed and carries its own back button, and on
    /// macOS this page inherits that bare header — without this it was a page
    /// with no way out but the sidebar.
    var onBack: (() -> Void)? = nil

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    /// Recomputed on every library publish, which is what makes un-liking a row
    /// remove it immediately.
    private var tracks: [Track] {
        DiscoverArtistCounts.likedTracks(by: artist.name, in: deps.libraryService)
    }

    #if os(macOS)
    private let pagePadding: CGFloat = 24
    #else
    private let pagePadding: CGFloat = 20
    #endif

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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                Text("By \(artist.name)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                if let first = tracks.first {
                    playButton(first)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The artist's photo with a heart badged onto it — the artwork *is* the
    /// artist, and the heart is the only thing separating this page from theirs.
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
                .font(.system(size: 13, weight: .bold))
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
        // The list is snapshotted once per redraw rather than read inside the
        // loop: `tracks` hits the library on every access, and the play context
        // has to be the same array the rows were built from.
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
                .onTapGesture {
                    Task { await engine.play(track: track, in: shown, source: .named("Liked Songs")) }
                }
                .contextMenu {
                    Button("Play Now") {
                        Task { await engine.play(track: track, in: shown, source: .named("Liked Songs")) }
                    }
                    Button("Play Next")   { engine.queue.insertNext(track) }
                    Button("Add to Queue") { engine.queue.append(track) }
                    Divider()
                    Button("Remove from Liked Songs", systemImage: "heart.slash") {
                        deps.toggleFavourite(trackID: track.id)
                    }
                    Divider()
                    ShareMenuItems(.track(track))
                }

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 56)
            }
        }
    }

    // MARK: - Empty

    /// Only reachable by un-liking the last song while looking at the list —
    /// the line that opens this page doesn't exist at zero. So it's phrased as
    /// something that just happened, not as an empty library.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart")
                .font(.system(size: 34))
                .foregroundStyle(Color.mixTextTertiary)
            Text("Nothing liked by \(artist.name) any more.")
                .font(.system(size: 14))
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
