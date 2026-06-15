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

// MARK: - Accent

public enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case orange, blue, green, pink, purple, red, teal, yellow

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var hex: String {
        switch self {
        case .orange: return "#FF6B00"
        case .blue:   return "#2E8BFF"
        case .green:  return "#1DB954"
        case .pink:   return "#EC4899"
        case .purple: return "#8B5CF6"
        case .red:    return "#E53935"
        case .teal:   return "#14B8A6"
        case .yellow: return "#F5B301"
        }
    }

    /// Slightly darker pressed/secondary variant.
    public var darkHex: String {
        switch self {
        case .orange: return "#E05C00"
        case .blue:   return "#1F6FD6"
        case .green:  return "#159443"
        case .pink:   return "#D12F86"
        case .purple: return "#7440E0"
        case .red:    return "#C62E2A"
        case .teal:   return "#0E9384"
        case .yellow: return "#D89A00"
        }
    }

    public var color: Color { Color(hex: hex) }
    public var darkColor: Color { Color(hex: darkHex) }
}

// MARK: - Manager

public final class ThemeManager: ObservableObject {

    public static let shared = ThemeManager()

    private enum Keys {
        static let appearance = "theme.appearance"
        static let accent     = "theme.accent"
    }

    @Published public var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published public var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Keys.accent) }
    }

    public init() {
        let defaults = UserDefaults.standard
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        self.accent     = AppAccent(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .orange
    }

    public var preferredColorScheme: ColorScheme? { appearance.colorScheme }
    public var accentColor: Color { accent.color }
}
