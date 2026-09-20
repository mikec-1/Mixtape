// EmptyStateView.swift
// Mixtape — SharedUI/Components
//
// Reusable, consistent empty-state used across screens (library sections,
// search, playlists, downloads…).
//
// The layout is `ContentUnavailableView` now rather than a hand-stacked
// VStack. The two were already trying to be the same thing — a large muted
// glyph, a title, a line of explanation, centred — and the system's version
// is the one that stays right: it carries Apple's own spacing and optical
// centring, it lays out correctly at every Dynamic Type size and in every
// window width without the `.padding(.horizontal, 32)` that used to be
// holding the copy in, and it is the shape a user has already seen in Mail,
// Photos and Files. Matching it by hand is work that can only ever converge
// on what this line gives for free.
//
// The public initialiser is unchanged, so every call site is untouched.

import SwiftUI

public struct EmptyStateView: View {

    private let icon: String
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        icon: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            // Label rather than a bare Image: the system draws the symbol at
            // its own display size and the title in its own weight, and keeps
            // the two optically related as the text scales.
            Label(title, systemImage: icon)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                // `.bordered` with a tint, which is how the system draws the
                // action under an empty state — a soft tinted capsule with an
                // accent-coloured label. The previous filled capsule put white
                // on `mixAccentFill`, which is 2.9:1 in the light appearance
                // and under the 4.5:1 floor the palette is built to; tinted
                // text on the page background clears it in both.
                Button(actionTitle) {
                    Haptics.play(.light)
                    action()
                }
                .buttonStyle(.bordered).mixHandCursor()
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .tint(Color.mixPrimary)
            }
        }
        // `ContentUnavailableView` fills whatever it is given and centres
        // inside it, which is right on a whole screen but has no floor in a
        // scrolling column — a `ScrollView` proposes no height, so the view
        // falls back to the bare stack of its own contents and the empty
        // state reads as three stray labels rather than a considered pause.
        // Five of the six call sites are exactly that: a section inside a
        // page that scrolls. The minimum gives it the room the system would
        // have given it, and is inert where a caller already bounds it.
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
