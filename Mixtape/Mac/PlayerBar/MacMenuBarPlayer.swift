#if os(macOS)
import SwiftUI
import AppKit

/// Menu bar mini-player: the player bar in a popover. Toggle in Settings > General.
struct MacMenuBarPlayer: View {
    static let visibleKey = "mac.menuBarPlayer"
    /// The song's title beside the icon in the menu bar itself.
    static let titleKey = "mac.menuBarPlayer.title"

    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var queue: QueueService
    @ObservedObject var library: LibraryService   // only so the heart follows the like

    @AppStorage(MacMenuBarPlayer.titleKey) private var showsTitle = false
    @State private var wash: [Color] = []

    var body: some View {
        let track = queue.currentTrack
        VStack(alignment: .leading, spacing: 12) {
            header(track)
            MacProgressScrubber(clock: engine.clock)
                .environmentObject(engine)
            transport(hasTrack: track != nil)
            volume
            if let track { MenuBarLyricLine(track: track, clock: engine.clock) }
            upNext
            Divider()
            footer(track)
        }
        .padding(14)
        .frame(width: 300)
        .background {
            // The cover's own colours, faded into the popover's material.
            LinearGradient(colors: wash.map { $0.opacity(0.35) } + [.clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .task(id: track?.id) {
            wash = ArtworkColors.gradientColors(from: track?.displayArtwork)
        }
    }

    // MARK: - Pieces

    private func header(_ track: Track?) -> some View {
        HStack(spacing: 10) {
            MacArtworkView(data: track?.artworkData, artworkRef: track.map { .track($0.id) },
                           size: 56, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.displayTitle ?? "Not Playing").font(.headline)
                if let track { Text(track.displayArtistName).foregroundStyle(.secondary) }
                if let remaining = engine.sleepTimerRemaining {
                    Label(Self.clock(remaining), systemImage: "moon.zzz.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let track {
                let liked = engine.isLiked?(track) ?? false
                Button {
                    Task { await engine.onRemoteLike?(track); engine.syncRemoteCommandState() }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Color.mixPrimary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
            }
        }
    }

    private func transport(hasTrack: Bool) -> some View {
        HStack {
            Button { queue.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .foregroundStyle(queue.shuffleEnabled ? Color.mixPrimary : .secondary)
                .accessibilityLabel(queue.shuffleEnabled ? "Shuffle On" : "Shuffle Off")
            Spacer()
            Button { Task { await engine.playPrevious() } } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
                .disabled(!hasTrack)
            Spacer()
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { Task { await engine.playNext() } } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
                .disabled(!hasTrack)
            Spacer()
            Button { queue.cycleRepeat() } label: {
                Image(systemName: queue.repeatSystemImage)
            }
            .foregroundStyle(queue.repeatMode == .off ? .secondary : Color.mixPrimary)
            .accessibilityLabel(queue.repeatLabel)
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.volume = Float($0) }))
                .controlSize(.small)
                .tint(Color.mixPrimary)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var upNext: some View {
        let rows = queue.upcomingRows.prefix(3)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        MacArtworkView(data: row.track.artworkData, artworkRef: .track(row.track.id),
                                       size: 24, cornerRadius: 3)
                        Text(row.track.displayTitle).lineLimit(1)
                        Text(row.track.displayArtistName).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if row.isManual { Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func footer(_ track: Track?) -> some View {
        HStack {
            Button("Open Mixtape") {
                NSApp.activate(ignoringOtherApps: true)
                // ponytail: brings back a hidden window, not a closed one; the Dock icon reopens those.
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Spacer()
            Menu {
                Button("Play Something Random", systemImage: "dice") { playRandom() }
                    .disabled(library.tracks.isEmpty)
                Button("Copy Song Name", systemImage: "doc.on.doc") {
                    guard let track else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(track.displayTitle) — \(track.displayArtistName)", forType: .string)
                }
                .disabled(track == nil)

                Divider()

                Menu("Sleep Timer", systemImage: "moon.zzz") {
                    ForEach([5, 15, 30, 45, 60, 90], id: \.self) { mins in
                        Button("\(mins) minutes") { engine.setSleepTimer(TimeInterval(mins * 60)) }
                    }
                    if engine.sleepTimerRemaining != nil {
                        Divider()
                        Button("Turn Off") { engine.cancelSleepTimer() }
                    }
                }
                Picker("Speed", systemImage: "speedometer",
                       selection: Binding(get: { engine.playbackRate }, set: { engine.setRate($0) })) {
                    ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                        Text(rate == 1 ? "Normal" : String(format: "%g×", rate)).tag(rate)
                    }
                }
                Toggle("Show Song in Menu Bar", systemImage: "menubar.rectangle", isOn: $showsTitle)

                Divider()

                Button("Quit Mixtape") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .controlSize(.small)
    }

    // MARK: - Actions

    private func playRandom() {
        guard let track = library.tracks.randomElement() else { return }
        Task {
            await engine.play(track: track, in: library.tracks,
                              source: .playlist(id: Playlist.allSongsID, name: "All Songs"))
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Current and next line, own view so clock ticks only redraw these.
private struct MenuBarLyricLine: View {
    let track: Track
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var lyrics = LyricsService.shared

    var body: some View {
        let lines = lyrics.cached(for: track)?.synced ?? []
        let t = clock.currentTime - LyricsOffsets.get(for: track)
        if let i = lines.lastIndex(where: { $0.time <= t }), !lines[i].text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(lines[i].text).font(.callout.weight(.semibold))
                if i + 1 < lines.count { Text(lines[i + 1].text).font(.caption).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .animation(.easeOut(duration: 0.2), value: i)
            .task(id: track.id) { await lyrics.resolve(for: track) }
        } else {
            Color.clear.frame(height: 0)
                .task(id: track.id) { await lyrics.resolve(for: track) }
        }
    }
}

/// The Mixtape mark, plus the song if enabled.
struct MacMenuBarLabel: View {
    @ObservedObject var queue: QueueService
    @AppStorage(MacMenuBarPlayer.titleKey) private var showsTitle = false

    var body: some View {
        if showsTitle, let track = queue.currentTrack {
            let title = track.displayTitle
            Text("\(Image(systemName: MixtapeMark.symbolName)) \(title.count > 28 ? title.prefix(27) + "…" : title)")
        } else {
            Image(systemName: MixtapeMark.symbolName)
        }
    }
}
#endif
