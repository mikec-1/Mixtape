// MiniPlayerLayout.swift
// Mixtape — SharedUI/Components
//
// The one place that knows how much room the floating mini player takes up, and
// the modifier a page uses to reserve it.
//
// The pill is an overlay in the root ZStack rather than a layout sibling — it
// has to survive tab switches and keep playing state on screen — which means
// nothing underneath it knows it exists. The last playlist in Your Library was
// landing behind it with no way to scroll clear. `miniPlayerSafeArea()` hands
// the page back the strip the pill covers: content still scrolls *under* the
// frosted bar, but now it can scroll far enough that the final row clears it.
//
// macOS has no mini player — MacRootView's player bar is a real layout element
// that already takes its own space — so the modifier is a no-op there.

import SwiftUI

// MARK: - Metrics

enum MiniPlayerMetrics {

    /// 40pt artwork + 10pt of padding above and below it.
    static let barHeight: CGFloat = 60

    /// Breathing room between the pill and the tab bar under it.
    static let gapAboveTabBar: CGFloat = 8

    /// Breathing room between the page's last row and the pill above it.
    static let contentGap: CGFloat = 8

    /// Tab bar height, excluding the home-indicator inset — the root ZStack is
    /// already laid out inside that.
    static let tabBarHeight: CGFloat = 49

    /// What a page has to reserve at its bottom edge while the pill is up,
    /// measured from the bottom of the tab content (i.e. the top of the tab bar).
    static let contentInset: CGFloat = gapAboveTabBar + barHeight + contentGap

    /// Where a bottom-anchored overlay in the root ZStack has to sit to clear
    /// the tab bar.
    static let overlayBottomPadding: CGFloat = tabBarHeight + gapAboveTabBar
}

// MARK: - Safe area reservation

public extension View {
    /// Reserves room at the bottom of this page for the floating mini player,
    /// so its last row stays reachable while something is playing.
    ///
    /// **Apply it per page, inside the page's own NavigationStack** — on the
    /// container the page's scroll view or List sits in. It inserts a safe-area
    /// region rather than a frame, so content still scrolls *under* the frosted
    /// pill; it just gains enough room at the end to scroll clear of it.
    ///
    /// It deliberately isn't applied once at the tab root. An added safe area
    /// reaches the stack's root view but not the views the stack *pushes* —
    /// those are laid out by a fresh hosting controller that recomputes its
    /// insets from the window — which is exactly how the last song on a
    /// playlist page ended up stranded behind the pill. One page, one call, and
    /// nothing depends on a modifier surviving a push.
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

    @EnvironmentObject private var engine: PlaybackEngine
    @ObservedObject private var keyboard = KeyboardVisibility.shared

    /// Reserved only while the pill is actually on screen. It hides itself for
    /// the keyboard, and a page being typed into shouldn't be holding a strip
    /// of empty space for something that isn't there.
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

/// Whether the software keyboard is on screen.
///
/// The mini player lives in the root ZStack, which SwiftUI lifts clear of the
/// keyboard along with everything else — so typing in Search left the pill
/// stranded in mid-air above the keys. Views that float over the tab bar watch
/// this and get out of the way: the keyboard is what's being used, and nothing
/// should be hovering over it.
@MainActor
final class KeyboardVisibility: ObservableObject {

    static let shared = KeyboardVisibility()

    @Published private(set) var isVisible = false

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillShowNotification)
            .map { _ in true }
            .merge(with: center.publisher(for: UIResponder.keyboardWillHideNotification)
                                .map { _ in false })
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .assign(to: &$isVisible)
    }
}
#endif
