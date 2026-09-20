// DownloadStatusBar.swift
// Mixtape — SharedUI/Components
//
// "Downloading 8 of 10", with a bar under it.
//
// Percentages were the wrong unit for this. A percentage of a two-thousand-song
// library sits on 0 for minutes and then on 1, which reads as a stall rather
// than as progress; songs are the thing the user asked for, so songs are what
// the count should be in. The bar is the only place in the app that answers
// "how much of what I started is left", which is why it lives in the sidebar
// rather than on whichever playlist happened to start it.

import SwiftUI

/// The full row: label, count, bar. For the expanded sidebar.
struct DownloadStatusBar: View {

    @ObservedObject var downloads: DownloadManager

    /// The counters, observed separately from the manager that owns them: they
    /// tick many times a second and this is one of only two views that draws
    /// them. See `DownloadManager.progress`.
    @ObservedObject private var progress: DownloadProgress

    init(downloads: DownloadManager) {
        self.downloads = downloads
        self.progress  = downloads.progress
    }

    /// Collapses to nothing when there's no run under way, so the host can place
    /// it unconditionally.
    var body: some View {
        if downloads.isDownloadingBatch {
            let done  = progress.completed
            let total = progress.total

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(downloads.isConnectedForDownload ? "Downloading" : "Downloads paused")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Spacer(minLength: 4)
                    Text("\(done) of \(total)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.mixTextTertiary)
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.mixTextTertiary.opacity(0.22))
                        Capsule()
                            .fill(downloads.isConnectedForDownload
                                  ? Color.mixAccent
                                  : Color.mixTextTertiary)
                            .frame(width: max(0, geo.size.width * fraction(done, total)))
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .help(helpText(done: done, total: total))
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: done)
        }
    }

    private func fraction(_ done: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    private func helpText(done: Int, total: Int) -> String {
        guard downloads.isConnectedForDownload else {
            return "Paused — \(total - done) song\(total - done == 1 ? "" : "s") left to download."
        }
        return "\(done) of \(total) song\(total == 1 ? "" : "s") saved for offline listening."
    }
}

/// The 64pt version: a ring, no words. Same numbers in the tooltip.
struct DownloadStatusRing: View {

    @ObservedObject var downloads: DownloadManager

    /// See `DownloadStatusBar.progress`.
    @ObservedObject private var progress: DownloadProgress

    init(downloads: DownloadManager) {
        self.downloads = downloads
        self.progress  = downloads.progress
    }

    var body: some View {
        if downloads.isDownloadingBatch {
            let done  = progress.completed
            let total = progress.total
            let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0

            ZStack {
                Circle()
                    .stroke(Color.mixTextTertiary.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(downloads.isConnectedForDownload ? Color.mixAccent : Color.mixTextTertiary,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .frame(width: 22, height: 22)
            .padding(.vertical, 6)
            .help("Downloading — \(done) of \(total) songs")
            .animation(.easeInOut(duration: 0.25), value: done)
        }
    }
}
