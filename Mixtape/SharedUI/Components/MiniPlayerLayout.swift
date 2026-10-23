// How much room the iOS mini player takes, and the modifier that reserves it.
// It's an overlay in the root ZStack, so pages need `miniPlayerSafeArea()` to
// scroll their last row clear. No-op on macOS (the player bar takes real space).

import SwiftUI

// MARK: - Metrics

enum MiniPlayerMetrics {

    /// 40pt artwork + 10pt of padding above and below it.
    static let barHeight: CGFloat = 60

    /// Breathing room between the pill and the tab bar under it.
    static let gapAboveTabBar: CGFloat = 8

    /// Breathing room between the page's last row and the pill above it.
    static let contentGap: CGFloat = 8

    /// Excludes the home-indicator inset.
    static let tabBarHeight: CGFloat = 49

    /// Measured from the top of the tab bar.
    static let contentInset: CGFloat = gapAboveTabBar + barHeight + contentGap

    /// Where a bottom-anchored overlay in the root ZStack has to sit to clear
    /// the tab bar.
    static let overlayBottomPadding: CGFloat = tabBarHeight + gapAboveTabBar
}

// MARK: - Safe area reservation

public extension View {
    /// Reserves room so the last row stays reachable under the pill. Apply per page,
    /// inside its NavigationStack: a safe area set at the tab root doesn't reach pushed views.
    @ViewBuilder
    func miniPlayerSafeArea() -> some View {
        #if os(iOS)
        modifier(MiniPlayerSafeArea())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct MiniPlayerSafeArea: ViewModifier {

    @Environment(PlaybackEngine.self) private var engine
    private var keyboard: KeyboardVisibility { .shared }

    /// Only while the pill shows; it hides for the keyboard.
    private var inset: CGFloat {
        guard engine.state.isActive, !keyboard.isVisible else { return 0 }
        return MiniPlayerMetrics.contentInset
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: inset)
                .allowsHitTesting(false)
        }
    }
}
#endif

// MARK: - Keyboard visibility

#if os(iOS)
import Combine
import UIKit
import Observation

/// Keyboard visible. Floating views over the tab bar hide while typing.
@Observable
@MainActor
final class KeyboardVisibility {

    static let shared = KeyboardVisibility()

    private(set) var isVisible = false
    @ObservationIgnored private var watch: AnyCancellable?

    private init() {
        let center = NotificationCenter.default
        watch = center.publisher(for: UIResponder.keyboardWillShowNotification)
            .map { _ in true }
            .merge(with: center.publisher(for: UIResponder.keyboardWillHideNotification)
                                .map { _ in false })
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.isVisible = $0 }
    }
}
#endif
