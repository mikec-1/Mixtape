// NowPlayingBars.swift
// Mixtape — Components
//
// Animated equalizer bars shown on the playlist that's currently playing.
// Mimics the classic Spotify "now playing" indicator.

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
    private let minHeights: [CGFloat] = [3, 4, 3]
    private let maxHeights: [CGFloat] = [12, 14, 10]

    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: barWidth, height: animating && isPlaying
                           ? maxHeights[i % maxHeights.count]
                           : minHeights[i % minHeights.count])
                    .animation(
                        isPlaying
                        ? Animation
                            .easeInOut(duration: durations[i % durations.count])
                            .repeatForever(autoreverses: true)
                            .delay(phases[i % phases.count])
                        : .easeOut(duration: 0.2),
                        value: animating
                    )
            }
        }
        .frame(height: 14, alignment: .bottom)
        .onAppear {
            if isPlaying { animating = true }
        }
        .onChange(of: isPlaying) { _, playing in
            animating = playing
        }
    }
}
