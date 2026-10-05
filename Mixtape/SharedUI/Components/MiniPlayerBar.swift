// Floating pill above the tab bar: artwork, title/artist, play/pause, skip.
// Tapping the bar opens NowPlayingView.

import SwiftUI

public struct MiniPlayerBar: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    /// Non-iOS only. On iOS the flag lives on IOSAppState, since this bar unmounts
    /// between songs and would take the sheet with it.
    @State private var showNowPlaying = false
    @Environment(\.mixChrome) private var chrome
    /// Triggers the heart bounce. Never reset, or it would pop on song change.
    @State private var favouritePops = 0
    #if os(iOS)
    /// How far the row has been dragged sideways. See `swipe`.
    @State private var dragX: CGFloat = 0
    /// The row's width, so the incoming song can ride in exactly one row behind.
    @State private var rowWidth: CGFloat = 360
    #endif

    public var body: some View {
        Button { openNowPlaying() } label: {
            VStack(spacing: 0) {

                // Full-width device band; as a caption it truncated.
                WithActiveRemote(continuity: deps.continuity) { remote in
                    if let remote {
                        RemoteDeviceStrip(device: remote, alignment: .leading, hPadding: 12)
                    }
                }
                JamStrip(jam: deps.jam, alignment: .leading, hPadding: 12)

                HStack(spacing: 12) {

                    // Artwork
                    artworkView

                    // Track info
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        artistLine
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
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")

                    #if os(iOS)
                    // Only once there's another device.
                    WithActiveRemote(continuity: deps.continuity) { remote in
                        if remote != nil || !deps.continuity.devices.isEmpty {
                            DevicesButton(continuity: deps.continuity,
                                          downloads: deps.downloadManager, size: 17)
                        }
                    }
                    #endif

                    // Heart
                    if let track = engine.queue.currentTrack {
                        let favoured = deps.libraryService.isFavourited(trackID: track.id)
                        Button {
                            // Add pops, remove is quiet. `deps` shows the card.
                            guard deps.toggleFavourite(trackID: track.id) else { return }
                            favouritePops += 1
                            Haptics.play(.success)
                        } label: {
                            Image(systemName: favoured ? "heart.fill" : "heart")
                                .font(.system(size: 17))
                                .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextSecondary)
                                .mixSymbolReplace()
                                .mixAnimation(.snappy(duration: 0.22), value: favoured)
                                .frame(width: 36, height: 36)
                                .savePop(trigger: favouritePops)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .accessibilityLabel(favoured ? "Remove from Liked Songs" : "Add to Liked Songs")
                    }

                    #if !os(iOS)
                    // Not on iOS, where the bar is swiped (see `swipe`).
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
                    .buttonStyle(.plain).mixHandCursor()
                    .disabled(!engine.queue.hasNext)
                    .accessibilityLabel("Next")
                    #endif
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                #if os(iOS)
                .offset(x: dragX)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { rowWidth = $0 }
                // The next song, one row-width behind, so the drag reveals it.
                .overlay(alignment: .leading) { incomingPreview }
                .mixAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: dragX)
                .simultaneousGesture(swipe)
                #endif
            }
            .background(chrome.material(.ultraThinMaterial, flat: .mixSurface2))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Shadow for depth, no stroke. Flat chrome has no shadow, so it gets the hairline.
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.mixSeparator, lineWidth: 0.5)
                    .opacity(chrome.showsShadows ? 0 : 1)
            )
            .mixShadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityHint("Opens Now Playing")
        #if os(iOS)
        .contextMenu {
            if let track = engine.queue.currentTrack, deps.onlineCoordinator.canReResolve(track) {
                Button { Task { await deps.reResolve(track) } } label: {
                    Label("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        // The swipe is the only way to skip here, and VoiceOver can't swipe it.
        .accessibilityActions {
            if engine.queue.hasNext { Button("Next") { Task { await engine.playNext() } } }
            if engine.queue.hasPrevious { Button("Previous") { Task { await engine.playPrevious() } } }
        }
        #endif
        #if !os(iOS)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(deps)
        }
        #endif
    }

    #if os(iOS)
    // MARK: - Swipe to skip

    /// Wraps under repeat like `hasNext`/`hasPrevious`.
    private func neighbour(forward: Bool) -> Track? {
        let q = engine.queue.queue
        guard !q.isEmpty else { return nil }
        if engine.queue.repeatMode == .one { return engine.queue.currentTrack }
        let i = engine.queue.currentIndex + (forward ? 1 : -1)
        if q.indices.contains(i) { return q[i] }
        return engine.queue.repeatMode == .all ? q[(i + q.count) % q.count] : nil
    }

    @ViewBuilder
    private var incomingPreview: some View {
        if dragX != 0, let next = neighbour(forward: dragX < 0) {
            HStack(spacing: 12) {
                ArtworkThumbnail(data: next.artworkData, artworkRef: .track(next.id),
                                 size: 40, cornerRadius: 6, placeholder: MixtapeIcons.track)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.displayTitle)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(ImportService.displayArtists(title: next.title, artistName: next.artistName)
                            .joined(separator: ", "))
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: rowWidth)
            .offset(x: dragX + (dragX < 0 ? rowWidth : -rowWidth))
            .allowsHitTesting(false)
        }
    }

    /// Swipe sideways to change song; past a third commits, else springs back.
    /// `simultaneousGesture` so the bar's tap still opens Now Playing.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Nothing that way: half the travel, as resistance.
                let canGo = value.translation.width < 0
                    ? engine.queue.hasNext : engine.queue.hasPrevious
                dragX = canGo ? value.translation.width : value.translation.width / 3
            }
            .onEnded { value in
                let dx = value.translation.width + value.predictedEndTranslation.width / 4
                let forward = dx < 0
                let canGo = forward ? engine.queue.hasNext : engine.queue.hasPrevious
                guard abs(dx) > 90, canGo else { dragX = 0; return }

                Haptics.play(.light)
                // Slide out, snap (unanimated) to the other side with the new song.
                dragX = forward ? -rowWidth : rowWidth
                Task {
                    if forward { await engine.playNext() } else { await engine.playPrevious() }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { dragX = 0 }
                }
            }
    }
    #endif

    /// On iOS the app owns the sheet; elsewhere this bar presents it.
    private func openNowPlaying() {
        #if os(iOS)
        iosAppState.showNowPlaying = true
        #else
        showNowPlaying = true
        #endif
    }

    // MARK: - Artist (per-artist tappable)

    /// Stored artist plus features from the title. See `ImportService.displayArtists`.
    private var printedCredit: String {
        guard let track = engine.queue.currentTrack else { return "" }
        return ImportService.displayArtists(title: track.title,
                                            artistName: track.artistName)
            .joined(separator: ", ")
    }

    /// Plain text on every platform; the whole bar is one tap target. Per-artist
    /// links live in Now Playing. Long credits scroll.
    private var artistLine: some View {
        // Slower than the title so the two don't move as one block.
        MarqueeText(text: printedCredit, speed: 15)
    }

    // MARK: - Title

    /// Scrolls like the credit, starting a second later.
    private var titleLine: some View {
        MarqueeText(text: engine.queue.currentTrack?.displayTitle ?? "—",
                    font: .mixBodyBold,
                    color: .mixTextPrimary,
                    startDelay: .seconds(1))
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data  = engine.queue.currentTrack?.displayArtwork,
               let image = mixImage(from: data, displaySize: 40) {
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
