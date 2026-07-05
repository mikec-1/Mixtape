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
                nameView(item)
                if idx < targets.count - 1 {
                    Text(", ")
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                }
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func nameView(_ item: (name: String, action: (() -> Void)?)) -> some View {
        if let action = item.action {
            Button(action: action) {
                Text(item.name)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(item.name)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
