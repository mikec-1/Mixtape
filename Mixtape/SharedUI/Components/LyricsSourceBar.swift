// Where the lyrics came from, a menu to switch to another source for this song or
// between word-by-word and line-by-line, and a timing nudge for synced lines.
// Source and nudge are kept per song; word or line is for every song.

import SwiftUI

struct LyricsSourceBar: View {
    let track: Track
    let lyrics: TrackLyrics
    @Binding var offset: TimeInterval
    var showsNudge = true
    /// Chip colours: page pills on iOS, the dark tint on the Mac lyrics panel.
    var fill: Color = Color.mixSurface2.opacity(0.7)
    var ink: Color = .mixTextTertiary
    var height: CGFloat? = nil

    /// Read by the synced lyrics views: the whole line lights at once instead of sweeping.
    static let byLineKey = "lyricsByLine"

    @State private var sources: [LyricsSource: TrackLyrics] = [:]
    @AppStorage(Self.byLineKey) private var byLine = false

    /// An edit has its own lyrics, and one source is nothing to switch between.
    private var canSwitch: Bool { track.edit == nil && sources.count > 1 }

    var body: some View {
        HStack(spacing: 6) {
            if canSwitch || lyrics.hasSynced, let current = lyrics.source {
                sourceMenu(current)
            }
            if showsNudge, lyrics.hasSynced {
                nudge
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ink)
        // Re-probe after a switch or a save; the service caches the probe.
        .task(id: [track.id.uuidString, lyrics.source?.rawValue ?? ""]) {
            sources = await LyricsService.shared.sources(for: track)
        }
    }

    private func sourceMenu(_ current: LyricsSource) -> some View {
        Menu {
            if lyrics.hasSynced {
                Section("Timing") {
                    Picker("Timing", selection: $byLine) {
                        Text("Word by Word").tag(false)
                        Text("Line by Line").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            if canSwitch {
                Section("Source") {
                    Picker("Source", selection: Binding(
                        get: { current },
                        set: { LyricsService.shared.use($0, for: track) }
                    )) {
                        ForEach(LyricsSource.allCases.filter { sources[$0] != nil }, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.quote").font(.system(size: 10, weight: .semibold))
                Text(current.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .frame(height: height)
            .padding(.vertical, height == nil ? 5 : 0)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .mixHandCursor()
        .help("Lyrics source and timing")
    }

    private var nudge: some View {
        HStack(spacing: 0) {
            step("minus", help: "Lyrics earlier") { setOffset(offset - 0.5) }
            Text(String(format: "%+.1f s", offset))
                .monospacedDigit()
                .frame(minWidth: 40)
            step("plus", help: "Lyrics later") { setOffset(offset + 0.5) }
            if offset != 0 {
                step("arrow.counterclockwise", help: "Reset timing") { setOffset(0) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: height)
        .padding(.vertical, height == nil ? 2 : 0)
        .background(fill, in: Capsule())
        .mixAnimation(.mixQuick, value: offset == 0)
    }

    private func step(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    /// Half-second steps, ten seconds either way. Positive holds the lyrics back.
    private func setOffset(_ value: TimeInterval) {
        offset = min(10, max(-10, (value * 2).rounded() / 2))
        LyricsOffsets.set(offset, for: track)
    }
}
