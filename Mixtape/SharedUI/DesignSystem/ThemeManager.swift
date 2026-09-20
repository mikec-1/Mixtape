// ThemeManager.swift
// Mixtape — Design System
//
// Single source of truth for user-selectable appearance (system/light/dark)
// and accent colour. Persists choices in UserDefaults and republishes so the
// UI re-renders. The neutral colour tokens in MixtapeColors resolve light/dark
// automatically via trait-aware dynamic colours; only the *accent* is a user
// choice and therefore read back from `ThemeManager.shared`.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Combine

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Appearance

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil = follow the system setting.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    #if os(macOS)
    /// AppKit equivalent. nil = follow the system setting. Applied to
    /// `NSApp.appearance` so AppKit-backed controls (pop-up buttons, the
    /// NSTableView song list) flip immediately instead of lagging behind
    /// SwiftUI's `.preferredColorScheme`.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

// MARK: - Accent (fixed)

/// The app's single brand accent. No longer user-selectable.
public enum BrandAccent {
    public static let hex     = "#FF6B00"
    public static let darkHex = "#E05C00"
    public static let color     = Color(hex: hex)
    public static let darkColor = Color(hex: darkHex)
}

// MARK: - Manager

public final class ThemeManager: ObservableObject {

    public static let shared = ThemeManager()

    private enum Keys {
        static let appearance = "theme.appearance"
        static let density    = "theme.density"
        static let motion     = "theme.motion"
        static let chrome     = "theme.chrome"
    }

    @Published public var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppKitAppearance()
        }
    }

    /// How much room the layout gives itself. See `MixDensity`.
    @Published public var density: MixDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: Keys.density) }
    }

    /// How much the app animates. See `MixMotion`.
    ///
    /// Mirrored into `MixMotion.current` on every write, because the imperative
    /// half of the app (`withMixAnimation`) has no environment to read from.
    @Published public var motion: MixMotion {
        didSet {
            UserDefaults.standard.set(motion.rawValue, forKey: Keys.motion)
            MixMotion.current = motion
        }
    }

    /// Token for the system Reduce Motion observer.
    private var motionObserver: NSObjectProtocol?

    /// How much the app decorates. See `MixChrome`.
    @Published public var chrome: MixChrome {
        didSet { UserDefaults.standard.set(chrome.rawValue, forKey: Keys.chrome) }
    }

    /// The named look the three axes currently amount to.
    ///
    /// Reading it is a lookup, not stored state — so tinkering with one axis
    /// moves the picker to Custom by itself, and there is no fourth value that
    /// can disagree with the three real ones.
    public var preset: MixAppearancePreset {
        get { MixAppearancePreset.matching(density: density, motion: motion, chrome: chrome) }
        set {
            guard let axes = newValue.axes else { return }
            density = axes.density
            motion  = axes.motion
            chrome  = axes.chrome
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        // Defaults are the Normal preset: this is how the app has always looked,
        // and an update must not quietly redesign anyone's library.
        self.density = MixDensity(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .comfortable
        // No stored choice means the system gets to answer. Someone with Reduce
        // Motion on has already said what they want and should not have to find
        // this app's own switch; someone who has picked an axis value keeps it,
        // in either direction.
        self.motion  = MixMotion(rawValue: defaults.string(forKey: Keys.motion) ?? "")
                    ?? (Self.systemWantsReducedMotion ? .reduced : .full)
        self.chrome  = MixChrome(rawValue:  defaults.string(forKey: Keys.chrome)  ?? "") ?? .rich
        MixMotion.current = self.motion
        applyAppKitAppearance()
        observeSystemMotionSetting()
    }

    /// Whether the OS is currently asking for reduced motion.
    static var systemWantsReducedMotion: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }

    /// Follow the system setting while the user has never overridden it.
    ///
    /// Once they touch the axis in Settings the stored value wins and this stops
    /// having an opinion — otherwise toggling the OS switch would silently undo
    /// a deliberate choice.
    private func observeSystemMotionSetting() {
        #if canImport(UIKit)
        let name = UIAccessibility.reduceMotionStatusDidChangeNotification
        let center = NotificationCenter.default
        #elseif canImport(AppKit)
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        let center = NSWorkspace.shared.notificationCenter
        #else
        return
        #endif
        motionObserver = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self,
                  UserDefaults.standard.string(forKey: Keys.motion) == nil else { return }
            let wanted: MixMotion = Self.systemWantsReducedMotion ? .reduced : .full
            guard wanted != self.motion else { return }
            self.motion = wanted
            // `motion`'s didSet persists the value, which would freeze the
            // follow-the-system behaviour. Clear it again so the app keeps
            // tracking until the user makes an actual choice.
            UserDefaults.standard.removeObject(forKey: Keys.motion)
        }
    }

    public var preferredColorScheme: ColorScheme? { appearance.colorScheme }
    public var accentColor: Color { BrandAccent.color }

    /// Drive the global AppKit appearance so AppKit-backed controls update
    /// instantly when the user changes the Light/Dark/System setting.
    private func applyAppKitAppearance() {
        #if os(macOS)
        NSApplication.shared.appearance = appearance.nsAppearance
        #endif
    }
}
