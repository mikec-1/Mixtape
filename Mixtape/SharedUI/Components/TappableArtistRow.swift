// TappableArtistRow.swift
// Mixtape — SharedUI/Components
//
// Renders one or more individually-tappable artist names on a single line,
// comma-separated. A "feat." blob (split via ImportService.splitArtists) becomes
// several separate tap targets so tapping a featured artist opens *their*
// profile rather than failing on the whole "Drake feat. 21 Savage" string.
//
// A single artist (the common case) looks and behaves exactly like a lone text
// link, so non-featured rows are visually unchanged. When an entry's action is
// nil it degrades to plain, non-interactive text.

import SwiftUI

struct TappableArtistRow: View {
    /// One entry per individual artist. `action == nil` renders plain text.
    let targets: [(name: String, action: (() -> Void)?)]
    var font:  Font  = .mixLabel
    var color: Color = .mixTextSecondary

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.offset) { idx, item in
                // A four-name credit won't always fit. Descending priority
                // spends the width from the left, so the line reads in full and
                // trails off once at the end — without it SwiftUI shortens every
                // name at once ("Kwengfa…, Digga D, Booter B…") and the
                // credit names nobody. The separator shares its name's priority
                // so a comma is never drawn after a name that lost its letters.
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
            // Linked names take the brighter text colour and the separators
            // keep the passed one, which is what tells them apart now that the
            // underline is gone — the same contrast Spotify's bylines use.
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

/// One linked name.
///
/// No standing underline: a byline of three artists drawn with three rules
/// under it reads as a form field, not as a credit. What marks it as a link is
/// the brighter colour against the dimmed separators around it, plus the
/// pointing hand and an underline that appears under the pointer.
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
