// DownloadStateBadge.swift
// Mixtape — SharedUI/Components
//
// "Is this playlist on my device?" in one glyph, on both platforms.
//
// Three states, one of which used to be missing: nothing at all, a ring that
// fills while the songs come down, and the green disc once they are all here.
// Without the middle one a long download looked exactly like no download until
// the moment it finished, which is why people pressed the button twice.

import SwiftUI

struct DownloadStateBadge: View {

    /// The songs this badge speaks for — a playlist, an album, one track.
    let ids: [UUID]
    @ObservedObject var downloads: DownloadManager
    var size: CGFloat = 11

    var body: some View {
        // Read once: `downloadFraction` is nil unless something is in flight,
        // so the ring never outlives the run it belongs to.
        if let fraction = downloads.downloadFraction(ids) {
            ZStack {
                Circle()
                    .stroke(Color.mixTextTertiary.opacity(0.35), lineWidth: size * 0.16)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            .mixAnimation(.easeInOut(duration: 0.25), value: fraction)
            .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent")
        } else if downloads.isFullyDownloaded(ids) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Available offline")
        }
    }
}
