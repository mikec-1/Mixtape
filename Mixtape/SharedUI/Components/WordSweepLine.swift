// A lyric line drawn word by word, each word filling over the span it's sung.
// TTML gives real per-word timing; LRC gets estimates from `LyricSync.words(for:)`.
// Used by `MacSyncedLyrics` and `SyncedLyricsView`.

import SwiftUI

struct WordSweepLine: View {
    let words: [LyricWord]
    /// Playback position, in the same seconds the words are stamped in.
    let time: TimeInterval
    let font: Font
    let sung: Color
    let unsung: Color

    var body: some View {
        WordFlow(spacing: 0, lineSpacing: 2) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                SweptWord(
                    // Trailing space stays with the word so wrapping keeps spacing.
                    text: index == words.count - 1 ? word.text : word.text + " ",
                    time: time,
                    start: word.time,
                    end: word.end,
                    lead: lead(at: index),
                    glows: glows(word),
                    sung: sung,
                    unsung: unsung
                )
                .font(font)
            }
        }
    }

    /// How early a word starts brightening. Only when the previous word ends within
    /// `maxGap`, so the sweep carries across words but not after a pause.
    private func lead(at index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        let gap = words[index].time - words[index - 1].end
        guard gap >= 0, gap <= 0.18 else { return 0 }
        return min(0.24, max(0.08, gap))
    }

    /// Whether a word is held long enough to swell. Thresholds from `am-lyrics`.
    private func glows(_ word: LyricWord) -> Bool {
        let held = word.end - word.time
        let count = word.text.count
        if count <= 3 { return held >= 1.36 + Double(count - 2) * 0.14 }
        if count == 4 { return held >= 1.05 }
        return held >= 0.9 && held >= Double(count) * 0.2
    }
}

/// A word painted twice: unsung underneath, sung on top, masked to the sweep.
private struct SweptWord: View {
    let text: String
    let time: TimeInterval
    let start: TimeInterval
    let end: TimeInterval
    let lead: TimeInterval
    let glows: Bool
    let sung: Color
    let unsung: Color

    var body: some View {
        Text(text)
            .foregroundStyle(unsung)
            .overlay(alignment: .leading) {
                Text(text)
                    .foregroundStyle(sung)
                    .mask {
                        GeometryReader { geometry in
                            // Soft edge about a character wide, so words bloom instead of looking like a
                            // slider. `am-lyrics` uses 0.75em; a line box is ~1.2em tall.
                            let edge = max(1, geometry.size.height * 0.62)
                            let width = max(1, geometry.size.width)
                            let head = head(width: width, edge: edge)
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: min(1, max(0, (head - edge) / width))),
                                    .init(color: .clear, location: min(1, max(0, head / width)))
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
            }
            // Swell and glow through the middle of a held note. Doesn't affect layout.
            .scaleEffect(1 + 0.08 * swell)
            .offset(y: -2 * swell)
            .shadow(color: sung.opacity(0.55 * swell), radius: 5 * swell)
            .fixedSize()
    }

    /// Leading edge position in points. With a `lead`, it first slides in to the
    /// word's width before its start; then it runs the word, ending `edge` past it
    /// so the word finishes fully lit.
    private func head(width: CGFloat, edge: CGFloat) -> CGFloat {
        if time < start {
            guard lead > 0, time > start - lead else { return 0 }
            return edge * CGFloat((time - (start - lead)) / lead)
        }
        let span = max(0.001, end - start)
        let progress = min(1, (time - start) / span)
        return edge + width * CGFloat(progress)
    }

    /// 0 at the word's edges, 1 in the middle.
    private var swell: Double {
        guard glows, time >= start, time <= end else { return 0 }
        let progress = (time - start) / max(0.001, end - start)
        return sin(progress * .pi)
    }
}

/// Left-to-right word layout with wrapping, since each word is its own view.
struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var centred = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in rows(for: subviews, in: bounds.width) {
            var x = bounds.minX + (centred ? (bounds.width - row.width) / 2 : 0)
            for _ in 0..<row.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
                index += 1
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var count = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let next = row.count == 0 ? size.width : row.width + spacing + size.width
            if row.count > 0, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.count == 0 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.count += 1
        }
        if row.count > 0 { rows.append(row) }
        return rows
    }
}

/// Three dots for an instrumental break, filling as it plays (timings from
/// Apple Music via `am-lyrics`). Drawn for every gap so the list doesn't reflow;
/// outside its gap it rests as three dim dots.
struct LyricGapDots: View {
    let start: TimeInterval
    let end: TimeInterval
    let time: TimeInterval
    let color: Color
    /// Surrounding lyric size; the dots scale with it (sized in em).
    var fontSize: CGFloat = 34

    /// Dots pop over the last 350ms before the vocal returns.
    private static let exitLead: TimeInterval = 0.35
    private static let exitStart: TimeInterval = 0.85
    /// The pop takes the first 35% of the exit; the rest is the vanish.
    private static let popShare = 0.35
    private static let pulse: TimeInterval = 4

    var body: some View {
        HStack(spacing: fontSize * 0.16) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(0.25 + 0.75 * fill(index)))
                    .frame(width: fontSize * 0.4, height: fontSize * 0.4)
            }
        }
        // Anchored left so the pop doesn't clip at the scroll edge.
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
    }

    /// Dots light in sequence, all full before the exit.
    private func fill(_ index: Int) -> Double {
        let duration = max(1, end - start - Self.exitStart)
        let progress = min(1, max(0, (time - start) / duration))
        return min(1, max(0, progress * 3 - Double(index)))
    }

    private var elapsed: TimeInterval { time - start }

    /// Nil outside the exit window; 0 -> 1 across the pop.
    private var exitProgress: Double? {
        let remaining = end - time
        guard time >= start, remaining <= Self.exitStart else { return nil }
        return min(1, max(0, (Self.exitStart - remaining) / Self.exitLead))
    }

    private var scale: Double {
        if let exit = exitProgress {
            if exit <= Self.popShare {
                // Shoot up: 0.94 -> 1.2, the size the web port pops to.
                return 0.94 + (1.2 - 0.94) * smoothstep(exit / Self.popShare)
            }
            // Then vanish from that peak.
            return 1.2 * (1 - smoothstep((exit - Self.popShare) / (1 - Self.popShare)))
        }
        guard time >= start, time <= end else { return 0.94 }
        return breath * min(1, easeOutExpo(elapsed / 0.4))
    }

    private var opacity: Double {
        if let exit = exitProgress, exit > Self.popShare {
            return 1 - smoothstep((exit - Self.popShare) / (1 - Self.popShare))
        }
        guard time >= start, time <= end else { return 1 }
        return min(1, elapsed / 0.16)
    }

    /// Slow breath during the gap, bottoming out as the pop begins. Shallower
    /// than `am-lyrics`' range, which looked like bouncing at this size.
    private var breath: Double {
        let cycle = Self.pulse * 2
        let offset = (Self.pulse - max(0, (end - start) - Self.exitStart))
            .truncatingRemainder(dividingBy: cycle)
        let position = (elapsed + offset + cycle).truncatingRemainder(dividingBy: cycle)
        let mix = (1 - cos(.pi * position / Self.pulse)) / 2
        return 1.06 + (0.94 - 1.06) * mix
    }

    private func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    private func easeOutExpo(_ t: Double) -> Double {
        t >= 1 ? 1 : 1 - pow(2, -10 * t)
    }
}
