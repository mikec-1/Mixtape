// BackButton.swift
// Mixtape — SharedUI/Components
//
// The circular back control used on every drill-down page.
//
// It replaces the "‹ Back" text link the app used to carry. A word is only worth
// spending when it says something the shape doesn't, and back is the one
// direction every platform already draws as a chevron — the label was paying for
// itself in width and nothing else. The circle is what makes it a target rather
// than a glyph floating in space.
//
// `.contentShape(Circle())` is load-bearing: SwiftUI hit-tests a plain Image
// against the glyph it drew, not the frame you gave it or the background you put
// behind it, so without it every click that lands on the circle instead of the
// chevron's own strokes goes nowhere.
//
// Use `.pageBack { … }` rather than placing the button by hand. The control
// belongs *on* the page, floating in its top-leading corner — not in a strip
// above it. A bar is a second toolbar under the real one: it costs a full row of
// height on every drill-down, draws a hard edge across artwork the page went to
// trouble to bleed, and shifts the whole page down the moment you navigate.

import SwiftUI

struct BackButton: View {

    let action: () -> Void
    /// Tooltip / accessibility label. "Back" is right most of the time; name the
    /// destination when the page came from somewhere specific ("All artists").
    var label: String = "Back"

    @State private var isHovering = false

    private let diameter: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(isHovering ? Color.mixSurface2 : Color.mixSurface)
                        // The button floats over artwork on some pages, so it
                        // carries its own edge instead of relying on contrast
                        // with whatever happens to be behind it.
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovering = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Floats the back control in this page's top-leading corner.
    ///
    /// An overlay, deliberately: it is the last thing drawn and the first thing
    /// hit-tested, so no amount of content overflow underneath can swallow the
    /// click — which is exactly what a sibling laid out *above* the page could
    /// not promise.
    func pageBack(_ label: String = "Back", action: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            BackButton(action: action, label: label)
                .padding(.leading, 16)
                .padding(.top, 14)
        }
    }
}
