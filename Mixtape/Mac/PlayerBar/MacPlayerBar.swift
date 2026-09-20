// MacPlayerBar.swift
// Mixtape — Mac/PlayerBar
//
// Persistent now-playing bar pinned to the bottom of the main window.
//
// Layout (3-column at 72px tall):
//   Left  (260px) — artwork + track title / artist  (crossfades on track change)
//   Center (flex) — transport controls + progress scrubber
//   Right  (200px) — volume slider
//
// Controls:
//   • Shuffle / Repeat buttons wired to QueueService (toggle / cycle)
//   • Active-state indicator dot under shuffle and repeat
//   • TransportButton component with hover-background + per-button hover state
//   • PlayPauseButton scales up slightly on hover
//   • Now-playing section crossfades when the current track changes

#if os(macOS)
import SwiftUI

struct MacPlayerBar: View {

    /// The bar's own height, excluding the hairline above it. Named because
    /// bottom-anchored overlays on the root have to clear it and were otherwise
    /// each carrying their own copy of 72.
    static let height: CGFloat = 72

    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var appState:    MacAppState
    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    /// See MacQueuePanelView: `engine.queue` is a plain `let`, so shuffle and
    /// repeat state has to be observed on the service itself for the buttons to
    /// light up the moment they are pressed.
    @EnvironmentObject private var queueService: QueueService


    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.mixSeparator.opacity(appState.karaokeActive ? 0.4 : 1))

            // Three columns, and the outer two are *equally* flexible rather
            // than fixed. That is what keeps the transport controls on the
            // window's centre line while the now-playing block takes whatever
            // room is left — which, on a normal window, is a good 200pt more
            // than the 260 this used to hand it. A song called "FRANCHISE
            // (feat. Future, Young Thug & M.I.A.) - REMIX" was being cut to
            // "FRANCHISE (feat. Futu…" with half the bar sitting empty.
            //
            // The centre is the least flexible of the three (a bounded range),
            // so the stack sizes it first and splits the remainder between the
            // sides — equal shares, so nothing shifts when the song changes.
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

            // Spotify's strip: which device the controls above are driving.
            // ponytail: grows the bar 24pt while showing, so toasts placed off
            // `height` sit a little low; fold it into `height` if that shows.
            WithActiveRemote(continuity: deps.continuity) { remote in
                if let remote {
                    RemoteDeviceStrip(device: remote, hPadding: 20)
                }
            }
        }
        // Flat, not a material, and on purpose.
        //
        // A `Material` at the bottom edge of the window has nothing of the
        // app's behind it to blend with, so AppKit blends it against what is
        // behind the *window* — the desktop. The bar came out blue over a blue
        // wallpaper and grey over a grey one, changing colour as the window
        // moved, for no reason the app could explain. Exactly the bug the
        // sidebar had before it stopped being an NSVisualEffectView; see the
        // note on the sidebar background in `MacRootView`.
        //
        // An opaque colour *under* the material wouldn't fix it, because
        // behind-window blending never samples in-window content. The band has
        // to take a real colour: `mixSurface` over `mixBackground` still reads
        // as raised, and now reads the same everywhere the window sits.
        // Opaque either way — a see-through bar over moving lyrics is
        // unreadable. In karaoke the fill is the album's own colour under the
        // same scrim the backdrop uses, so the bar continues the wash instead
        // of cutting a grey band across it.
        .background {
            if appState.karaokeActive {
                ZStack {
                    (karaokeTint ?? Color(white: 0.12))
                    // Only a light scrim: the tint is already the backdrop's own
                    // colour, mixed and darkened the same way, so a heavy black
                    // wash here just brought back the slab it replaced.
                    Color.black.opacity(0.22)
                }
            } else {
                Color.mixSurface
            }
        }
        .onAppear(perform: refreshKaraokeTint)
        .onChange(of: appState.karaokeActive) { _, _ in refreshKaraokeTint() }
        .onChange(of: queueService.currentTrack?.id) { _, _ in refreshKaraokeTint() }
    }

    /// The second stop of the karaoke gradient — the colour it has reached by
    /// the bottom of the window, which is where the bar sits.
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
                        }

                        MixArtistLine(targets: artistTargets(for: track))
                    }

                    // No spacer before it: the mark belongs to the song's name,
                    // so it sits at the end of the name rather than pinned to a
                    // column edge the title may never reach. Spotify's does the
                    // same, and it's the difference between "is this saved?" and
                    // "is *that* saved?".
                    //
                    // One control, one meaning: in your library or not. The heart
                    // lives in the right-click menu — `toggleFavourite` refuses a
                    // song that isn't saved yet, so it can't be the primary
                    // affordance here anyway.
                    NowPlayingSaveButton(trackID: track.id, size: 13)
                        .padding(.leading, 2)
                }
                .id(track.id)           // forces SwiftUI to re-create on track change → transition fires
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


    /// Navigation target for the artist line. Kept for the context-menu
    /// "Go to Artist" action, which routes to the primary artist.
    private func artistTarget(for track: Track) -> (() -> Void)? {
        artistTargets(for: track).first?.action
    }

    /// One tappable target per individual artist on the track, and the
    /// title's album target. Both rules live in `TrackLinks` — the queue, the
    /// Recent list and the lyrics header ask the same questions of the same
    /// track and have to get the same answers.
    private func artistTargets(for track: Track) -> [(name: String, action: () -> Void)] {
        TrackLinks.artists(for: track, appState: appState)
    }

    private func albumTarget(for track: Track) -> (() -> Void)? {
        TrackLinks.album(for: track, appState: appState)
    }

    private func isInLibrary(_ track: Track) -> Bool {
        deps.libraryService.track(id: track.id) != nil && !SavedAlbumsService.shared.albumOnlyIDs.contains(track.id)
    }

    /// Right-click menu for the now-playing track in the player bar. Mirrors the
    /// Discover row menu, plus favourite + navigation. Library/queue actions for
    /// an unsaved (online) track route through the coordinator.
    @ViewBuilder
    private func nowPlayingMenu(track: Track, favoured: Bool) -> some View {
        Button(engine.state.isPlaying ? "Pause" : "Play",
               systemImage: engine.state.isPlaying ? "pause.fill" : "play.fill") {
            engine.togglePlayPause()
        }

        // Queue actions, whatever is playing. An unsaved Discover track has to go
        // through the coordinator so a stream gets resolved for it; a library row
        // goes straight onto the queue, and the engine resolves it online on
        // arrival if it has no audio of its own. Only the coordinator branch used
        // to exist, which left songs imported from a Spotify playlist link — real
        // library rows — with no queue actions at all.
        if let online = coordinator.currentOnlineTrack, !isInLibrary(track) {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { await coordinator.playNext(online) }
            }
            Button("Add to Queue", systemImage: "text.append") {
                Task { await coordinator.addToQueue(online) }
            }
            Divider()
            Button("Add to Library", systemImage: "plus") {
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
        // Favouriting needs a library row — `toggleFavourite` refuses anything
        // else — so on an unsaved Discover song this was a menu item that looked
        // live and did nothing. "Add to Library" above is the offer there.
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
                icon: queueService.repeatMode.systemImage,
                label: queueService.repeatMode.accessibilityLabel,
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

            // ── Volume ────────────────────────────────────────────────────
            Image(systemName: engine.volume < 0.01 ? "speaker.fill" : "speaker.wave.1.fill")
                .accessibilityHidden(true)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)

            Slider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(width: 70)
            .tint(Color.mixPrimary)
            .controlSize(.mini)
            .accessibilityLabel("Volume")

            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)

            // ── Speed / Sleep timer menu ──────────────────────────────────
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
                Image(systemName: engine.sleepTimerRemaining != nil ? "moon.zzz.fill" : "speedometer")
                    .font(.system(size: 13))
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

            // ── Divider ───────────────────────────────────────────────────
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            // ── Devices (continuity) ──────────────────────────────────────
            MacDevicesButton(continuity: deps.continuity, downloads: deps.downloadManager)

            // ── Lyrics button ─────────────────────────────────────────────
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
                // Only treat a dismiss as "close lyrics" when we're still in
                // windowed mode. If lyricsFullscreen just flipped to true, the
                // popover is dismissing to hand off to the fullscreen overlay —
                // keep lyricsPresented so the overlay stays up.
                set: { if !$0 && !appState.lyricsFullscreen { appState.lyricsPresented = false } }
            ), arrowEdge: .top) {
                MacLyricsView()
                    .environmentObject(engine)
                    .environmentObject(appState)
                    .environmentObject(deps)
            }

            // ── Queue button ──────────────────────────────────────────────
            BarIconButton(
                icon: "list.bullet",
                isActive: appState.rightPanel == .queue,
                help: "Queue"
            ) {
                appState.toggleQueue()
            }

            // ── Now Playing / Inspector toggle ────────────────────────────
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
//
// A unified skip / mode button with:
//   • Hover: subtle rounded-rect background
//   • Active (shuffle on / repeat not .off): accent color + indicator dot

