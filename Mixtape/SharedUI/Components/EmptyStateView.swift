// EmptyStateView.swift
// Mixtape — SharedUI/Components
//
// Reusable, consistent empty-state used across screens (library sections,
// search, playlists, downloads…). Centralises spacing/typography so every
// "nothing here yet" looks the same.

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
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Color.mixTextTertiary)

            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button {
                    Haptics.play(.light)
                    action()
                } label: {
                    Text(actionTitle)
                        .font(.mixBodyBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Color.mixPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}
