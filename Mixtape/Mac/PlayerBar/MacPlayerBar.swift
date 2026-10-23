// Now-playing bar pinned to the bottom of the main window: track info on the
// left, transport + scrubber in the centre, volume and extras on the right.

#if os(macOS)
import SwiftUI

struct MacPlayerBar: View {

    /// Bar height without the hairline, for overlays that have to clear it.
    static let height: CGFloat = 72

    @Environment(PlaybackEngine.self) private var engine
    @Environment(MacAppState.self) private var appState
    @Environment(AppDependencies.self) private var deps
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator
    /// Observed directly: `engine.queue` is a plain `let`, so shuffle/repeat
    /// changes don't publish through the engine.
    @Environment(QueueService.self) private var queueService


    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.mixSeparator.opacity(appState.karaokeActive ? 0.4 : 1))

            // Above the bar, so it reads as the Jam the whole player belongs to.
            JamStrip(jam: deps.jam, hPadding: 20)

            // Outer columns are equally flexible so the transport stays centred and the
            // title gets the leftover width. The centre is bounded, so it's sized first.
            HStack(spacing: 20) {
                nowPlayingSection
                    .frame(maxWidth: .infinity, alignment: .leading)

                centerSection
                    .frame(minWidth: 300, maxWidth: 520)

                rightSection
                    .frame(width: 200, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .frame(height: Self.height)

            // Which device the controls are driving.
            // ponytail: grows the bar 24pt while showing, so toasts placed off
            // `height` sit a little low; fold it into `height` if that shows.
            WithActiveRemote(continuity: deps.continuity) { remote in
                if let remote {
                    RemoteDeviceStrip(device: remote, hPadding: 20)
                }
            }
        }
        // Flat, not a Material: at the window edge a material blends with the desktop
        // behind the window. Opaque: a see-through bar over moving lyrics is unreadable.
        // In karaoke it takes the album tint under the backdrop's scrim.
        .background {
            if appState.karaokeActive {
                ZStack {
                    (karaokeTint ?? Color(white: 0.12))
                    // Light scrim only; the tint is already darkened like the backdrop.
                    Color.black.opacity(0.22)
                }
            } else {
                MixGlassBackground { Color.mixSurface }
            }
        }
        .onAppear(perform: refreshKaraokeTint)
        .onChange(of: appState.karaokeActive) { _, _ in refreshKaraokeTint() }
        .onChange(of: queueService.currentTrack?.id) { _, _ in refreshKaraokeTint() }
    }

    /// The karaoke gradient's bottom colour, where the bar sits.
    @State private var karaokeTint: Color? = nil

    private func refreshKaraokeTint() {
        guard appState.karaokeActive else { karaokeTint = nil; return }
        let tint = KaraokeBackdrop.chromeTint(for: queueService.currentTrack?.displayArtwork)
        withMixAnimation(.easeInOut(duration: 0.5)) { karaokeTint = tint }
    }

    // MARK: - Now Playing  (crossfades on track change via .id)

    private var nowPlayingSection: some View {
        Group {
            if let track = queueService.currentTrack {
                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                HStack(spacing: 10) {
                    MacArtworkView(data: track.artworkData, artworkRef: .track(track.id), size: 44, cornerRadius: 6)
                        .mixShadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .modifier(MiniPlayerCoverButton())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            MixLinkText(
                                text: track.displayTitle,
                                font: .system(size: 13, weight: .semibold),
                                color: Color.mixTextPrimary,
                                target: albumTarget(for: track)
                            )
                            // The one title long enough to still not fit is the
                            // one you most want to read.
                            .help(track.displayTitle)

                            if track.isExplicit { MixExplicitBadge() }
                            if track.origin == .edit { MixEditBadge() }
                        }

                        MixArtistLine(targets: artistTargets(for: track))
                    }

                    // Right after the title (Spotify style). Library in/out only; the heart is in the
                    // right-click menu since `toggleFavourite` needs a saved song.
                    NowPlayingSaveButton(trackID: track.id, size: 13)
                        .padding(.leading, 2)
                }
                .id(track.id)  // recreated per track so the transition runs
                .transition(.opacity)
                .contextMenu { nowPlayingMenu(track: track, favoured: favoured) }
            } else {
                HStack(spacing: 10) {
                    MacArtworkView(data: nil, size: 44, cornerRadius: 6)
                        .opacity(0.4)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not Playing")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.mixTextTertiary)
                        Text("Choose a song to play")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mixTextTertiary.opacity(0.6))
                    }
                }
                .transition(.opacity)
            }
        }
        .mixAnimation(.easeInOut(duration: 0.25), value: queueService.currentTrack?.id)
    }


    /// For the context menu's "Go to Artist" (primary artist).
    private func artistTarget(for track: Track) -> (() -> Void)? {
        artistTargets(for: track).first?.action
    }

    /// Per-artist targets plus the album target. Rules live in `TrackLinks`.
    private func artistTargets(for track: Track) -> [(name: String, action: () -> Void)] {
        TrackLinks.artists(for: track, appState: appState)
    }

    private func albumTarget(for track: Track) -> (() -> Void)? {
        TrackLinks.album(for: track, appState: appState)
    }

    private func isInLibrary(_ track: Track) -> Bool {
        deps.libraryService.track(id: track.id) != nil && !SavedAlbumsService.shared.albumOnlyIDs.contains(track.id)
    }

    /// Right-click menu for the current track. Unsaved online tracks route
    /// through the coordinator.
    @ViewBuilder
    private func nowPlayingMenu(track: Track, favoured: Bool) -> some View {
        Button(engine.state.isPlaying ? "Pause" : "Play",
               systemImage: engine.state.isPlaying ? "pause.fill" : "play.fill") {
            engine.togglePlayPause()
        }

        // Unsaved Discover tracks go through the coordinator to resolve a stream;
        // library rows go straight onto the queue.
        if let online = coordinator.currentOnlineTrack, !isInLibrary(track) {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { await coordinator.playNext(online) }
            }
            Button("Add to Queue", systemImage: "text.append") {
                Task { await coordinator.addToQueue(online) }
            }
            Divider()
            Button("Add to Liked Songs", systemImage: "heart") {
                Task { await coordinator.addToLibrary(online) }
            }
        } else {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                engine.queue.insertNext(track)
            }
            Button("Add to Queue", systemImage: "text.append") {
                engine.queue.append(track)
            }
        }

        Divider()
        // Favouriting needs a library row; unsaved songs get Add to Library instead.
        if isInLibrary(track) {
            Button(favoured ? "Remove from Liked Songs" : "Add to Liked Songs",
                   systemImage: favoured ? "heart.slash" : "heart") {
                deps.toggleFavourite(trackID: track.id)
            }
        }
        if let go = albumTarget(for: track) {
            Button("Go to Album", systemImage: "square.stack", action: go)
        }
        if let go = artistTarget(for: track) {
            Button("Go to Artist", systemImage: "music.mic", action: go)
        }
        if coordinator.canReResolve(track) {
            Button("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath") {
                Task { await deps.reResolve(track) }
            }
        }
        if track.canEdit {
            Button("Edit Song…", systemImage: "slider.horizontal.3") { appState.editTrack = track }
        }
        if track.edit != nil {
            Button("Post…", systemImage: "paperplane") { appState.postTrack = track }
        }
        Divider()
        // A Discover song keeps its Deezer id, which makes the shorter link.
        if let online = coordinator.currentOnlineTrack, !isInLibrary(track) {
            ShareMenuItems(.track(online))
        } else {
            ShareMenuItems(.track(track))
        }
    }

    // MARK: - Center  (Transport + Progress)

    private var centerSection: some View {
        VStack(spacing: 8) {
            transportControls
            MacProgressScrubber(clock: engine.clock)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {

            // Shuffle
            TransportButton(
                icon: "shuffle",
                label: "Shuffle",
                size: 13,
                isActive: queueService.shuffleEnabled
            ) {
                engine.queue.toggleShuffle()
            }

            // Previous
            TransportButton(
                icon: "backward.fill",
                label: "Previous",
                size: 17,
                isDisabled: queueService.currentTrack == nil
            ) {
                Task { await engine.playPrevious() }
            }

            // Play / Pause
            PlayPauseButton()

            // Next
            TransportButton(
                icon: "forward.fill",
                label: "Next",
                size: 17,
                isDisabled: queueService.currentTrack == nil
            ) {
                Task { await engine.playNext() }
            }

            // Repeat
            TransportButton(
                icon: queueService.repeatSystemImage,
                label: queueService.repeatLabel,
                size: 13,
                isActive: queueService.repeatMode != .off
            ) {
                engine.queue.cycleRepeat()
            }
        }
    }

    // MARK: - Right  (Volume + Queue + Now Playing)

    private var rightSection: some View {
        HStack(spacing: 8) {

            // Volume
            Image(systemName: engine.volume < 0.01 ? "speaker.fill" : "speaker.wave.1.fill")
                .accessibilityHidden(true)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)

            BarSlider(value: Double(engine.volume)) { engine.volume = Float($0) }
                .frame(width: 70)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((engine.volume * 100).rounded())) percent")

            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)

            // Speed / Sleep timer menu
            Menu {
                Section("Playback Speed") {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            engine.setRate(Float(rate))
                        } label: {
                            let on = abs(Double(engine.playbackRate) - rate) < 0.01
                            Label(rate == 1.0 ? "Normal" : String(format: "%g×", rate),
                                  systemImage: on ? "checkmark" : "")
                        }
                    }
                }
                Section("Sleep Timer") {
                    if let remaining = engine.sleepTimerRemaining {
                        Button("Cancel (\(Int(remaining) / 60) min left)") {
                            engine.cancelSleepTimer()
                        }
                    }
                    ForEach([15, 30, 45, 60], id: \.self) { mins in
                        Button("\(mins) minutes") {
                            engine.setSleepTimer(TimeInterval(mins * 60))
                        }
                    }
                }
            } label: {
                Group {
                    // Shows the rate, not just a colour.
                    if engine.sleepTimerRemaining == nil && engine.playbackRate != 1.0 {
                        Text(String(format: "%g×", Double(engine.playbackRate)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    } else {
                        Image(systemName: engine.sleepTimerRemaining != nil ? "moon.zzz.fill" : "speedometer")
                            .font(.system(size: 13))
                    }
                }
                .foregroundStyle(
                    (engine.playbackRate != 1.0 || engine.sleepTimerRemaining != nil)
                        ? Color.mixPrimary : Color.mixTextTertiary
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Playback speed and sleep timer")
            .help("Playback speed & sleep timer")

            // Divider
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            // Devices (continuity)
            MacDevicesButton(continuity: deps.continuity, downloads: deps.downloadManager)

            if let track = queueService.currentTrack, track.canEdit {
                BarIconButton(icon: "slider.horizontal.3", isActive: false, help: "Edit Song") {
                    appState.editTrack = track
                }
            }

            // Lyrics button
            BarIconButton(
                icon: "quote.bubble",
                isActive: appState.lyricsPresented,
                help: "Lyrics"
            ) {
                appState.toggleLyrics()
            }
            .disabled(queueService.currentTrack == nil)
            // Popover only in windowed mode; fullscreen is hosted by MacRootView.
            .popover(isPresented: Binding(
                get: { appState.lyricsPresented && !appState.lyricsFullscreen },
                // Only close lyrics on dismiss in windowed mode; a switch to fullscreen
                // dismisses the popover too.
                set: { if !$0 && !appState.lyricsFullscreen { appState.lyricsPresented = false } }
            ), arrowEdge: .top) {
                MacLyricsView()
                    .environment(engine)
                    .environment(appState)
                    .environment(deps)
            }

            // Queue button
            BarIconButton(
                icon: "list.bullet",
                isActive: appState.rightPanel == .queue,
                help: "Queue"
            ) {
                appState.toggleQueue()
            }

            // Now Playing / Inspector toggle
            BarIconButton(
                icon: "sidebar.right",
                isActive: appState.rightPanel == .nowPlaying,
                help: "Now Playing"
            ) {
                if let current = queueService.currentTrack {
                    appState.toggleNowPlaying(for: current)
                }
            }
            .disabled(queueService.currentTrack == nil)
        }
    }
}

// MARK: - TransportButton
// Skip/mode button: hover plate, accent colour + dot when active.

private struct TransportButton: View {
    let icon:       String
    /// Spoken name for VoiceOver.
    let label:      String
    var size:       CGFloat = 14
    var isActive:   Bool    = false
    var isDisabled: Bool    = false
    let action:     () -> Void

    @State private var isHovered = false

    var body: some View {
        // Only the 28x28 icon takes part in vertical centring; the dot is an overlay
        // hanging below it so it doesn't shift the icon.
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: isActive ? .semibold : .regular))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    isHovered && !isDisabled
                        ? Color.primary.opacity(0.07)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
                .overlay(alignment: .bottom) {
                    // Active indicator dot (visible only for mode buttons when active)
                    Circle()
                        .fill(isActive ? Color.mixPrimary : Color.clear)
                        .frame(width: 4, height: 4)
                        .offset(y: 7)        // hangs below the icon; zero layout impact
                }
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        // The dot is invisible to VoiceOver.
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var iconColor: Color {
        if isDisabled { return Color.mixTextTertiary.opacity(0.35) }
        if isActive   { return Color.mixPrimary }
        if isHovered  { return Color.mixTextPrimary }
        return Color.mixTextSecondary
    }
}

