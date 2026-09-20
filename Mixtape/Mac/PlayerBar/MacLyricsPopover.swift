// MacLyricsPopover.swift
// Mixtape — Mac/PlayerBar
//
// Lyrics view shown from the macOS player bar, styled after Spotify's full
// lyrics view: large bold lines, the active line bright, others dimmed, over an
// album-art–tinted background. Reuses LyricsService (the same resolver as iOS):
// embedded tags → .lrc sidecar → LRCLIB. Synced lyrics get karaoke-style
// highlighting + autoscroll + tap-to-seek; otherwise plain lyrics; otherwise an
// empty state.
//
// Two presentation modes, driven by MacAppState.lyricsFullscreen (persisted):
//   • Windowed — a fixed-size popover from the player bar.
//   • Fullscreen — fills the main content column (between sidebar, toolbar,
//     player bar and right panel), like Spotify, over a solid album-tinted
//     background. Hosted by MacRootView's detail column.
// The header's expand/collapse button toggles between them.

#if os(macOS)
import SwiftUI

struct MacLyricsView: View {

    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @StateObject private var lyricsService = LyricsService.shared

    @State private var isLoading = false

    /// Read straight from the service rather than mirrored into `@State`.
    ///
    /// The mirror was why lyrics the user had just saved didn't appear until
    /// the popover was closed and reopened: `LyricsService.cache` is
    /// `@Published`, so writing to it *did* re-run this body — but the body
    /// then drew a `@State` copy that only `refresh()` ever updated. One source
    /// of truth means a save shows up on the next frame, from anywhere,
    /// without anything having to remember to re-read.
    private var lyrics: TrackLyrics? {
        guard let track = engine.queue.currentTrack else { return nil }
        return lyricsService.cached(for: track)
    }
    @State private var tint: [Color] = []

    private var fullscreen: Bool { appState.lyricsFullscreen }
    /// Big, Spotify-style type in fullscreen; compact in the popover. Scaled by
    /// the user's zoom, clamped so the words always fit the column.
    @AppStorage("lyricsZoom") private var zoom: Double = 1
    private var lineFont: CGFloat { (fullscreen ? 40 : 26) * zoom }
    private var hPadding: CGFloat { fullscreen ? 80 : 28 }

