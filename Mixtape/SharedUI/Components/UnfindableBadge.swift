// Red triangle on a queue row when nothing online has the song. Shared by both queue lists.

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
                // Not `.help()`, whose tooltip takes about a second; this shows immediately.
                .overlay(alignment: .bottomLeading) {
                    if isHovering { tip.offset(x: 14, y: -14) }
                }
                .accessibilityLabel("Couldn't be found — will be skipped")
                .zIndex(1)
        }
    }

    /// Black rather than the surface colour so it floats in both themes.
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
            // Never takes the hover, or it flickers.
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
