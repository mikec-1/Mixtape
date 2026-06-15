// MiniPlayerBar.swift
// Mixtape — SharedUI/Components
//
// Persistent pill that floats above the tab bar while something is playing.
// Artwork · Title/Artist · Play-Pause · Skip.
// Tap anywhere on the bar (except the two control buttons) → opens NowPlayingView.

import SwiftUI

public struct MiniPlayerBar: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    @State private var showNowPlaying = false

    public var body: some View {
        Button { showNowPlaying = true } label: {
            HStack(spacing: 12) {

                // Artwork
                artworkView

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.queue.currentTrack?.title ?? "—")
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(engine.queue.currentTrack?.artistName ?? "")
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Play / Pause
                Button {
                    engine.togglePlayPause()
                } label: {
                    Group {
                        if engine.state == .loading {
                            ProgressView().tint(Color.mixTextPrimary)
                        } else {
                            Image(systemName: engine.state.isPlaying ? MixtapeIcons.pause : MixtapeIcons.play)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.mixTextPrimary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Heart
                if let track = engine.queue.currentTrack {
                    let favoured = deps.libraryService.isFavourited(trackID: track.id)
                    Button {
                        deps.libraryService.toggleFavourite(trackID: track.id)
                    } label: {
                        Image(systemName: favoured ? "heart.fill" : "heart")
                            .font(.system(size: 17))
                            .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextSecondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Skip forward
                Button {
                    Task { await engine.playNext() }
                } label: {
                    Image(systemName: MixtapeIcons.skipForward)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(
                            engine.queue.hasNext ? Color.mixTextPrimary : Color.mixTextTertiary
                        )
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!engine.queue.hasNext)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.mixSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(deps)
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data  = engine.queue.currentTrack?.artworkData,
               let image = platformImage(from: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.mixSurface2
                    .overlay(
                        Image(systemName: MixtapeIcons.track)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #else
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    ZStack(alignment: .bottom) {
        Color.mixBackground.ignoresSafeArea()
        MiniPlayerBar()
            .padding(.horizontal, 8)
            .padding(.bottom, 57)
            .environmentObject(deps)
            .environmentObject(deps.playbackEngine)
    }
}
