// AppVisibility.swift
// Mixtape — SharedUI/DesignSystem

import Foundation
import SwiftUI
import Combine

/// Whether the app is on screen.
///
/// Music keeps playing when the phone is locked or the app is put away, so the
/// process stays alive — and every one of the app's forever-looping animations
/// (the equaliser bars on each row of the playing playlist, the shimmer, the
/// two indeterminate bars) kept driving the SwiftUI run loop at display rate
/// against a screen nobody was looking at. iOS killed the app for it: the
/// crash report reads `cpu_resource_fatal`, "48 seconds cpu time over 58
/// seconds (83% cpu average)", taken while non-frontmost with the user idle.
/// That is the ten-minute "crash".
///
/// So the loops ask here first. This gates the *driver* of an animation — the
/// state it animates towards — never the modifier's output, which would make
/// the view's identity depend on the scene phase and re-lay-out the world on
/// every backgrounding.
@MainActor
public final class AppVisibility: ObservableObject {

    public static let shared = AppVisibility()

    /// True while the scene is `.active`. Inactive counts as away: the app is
    /// behind the app switcher or a call banner, and still not being watched.
    @Published public private(set) var isForeground = true

    private init() {}

    public func update(_ phase: ScenePhase) {
        let foreground = phase == .active
        guard foreground != isForeground else { return }
        isForeground = foreground
    }
}
