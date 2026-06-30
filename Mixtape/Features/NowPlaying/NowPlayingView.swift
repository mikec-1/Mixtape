// NowPlayingView.swift
// Mixtape — Features/NowPlaying
//
// Full-screen player sheet.
// All state comes from PlaybackEngine and QueueService (@EnvironmentObject).
//
// Overhaul: ambient album-art background, synced/plain lyrics panel, and new
// playback controls (sleep timer, playback speed, Up Next reorder).

import SwiftUI

public struct NowPlayingView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    @Environment(\.dismiss)  private var dismiss

    /// Lyrics resolution + caching.
    @StateObject private var lyricsService = LyricsService.shared

    /// True while the user is dragging the seek slider (freeze timer updates).
    @State private var isScrubbing = false
    @State private var scrubValue:  Double = 0

    /// Ambient background colours derived from current artwork.
    @State private var ambientColors: [Color] = ArtworkColors.fallback

    /// Lyrics for the current track (nil = not yet resolved this appearance).
    @State private var lyrics: TrackLyrics?
    @State private var isLoadingLyrics = false

    /// Sheets / panels.
    @State private var showLyrics  = false
    @State private var showUpNext  = false
    @State private var showGetInfo = false

    /// Drives the swipe-to-skip slide transition on the artwork.
    @State private var artworkSlide: CGFloat = 0

    public var body: some View {
        ZStack {
            ambientBackground
            content
        }
        // Keep scrub value in sync while NOT dragging
        .onChange(of: engine.currentTime) { _, t in
            if !isScrubbing { scrubValue = t }
        }
        .onChange(of: engine.duration) { _, d in
            if !isScrubbing, d > 0 { scrubValue = engine.currentTime }
        }
        // React to track changes: refresh ambient colours + lyrics.
        .onChange(of: engine.queue.currentTrack?.id) { _, _ in
            refreshForCurrentTrack()
        }
        .onAppear { refreshForCurrentTrack() }
        .sheet(isPresented: $showUpNext) {
            UpNextSheet()
                .environmentObject(engine)
        }
        .sheet(isPresented: $showGetInfo) {
            if let track = engine.queue.currentTrack {
                GetInfoSheet(
                    track: track,
                    isOnline: deps.onlineCoordinator.hasActiveOnlineSession
                )
            }
        }
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            // Animated gradient from the dominant artwork colours.
            LinearGradient(
                colors: gradientStops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: ambientColors)

            // Dark scrim keeps text legible over bright artwork.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.25),
                    Color.black.opacity(0.55),
                    Color.mixBackground.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Builds 2-3 gradient stops from ambient colours with a dark anchor.
    private var gradientStops: [Color] {
        var stops = ambientColors.prefix(3).map { $0.opacity(0.85) }
        if stops.isEmpty { stops = [Color.mixPrimary.opacity(0.45)] }
        stops.append(Color.mixBackground)
        return Array(stops)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            if showLyrics {
                lyricsPanel
                Spacer(minLength: 20)
            } else {
                artworkView
                Spacer(minLength: 28)
            }
            trackInfo
            Spacer(minLength: 22)
            seekBar
            Spacer(minLength: 24)
            controls
            Spacer(minLength: 28)
            bottomRow
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Top Bar

    /// chevron.down (dismiss) · context label · ellipsis (••• menu).
    private var topBar: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("PLAYING FROM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
                    .tracking(0.8)
                Text(deps.onlineCoordinator.hasActiveOnlineSession ? "Discover" : "Library")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
            }
            .lineLimit(1)

            Spacer()

            optionsMenu
        }
        .padding(.top, 8)
    }

    // MARK: - Options (•••) Menu

    private var optionsMenu: some View {
        Menu {
            if let track = engine.queue.currentTrack {
                let targetPlaylists = deps.libraryService.playlists.filter {
                    !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id)
                }
                if !targetPlaylists.isEmpty {
                    Menu("Add to Playlist") {
                        ForEach(targetPlaylists) { pl in
                            Button(pl.name) {
                                deps.libraryService.addTrack(id: track.id, toPlaylist: pl.id)
                                deps.showToast("Added to \(pl.name)")
                            }
                        }
                    }
                }
            }

            if deps.onlineCoordinator.hasActiveOnlineSession,
               let onlineTrack = deps.onlineCoordinator.currentOnlineTrack {
                Button {
                    Task {
                        await deps.onlineCoordinator.addToLibrary(onlineTrack)
                        deps.showToast("Added to Library")
                    }
                } label: {
                    Label("Add to Library", systemImage: "plus.circle")
                }
            }

            Divider()

            Menu("Playback Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        engine.setRate(Float(rate))
                    } label: {
                        Label(
                            speedLabel(rate),
                            systemImage: abs(Double(engine.playbackRate) - rate) < 0.01 ? "checkmark" : ""
                        )
                    }
                }
            }

            Menu("Sleep Timer") {
                if engine.sleepTimerRemaining != nil {
                    Button(role: .destructive) {
                        engine.cancelSleepTimer()
                    } label: {
                        Label("Cancel Timer", systemImage: "xmark")
                    }
                    Divider()
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) min") {
                        engine.setSleepTimer(TimeInterval(minutes * 60))
                    }
                }
            }

            Menu("Crossfade") {
                ForEach(CrossfadeMode.allCases) { mode in
                    Button {
                        engine.setCrossfadeMode(mode)
                    } label: {
                        Label(
                            mode.title,
                            systemImage: engine.crossfadeMode == mode ? "checkmark" : ""
                        )
                    }
                }
            }

            Divider()

            Button {
                showGetInfo = true
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data = engine.queue.currentTrack?.artworkData,
               let image = platformImage(from: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.mixSurface2
                    .overlay(
                        Image(systemName: MixtapeIcons.track)
                            .font(.system(size: 72))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .scaleEffect(engine.state.isPlaying ? 1.0 : 0.92)
        .offset(x: artworkSlide)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: engine.state.isPlaying)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < -50 {
                        // Swipe left → next.
                        withAnimation(.easeInOut(duration: 0.18)) { artworkSlide = -320 }
                        Task {
                            await engine.playNext()
                            artworkSlide = 320
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { artworkSlide = 0 }
                        }
                    } else if value.translation.width > 50 {
                        // Swipe right → previous.
                        withAnimation(.easeInOut(duration: 0.18)) { artworkSlide = 320 }
                        Task {
                            await engine.playPrevious()
                            artworkSlide = -320
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { artworkSlide = 0 }
                        }
                    }
                }
        )
    }

    // MARK: - Lyrics Panel

    private var lyricsPanel: some View {
        VStack(spacing: 0) {
            if isLoadingLyrics {
                Spacer()
                ProgressView()
                    .tint(Color.mixTextSecondary)
                Spacer()
            } else if let lyrics, lyrics.hasSynced {
                SyncedLyricsView(lines: lyrics.synced, currentTime: engine.currentTime) { time in
                    engine.seek(to: time)
                    scrubValue = time
                }
            } else if let plain = lyrics?.plain, !plain.isEmpty {
                ScrollView {
                    Text(plain)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.mixTextTertiary)
                    Text("No lyrics found")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }

    // MARK: - Track Info

    private var trackInfo: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                showGetInfo = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.queue.currentTrack?.title ?? "—")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(engine.queue.currentTrack?.artistName ?? "")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            // Heart / favourite
            if let track = engine.queue.currentTrack {
                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                Button {
                    deps.libraryService.toggleFavourite(trackID: track.id)
                } label: {
                    Image(systemName: favoured ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Seek Bar

    private var seekBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: $scrubValue,
                in: 0...(max(engine.duration, 1))
            ) { editing in
                isScrubbing = editing
                if !editing { engine.seek(to: scrubValue) }
            }
            .tint(Color.mixPrimary)

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : engine.currentTime))
                Spacer()
                Text("-" + formatTime(max(0, engine.duration - (isScrubbing ? scrubValue : engine.currentTime))))
            }
            .font(.mixCaption)
            .foregroundStyle(Color.mixTextTertiary)
        }
    }

    // MARK: - Bottom Row (Lyrics · Share · AirPlay · Up Next)

    private var bottomRow: some View {
        HStack(spacing: 0) {
            // Lyrics toggle (left) — primary, on-screen access (not buried in •••).
            NPButton(icon: "quote.bubble", isActive: showLyrics, size: 18) {
                withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() }
            }

            Spacer()

            // Share · AirPlay · Up Next (right).
            HStack(spacing: 16) {
                if let track = engine.queue.currentTrack {
                    ShareLink(item: "\(track.title) — \(track.artistName)") {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                #if os(iOS)
                AirPlayButton()
                    .frame(width: 44, height: 44)
                #endif
                NPButton(icon: MixtapeIcons.queue, size: 18) {
                    showUpNext = true
                }
            }
        }
    }

    // MARK: - Playback Controls

    private var controls: some View {
        // spacing: 0 + flexible Spacers — the spacing must NOT be added on top of
        // the Spacers or the row's minimum width exceeds the screen and shoves the
        // whole layout off-edge. The Spacers spread the cluster evenly to fill.
        HStack(spacing: 0) {
            // Shuffle
            NPButton(
                icon:     engine.queue.shuffleEnabled ? MixtapeIcons.shuffle : MixtapeIcons.shuffle,
                isActive: engine.queue.shuffleEnabled,
                size:     20
            ) { engine.queue.toggleShuffle() }

            Spacer(minLength: 8)

            // Skip back
            NPButton(icon: MixtapeIcons.skipBack, size: 28) {
                Task { await engine.playPrevious() }
            }

            Spacer(minLength: 8)

            // Play / Pause (primary)
            Button {
                engine.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.mixPrimary)
                        .frame(width: 68, height: 68)
                    if engine.state == .loading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: engine.state.isPlaying ? MixtapeIcons.pause : MixtapeIcons.play)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: engine.state.isPlaying ? 0 : 2)
                    }
                }
            }
            .disabled(engine.state == .loading)

            Spacer(minLength: 8)

            // Skip forward
            NPButton(icon: MixtapeIcons.skipForward, size: 28) {
                Task { await engine.playNext() }
            }

            Spacer(minLength: 8)

            // Repeat
            NPButton(
                icon:     engine.queue.repeatMode.systemImage,
                isActive: engine.queue.repeatMode != .off,
                size:     20
            ) { engine.queue.cycleRepeat() }
        }
    }

    // MARK: - Volume

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: MixtapeIcons.volumeLow)
                .foregroundStyle(Color.mixTextTertiary)
            #if os(iOS)
            // MPVolumeView renders the system volume slider on iOS
            SystemVolumeSlider()
                .frame(height: 30)
            #else
            Slider(value: .constant(0.7))
                .tint(Color.mixTextSecondary)
            #endif
            Image(systemName: MixtapeIcons.volumeHigh)
                .foregroundStyle(Color.mixTextTertiary)
        }
        .font(.system(size: 14))
    }

    // MARK: - Track-change side effects

    private func refreshForCurrentTrack() {
        // Ambient colours from artwork (cheap, synchronous).
        ambientColors = ArtworkColors.dominantColors(from: engine.queue.currentTrack?.artworkData)

        // Lyrics (cached or async fetch).
        guard let track = engine.queue.currentTrack else {
            lyrics = nil
            return
        }
        // Show whatever we have instantly. A plain-only (or missing) result still
        // falls through to resolve() so we keep trying to upgrade to interactive
        // synced lyrics rather than getting stuck on a plain block.
        let cached = lyricsService.cached(for: track)
        lyrics = cached
        if let cached, cached.hasSynced { return }

        isLoadingLyrics = (cached == nil)
        Task {
            let resolved = await lyricsService.resolve(for: track)
            // Only apply if still the same track.
            if engine.queue.currentTrack?.id == track.id, resolved.hasAny {
                lyrics = resolved
            }
            isLoadingLyrics = false
        }
    }

    // MARK: - Helpers

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func speedLabel(_ rate: Double) -> String {
        if rate == 1.0 { return "1x" }
        // Trim trailing zeros: 0.5 -> "0.5x", 1.25 -> "1.25x"
        let str = String(format: "%g", rate)
        return "\(str)x"
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

// MARK: - Synced Lyrics View

/// Auto-scrolling synced lyrics with the active line highlighted.
private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let currentTime: TimeInterval
    let onTapLine: (TimeInterval) -> Void

    /// Index of the line whose timestamp is the latest <= currentTime.
    /// A small lead offset advances highlighting slightly so lines light up as
    /// they're sung rather than 1–2s late (LRC timestamps mark a line's start and
    /// the 0.5s progress tick adds latency on top).
    private var activeIndex: Int? {
        let lead = LyricSync.leadOffset
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= currentTime + lead { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        let isActive = (i == activeIndex)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.mixBody)
                            .fontWeight(isActive ? .bold : .regular)
                            .foregroundStyle(isActive ? Color.mixTextPrimary : Color.mixTextSecondary.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { onTapLine(line.time) }
                    }
                }
                .padding(.vertical, 24)
            }
            .onChange(of: activeIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Up Next Sheet

/// Drag-to-reorder list of upcoming queue items.
private struct UpNextSheet: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    /// Upcoming tracks (after the current index) paired with their queue index.
    private var upcoming: [(index: Int, track: Track)] {
        let start = engine.queue.currentIndex + 1
        guard start < engine.queue.queue.count else { return [] }
        return (start..<engine.queue.queue.count).map { ($0, engine.queue.queue[$0]) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if upcoming.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: MixtapeIcons.queue)
                            .font(.system(size: 40))
                            .foregroundStyle(Color.mixTextTertiary)
                        Text("Nothing up next")
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mixBackground)
                } else {
                    List {
                        ForEach(upcoming, id: \.track.id) { item in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.track.title)
                                        .font(.mixBody)
                                        .foregroundStyle(Color.mixTextPrimary)
                                        .lineLimit(1)
                                    Text(item.track.artistName)
                                        .font(.mixCaption)
                                        .foregroundStyle(Color.mixTextSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .listRowBackground(Color.mixSurface)
                        }
                        .onMove(perform: move)
                    }
                    .listStyle(.plain)
                    #if os(iOS)
                    .environment(\.editMode, .constant(.active))
                    #endif
                }
            }
            .navigationTitle("Up Next")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Maps the list's local offsets back to absolute queue indices.
    private func move(from source: IndexSet, to destination: Int) {
        let base = engine.queue.currentIndex + 1
        guard let first = source.first else { return }
        let fromIndex = base + first
        let toIndex = base + destination
        // moveQueueItem uses the same destination semantics as Array.move(...)
        engine.queue.moveQueueItem(from: fromIndex, to: toIndex)
    }
}

// MARK: - Helper Views

/// Icon button used inside the controls row.
private struct NPButton: View {
    let icon: String
    var isActive: Bool = false
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isActive ? Color.mixPrimary : Color.mixTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps MPVolumeView (system volume slider) on iOS.
#if os(iOS)
import MediaPlayer
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.tintColor = UIColor(Color.mixTextSecondary)
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Native AirPlay / route picker (AirPlay, Bluetooth, speaker).
import AVKit
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Color.mixTextSecondary)
        v.activeTintColor = UIColor(Color.mixPrimary)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - Get Info Sheet

/// Read-only metadata for the current track.
private struct GetInfoSheet: View {
    let track: Track
    let isOnline: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("Title", track.title)
                row("Artist", track.artistName)
                if !track.albumTitle.isEmpty { row("Album", track.albumTitle) }
                row("Duration", formatTime(track.duration))
                if let year = track.year { row("Year", String(year)) }
                if let genre = track.genre, !genre.isEmpty { row("Genre", genre) }
                row("Source", isOnline ? "Streaming (Discover)" : "Library")
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Song Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
            Spacer()
            Text(value)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    NowPlayingView()
        .environmentObject(deps)
        .environmentObject(deps.playbackEngine)
}
