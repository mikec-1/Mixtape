// Player-bar lyrics, Spotify style: big lines, active one bright, synced
// highlighting + autoscroll + tap-to-seek, else plain text, else empty state.
// Uses LyricsService (tags > .lrc > LRCLIB).
// Windowed (popover) or fullscreen (content column), via MacAppState.lyricsFullscreen.

#if os(macOS)
import SwiftUI

struct MacLyricsView: View {

    @Environment(PlaybackEngine.self) private var engine
    @Environment(MacAppState.self) private var appState
    private var lyricsService: LyricsService { .shared }

    @State private var isLoading = false

    /// Read straight from the service (`@Published`) so saved lyrics show immediately.
    private var lyrics: TrackLyrics? {
        guard let track = engine.queue.currentTrack else { return nil }
        return lyricsService.cached(for: track)
    }
    @State private var tint: [Color] = []

    private var fullscreen: Bool { appState.lyricsFullscreen }
    /// Scaled by the user's zoom, clamped to fit the column.
    @AppStorage("lyricsZoom") private var zoom: Double = 1
    private var lineFont: CGFloat { (fullscreen ? 40 : 26) * zoom }
    private var hPadding: CGFloat { fullscreen ? 80 : 28 }

    /// Per-song timing offset in seconds; positive holds lyrics back. Keyed like user lyrics.
    @State private var offset: TimeInterval = 0

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
        }
        .modifier(LyricsFrame(fullscreen: fullscreen))
        .onAppear { refresh() }
        .onChange(of: engine.queue.currentTrack?.id) { _, _ in refresh() }
        // MacRootView presents the editor; its closing re-runs this body.
        .onChange(of: appState.lyricsEditorTrack == nil) { _, closed in
            if closed { refresh() }
        }
    }

    // MARK: - Background (album-art tint)

    @ViewBuilder
    private var background: some View {
        // In karaoke the root paints the backdrop, behind the player bar too.
        if appState.karaokeActive {
            Color.clear
        } else {
            windowedBackground
        }
    }

    private var windowedBackground: some View {
        // Opaque album-tinted gradient, darkened for white text.
        ZStack {
            LinearGradient(
                colors: tint.isEmpty
                    ? [Color(white: 0.16), Color(white: 0.10)]
                    : [tint[0], tint.count > 1 ? tint[1] : tint[0]],
                // Axis drifts in karaoke only.
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Lighter scrim in fullscreen so covers don't all go grey.
            Color.black.opacity(fullscreen ? 0.28 : 0.45)
        }
        .mixAnimation(.easeInOut(duration: 0.5), value: tint)
        .ignoresSafeArea()
    }

    // MARK: - Header links
    // Lyrics are an overlay, so navigating away closes them.

    private func closingLyrics(_ go: @escaping () -> Void) -> () -> Void {
        { appState.lyricsPresented = false; go() }
    }

    private var albumTarget: (() -> Void)? {
        guard let track = engine.queue.currentTrack,
              let go = TrackLinks.album(for: track, appState: appState) else { return nil }
        return closingLyrics(go)
    }

    private var artistTargets: [(name: String, action: () -> Void)] {
        guard let track = engine.queue.currentTrack else { return [] }
        return TrackLinks.artists(for: track, appState: appState).map {
            ($0.name, closingLyrics($0.action))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            MacArtworkView(data: engine.queue.currentTrack?.displayArtwork, size: fullscreen ? 56 : 40, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                MixLinkText(text:  engine.queue.currentTrack?.displayTitle ?? "Lyrics",
                            font:  .system(size: fullscreen ? 20 : 15, weight: .bold),
                            color: .white,
                            target: albumTarget)
                // Every credited name, each a link, like the player bar.
                if engine.queue.currentTrack != nil {
                    MixArtistLine(targets: artistTargets,
                                  font:  .system(size: fullscreen ? 15 : 12),
                                  color: .white.opacity(0.7))
                }
            }
            Spacer()

            if let track = engine.queue.currentTrack, let lyrics, lyrics.hasAny {
                // Fullscreen keeps timing in the tuning popover.
                LyricsSourceBar(track: track, lyrics: lyrics, offset: $offset, showsNudge: !fullscreen,
                                fill: .white.opacity(0.12), ink: .white.opacity(0.85), height: 30)
                headerButton(icon: MixtapeIcons.share, help: "Share lyrics as a card") {
                    appState.lyricCard = LyricCardRequest(track: track, lyrics: lyrics)
                    appState.lyricsPresented = false
                }
            }

            // Add/edit user lyrics, even over a found match.
            if engine.queue.currentTrack != nil {
                headerButton(
                    icon: "square.and.pencil",
                    help: lyrics?.isUserProvided == true ? "Edit your lyrics" : "Add your own lyrics"
                ) { appState.lyricsEditorTrack = engine.queue.currentTrack }
            }

            // Timing and text size in one menu.
            if fullscreen {
                headerButton(icon: "slider.horizontal.3",
                             help: "Lyrics timing and size",
                             isActive: showsTuning || offset != 0 || zoom != 1) {
                    showsTuning.toggle()
                }
                .popover(isPresented: $showsTuning, arrowEdge: .bottom) { tuningPopover }

                headerDivider
            }

            // Expand / collapse fullscreen.
            headerButton(
                icon: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: fullscreen ? "Exit fullscreen" : "Fullscreen"
            ) { withMixAnimation(.easeInOut(duration: 0.25)) { appState.toggleLyricsFullscreen() } }

            // Fullscreen only; lit while on.
            if fullscreen {
                headerButton(
                    icon: "music.mic",
                    help: appState.karaokeActive ? "Exit karaoke" : "Karaoke",
                    isActive: appState.karaokeActive
                ) { withMixAnimation(.easeInOut(duration: 0.3)) { appState.toggleKaraoke() } }
            }

            // Fullscreen only; the popover dismisses by clicking away.
            if fullscreen {
                headerButton(icon: "xmark", help: "Close lyrics") {
                    appState.lyricsPresented = false
                }
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.top, fullscreen ? 28 : 22)
        .padding(.bottom, 8)
    }

    @State private var showsTuning = false

    /// Hairline between the adjustments and the actions beside them.
    private var headerDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private var tuningPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lyrics?.hasSynced == true {
                tuningRow(title: "Timing",
                          value: String(format: "%+.1f s", offset),
                          canReset: offset != 0,
                          onMinus: { setOffset(offset - 0.5) },
                          onPlus:  { setOffset(offset + 0.5) },
                          onReset: { setOffset(0) })
                Text("Nudge the lyrics later or earlier if they run out of step.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            tuningRow(title: "Text size",
                      value: "\(Int((zoom * 100).rounded()))%",
                      canReset: zoom != 1,
                      onMinus: { zoom = max(0.6, (zoom - 0.1).rounded(toPlaces: 1)) },
                      onPlus:  { zoom = min(1.6, (zoom + 0.1).rounded(toPlaces: 1)) },
                      onReset: { zoom = 1 })
        }
        .padding(16)
        .frame(width: 260)
    }

    private func tuningRow(title: String,
                           value: String,
                           canReset: Bool,
                           onMinus: @escaping () -> Void,
                           onPlus: @escaping () -> Void,
                           onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Button(action: onReset) { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).mixHandCursor()
                .help("Reset")
                .opacity(canReset ? 1 : 0)
                .disabled(!canReset)
            Button(action: onMinus) { Image(systemName: "minus") }
                .buttonStyle(.borderless).mixHandCursor()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 52)
            Button(action: onPlus) { Image(systemName: "plus") }
                .buttonStyle(.borderless).mixHandCursor()
        }
    }

    private func setOffset(_ value: TimeInterval) {
        guard let track = engine.queue.currentTrack else { return }
        offset = min(10, max(-10, (value * 2).rounded() / 2))
        LyricsOffsets.set(offset, for: track)
    }

    private func headerButton(icon: String,
                              help: String,
                              isActive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.mixOnAccent : .white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(isActive ? Color.mixAccentFill : .white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered { ProgressView().controlSize(.large).tint(.white) }
        } else if let lyrics, lyrics.hasSynced {
            MacSyncedLyrics(lines: lyrics.synced, clock: engine.clock,
                            isPlaying: engine.state.isPlaying,
                            fontSize: lineFont, hPadding: hPadding, offset: offset) { time in
                engine.seek(to: time)
            }
            // Bottom margin in karaoke so the last line clears the player bar.
            .contentMargins(.bottom, appState.karaokeActive ? MacPlayerBar.height + 64 : 0,
                            for: .scrollContent)
        } else if let plain = lyrics?.plain, !plain.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(plain)
                    .font(.system(size: lineFont, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, hPadding)
                    .padding(.vertical, 24)
            }
        } else {
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(engine.queue.currentTrack == nil ? "Nothing playing" : "No lyrics found")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    // Four sources came back empty; the user is the fifth.
                    if engine.queue.currentTrack != nil {
                        Button { appState.lyricsEditorTrack = engine.queue.currentTrack } label: {
                            Text("Add Lyrics")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.16), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Resolution

    /// Starts lyric resolution (the view reads the cache), artwork tint and spinner.
    private func refresh() {
        tint = ArtworkColors.dominantColors(from: engine.queue.currentTrack?.displayArtwork)
        guard let track = engine.queue.currentTrack else {
            isLoading = false
            offset = 0
            return
        }
        offset = LyricsOffsets.get(for: track)
        let cached = lyricsService.cached(for: track)
        if let cached, cached.hasSynced || cached.isUserProvided {
            isLoading = false
            return
        }

        isLoading = (cached == nil)
        Task {
            await lyricsService.resolve(for: track)
            isLoading = false
        }
    }
}

/// Fixed popover size when windowed; fill the window when fullscreen.
private struct LyricsFrame: ViewModifier {
    let fullscreen: Bool
    func body(content: Content) -> some View {
        if fullscreen {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(width: 560, height: 660)
        }
    }
}

// MARK: - Synced lyrics (Spotify-style: big bold lines, active bright, rest dimmed)

private struct MacSyncedLyrics: View {
    let lines: [LyricLine]
    /// Observed here so clock ticks only redraw this view. See `PlaybackClock`.
    var clock: PlaybackClock
    /// Stops the per-frame sweep redrawing a line that isn't moving.
    let isPlaying: Bool
    let fontSize: CGFloat
    let hPadding: CGFloat
    /// Seconds the lyrics should lag the audio by (user correction).
    let offset: TimeInterval
    let onSeek: (TimeInterval) -> Void

    /// Playback position as the *lyrics* see it.
    private func now() -> TimeInterval { clock.interpolatedTime() - offset }

    @State private var hovered: Int? = nil

    /// Karaoke drops the hover highlight since the pointer is hidden.
    @Environment(MacAppState.self) private var appState

    /// Per-word spans, cached since body runs every tick.
    @State private var words: [[LyricWord]] = []
    @AppStorage(LyricsSourceBar.byLineKey) private var byLine = false

    private var activeIndex: Int? {
        guard !lines.isEmpty else { return nil }
        // No lead: a line stays active until the next begins.
        let now = now()
        var idx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.time <= now { idx = i } else { break }
        }
        return idx
    }

    /// Instrumental dots while playing, else the sung line.
    private var scrollTarget: String? {
        let next = (activeIndex ?? -1) + 1
        if next < lines.count,
           let gap = LyricSync.instrumentalGap(before: next, lines: lines, words: words) {
            let now = now()
            if now >= gap.start, now < gap.end { return "gap-\(next)" }
        }
        guard let idx = activeIndex else { return nil }
        return "line-\(idx)"
    }

    var body: some View {
        // Once per tick, not per line: each read scans every line.
        let active = activeIndex
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Leading space so the first line can scroll to center.
                    Color.clear.frame(height: 40)

                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        // Only exists while playing (plus a lead-in).
                        if let gap = LyricSync.instrumentalGap(before: i, lines: lines, words: words),
                           clock.currentTime - offset >= gap.start - 0.2, clock.currentTime - offset < gap.end {
                            TimelineView(.animation(paused: !isPlaying)) { _ in
                                LyricGapDots(start: gap.start, end: gap.end,
                                             time: now(), color: .white,
                                             fontSize: fontSize)
                            }
                            .padding(.vertical, 4)
                            .id("gap-\(i)")
                        }
                        Group {
                            if i == active, !byLine, i < words.count, !words[i].isEmpty {
                                // Only the active line draws per word.
                                TimelineView(.animation(paused: !isPlaying)) { _ in
                                    WordSweepLine(
                                        words: words[i],
                                        time: now() + LyricSync.sweepOffset,
                                        font: .system(size: fontSize, weight: .bold),
                                        sung: .white,
                                        unsung: .white.opacity(0.45)
                                    )
                                }
                            } else {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: fontSize, weight: .bold))
                                    .foregroundStyle(color(for: i, active: active))
                                    .opacity(0.85)
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                            .onTapGesture { onSeek(line.time + offset) }
                            .mixAnimation(.easeInOut(duration: 0.25), value: active)
                            .id("line-\(i)")
                    }

                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, hPadding)
            }
            .onChange(of: lines) { _, new in
                words = LyricSync.words(for: new)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withMixAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onAppear {
                words = LyricSync.words(for: lines)
                guard let idx = activeIndex else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("line-\(idx)", anchor: .center)
                }
            }
        }
    }

    /// Active line: bright white. Past/upcoming: dimmed white. Hovered: brighten.
    private func color(for i: Int, active: Int?) -> Color {
        if i == active { return .white }
        if i == hovered, !appState.karaokeActive { return .white.opacity(0.85) }
        return .white.opacity(0.45)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}

#endif
