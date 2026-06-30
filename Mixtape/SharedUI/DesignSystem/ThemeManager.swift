// ThemeManager.swift
// Mixtape — Design System
//
// Single source of truth for user-selectable appearance (system/light/dark)
// and accent colour. Persists choices in UserDefaults and republishes so the
// UI re-renders. The neutral colour tokens in MixtapeColors resolve light/dark
// automatically via trait-aware dynamic colours; only the *accent* is a user
// choice and therefore read back from `ThemeManager.shared`.

import SwiftUI
import Combine

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
    }

    @Published public var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    public init() {
        let defaults = UserDefaults.standard
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
    }

    public var preferredColorScheme: ColorScheme? { appearance.colorScheme }
    public var accentColor: Color { BrandAccent.color }
}