private struct TransportButton: View {
    let icon:       String
    /// Spoken name. The SF Symbol name is not one — VoiceOver reads an
    /// unlabelled icon button as "button" and nothing else.
    let label:      String
    var size:       CGFloat = 14
    var isActive:   Bool    = false
    var isDisabled: Bool    = false
    let action:     () -> Void

    @State private var isHovered = false

    var body: some View {
        // The button's 28×28 icon frame is the *only* thing that participates in
        // the HStack's vertical centering, so its icon center sits exactly on the
        // transport row's centerline — matching the dot-less PlayPauseButton.
        // The active-indicator dot is drawn as a bottom-anchored overlay with a
        // negative offset, so it hangs *below* the icon without changing the
        // layout height or shifting the icon's center.
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
        // The active dot is the only visual saying shuffle/repeat is on, and it
        // is not something VoiceOver can see.
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
    @EnvironmentObject private var engine: PlaybackEngine
    @State private var isHovered = false

    var body: some View {
        Button {
            switch engine.state {
            case .playing, .paused: engine.togglePlayPause()
            default:
                // Stopped, but a queue can still be sitting there waiting —
                // filled by "Add to Queue" before anything was ever played.
                // togglePlayPause starts it from the top.
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
                    .mixAnimation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)

                Image(systemName: playPauseIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    // A right-pointing triangle's geometric centroid sits left of
                    // its optical center, so play.fill reads as shifted-left in the
                    // circle. Nudge it right ~1.5pt to optically center it. pause.fill
                    // and hourglass are symmetric and stay perfectly centered.
                    .offset(x: playPauseIcon == "play.fill" ? 1.5 : 0)
                    .mixBounce(value: engine.state.isPlaying)
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
    @ObservedObject var continuity: ContinuityService
    @ObservedObject var downloads: DownloadManager
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
//
// Small icon button used in the right section of the player bar.
// Active state shows the icon in accent colour.

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
        // The tooltip is already the button's name in words — an icon-only
        // button has nothing else for VoiceOver to read.
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Progress Scrubber

struct MacProgressScrubber: View {

    /// Passed in rather than taken from the environment: this is the one view in
    /// the bar that has to redraw on every tick, and holding the clock here
    /// keeps the tick from reaching anything else. See `PlaybackClock`.
    @ObservedObject var clock: PlaybackClock

    @EnvironmentObject private var engine: PlaybackEngine
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragValue : clock.currentTime)

            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : clock.currentTime },
                    set: { dragValue = $0 }
                ),
                in: 0...(max(engine.duration, 1)),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { engine.seek(to: dragValue) }
                }
            )
            .tint(Color.mixPrimary)
            .disabled(engine.duration == 0)

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

#endif
