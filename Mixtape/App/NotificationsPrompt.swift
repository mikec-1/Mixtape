// First-launch ask for notifications. Any way out counts as answered; see RootView.

import SwiftUI

struct NotificationsPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isBusy = false

    private static let kinds: [(icon: String, tint: Color, title: String, detail: String)] = [
        ("bubble.left.and.bubble.right.fill", .blue, "Messages",
         "Songs and notes sent to you. Reply right from the banner."),
        ("tray.full.fill", .orange, "Playlist activity",
         "Invites to collaborate, and when someone joins, saves or dubs one of yours."),
        ("dot.radiowaves.left.and.right", .purple, "Jams near you",
         "When a friend nearby starts a Jam you can join."),
        ("sparkles", .pink, "New releases",
         "New music from artists in your library, at most a few a day."),
        ("calendar", .green, "Monthly recap",
         "Your month in music, ready on the 1st."),
    ]

    var body: some View {
        MixSheet(title: "",
                 size: .large,
                 primary: MixSheetAction("Turn On", isBusy: isBusy, action: turnOn),
                 cancelTitle: "Not Now") {
            VStack(spacing: 8) {
                hero
                ForEach(Self.kinds, id: \.title) { kind in
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.system(size: MixFontScale.size(13.5), weight: .medium))
                                .foregroundStyle(Color.mixTextPrimary)
                            Text(kind.detail)
                                .font(.system(size: MixFontScale.size(12)))
                                .foregroundStyle(Color.mixTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.mixPrimary.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            Text("Turn on notifications")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Only for things that involve you. Change it any time in Settings.")
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    /// Blocked earlier in System Settings, so the system won't ask again: send them there.
    private func turnOn() {
        isBusy = true
        Task {
            if await !InviteNotifier.shared.enable(), let url = InviteNotifier.systemSettingsURL { openURL(url) }
            dismiss()
        }
    }
}
