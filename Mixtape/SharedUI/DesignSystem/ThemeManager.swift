// Appearance (system/light/dark) and accent colour, persisted in
// UserDefaults. Neutral tokens resolve light/dark themselves; only the accent is
// read from `ThemeManager.shared`.

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
    /// AppKit appearance; nil follows the system. Set on `NSApp.appearance` so
    /// AppKit controls flip immediately.
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
public nonisolated enum BrandAccent {
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
        static let backdrop   = "theme.backdrop"
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

    /// See `MixMotion`. Mirrored into `MixMotion.current` for `withMixAnimation`.
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

    /// A colour mixed into the app's background, nil for plain. Follows the account.
    @Published public var backdrop: MixBackdrop? {
        didSet {
            guard backdrop != oldValue else { return }
            UserDefaults.standard.set(backdrop?.raw, forKey: Keys.backdrop)
            guard !isApplyingRemote else { return }
            lastLocalBackdropChange = .now
            // Debounced: the colour picker reports every step of a drag.
            let raw = backdrop?.raw ?? MixBackdrop.offRaw
            backdropPush?.cancel()
            backdropPush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.backdropWriter?(raw)
            }
        }
    }

    /// A picture in place of the colour, on this device only. See `MixWallpaper`.
    @Published private(set) var wallpaper: MixWallpaper.Picture?

    func setWallpaper(_ data: Data) async throws {
        wallpaper = try await MixWallpaper.save(data)
    }

    func removeWallpaper() {
        MixWallpaper.remove()
        wallpaper = nil
    }

    /// Writes the raw value to `user_metadata`. Nil in previews.
    public var backdropWriter: ((String) -> Void)?
    private var backdropPush: Task<Void, Never>?
    private var isApplyingRemote = false
    private var lastLocalBackdropChange = Date.distantPast

    /// The account's colour wins. Nil (never set) leaves the local one alone.
    public func adoptRemoteBackdrop(_ raw: String?) {
        // An echo of an older write mid-drag would snap the picker back.
        guard let raw, Date.now.timeIntervalSince(lastLocalBackdropChange) > 5 else { return }
        let remote = MixBackdrop(raw: raw)
        guard remote != backdrop else { return }
        isApplyingRemote = true
        backdrop = remote
        isApplyingRemote = false
    }

    /// The preset matching the three axes. Computed, so changing an axis shows Custom.
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
        // Defaults match the Normal preset.
        self.density = MixDensity(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .comfortable
        // No stored choice: follow the system's Reduce Motion. A stored choice wins.
        self.motion  = MixMotion(rawValue: defaults.string(forKey: Keys.motion) ?? "")
                    ?? (Self.systemWantsReducedMotion ? .reduced : .full)
        self.chrome  = MixChrome(rawValue:  defaults.string(forKey: Keys.chrome)  ?? "") ?? .rich
        self.backdrop = defaults.string(forKey: Keys.backdrop).flatMap(MixBackdrop.init(raw:))
        MixMotion.current = self.motion
        applyAppKitAppearance()
        observeSystemMotionSetting()
        Task { [weak self] in
            let picture = await MixWallpaper.load()
            self?.wallpaper = picture
        }
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

    /// Follows the system setting until the user picks an axis value in Settings.
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
            // `motion`'s didSet persisted it; clear so the app keeps following the system.
            UserDefaults.standard.removeObject(forKey: Keys.motion)
        }
    }

    public var preferredColorScheme: ColorScheme? { appearance.colorScheme }
    public var accentColor: Color { BrandAccent.color }

    /// Sets the AppKit appearance so AppKit controls update immediately.
    private func applyAppKitAppearance() {
        #if os(macOS)
        NSApplication.shared.appearance = appearance.nsAppearance
        #endif
    }
}
