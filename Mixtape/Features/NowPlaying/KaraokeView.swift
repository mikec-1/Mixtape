// KaraokeView.swift
// Mixtape — Features/NowPlaying
//
// The lyrics, alone, at reading-across-the-room size, over the record's own
// colours. Synced lyrics only: without per-line timings there is nothing to
// sing along *to*, and the Now Playing panel is the right place for a wall of
// static text.
//
// Nothing here is new machinery. The word sweep is `WordSweepLine`, the
// per-word spans are `LyricSync`, the instrumental dots are `LyricGapDots` and
// the scroll-and-highlight is `SyncedLyricsView` at its larger size — the same
// view the panel draws, with the type scale turned up. macOS has had this since
// the lyrics popover learned to go fullscreen (`MacLyricsView`); this is the
// iPhone half of it, presented over Now Playing rather than beside a player bar.
//
// Visual only. There is no vocal removal: the streaming path is an `AVPlayer`
// pointed at a remote file, with nowhere to put a filter.

#if os(iOS)
import SwiftUI

struct KaraokeView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    /// `engine.queue` is a plain `let`, so track changes don't republish
    /// through the engine — the same reason Now Playing observes the service.
    @EnvironmentObject private var queueService: QueueService
    @Environment(\.dismiss) private var dismiss

    let lines: [LyricLine]

    @State private var colors: [Color] = ArtworkColors.fallback

    /// Shared with the macOS lyrics view, so a size set on one is the size on
    /// the other.
    @AppStorage("lyricsZoom") private var zoom: Double = 1
    /// Per-song timing correction, in seconds: positive holds the lyrics back.
    @State private var offset: TimeInterval = 0

    /// Transport, seek bar and header fade out while nothing is being touched —
    /// the same three seconds macOS gives its karaoke chrome.
    @State private var awake = true
    @State private var showsTuning = false
    @State private var sleep: Task<Void, Never>?

    private var track: Track? { queueService.currentTrack }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                SyncedLyricsView(lines: lines,
                                 clock: engine.clock,
                                 isPlaying: engine.state.isPlaying,
                                 onTapLine: { engine.seek(to: $0) },
                                 lineFont: .system(size: 30 * zoom, weight: .semibold),
                                 activeFont: .system(size: 30 * zoom, weight: .heavy),
                                 sung: .white,
                                 unsung: .white.opacity(0.4),
                                 gapSize: 34,
                                 lineSpacing: 22,
                                 offset: offset,
                                 hPadding: 24)
                controls
            }
            if showsTuning {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { closeTuning() }
                VStack {
                    HStack {
                        Spacer()
                        tuningCard
                    }
                    Spacer()
                }
            }
        }
        // Anywhere that isn't a lyric or a button brings the chrome back.
        .contentShape(Rectangle())
        // A tap gesture would miss a scroll; this fires the moment a finger
        // lands and doesn't take the drag away from the lyrics list.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if !awake { wake() }
        })
        .onAppear { refreshColors(); loadOffset(); wake() }
        .onChange(of: track?.id) { _, _ in refreshColors(); loadOffset() }
        .onDisappear { sleep?.cancel() }
    }

    // MARK: Idle

    private func wake() {
        withMixAnimation(.easeInOut(duration: 0.3)) { awake = true }
        sleep?.cancel()
        sleep = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withMixAnimation(.easeInOut(duration: 0.35)) { awake = false }
        }
    }

    private func closeTuning() {
        withMixAnimation(.easeOut(duration: 0.2)) { showsTuning = false }
    }

    private func loadOffset() {
        offset = track.map { LyricsOffsets.get(for: $0) } ?? 0
    }

    private func setOffset(_ value: TimeInterval) {
        offset = min(10, max(-10, (value * 2).rounded() / 2))
        if let track { LyricsOffsets.set(offset, for: track) }
        wake()
    }

    private func refreshColors() {
        colors = ArtworkColors.dominantColors(from: track?.displayArtwork)
    }

    // MARK: Chrome

    /// Opaque and darkened. The lyrics are the only thing on screen, so the
    /// background's whole job is to stay out of their way while still being
    /// this record's colour rather than a grey box.
    private var background: some View {
        ZStack {
            LinearGradient(colors: colors.isEmpty ? ArtworkColors.fallback : colors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            Color.black.opacity(0.5)
        }
        .ignoresSafeArea()
        .mixAnimation(.easeInOut(duration: 0.6), value: colors)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.displayTitle ?? "Karaoke")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Every name on the record, not the stored credit — a Discover
                // song stores the headliner alone. Same rule as the player bar.
                if let track {
                    Text(ImportService.displayArtists(title: track.title,
                                                      artistName: track.artistName)
                            .joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            tuning
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityLabel("Close karaoke")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One control for the two adjustments, the way the macOS lyrics header
    /// does it: four bare steppers say nothing about where they are now or how
    /// to get back to normal.
    private var tuning: some View {
        Button {
            withMixAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showsTuning.toggle()
            }
            wake()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(showsTuning || offset != 0 || zoom != 1 ? 0.28 : 0.14),
                            in: Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityLabel("Lyrics timing and size")
    }

    /// The card itself, hung under the header rather than presented as a sheet:
    /// a sheet would cover the lyrics it is adjusting.
    private var tuningCard: some View {
        VStack(spacing: 16) {
            tuningRow(title: "Timing",
                      value: String(format: "%+.1f s", offset),
                      hint: offset == 0 ? "In step" : (offset > 0 ? "Later" : "Earlier"),
                      canReset: offset != 0,
                      onMinus: { setOffset(offset - 0.5) },
                      onPlus:  { setOffset(offset + 0.5) },
                      onReset: { setOffset(0) })

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            tuningRow(title: "Text size",
                      value: "\(Int((zoom * 100).rounded()))%",
                      hint: zoom == 1 ? "Default" : nil,
                      canReset: zoom != 1,
                      onMinus: { setZoom(zoom - 0.1) },
                      onPlus:  { setZoom(zoom + 0.1) },
                      onReset: { setZoom(1) })
        }
        .padding(18)
        .frame(width: 290)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .padding(.trailing, 20)
        .padding(.top, 62)
        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
    }

    private func tuningRow(title: String,
                           value: String,
                           hint: String?,
                           canReset: Bool,
                           onMinus: @escaping () -> Void,
                           onPlus: @escaping () -> Void,
                           onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .opacity(canReset ? 1 : 0)
                .disabled(!canReset)
                .accessibilityLabel("Reset \(title.lowercased())")
            }

            HStack(spacing: 0) {
                stepper("minus", "Decrease \(title.lowercased())", action: onMinus)
                Text(value)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                stepper("plus", "Increase \(title.lowercased())", action: onPlus)
            }
            .frame(height: 38)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }

    private func stepper(_ icon: String,
                         _ label: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.light)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityLabel(label)
    }

    private func setZoom(_ value: Double) {
        zoom = min(1.6, max(0.6, (value * 10).rounded() / 10))
        wake()
    }

    /// Transport plus the seek bar: the chrome that fades together.
    private var controls: some View {
        VStack(spacing: 0) {
            transport
            NowPlayingSeekBar(clock: engine.clock, duration: engine.duration) { time in
                engine.seek(to: time)
                wake()
            }
            .tint(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        // Collapsed rather than merely hidden: the lyrics grow down into the
        // space, the way they take over the player bar on macOS.
        .frame(height: awake ? nil : 0, alignment: .top)
        .opacity(awake ? 1 : 0)
        .clipped()
        .allowsHitTesting(awake)
    }

    /// Just enough transport to not have to leave. Skipping is the one thing
    /// you reach for mid-song, and pausing is the other.
    private var transport: some View {
        HStack(spacing: 36) {
            transportButton("backward.fill", label: "Previous") {
                Task { await engine.playPrevious() }
            }
            transportButton(engine.state.isPlaying ? "pause.fill" : "play.fill",
                            label: engine.state.isPlaying ? "Pause" : "Play",
                            size: 30) {
                engine.togglePlayPause()
            }
            transportButton("forward.fill", label: "Next") {
                Task { await engine.playNext() }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func transportButton(_ icon: String,
                                 label: String,
                                 size: CGFloat = 22,
                                 action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.light)
            action()
            wake()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityLabel(label)
    }
}
#endif