// MARK: - PlayPauseButton

private struct PlayPauseButton: View {
    @Environment(PlaybackEngine.self) private var engine
    @State private var isHovered = false

    var body: some View {
        Button {
            switch engine.state {
            case .playing, .paused: engine.togglePlayPause()
            default:
                // Stopped with a queue waiting: start from the top.
                if !engine.queue.queue.isEmpty { engine.togglePlayPause() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.mixPrimary)
                    .frame(width: 36, height: 36)
                    .scaleEffect(isHovered ? 1.07 : 1.0)
                    .mixShadow(
                        color: Color.mixPrimary.opacity(isHovered ? 0.45 : 0.2),
                        radius: isHovered ? 10 : 5
                    )
                    .mixAnimation(.mixSnappy, value: isHovered)

                Image(systemName: playPauseIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    // Optical centring: nudge the play triangle right.
                    .offset(x: playPauseIcon == "play.fill" ? 1.5 : 0)
            }
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
    }

    private var playPauseIcon: String {
        switch engine.state {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        default:       return "play.fill"
        }
    }
}

// MARK: - MacDevicesButton

private struct MacDevicesButton: View {
    var continuity: ContinuityService
    var downloads: DownloadManager
    @State private var showPicker = false

    var body: some View {
        BarIconButton(
            icon: "laptopcomputer.and.iphone",
            isActive: continuity.activeRemote != nil,
            help: continuity.activeRemote.map { "Playing on \($0.name)" } ?? "Devices"
        ) {
            showPicker.toggle()
        }
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            DevicePickerList(continuity: continuity, downloads: downloads) { showPicker = false }
                .padding(16)
                .frame(width: 340)
        }
    }
}

// MARK: - BarIconButton
// Small right-section icon button; accent colour when active.

private struct BarIconButton: View {
    let icon:     String
    var isActive: Bool = false
    var help:     String = ""
    let action:   () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(
                    isActive  ? Color.mixPrimary :
                    isHovered ? Color.mixTextPrimary :
                    Color.mixTextSecondary
                )
                .frame(width: 26, height: 26)
                .background(
                    isHovered ? Color.primary.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .mixAnimation(.easeOut(duration: 0.1), value: isHovered)
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
        .help(help)
        // Icon-only button: VoiceOver reads the tooltip text.
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Progress Scrubber

struct MacProgressScrubber: View {

    /// Passed in so only this view redraws on each tick. See `PlaybackClock`.
    var clock: PlaybackClock

    @Environment(PlaybackEngine.self) private var engine
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragValue : clock.currentTime)

            let span = max(engine.duration, 1)
            BarSlider(value: (isDragging ? dragValue : clock.currentTime) / span, step: 10 / span) {
                dragValue = $0 * span
            } onEditingChanged: { editing in
                if editing { dragValue = clock.currentTime }
                isDragging = editing
                if !editing { engine.seek(to: dragValue) }
            }
            .disabled(engine.duration == 0)
            .overlay { CommentDots(queue: engine.queue, duration: engine.duration, color: .mixTextPrimary).allowsHitTesting(false) }
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(isDragging ? dragValue : clock.currentTime)) of \(formatTime(engine.duration))")

            timeLabel(engine.duration)
        }
    }

    private func timeLabel(_ t: Double) -> some View {
        Text(formatTime(t))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.mixTextTertiary)
            .frame(width: 36)
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A slider drawn from plain shapes. The system knob is a glass layer on macOS 26 that waits on
/// the window server every time it moves, and the scrubber moves it five times a second.
struct BarSlider: View {

    /// 0...1.
    let value: Double
    /// One accessibility increment.
    var step: Double = 0.05
    let onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * min(max(value, 0), 1)
            let knob: CGFloat = hovering || dragging ? 12 : 10
            ZStack(alignment: .leading) {
                Capsule().fill(Color.mixTextTertiary.opacity(0.35))
                Capsule().fill(isEnabled ? Color.mixPrimary : Color.mixTextTertiary)
                    .frame(width: x)
            }
            .frame(height: 4)
            .overlay(alignment: .leading) {
                if isEnabled {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: knob, height: knob)
                        .offset(x: x - knob / 2)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        onChange(min(max(g.location.x / max(geo.size.width, 1), 0), 1))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            let to = direction == .increment ? min(value + step, 1) : max(value - step, 0)
            onEditingChanged(true)
            onChange(to)
            onEditingChanged(false)
        }
    }
}

#endif