    /// Per-song timing correction, in seconds: positive holds the lyrics back.
    /// Keyed like the user's own lyrics, so it follows the song rather than the
    /// library row.
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
        // The editor is put up by MacRootView, from the main window — see
        // `MacAppState.lyricsEditorTrack`. Its closing is what re-runs this
        // body, which is how a just-saved set of lyrics reaches the screen
        // without the popover being closed and reopened.
        .onChange(of: appState.lyricsEditorTrack == nil) { _, closed in
            if closed { refresh() }
        }
    }

    // MARK: - Background (album-art tint)

    @ViewBuilder
    private var background: some View {
        // In karaoke the backdrop is painted by the root, behind the player bar
        // as well as the words — the bar fades out there, and a gradient that
        // stopped at the top of it left a black band where it had been.
        if appState.karaokeActive {
            Color.clear
        } else {
            windowedBackground
        }
    }

    private var windowedBackground: some View {
        // Solid, fully opaque fill — an album-tinted gradient (no translucency,
        // so nothing behind shows through), darkened for white-text legibility.
        ZStack {
            LinearGradient(
                colors: tint.isEmpty
                    ? [Color(white: 0.16), Color(white: 0.10)]
                    : [tint[0], tint.count > 1 ? tint[1] : tint[0]],
                // Karaoke breathes: the gradient's axis drifts over 14s and
                // back, so the screen is never quite still. Everywhere else the
                // points are fixed — a popover-sized gradient sliding under the
                // words is just movement in the corner of the eye.
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Lighter in fullscreen: with the sidebar and panel gone the
            // gradient is the whole screen, and a 0.45 scrim washed every
            // record down to the same grey.
            Color.black.opacity(fullscreen ? 0.28 : 0.45)
        }
        .mixAnimation(.easeInOut(duration: 0.5), value: tint)
        .ignoresSafeArea()
    }

    // MARK: - Header links
    //
    // Lyrics are an overlay, not a page: leaving them up while the page you
    // asked for opens underneath means the click looks like it did nothing.
    // Both modes close — the fullscreen one already did, via `showOnlineArtist`.

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
                // Every name on the record, same as the player bar: the header
                // used to print the stored credit, which for a Discover song is
                // the headliner alone. Each one is its own link now, as it is
                // in the bar this panel hangs off.
                if engine.queue.currentTrack != nil {
                    MixArtistLine(targets: artistTargets,
                                  font:  .system(size: fullscreen ? 15 : 12),
                                  color: .white.opacity(0.7))
                }
            }
            Spacer()

            // Add / edit the user's own lyrics. Present whatever is on screen:
            // a wrong LRCLIB match is as worth correcting as a missing one, and
            // the header is the only chrome the fullscreen mode keeps.
            if engine.queue.currentTrack != nil {
                headerButton(
                    icon: "square.and.pencil",
                    help: lyrics?.isUserProvided == true ? "Edit your lyrics" : "Add your own lyrics"
                ) { appState.lyricsEditorTrack = engine.queue.currentTrack }
            }

            // Timing + text size live behind one control rather than five in a
            // row: they're adjustments you make once and forget, and spelling
            // them all out crowded the header next to the things you actually
            // reach for (edit, fullscreen, karaoke, close).
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

            // Karaoke. Fullscreen only: it is fullscreen *plus* clearing the
            // window, so there is nothing for it to mean from a popover. Lit
            // while it is on — the control that got you here gets you out.
            if fullscreen {
                headerButton(
                    icon: "music.mic",
                    help: appState.karaokeActive ? "Exit karaoke" : "Karaoke",
                    isActive: appState.karaokeActive
                ) { withMixAnimation(.easeInOut(duration: 0.3)) { appState.toggleKaraoke() } }
            }

            // Close (fullscreen only — the popover dismisses by clicking away).
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
            // The list runs the full height of the window in karaoke so lines
            // rise into view rather than appearing out of a dead strip — which
            // means the bottom one would otherwise sit right on the player bar
            // until the next scroll nudged it clear.
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

    /// Kicks off whatever this track still needs. It no longer *publishes* the
    /// lyrics — `resolve` writes them into the service's cache and `lyrics`
    /// reads them back out — so all that's left here is the artwork tint and
    /// the spinner.
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
    /// Observed here rather than passed as a number, so the tick that moves the
    /// highlight stops at this view instead of redrawing the popover's header,
    /// artwork and buttons with it. See `PlaybackClock`.
    @ObservedObject var clock: PlaybackClock
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

    /// Karaoke drops the hover highlight: the pointer is hidden while the
    /// screen is idle, so a lit line there points at nothing.
    @EnvironmentObject private var appState: MacAppState

    /// Per-word spans, so the active line can be swept rather than flipped on.
    /// Held in state because this view's body re-runs on every clock tick, and
    /// the spans only change when the lyrics do.
    @State private var words: [[LyricWord]] = []

    private var activeIndex: Int? {
        guard !lines.isEmpty else { return nil }
        // No lead. A line stays active until the next one actually begins, so
        // the singer finishing the last word of a line still has that line lit.
        // Leading the match moved on early and left the new line grey for a
        // second or two, which read as the lyrics skipping ahead.
        let now = now()
        var idx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.time <= now { idx = i } else { break }
        }
        return idx
    }

    /// What the list should be centred on: an instrumental's dots while it's
    /// playing, otherwise the line being sung.
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Leading space so the first line can scroll to center.
                    Color.clear.frame(height: 40)

                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        // Only present while it's actually playing (plus a beat of lead-in
                        // so the entry animation has somewhere to start). Outside that the
                        // row doesn't exist at all — three dim dots parked mid-song read as
                        // a stray bullet list.
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
                            if i == activeIndex, i < words.count, !words[i].isEmpty {
                                // Only the line being sung is drawn word by
                                // word: it's the only one whose fill moves, and
                                // a whole song of per-word views would redraw
                                // on every frame for nothing.
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
                                    .foregroundStyle(color(for: i))
                                    .opacity(0.85)
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                            .onTapGesture { onSeek(line.time + offset) }
                            .mixAnimation(.easeInOut(duration: 0.25), value: activeIndex)
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
    private func color(for i: Int) -> Color {
        if i == activeIndex { return .white }
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
