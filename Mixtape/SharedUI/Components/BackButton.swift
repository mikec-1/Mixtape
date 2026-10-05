// Circular back button for drill-down pages. `.contentShape(Circle())` matters:
// a plain Image only hit-tests its glyph strokes.
// Use `.pageBack { ... }` to float it in the corner instead of a toolbar strip.

import SwiftUI

struct BackButton: View {

    let action: () -> Void
    /// Tooltip/accessibility label; name the destination when it's specific.
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
                        // Own shadow since it can float over artwork.
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
    /// An overlay so it's hit-tested first and nothing underneath swallows the click.
    func pageBack(_ label: String = "Back", action: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            BackButton(action: action, label: label)
                .padding(.leading, 16)
                .padding(.top, 14)
        }
    }
}
