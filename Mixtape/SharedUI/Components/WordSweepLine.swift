// WordSweepLine.swift
// Mixtape — SharedUI/Components
//
// One lyric line, drawn word by word, with the highlight filling each word over
// exactly the span it's sung. Apple's TTML carries those spans per word — a
// held "babyyyy" fills slowly because it *is* held that long — and LRC sources
// get estimated ones from `LyricSync.words(for:)`, which is what makes a sung
// line look sung even when nothing timed it.
//
// Used by both synced-lyrics views (`MacSyncedLyrics`, `SyncedLyricsView`), so
// the same line reads the same way on every platform.

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
                    // The trailing space rides along with the word so the flow
                    // keeps its spacing when a line wraps mid-phrase.
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

    /// How long before its own start a word begins brightening.
    ///
    /// Only when the word before it ends within `maxGap` — the lead is meant to
    /// carry the sweep across a word boundary in continuous singing, not to
    /// light a word up out of nowhere after a pause.
    private func lead(at index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        let gap = words[index].time - words[index - 1].end
        guard gap >= 0, gap <= 0.18 else { return 0 }
        return min(0.24, max(0.08, gap))
    }

    /// Whether a word is held long enough to be worth swelling.
    ///
    /// Short words go by in a blink; scaling those would be a twitch on every
    /// syllable rather than the sense of a note being held. The thresholds are
    /// `am-lyrics`' own: a short word has to be held much longer to qualify.
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
                            // A soft edge, not a hard one. A rectangle mask cuts
                            // the fill mid-glyph, which reads as a slider being
                            // dragged across the line rather than words being
                            // sung — the edge has to be wide enough to cover
                            // roughly a character, so a word blooms into
                            // brightness. `am-lyrics` does the same thing with a
                            // 0.75em gradient; a rendered line box is about
                            // 1.2em tall, so that's what this is a fraction of.
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
            // Swells and glows through the middle of a held note, back to rest
            // before it ends. Layout is unaffected, so the line doesn't reflow.
            .scaleEffect(1 + 0.08 * swell)
            .offset(y: -2 * swell)
            .shadow(color: sung.opacity(0.55 * swell), radius: 5 * swell)
            .fixedSize()
    }

    /// How far the leading edge has travelled, in points.
    ///
    /// Two stages. Before the word's own start — only when a `lead` was granted
    /// — the edge slides in to exactly its own width, so the first characters
    /// are already brightening as the singer arrives. Then it runs the length of
    /// the word, finishing `edge` past the end so the word ends *fully* sung
    /// rather than fading out at its tail.
    private func head(width: CGFloat, edge: CGFloat) -> CGFloat {
        if time < start {
            guard lead > 0, time > start - lead else { return 0 }
            return edge * CGFloat((time - (start - lead)) / lead)
        }
        let span = max(0.001, end - start)
        let progress = min(1, (time - start) / span)
        return edge + width * CGFloat(progress)
    }

    /// 0 at the word's edges, 1 in the middle — the shape of the swell.
    private var swell: Double {
        guard glows, time >= start, time <= end else { return 0 }
        let progress = (time - start) / max(0.001, end - start)
        return sin(progress * .pi)
    }
}

/// Lays words out left to right, wrapping to the next line when they run out of
/// width — what a `Text` does for itself, and what it stops being able to do
/// once each word has to be its own view.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

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
            var x = bounds.minX
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

/// The three dots that stand in for an instrumental break, filling left to
/// right as it plays out — Apple Music's, and `am-lyrics`' own numbers.
///
/// Rendered for every qualifying gap, not just the one playing, so the list
/// doesn't reflow underneath the reader when a break arrives. Outside its own
/// gap it sits at rest: three dim dots.
struct LyricGapDots: View {
    let start: TimeInterval
    let end: TimeInterval
    let time: TimeInterval
    let color: Color
    /// Font size of the surrounding lyrics. `am-lyrics` sizes its dots in `em`,
    /// so they grow with the text instead of staying a fixed 12pt speck.
    var fontSize: CGFloat = 34

    /// `am-lyrics` starts collapsing the gap 850ms before the vocal returns and
    /// pops the dots over the last 350ms of that.
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
        // Anchored left so the pop grows into the line, not out past the
        // scroll view's edge where it would be clipped.
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
    }

    /// The dots light in sequence across the gap, finishing before the exit
    /// starts so the last one is full while they pop away.
    private func fill(_ index: Int) -> Double {
        let duration = max(1, end - start - Self.exitStart)
        let progress = min(1, max(0, (time - start) / duration))
        return min(1, max(0, progress * 3 - Double(index)))
    }

    private var elapsed: TimeInterval { time - start }

    /// Nil outside the exit window. Inside, 0 at the start of the pop and 1
    /// once the dots are gone.
    private var exitProgress: Double? {
        let remaining = end - time
        guard time >= start, remaining <= Self.exitStart else { return nil }
        return min(1, max(0, (Self.exitStart - remaining) / Self.exitLead))
    }

    private var scale: Double {
        if let exit = exitProgress {
            if exit <= Self.popShare {
                // Shoot up: 0.94 → 1.2, the size the web port pops to.
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

    /// A slow breath while the gap plays, phased so it bottoms out just as the
    /// pop begins. Kept shallower than `am-lyrics`' 0.85–1.12 — at this dot
    /// size that range read as bouncing.
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
