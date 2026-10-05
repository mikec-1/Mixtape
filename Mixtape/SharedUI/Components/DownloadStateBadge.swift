// Playlist offline state in one glyph: nothing, a filling ring, or the green disc.

import SwiftUI

struct DownloadStateBadge: View {

    /// The songs this badge speaks for: a playlist, an album, one track.
    let ids: [UUID]
    @ObservedObject var downloads: DownloadManager
    var size: CGFloat = 11
    /// False for a playlist nobody asked to keep: a shared song downloading elsewhere isn't its download.
    var showsProgress = true

    var body: some View {
        // Nil unless a download is in flight.
        if showsProgress, let fraction = downloads.downloadFraction(ids) {
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
