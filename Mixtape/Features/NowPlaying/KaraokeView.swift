// Synced lyrics full screen over the record's colours (iPhone). Reuses
// `SyncedLyricsView` at a larger size; macOS has `MacLyricsView`. Visual only, no vocal removal.

#if os(iOS)
import SwiftUI

struct KaraokeView: View {

    @Environment(PlaybackEngine.self) private var engine
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @Environment(QueueService.self) private var queueService
    @Environment(\.dismiss) private var dismiss

    let lines: [LyricLine]

    @State private var colors: [Color] = ArtworkColors.fallback

    /// Shared with the macOS lyrics view.
    @AppStorage("lyricsZoom") private var zoom: Double = 1
    /// Per-song timing correction, in seconds: positive holds the lyrics back.
    @State private var offset: TimeInterval = 0

    /// Chrome fades after three seconds idle, like macOS.
    @State private var awake = true
    /// VoiceOver can't reach controls that have faded out, so they never do.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
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
                                 lineFont: .system(size: MixFontScale.size(30) * zoom, weight: .semibold),
                                 activeFont: .system(size: MixFontScale.size(30) * zoom, weight: .heavy),
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
        // Fires on touch-down without stealing the lyrics list's scroll.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if !awake { wake() }
        })
        .onAppear { refreshColors(); loadOffset(); wake() }
        .onChange(of: track?.id) { _, _ in refreshColors(); loadOffset() }
        .onChange(of: voiceOver) { _, _ in wake() }
        .onDisappear { sleep?.cancel() }
    }

    // MARK: Idle

    private func wake() {
        withMixAnimation(.easeInOut(duration: 0.3)) { awake = true }
        sleep?.cancel()
        guard !voiceOver else { return }
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

    /// Opaque and darkened, but still this record's colour.
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
                    .font(.system(size: MixFontScale.size(17), weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Every name on the record, not the stored credit. Same rule as the player bar.
                if let track {
                    Text(ImportService.displayArtists(title: track.title,
                                                      artistName: track.artistName)
                            .joined(separator: ", "))
                        .font(.system(size: MixFontScale.size(13)))
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

    /// One control for both adjustments, like the macOS lyrics header.
    private var tuning: some View {
        Button {
            withMixAnimation(.mixSnappy) {
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

    /// Hung under the header, not a sheet, so it doesn't cover the lyrics.
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
                    .font(.system(size: MixFontScale.size(14), weight: .semibold))
                    .foregroundStyle(.white)
                if let hint {
                    Text(hint)
                        .font(.system(size: MixFontScale.size(11)))
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
                    .font(.system(size: MixFontScale.size(15), weight: .bold).monospacedDigit())
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
        // Collapsed so the lyrics grow into the space.
        .frame(height: awake ? nil : 0, alignment: .top)
        .opacity(awake ? 1 : 0)
        .clipped()
        .allowsHitTesting(awake)
    }

    /// Minimal transport: pause and skip.
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
