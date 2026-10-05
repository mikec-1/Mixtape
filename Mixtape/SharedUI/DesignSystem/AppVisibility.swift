import Foundation
import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

/// Whether the app is on screen. Audio keeps the process alive in the
/// background, and looping animations kept running at display rate there until
/// iOS killed the app for CPU use. Loops check this first.
/// Gate the animation's driver (target state), never the modifier, or view
/// identity would depend on scene phase.
@MainActor
public final class AppVisibility: ObservableObject {

    public static let shared = AppVisibility()

    /// True while `.active`. Inactive (app switcher, call banner) counts as away.
    @Published public private(set) var isForeground = true

    /// Whether the user is looking at Mixtape right now, so a banner would be noise.
    /// A Mac window stays `.active` behind other apps, so macOS asks AppKit instead.
    public var isFrontmost: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        isForeground
        #endif
    }

    private init() {}

    public func update(_ phase: ScenePhase) {
        let foreground = phase == .active
        guard foreground != isForeground else { return }
        isForeground = foreground
    }
}
