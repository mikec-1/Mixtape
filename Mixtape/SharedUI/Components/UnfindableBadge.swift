// UnfindableBadge.swift
// Mixtape — SharedUI/Components
//
// The red triangle a queue row wears when nothing online has the song.
//
// Drawn once and used by both queue lists, because the two of them disagreeing
// about what a warning looks like is worse than either choice.

import SwiftUI

struct UnfindableBadge: View {

    @ObservedObject private var unavailable = UnavailableTracks.shared

    @State private var isHovering = false

    let track: Track

    var body: some View {
        if unavailable.contains(track) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .onHover { isHovering = $0 }
                // Not `.help()`: the system tooltip waits about a second before
                // it appears, which is long enough that the pointer has usually
                // moved on. This shows on the frame the pointer arrives.
                .overlay(alignment: .bottomLeading) {
                    if isHovering { tip.offset(x: 14, y: -14) }
                }
                .accessibilityLabel("Couldn't be found — will be skipped")
                .zIndex(1)
        }
    }

    /// Deliberately black rather than the surface colour: it has to read as
    /// floating above the row it is covering, in both themes.
    private var tip: some View {
        Text("Not found online — will be skipped")
            .font(.mixCaption)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            // The pointer must never land on the tip itself — it sits over the
            // row, and swallowing the hover would make it flicker.
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
