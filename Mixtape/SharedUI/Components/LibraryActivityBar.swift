// LibraryActivityBar.swift
// Mixtape — SharedUI/Components
//
// "Updating library — 2,010 songs", with a spinner.
//
// The companion to `DownloadStatusBar`, in the same corner and the same shape,
// because it answers the same question: is the app doing something, or is it
// stuck. Reading the library takes real time on a large one, and while it ran
// the app said nothing at all — an empty list and a still screen, which reads
// as broken rather than as busy.
//
// A spinner rather than a bar: unlike a download run, a library read has no
// honest denominator to divide by. Inventing one would be worse than showing
// none.

import SwiftUI
import Combine

/// The full row: spinner, label, count. For the expanded sidebar.
struct LibraryActivityBar: View {

    @ObservedObject var library: LibraryService

    /// Collapses to nothing when the library is idle, so the host can place it
    /// unconditionally.
    var body: some View {
        if let label = library.activity.label {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let detail = library.activity.detail {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium))
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
                // An indeterminate track under the row. It carries no number —
                // there isn't an honest one — but a moving bar is what people
                // read as "still going", where a lone spinner beside text reads
                // as decoration.
                IndeterminateBar()
            }
            // Slide-and-push rather than a fade: this row appears above a list
            // the user is already looking at, and the point is that it moves
            // that list down far enough to be noticed.
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// A single lit segment sweeping left to right, on nothing.
///
/// Not `ProgressView(.linear)`: an indeterminate linear style draws its unfilled
/// track, and that grey line spans the sidebar whether or not the lit part has
/// reached it — which reads as a half-finished determinate bar rather than as
/// motion. There is no honest denominator here, so there should be no groove for
/// one to fill.
private struct IndeterminateBar: View {

    @State private var sweeping = false
    @ObservedObject private var visibility = AppVisibility.shared

    var body: some View {
        GeometryReader { geo in
            let width   = geo.size.width
            let segment = max(48, width * 0.3)

            Capsule()
                .fill(Color.mixPrimary)
                .frame(width: segment)
                // Starts fully off the leading edge and ends fully off the
                // trailing one, so the sweep has no visible pop at either end.
                .offset(x: sweeping ? width : -segment)
                .animation(visibility.isForeground
                           ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                           : nil,
                           value: sweeping)
        }
        .frame(height: 2)
        .clipped()
        .onAppear { sweeping = visibility.isForeground }
        // A sync that outlives the app going away must not keep the sweep
        // running against a screen nobody sees — see `AppVisibility`.
        .onChange(of: visibility.isForeground) { _, visible in sweeping = visible }
    }
}

/// The 64pt version: a spinner, no words. Same text in the tooltip.
struct LibraryActivityRing: View {

    @ObservedObject var library: LibraryService

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
