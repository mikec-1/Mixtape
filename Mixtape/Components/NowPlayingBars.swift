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
    // Floors kept well clear of the bar width: at 3pt a 2.5pt-wide bar renders
    // as a stray dot rather than a bar, so mid-animation the group read as
    // debris instead of an equaliser.
    private let minHeights: [CGFloat] = [6, 7, 5]
    private let maxHeights: [CGFloat] = [12, 14, 10]

    @State private var animating = false
    @Environment(\.mixMotion) private var motion
    /// Music plays on with the app put away, and every row of the playing
    /// playlist carries one of these — see `AppVisibility`.
    @ObservedObject private var visibility = AppVisibility.shared

    /// One of the app's two forever-looping animations, and the one that runs
    /// while you're just listening — every row of the playing playlist carries
    /// it. Reduced motion draws the same three bars at their tall height and
    /// stops there: still the "this is the one that's playing" mark, at no
    /// cost per frame, because there are no frames.
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
        // Still, the bars have to say "playing" on their own — so a paused
        // indicator sits at the floor and a playing one stands at full height,
        // instead of both resting wherever the animation was switched off.
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
