// ArtistDetailView.swift
// Mixtape — Features/Library/Detail

import SwiftUI

public struct ArtistDetailView: View {

    let artist: Artist

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    private var tracks: [Track] {
        deps.libraryService.tracks(by: artist)
    }

    private var albums: [Album] {
        let ids = Set(artist.albumIDs)
        return deps.libraryService.albums.filter { ids.contains($0.id) }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity)
                if !albums.isEmpty  { albumsSection }
                if !tracks.isEmpty  { tracksSection }
                if albums.isEmpty && tracks.isEmpty { emptyState }
            }
            .padding(.bottom, 120)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            // Avatar
            ArtworkThumbnail(
                data: artist.artworkData,
                size: 160,
                cornerRadius: 80,
                placeholder: MixtapeIcons.artist
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .padding(.top, 28)
            .contextMenu {
                Button {
                    Task {
                        do {
                            try await deps.libraryService.refreshArtistImage(artistID: artist.id)
                            deps.showToast("Refreshed profile photo")
                        } catch {
                            deps.showToast("Failed: \(error.localizedDescription)")
                        }
                    }
                } label: {
                    Label("Refresh Profile Photo", systemImage: "arrow.clockwise")
                }
            }

            VStack(spacing: 6) {
                Text(artist.name)
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 4) {
                    if !albums.isEmpty {
                        Text("\(albums.count) album\(albums.count == 1 ? "" : "s")")
                    }
                    if !albums.isEmpty && !tracks.isEmpty {
                        Text("·").foregroundStyle(Color.mixTextTertiary)
                    }
                    if !tracks.isEmpty {
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    }
                }
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)

                if let bio = artist.bio {
                    Text(bio)
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }
            }

            // Play all button
            Button {
                guard let first = tracks.first else { return }
                Task { await engine.play(track: first, in: tracks) }
            } label: {
                Label("Play all", systemImage: MixtapeIcons.play)
                    .font(.mixButtonSmall)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Color.mixPrimary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .padding(.bottom, 16)
        }
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
                                    data: album.artworkData,
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
                        .buttonStyle(.plain)
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
                    downloadStatus: deps.downloadManager.status(for: track.id)
                )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await engine.play(track: track, in: tracks) }
                }
                .contextMenu {
                    Button("Play Now") {
                        Task { await engine.play(track: track, in: tracks) }
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
