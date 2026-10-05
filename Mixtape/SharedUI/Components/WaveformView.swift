// A song's shape as bars, SoundCloud style: played bars lit, a faint reflection under them.
// Click or drag to seek (tap on iOS, so it doesn't fight scrolling). Timed comments sit on the line.

import SwiftUI

struct WaveMark: Identifiable {
    let id: UUID
    /// 0...1 along the song.
    let at: Double
    let label: String
    var avatar: URL?
    var name = ""
}

struct WaveformView: View {
    /// Nil draws a flat line, for posts from before waveforms.
    let peaks: [Float]?
    var progress: Double = 0
    var marks: [WaveMark] = []
    /// Where each part after the first starts, 0...1. Parts are shaded in turns and numbered.
    var parts: [Double] = []
    var height: CGFloat = 48
    /// Shows the length at the right end, and the time played at the left once started.
    var duration: Double?
    var onSeek: ((Double) -> Void)?
    var onMark: ((WaveMark) -> Void)?

    @State private var drag: Double?
    @State private var hover: Double?

    /// The bars' baseline; the reflection fills the rest.
    private var baseline: CGFloat { height * 0.72 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bars
                if let duration, duration > 0 { times(duration, width: geo.size.width) }
                ForEach(marks) { mark in markView(mark).position(x: geo.size.width * mark.at, y: baseline) }
            }
            .contentShape(Rectangle())
            .gesture(seek(width: geo.size.width), including: onSeek == nil ? .subviews : .all)
            .onContinuousHover { phase in
                if case .active(let at) = phase, onSeek != nil, geo.size.width > 0 {
                    hover = at.x / geo.size.width
                } else {
                    hover = nil
                }
            }
        }
        .frame(height: height)
        .modifier(SeekCursor(on: onSeek != nil))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            onSeek?(min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }

    private var bars: some View {
        let shown = drag ?? progress
        let hovered = hover
        return Canvas { ctx, size in
            let bar: CGFloat = 2, gap: CGFloat = 1
            let count = max(Int((size.width + gap) / (bar + gap)), 1)
            let base = baseline
            // Shaded parts first, under the bars.
            let edges = [0] + parts + [1]
            for i in 0..<(edges.count - 1) where parts.count > 0 {
                let rect = CGRect(x: edges[i] * size.width, y: 0,
                                  width: (edges[i + 1] - edges[i]) * size.width, height: size.height)
                if i % 2 == 1 { ctx.fill(Path(rect), with: .color(Color.primary.opacity(0.06))) }
                if i > 0 {
                    ctx.fill(Path(CGRect(x: rect.minX, y: 0, width: 1, height: size.height)),
                             with: .color(Color.mixPrimary.opacity(0.5)))
                }
                ctx.draw(Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.mixTextTertiary),
                         at: CGPoint(x: rect.minX + 4, y: 2), anchor: .topLeading)
            }
            guard let peaks else {
                ctx.fill(Path(CGRect(x: 0, y: base - 1, width: size.width, height: 2)),
                         with: .color(Color.mixTextTertiary.opacity(0.5)))
                ctx.fill(Path(CGRect(x: 0, y: base - 1, width: size.width * shown, height: 2)),
                         with: .color(Color.mixPrimary))
                return
            }
            for (i, p) in Waveform.resample(peaks, to: count).enumerated() {
                let x = CGFloat(i) * (bar + gap)
                let at = (x + bar / 2) / size.width
                let h = max(CGFloat(p) * base, 1.5)
                let color: Color = at <= shown ? .mixPrimary
                    : hovered.map { at <= $0 } == true ? Color.mixTextPrimary : Color.mixTextSecondary
                ctx.fill(Path(CGRect(x: x, y: base - h, width: bar, height: h)), with: .color(color))
                ctx.fill(Path(CGRect(x: x, y: base + 1, width: bar, height: h * (size.height - base) / base)),
                         with: .color(color.opacity(0.4)))
            }
        }
        .gpuRendered()
    }

    private func times(_ duration: Double, width: CGFloat) -> some View {
        let shown = drag ?? progress
        return HStack {
            if shown > 0 { tag(shown * duration, color: .mixPrimary) }
            Spacer(minLength: 0)
            tag(duration, color: .white.opacity(0.85))
        }
        .frame(width: width)
        .position(x: width / 2, y: baseline - 8)
        .allowsHitTesting(false)
    }

    private func tag(_ seconds: Double, color: Color) -> some View {
        Text(PostPageView.clock(seconds))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.75))
    }

    @ViewBuilder
    private func markView(_ mark: WaveMark) -> some View {
        Group {
            if mark.avatar != nil || !mark.name.isEmpty {
                AvatarView(url: mark.avatar, fallbackText: mark.name, size: 16)
                    .overlay(Circle().stroke(Color.mixSurface, lineWidth: 1))
            } else {
                Circle().fill(Color.mixPrimary)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 5, height: 5)
            }
        }
        .help(mark.label)
        .onTapGesture { onMark?(mark) }
    }

    private func seek(width: CGFloat) -> some Gesture {
        #if os(macOS)
        DragGesture(minimumDistance: 0)
            .onChanged { drag = min(max($0.location.x / max(width, 1), 0), 1) }
            .onEnded { value in
                drag = nil
                onSeek?(min(max(value.location.x / max(width, 1), 0), 1))
            }
        #else
        SpatialTapGesture()
            .onEnded { onSeek?(min(max($0.location.x / max(width, 1), 0), 1)) }
        #endif
    }
}

private struct SeekCursor: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.mixHandCursor() } else { content }
    }
}

/// Redraws `content` with the player's position as 0...1, so only it ticks.
struct PlaybackProgress<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(duration > 0 ? min(max(clock.currentTime / duration, 0), 1) : 0)
    }
}
