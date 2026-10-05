// Artist names on one line, each tappable. Features are split
// (ImportService.splitArtists) so each opens its own profile. Nil action = plain text.

import SwiftUI

struct TappableArtistRow: View {
    /// One entry per individual artist. `action == nil` renders plain text.
    let targets: [(name: String, action: (() -> Void)?)]
    var font:  Font  = .mixLabel
    var color: Color = .mixTextSecondary

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.offset) { idx, item in
                // Descending layout priority, so names truncate from the end rather than all
                // at once. Separators share their name's priority.
                nameView(item)
                    .layoutPriority(Double(targets.count - idx))
                if idx < targets.count - 1 {
                    Text(", ")
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        .layoutPriority(Double(targets.count - idx))
                }
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func nameView(_ item: (name: String, action: (() -> Void)?)) -> some View {
        if let action = item.action {
            // Linked names are brighter than the separators.
            TappableArtistName(name: item.name, font: font,
                               color: .mixTextPrimary, action: action)
        } else {
            Text(item.name)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// One linked name: brighter colour, pointing hand, underline on hover.
private struct TappableArtistName: View {
    let name: String
    let font: Font
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(font)
                .foregroundStyle(color)
                .underline(isHovered)
                .lineLimit(1)
        }
        .buttonStyle(.plain).mixHandCursor()
        #if os(macOS)
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
        .accessibilityLabel(name)
        .accessibilityHint("Opens \(name)")
    }
}
