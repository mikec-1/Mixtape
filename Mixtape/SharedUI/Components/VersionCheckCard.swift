// The card after "Wrong version" lands on a new upload: go back, try another, or keep it.
// Stays until answered or the song changes, since judging a version takes a listen.

import SwiftUI

struct VersionCheckHost: View {

    @ObservedObject var coordinator: OnlinePlaybackCoordinator
    @ObservedObject var queue: QueueService
    /// Gap below the card; carried by the card so an empty host takes no space.
    var bottomGap: CGFloat = 0

    var body: some View {
        ZStack {
            if let check = coordinator.versionCheck {
                VersionCheckCard(check: check)
                    .padding(.bottom, bottomGap)
                    .id(check.id)
                    .transition(SavedToastHost.transition)
            }
        }
        .mixAnimation(SavedToastHost.animation, value: coordinator.versionCheck?.id)
        .onChange(of: queue.currentTrack?.id) { _, _ in coordinator.dismissVersionCheck() }
    }
}

private struct VersionCheckCard: View {

    let check: OnlinePlaybackCoordinator.VersionCheck

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Right version?")
                    .font(.system(size: MixFontScale.size(13), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                Text(check.title)
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .padding(.trailing, 6)
            Spacer(minLength: 0)

            if check.canGoBack {
                button("arrow.uturn.backward", "Go back to the earlier version") {
                    Task { await deps.restorePreviousVersion() }
                }
            }
            button("hand.thumbsdown", "Try another version") {
                Task { await deps.tryAnotherVersion() }
            }
            button("hand.thumbsup.fill", "Keep this version", prominent: true) {
                Haptics.play(.success)
                deps.onlineCoordinator.confirmVersion()
            }
            button("xmark", "Dismiss", small: true) {
                deps.onlineCoordinator.dismissVersionCheck()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mixSeparator.opacity(0.8), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.32), radius: 14, y: 5)
    }

    private func button(_ icon: String, _ label: String, prominent: Bool = false,
                        small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: small ? 11 : 14, weight: .semibold))
                .foregroundStyle(prominent ? Color.mixOnAccent : Color.mixTextPrimary)
                .frame(width: small ? 24 : 34, height: small ? 24 : 34)
                .background(prominent ? Color.mixAccentFill : Color.primary.opacity(small ? 0 : 0.08),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}
