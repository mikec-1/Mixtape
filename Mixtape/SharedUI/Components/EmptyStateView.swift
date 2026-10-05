// Shared empty state, built on `ContentUnavailableView`.

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
            // Label so the system sizes the symbol and title together.
            Label(title, systemImage: icon)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                // Tinted `.bordered` for contrast; white on `mixAccentFill` failed 4.5:1 in light mode.
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
        // Min height for use inside scroll views, which propose no height.
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
