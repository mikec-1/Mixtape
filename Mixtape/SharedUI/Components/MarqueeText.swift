// MarqueeText.swift
// Mixtape — SharedUI/Components
//
// One line of content that slides sideways when it doesn't fit, so a long
// credit or title can be read in full without the row growing to hold it.

import SwiftUI

// MARK: - Scroller

/// A single line that scrolls its own overflow into view and back.
///
/// Built for the mini player's artist line and reused by the full player for
/// the title and credit. Three names — "David Guetta, Flo Rida, Nicki Minaj" —
/// have no chance of fitting a 56pt bar, and a plain truncation shows the first
/// name and a shrug. This holds still long enough to read the beginning, walks
/// left until the end is visible, holds again, and returns.
///
/// Content that fits is left completely alone: no animation, no travel. The
/// scrolling case is the exception, not the default.
///
/// Generic over its content so the full player's per-artist tap targets keep
/// working while the row they sit in scrolls: the whole `HStack` is measured
/// and moved as one, rather than each name deciding for itself.
struct MarqueeScroller<Content: View>: View {

    /// What this line is *about* — the song's credit, the title, whatever.
    /// A change here restarts the cycle and, crucially, invalidates the last
    /// measurement: see `contentWidth`.
    let identity: String

    /// Held on top of `holdAtStart` before every walk. Two lines in the same
    /// bar setting off together read as the whole bar sliding; a second of
    /// stagger makes them two lines, each doing its own thing.
    var startDelay: Duration = .zero

    /// How fast the content walks, in points per second — an average, since
    /// the travel eases in and out around it. Slow enough to read a name as it
    /// passes rather than to notice that something moved. A credit is several
    /// names rather than one phrase, so it reads better slower than a title.
    var speed: Double = 22

    @ViewBuilder var content: () -> Content

    /// The hold at each end. The pause at the start is what makes the line
    /// readable at a glance for someone who isn't watching it travel.
    private static var holdAtStart: Duration { .seconds(2.5) }
    private static var holdAtEnd:   Duration { .seconds(1.5) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mixMotion) private var motion
    /// The mini player keeps its marquee while the app is put away — see
    /// `AppVisibility`.
    @ObservedObject private var visibility = AppVisibility.shared

    @State private var measured = Measurement(identity: "", width: 0)
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// The natural width of what is on screen *now*.
    ///
    /// A measurement is only believed while it still describes the current
    /// identity. This is the whole fix for the line that used to walk on a song
    /// change even when the new credit was one short name: the new text renders
    /// a frame before its width is reported, so for that frame the view was
    /// reading the *previous* song's width and deciding, correctly for the wrong
    /// string, that it overflowed. An unmatched measurement now reads as zero
    /// width — nothing overflows, so nothing moves — until the real one lands.
    private var contentWidth: CGFloat {
        measured.identity == identity ? measured.width : 0
    }

    /// How far the content has to travel to show its tail.
    private var overflow: CGFloat { max(0, contentWidth - containerWidth) }

    /// Motion has to be wanted, possible, and worth it. A couple of points of
    /// overflow is a rounding error, not a hidden name.
    private var shouldScroll: Bool {
        !reduceMotion && !motion.isReduced && visibility.isForeground && overflow > 4
    }

    var body: some View {
        // A hidden, *unfixed* copy is the only thing in the layout: it takes
        // the width it is offered, truncating like any other line, and gives
        // the row the content's own height rather than a hardcoded one.
        //
        // The scrolling copy travels in an overlay, which cannot report a size
        // back to the parent. It used to be the layout itself, and
        // `.fixedSize(horizontal: true)` means "ignore the proposal, take your
        // ideal width" — so a long title or a four-name credit made the line
        // genuinely that wide. `.clipped()` hid the overhang but changed
        // nothing about the size that had already been published upwards, and
        // the whole screen grew sideways around it.
        content()
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                content()
                    // Measured at its natural width so the overflow is
                    // knowable. Safe here: an overlay is sized by its host.
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: MarqueeWidthKey.self,
                                value: Measurement(identity: identity, width: inner.size.width)
                            )
                        }
                    )
                    .offset(x: offset)
            }
            .clipped()
            .background(
                GeometryReader { outer in
                    Color.clear
                        .onAppear { containerWidth = outer.size.width }
                        .onChange(of: outer.size.width) { _, new in containerWidth = new }
                }
            )
            .onPreferenceChange(MarqueeWidthKey.self) { measured = $0 }
            // Restart from the beginning whenever the line itself changes — a
            // new song must not inherit the previous one's scroll position.
            .task(id: cycleIdentity) { await runCycle() }
    }

    /// What a fresh scroll cycle depends on. Width changes matter as much as the
    /// identity does: a rotation can turn an overflowing line into a fitting one.
    private var cycleIdentity: String {
        "\(identity)|\(Int(contentWidth))|\(Int(containerWidth))|\(shouldScroll)"
    }

    private func runCycle() async {
        offset = 0
        guard shouldScroll else { return }

        let travel = Duration.seconds(Double(overflow) / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.holdAtStart + startDelay)
            guard !Task.isCancelled else { return }

            // Eases out of the hold and back into it instead of snapping into
            // a constant crawl — the line looks like it decided to move rather
            // than like a timer fired. `.linear` was correct for a ticker and
            // wrong for two of these sitting one above the other.
            withAnimation(.easeInOut(duration: travel.seconds)) { offset = -overflow }
            try? await Task.sleep(for: travel + Self.holdAtEnd)
            guard !Task.isCancelled else { return }

            // Back in one quick move rather than the same slow walk: the return
            // is not something anyone needs to read.
            withAnimation(.easeInOut(duration: 0.45)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.45))
        }
    }
}

// MARK: - Text

/// The plain-text case, which is most of them.
struct MarqueeText: View {

    let text: String
    var font: Font = .mixLabel
    var color: Color = .mixTextSecondary
    /// See `MarqueeScroller.startDelay`.
    var startDelay: Duration = .zero
    /// See `MarqueeScroller.speed`.
    var speed: Double = 22

    var body: some View {
        MarqueeScroller(identity: text, startDelay: startDelay, speed: speed) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .accessibilityLabel(text)
    }
}

// MARK: - Measurement

/// A width, and the thing it is a width *of*.
///
/// Pairing the two is what lets a stale report be recognised and dropped rather
/// than applied to whatever happens to be on screen.
private struct Measurement: Equatable {
    var identity: String
    var width: CGFloat
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue = Measurement(identity: "", width: 0)
    static func reduce(value: inout Measurement, nextValue: () -> Measurement) {
        let next = nextValue()
        // The widest report for the identity being measured. A zero-width
        // default from an empty branch must never win over a real one.
        if next.identity == value.identity {
            value.width = max(value.width, next.width)
        } else if !next.identity.isEmpty {
            value = next
        }
    }
}

private extension Duration {
    /// Seconds as a `Double`, for the SwiftUI animation APIs that want one.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
