// One line that scrolls sideways when it doesn't fit.

import SwiftUI

// MARK: - Scroller

/// Scrolls its overflow into view and back, pausing at each end. Content that
/// fits doesn't move. Generic so per-artist tap targets still work while scrolling.
struct MarqueeScroller<Content: View>: View {

    /// A change restarts the cycle and invalidates the measurement.
    let identity: String

    /// Staggers two lines so they don't move together.
    var startDelay: Duration = .zero

    /// Average points per second (it eases). Credits read better slower.
    var speed: Double = 22

    @ViewBuilder var content: () -> Content

    /// The hold at each end. The pause at the start is what makes the line
    /// readable at a glance for someone who isn't watching it travel.
    private static var holdAtStart: Duration { .seconds(2.5) }
    private static var holdAtEnd:   Duration { .seconds(1.5) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mixMotion) private var motion
    /// Pauses in the background. See `AppVisibility`.
    private var visibility: AppVisibility { .shared }

    @State private var measured = Measurement(identity: "", width: 0)
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Natural width, only trusted if it was measured for the current identity.
    /// Otherwise 0, so a new song doesn't scroll using the old width.
    private var contentWidth: CGFloat {
        measured.identity == identity ? measured.width : 0
    }

    /// How far the content has to travel to show its tail.
    private var overflow: CGFloat { max(0, contentWidth - containerWidth) }

    /// A couple of points of overflow isn't worth scrolling.
    private var shouldScroll: Bool {
        !reduceMotion && !motion.isReduced && visibility.isForeground && overflow > 4
    }

    var body: some View {
        // A hidden, unfixed copy does the layout (truncating, real height). The
        // scrolling copy is an overlay, so its fixed width can't widen the parent.
        content()
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                content()
                    // Natural width so overflow is measurable. Safe in an overlay.
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
            // Restart when the line changes.
            .task(id: cycleIdentity) { await runCycle() }
    }

    /// Width matters too: rotation can make a line fit.
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

            // Ease in and out of the holds.
            withAnimation(.easeInOut(duration: travel.seconds)) { offset = -overflow }
            try? await Task.sleep(for: travel + Self.holdAtEnd)
            guard !Task.isCancelled else { return }

            // Quick return.
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

/// Width paired with what it measured, so stale reports get dropped.
private struct Measurement: Equatable {
    var identity: String
    var width: CGFloat
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue = Measurement(identity: "", width: 0)
    static func reduce(value: inout Measurement, nextValue: () -> Measurement) {
        let next = nextValue()
        // The widest report for this identity wins over empty-branch zeros.
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
