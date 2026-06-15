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

    @EnvironmentObject private var engine:   PlaybackEngine
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.mixSeparator)

            HStack(spacing: 0) {
                nowPlayingSection
                    .frame(width: 260, alignment: .leading)

                Spacer(minLength: 20)

                centerSection
                    .frame(maxWidth: 520)

                Spacer(minLength: 20)

                rightSection
                    .frame(width: 200, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .frame(height: 72)
        }
        .background(.regularMaterial)
    }

    // MARK: - Now Playing  (crossfades on track change via .id)

    private var nowPlayingSection: some View {
        Group {
            if let track = engine.queue.currentTrack {
                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                HStack(spacing: 10) {
                    MacArtworkView(data: track.artworkData, size: 44, cornerRadius: 6)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button {
                        deps.libraryService.toggleFavourite(trackID: track.id)
                    } label: {
                        Image(systemName: favoured ? "heart.fill" : "heart")
                            .font(.system(size: 13))
                            .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(favoured ? "Remove from Favourites" : "Add to Favourites")
                }
                .id(track.id)           // forces SwiftUI to re-create on track change → transition fires
                .transition(.opacity)
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
        .animation(.easeInOut(duration: 0.25), value: engine.queue.currentTrack?.id)
    }

    // MARK: - Center  (Transport + Progress)

    private var centerSection: some View {
        VStack(spacing: 8) {
            transportControls
            MacProgressScrubber()
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {

            // Shuffle
            TransportButton(
                icon: "shuffle",
                size: 13,
                isActive: engine.queue.shuffleEnabled
            ) {
                engine.queue.toggleShuffle()
            }

            // Previous
            TransportButton(
                icon: "backward.fill",
                size: 17,
                isDisabled: engine.queue.currentTrack == nil
            ) {
                Task { await engine.playPrevious() }
            }

            // Play / Pause
            PlayPauseButton()

            // Next
            TransportButton(
                icon: "forward.fill",
                size: 17,
                isDisabled: engine.queue.currentTrack == nil
            ) {
                Task { await engine.playNext() }
            }

            // Repeat
            TransportButton(
                icon: engine.queue.repeatMode.systemImage,
                size: 13,
                isActive: engine.queue.repeatMode != .off
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

            Image(systemName: "speaker.wave.3.fill")
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
            .help("Playback speed & sleep timer")

            // ── Divider ───────────────────────────────────────────────────
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

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
                if let current = engine.queue.currentTrack {
                    appState.toggleNowPlaying(for: current)
                }
            }
            .disabled(engine.queue.currentTrack == nil)
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
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .overlay(alignment: .bottom) {
                    // Active indicator dot (visible only for mode buttons when active)
                    Circle()
                        .fill(isActive ? Color.mixPrimary : Color.clear)
                        .frame(width: 4, height: 4)
                        .offset(y: 7)        // hangs below the icon; zero layout impact
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
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
            default: break
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.mixPrimary)
                    .frame(width: 36, height: 36)
                    .scaleEffect(isHovered ? 1.07 : 1.0)
                    .shadow(
                        color: Color.mixPrimary.opacity(isHovered ? 0.45 : 0.2),
                        radius: isHovered ? 10 : 5
                    )
                    .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)

                Image(systemName: playPauseIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    // A right-pointing triangle's geometric centroid sits left of
                    // its optical center, so play.fill reads as shifted-left in the
                    // circle. Nudge it right ~1.5pt to optically center it. pause.fill
                    // and hourglass are symmetric and stay perfectly centered.
                    .offset(x: playPauseIcon == "play.fill" ? 1.5 : 0)
                    .symbolEffect(.bounce, value: engine.state.isPlaying)
            }
        }
        .buttonStyle(.plain)
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
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Progress Scrubber

struct MacProgressScrubber: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragValue : engine.currentTime)

            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : engine.currentTime },
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
