// "Updating library - 2,010 songs" with a spinner, next to `DownloadStatusBar`.
// No real denominator, so no progress bar.

import SwiftUI
import Combine

/// The full row: spinner, label, count. For the expanded sidebar.
struct LibraryActivityBar: View {

    var library: LibraryService

    /// Empty when idle, so the host can place it unconditionally.
    var body: some View {
        if let label = library.activity.label {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(label)
                    .font(.system(size: MixFontScale.size(12), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let detail = library.activity.detail {
                    Text(detail)
                        .font(.system(size: MixFontScale.size(11.5), weight: .medium))
                        .foregroundStyle(Color.mixTextTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .help(library.activity.detail.map { "\(label) — \($0)" } ?? label)
            .overlay(alignment: .bottom) {
                // Indeterminate sweep; reads as "still going" better than a lone spinner.
                IndeterminateBar()
            }
            // Pushes the list down so it's noticed.
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// A lit segment sweeping across. Not `ProgressView(.linear)`, which draws a
/// grey track that reads as determinate.
private struct IndeterminateBar: View {

    @State private var sweeping = false
    private var visibility: AppVisibility { .shared }

    var body: some View {
        GeometryReader { geo in
            let width   = geo.size.width
            let segment = max(48, width * 0.3)

            Capsule()
                .fill(Color.mixPrimary)
                .frame(width: segment)
                // Fully off-screen at both ends so there's no pop.
                .offset(x: sweeping ? width : -segment)
                .animation(visibility.isForeground
                           ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                           : nil,
                           value: sweeping)
        }
        .frame(height: 2)
        .clipped()
        .onAppear { sweeping = visibility.isForeground }
        // Stop animating in the background. See `AppVisibility`.
        .onChange(of: visibility.isForeground) { _, visible in sweeping = visible }
    }
}

/// The 64pt version: a spinner, no words. Same text in the tooltip.
struct LibraryActivityRing: View {

    var library: LibraryService

    var body: some View {
        if let label = library.activity.label {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
                .padding(.vertical, 6)
                .help(library.activity.detail.map { "\(label) — \($0)" } ?? label)
                .transition(.opacity)
        }
    }
}
