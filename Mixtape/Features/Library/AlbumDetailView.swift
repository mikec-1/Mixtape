// AlbumDetailView.swift
// Mixtape — Features/Library/Detail

import SwiftUI

public struct AlbumDetailView: View {

    let album: Album

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

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
            .padding(.bottom, 120)
        }
        .background(Color.mixBackground.ignoresSafeArea())
        .navigationTitle(album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            ArtworkThumbnail(
                data: album.artworkData,
                size: 220,
                cornerRadius: 14,
                placeholder: MixtapeIcons.album
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 24)

            VStack(spacing: 6) {
                Text(album.title)
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(.center)

                Text(album.artistName)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixPrimary)

                HStack(spacing: 4) {
                    if let year = album.year {
                        Text(String(year))
                    }
                    if album.year != nil { Text("·").foregroundStyle(Color.mixTextTertiary) }
                    Text("\(album.trackCount) songs")
                    if !tracks.isEmpty {
                        Text("·").foregroundStyle(Color.mixTextTertiary)
                        Text(totalDuration)
                    }
                }
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
            }

            actionButtons
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                Task { await engine.play(track: first, in: tracks) }
            } label: {
                Label("Play", systemImage: MixtapeIcons.play)
                    .font(.mixButtonSmall)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mixPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            Button {
                if !engine.queue.shuffleEnabled { engine.queue.toggleShuffle() }
                guard let first = tracks.first else { return }
                Task { await engine.play(track: first, in: tracks) }
            } label: {
                Label("Shuffle", systemImage: MixtapeIcons.shuffle)
                    .font(.mixButtonSmall)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mixSurface)
                    .foregroundStyle(Color.mixTextPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.mixSeparator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
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
                    Task { await engine.play(track: track, in: tracks) }
                }

                Divider()
                    .background(Color.mixSeparator)
                    .padding(.leading, 56)
            }
        }
    }
}

// MARK: - Album Track Row

/// Compact row showing track number instead of artwork (shared album art is shown in the header).
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
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                } else {
                    Text("\(index)")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
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
