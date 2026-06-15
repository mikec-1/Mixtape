// Shimmer.swift
// Mixtape — SharedUI/Components
//
// Loading-skeleton primitives: an animated shimmer modifier plus ready-made
// placeholder shapes and row/carousel skeletons that mirror the real content
// layout so the transition into loaded data is calm, not jumpy.

import SwiftUI

// MARK: - Shimmer modifier

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
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
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
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

// MARK: - Horizontal carousel skeleton (artwork cards)

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
                SkeletonBox(width: 150, height: 18, cornerRadius: 5)
                    .padding(.horizontal, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBox(width: cardSize, height: cardSize, cornerRadius: 10)
                            SkeletonBox(width: cardSize * 0.75, height: 12, cornerRadius: 4)
                            SkeletonBox(width: cardSize * 0.5, height: 10, cornerRadius: 4)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}
