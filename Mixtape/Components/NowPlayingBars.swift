// Animated "now playing" bars.

import SwiftUI

struct NowPlayingBars: View {
    var isPlaying: Bool
    var color: Color = Color.mixPrimary
    var barCount: Int = 3
    var barWidth: CGFloat = 2.5
    var barSpacing: CGFloat = 2

    // Each bar gets a slightly different animation phase so they feel organic
    private let phases: [Double] = [0.0, 0.3, 0.15]
    private let durations: [Double] = [0.5, 0.7, 0.6]
    // Floors stay above the bar width or bars render as dots.
    private let minHeights: [CGFloat] = [6, 7, 5]
    private let maxHeights: [CGFloat] = [12, 14, 10]

    @State private var animating = false
    @Environment(\.mixMotion) private var motion
    private var visibility: AppVisibility { .shared }

    /// Reduced motion shows static bars.
    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: barWidth, height: barHeight(i))
                    .animation(motion.isReduced ? nil : barAnimation(i), value: animating)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .onAppear {
            animating = isPlaying && visibility.isForeground
        }
        .onChange(of: isPlaying) { _, playing in
            animating = playing && visibility.isForeground
        }
        .onChange(of: visibility.isForeground) { _, visible in
            animating = isPlaying && visible
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Paused sits at the floor, playing stands tall.
        let tall  = maxHeights[i % maxHeights.count]
        let short = minHeights[i % minHeights.count]
        if motion.isReduced { return isPlaying ? tall : short }
        return animating && isPlaying ? tall : short
    }

    private func barAnimation(_ i: Int) -> Animation {
        isPlaying
        ? Animation
            .easeInOut(duration: durations[i % durations.count])
            .repeatForever(autoreverses: true)
            .delay(phases[i % phases.count])
        : .easeOut(duration: 0.2)
    }
}
