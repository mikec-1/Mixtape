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

    @State private var lyrics: TrackLyrics?
    @State private var isLoading = false
    @State private var tint: [Color] = []

    private var fullscreen: Bool { appState.lyricsFullscreen }
    /// Big, Spotify-style type in fullscreen; compact in the popover.
    private var lineFont: CGFloat { fullscreen ? 40 : 26 }
    private var hPadding: CGFloat { fullscreen ? 80 : 28 }

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
    }

    // MARK: - Background (album-art tint)

    private var background: some View {
        // Solid, fully opaque fill — an album-tinted gradient (no translucency,
        // so nothing behind shows through), darkened for white-text legibility.
        ZStack {
            LinearGradient(
                colors: tint.isEmpty
                    ? [Color(white: 0.16), Color(white: 0.10)]
                    : [tint[0], tint.count > 1 ? tint[1] : tint[0]],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            MacArtworkView(data: engine.queue.currentTrack?.artworkData, size: fullscreen ? 56 : 40, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.queue.currentTrack?.title ?? "Lyrics")
                    .font(.system(size: fullscreen ? 20 : 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = engine.queue.currentTrack?.artistName {
                    Text(artist)
                        .font(.system(size: fullscreen ? 15 : 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()

            // Expand / collapse fullscreen.
            headerButton(
                icon: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: fullscreen ? "Exit fullscreen" : "Fullscreen"
            ) { withAnimation(.easeInOut(duration: 0.25)) { appState.toggleLyricsFullscreen() } }

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

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered { ProgressView().controlSize(.large).tint(.white) }
        } else if let lyrics, lyrics.hasSynced {
            MacSyncedLyrics(lines: lyrics.synced, currentTime: engine.currentTime,
                            fontSize: lineFont, hPadding: hPadding) { time in
                engine.seek(to: time)
            }
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
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Resolution

    private func refresh() {
        tint = ArtworkColors.dominantColors(from: engine.queue.currentTrack?.artworkData)
        guard let track = engine.queue.currentTrack else {
            lyrics = nil
            return
        }
        let cached = lyricsService.cached(for: track)
        lyrics = cached
        if let cached, cached.hasSynced { return }

        isLoading = (cached == nil)
        Task {
            let resolved = await lyricsService.resolve(for: track)
            if engine.queue.currentTrack?.id == track.id, resolved.hasAny {
                lyrics = resolved
            }
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
    let currentTime: TimeInterval
    let fontSize: CGFloat
    let hPadding: CGFloat
    let onSeek: (TimeInterval) -> Void

    @State private var hovered: Int? = nil

    private var activeIndex: Int? {
        guard !lines.isEmpty else { return nil }
        let lead = LyricSync.leadOffset
        var idx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.time <= currentTime + lead { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Leading space so the first line can scroll to center.
                    Color.clear.frame(height: 40)

                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(color(for: i))
                            .opacity(i == activeIndex ? 1 : 0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                            .onTapGesture { onSeek(line.time) }
                            .animation(.easeInOut(duration: 0.25), value: activeIndex)
                            .id(i)
                    }

                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, hPadding)
            }
            .onChange(of: activeIndex) { _, idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
            .onAppear {
                guard let idx = activeIndex else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    /// Active line: bright white. Past/upcoming: dimmed white. Hovered: brighten.
    private func color(for i: Int) -> Color {
        if i == activeIndex { return .white }
        if i == hovered     { return .white.opacity(0.85) }
        return .white.opacity(0.45)
    }
}

#endif
