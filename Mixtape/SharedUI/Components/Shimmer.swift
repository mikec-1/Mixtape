// Loading skeletons: a shimmer modifier plus placeholder shapes and rows
// that mirror the real layout.

import SwiftUI

// MARK: - Shimmer modifier

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.mixMotion) private var motion
    @ObservedObject private var visibility = AppVisibility.shared

    /// Reduce motion drops the overlay; a frozen band looks like a smear. Masked to the content,
    /// so one shimmer on a whole skeleton only lights its shapes.
    @ViewBuilder
    func body(content: Content) -> some View {
        if motion.isReduced {
            content
        } else {
            content
                .overlay(
                    GeometryReader { geo in
                        let width = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.18), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.6)
                        .offset(x: phase * width * 1.6)
                    }
                )
                .mask { content }
                .onAppear { sweep() }
                // Stop redrawing in the background. See `AppVisibility`.
                .onChange(of: visibility.isForeground) { _, _ in sweep() }
        }
    }
}

private extension Shimmer {
    func sweep() {
        guard visibility.isForeground else {
            withMixAnimation(nil) { phase = -1 }
            return
        }
        withMixAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

public extension View {
    /// Adds a sweeping shimmer highlight. Apply to skeleton placeholder shapes.
    func shimmering() -> some View { modifier(Shimmer()) }
}

// MARK: - Placeholder shape

public struct SkeletonBox: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 6) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.mixSurface2)
            .frame(width: width, height: height)
            .shimmering()
    }
}

// MARK: - Track row skeleton

public struct TrackRowSkeleton: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 12) {
            SkeletonBox(width: 44, height: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 160, height: 13, cornerRadius: 4)
                SkeletonBox(width: 100, height: 11, cornerRadius: 4)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// A skeleton shape with no shimmer of its own, for skeletons shimmered as a whole.
private func bone(width: CGFloat? = nil, height: CGFloat, radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Color.mixSurface2)
        .frame(width: width, height: height)
}

// MARK: - Track list skeleton

/// A track list still loading, at the real rows' size under one shimmer. Bones, not redacted
/// text: redaction drew the text lines far fainter than the artwork.
public struct TrackListSkeleton: View {
    private let rows: Int
    private let numbered: Bool

    public init(rows: Int = 8, numbered: Bool = false) {
        self.rows = rows
        self.numbered = numbered
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 12) {
                    if numbered {
                        bone(width: 12, height: 10, radius: 3)
                            .frame(width: Self.numberWidth, alignment: .trailing)
                    }
                    bone(width: Self.artwork, height: Self.artwork, radius: Self.artworkRadius)
                    VStack(alignment: .leading, spacing: 8) {
                        bone(width: Self.titles[i % Self.titles.count], height: Self.titleHeight, radius: 4)
                        bone(width: Self.artists[i % Self.artists.count], height: 10, radius: 4)
                    }
                    Spacer(minLength: 0)
                    bone(width: 30, height: 10, radius: 3)
                }
                .padding(.vertical, 6)
            }
        }
        .shimmering()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    // Uneven lengths, so the bars don't read as a grid.
    private static let titles:  [CGFloat] = [180, 240, 120, 210, 90]
    private static let artists: [CGFloat] = [110, 60, 140, 90]

    #if os(iOS)
    private static let artwork: CGFloat = 44, artworkRadius: CGFloat = 6, titleHeight: CGFloat = 13, numberWidth: CGFloat = 26
    #else
    private static let artwork: CGFloat = 40, artworkRadius: CGFloat = 4, titleHeight: CGFloat = 11, numberWidth: CGFloat = 22
    #endif
}

// MARK: - Horizontal carousel skeleton (artwork cards)

/// A shelf of cards still loading. Runs off the trailing edge like a real shelf.
public struct CarouselSkeleton: View {
    private let title: Bool
    private let cardSize: CGFloat

    public init(showTitle: Bool = true, cardSize: CGFloat = 140) {
        self.title = showTitle
        self.cardSize = cardSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title {
                bone(width: 150, height: 18, radius: 5)
                    .padding(.horizontal, 2)
            }
            HStack(spacing: 14) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        bone(width: cardSize, height: cardSize, radius: 10)
                        bone(width: cardSize * 0.75, height: 12, radius: 4)
                        bone(width: cardSize * 0.5, height: 10, radius: 4)
                    }
                }
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .shimmering()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
