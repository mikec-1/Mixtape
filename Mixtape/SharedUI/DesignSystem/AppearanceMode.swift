// Three independent appearance axes (size, motion, decoration) with a preset
// picker on top. Read through the environment so changes only invalidate what
// depends on them. `MixMotion.current` is the exception: `withAnimation` has no
// view to read from, so `ThemeManager` keeps a mirror.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Density

/// How much room the layout gives itself.
public enum MixDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact:     return "Compact"
        }
    }

    // MARK: Track rows (SwiftUI ones; macOS tables use `RowMetrics.at`)

    public var trackArtwork:      CGFloat { self == .compact ? 34 : 44 }
    public var trackRowPadding:   CGFloat { self == .compact ? 1  : 4  }
    public var trackTitleSpacing: CGFloat { self == .compact ? 1  : 3  }

    // MARK: Detail heroes

    /// The banner cover on macOS, and the centred one on iOS.
    public var heroCoverWide:     CGFloat { self == .compact ? 132 : 180 }
    public var heroCoverTall:     CGFloat { self == .compact ? 168 : 220 }
    public var heroCoverCircular: CGFloat { self == .compact ? 124 : 160 }
    /// The big page title on macOS. iOS uses `.mixTitle`, which Dynamic Type owns.
    public var heroTitleSize:     CGFloat { self == .compact ? 30 : 40 }
    public var heroSpacing:       CGFloat { self == .compact ? 16 : 22 }
    public var heroTopPadding:    CGFloat { self == .compact ? 40 : 52 }
    public var heroBottomPadding: CGFloat { self == .compact ? 10 : 16 }
    public var heroStackSpacing:  CGFloat { self == .compact ? 10 : 16 }
    public var heroTextSpacing:   CGFloat { self == .compact ? 4  : 6  }
    public var heroCoverTop:      CGFloat { self == .compact ? 12 : 24 }
}

// MARK: - Motion

/// How much the app animates. `reduced` turns off the app's own animations;
/// system ones (sheets, pushes, List inserts) are left alone.
public enum MixMotion: String, CaseIterable, Identifiable, Sendable {
    case full, reduced
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full:    return "Full"
        case .reduced: return "Reduced"
        }
    }

    public var isReduced: Bool { self == .reduced }

    /// An animation, or nothing, depending on the setting.
    public func resolve(_ animation: Animation?) -> Animation? {
        isReduced ? nil : animation
    }

    /// Mirror read by `withMixAnimation`; `ThemeManager` writes it at launch and on change.
    public static var current: MixMotion = .full
}

/// `withAnimation` honouring the motion setting. Same signature as the original.
@discardableResult
public func withMixAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(MixMotion.current.resolve(animation), body)
}

/// The app's motion tokens. Run them through `withMixAnimation` or `.mixAnimation`
/// so the motion setting can turn them off.
public extension Animation {
    /// Controls: toggles, pills, hover lifts, small badges.
    static var mixSnappy: Animation { .spring(response: 0.3, dampingFraction: 0.85) }
    /// Big surfaces: panels, sidebars, sheets of content.
    static var mixSoft: Animation { .spring(response: 0.42, dampingFraction: 0.9) }
    /// Colour and opacity flips.
    static var mixMicro: Animation { .easeOut(duration: 0.12) }
    /// Short fades and reveals.
    static var mixQuick: Animation { .easeOut(duration: 0.2) }
    /// A Mac page coming in: quick start, long settle.
    static var mixPage: Animation { .timingCurve(0.22, 1, 0.36, 1, duration: 0.22) }
}

// MARK: - Chrome

/// How much the app decorates. `flat`: no artwork wash, no decorative shadows,
/// no blur materials. Colour tokens are unchanged.
public enum MixChrome: String, CaseIterable, Identifiable, Sendable {
    case rich, flat
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rich: return "Full"
        case .flat: return "Flat"
        }
    }

    /// The gradient a detail page takes from its cover.
    public var showsArtworkWash: Bool { self == .rich }
    /// Drop shadows under covers and floating panels.
    public var showsShadows:     Bool { self == .rich }
    /// Blur materials. `flat` swaps them for an opaque surface colour.
    public var showsMaterials:   Bool { self == .rich }

    /// A blur material, or a flat colour in its place (blur resamples every frame).
    /// The system's Reduce Transparency always wins.
    public func material(_ material: Material, flat colour: Color) -> AnyShapeStyle {
        showsMaterials && !MixChrome.systemWantsOpaqueSurfaces
            ? AnyShapeStyle(material)
            : AnyShapeStyle(colour)
    }

    /// Whether the OS asked for opaque surfaces. Read directly since `material`
    /// has no view to read the environment from.
    public static var systemWantsOpaqueSurfaces: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceTransparencyEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #else
        return false
        #endif
    }
}

// MARK: - Presets

/// The three named looks, and the state of having wandered off them.
public enum MixAppearancePreset: String, CaseIterable, Identifiable, Sendable {
    case normal, minimal, efficient, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal:    return "Normal"
        case .minimal:   return "Minimal"
        case .efficient: return "Efficient"
        case .custom:    return "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .normal:    return "Full-size layout, artwork colour, subtle animation."
        case .minimal:   return "Tighter layout and a flat background. Animation kept."
        case .efficient: return "Tighter and flat, with the app's own animation switched off."
        case .custom:    return "Your own combination of the settings below."
        }
    }

    /// Nil for `.custom`.
    public var axes: (density: MixDensity, motion: MixMotion, chrome: MixChrome)? {
        switch self {
        case .normal:    return (.comfortable, .full,    .rich)
        case .minimal:   return (.compact,     .full,    .flat)
        case .efficient: return (.compact,     .reduced, .flat)
        case .custom:    return nil
        }
    }

    /// Which preset a set of axes amounts to, or `.custom` if none of them.
    public static func matching(density: MixDensity,
                                motion: MixMotion,
                                chrome: MixChrome) -> MixAppearancePreset {
        allCases.first { preset in
            guard let a = preset.axes else { return false }
            return a.density == density && a.motion == motion && a.chrome == chrome
        } ?? .custom
    }

    /// The ones offered in the picker. `.custom` isn't chosen, it's arrived at.
    public static var selectable: [MixAppearancePreset] { [.normal, .minimal, .efficient] }
}

// MARK: - Environment

private struct MixDensityKey: EnvironmentKey { static let defaultValue = MixDensity.comfortable }
private struct MixMotionKey:  EnvironmentKey { static let defaultValue = MixMotion.full }
private struct MixChromeKey:  EnvironmentKey { static let defaultValue = MixChrome.rich }

public extension EnvironmentValues {
    var mixDensity: MixDensity {
        get { self[MixDensityKey.self] }
        set { self[MixDensityKey.self] = newValue }
    }
    var mixMotion: MixMotion {
        get { self[MixMotionKey.self] }
        set { self[MixMotionKey.self] = newValue }
    }
    var mixChrome: MixChrome {
        get { self[MixChromeKey.self] }
        set { self[MixChromeKey.self] = newValue }
    }
}

// MARK: - View helpers

/// `.animation(_:value:)` honouring the motion setting. A modifier so the read
/// goes through the environment.
private struct MixAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.mixMotion) private var motion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(motion.resolve(animation), value: value)
    }
}

public extension View {
    /// Animate a value change, unless the user has asked the app to hold still.
    func mixAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MixAnimationModifier(animation: animation, value: value))
    }

    /// Fades the page in with a few points of lift whenever `key` changes. Reduce
    /// Motion keeps the fade only; reduced app motion swaps instantly.
    func mixPageTransition<Key: Hashable>(_ key: Key) -> some View {
        modifier(MixPageTransition(key: key))
    }

    /// A selection fill that slides between the options sharing `namespace`.
    /// Animate the selection change for it to move.
    func mixSlidingPill(isSelected: Bool, in namespace: Namespace.ID,
                        selected: some ShapeStyle, idle: some ShapeStyle) -> some View {
        background {
            ZStack {
                Capsule().fill(idle)
                if isSelected {
                    Capsule().fill(selected).matchedGeometryEffect(id: "mixSlidingPill", in: namespace)
                }
            }
        }
    }

    /// Injects the three axes. Applied once, at the root.
    func mixAppearance(density: MixDensity, motion: MixMotion, chrome: MixChrome) -> some View {
        environment(\.mixDensity, density)
            .environment(\.mixMotion, motion)
            .environment(\.mixChrome, chrome)
    }

    /// Pulsing symbol unless motion is reduced. Symbol effects ignore transactions
    /// and never stop, so they need their own gate.
    func mixPulse(isActive: Bool = true) -> some View {
        modifier(MixSymbolPulse(isActive: isActive))
    }

    /// The now-playing indicator on a row. See `mixPulse` for why it's gated.
    func mixVariableColor(isActive: Bool) -> some View {
        modifier(MixSymbolVariableColor(isActive: isActive))
    }

    /// Cross-fade between symbols, e.g. play -> pause.
    func mixSymbolReplace() -> some View {
        modifier(MixSymbolReplace())
    }

    /// A one-shot bounce when `value` changes.
    func mixBounce<V: Equatable>(value: V) -> some View {
        modifier(MixSymbolBounce(value: value))
    }

    /// A decorative shadow that flat chrome drops (covers, cards, artwork).
    /// Shadows that show layering (toast, palette, banners) use plain `.shadow`.
    func mixShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(MixShadowModifier(color: color, radius: radius, x: x, y: y))
    }
}

private struct MixPageTransition<Key: Hashable>: ViewModifier {
    @Environment(\.mixMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: Key

    func body(content: Content) -> some View {
        ZStack {
            content
                .id(key)
                .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
                                        removal: .identity))
        }
        .animation(motion.resolve(.mixPage), value: key)
    }
}

/// Draws a clear zero-radius shadow instead of removing the modifier, which
/// would rebuild the subtree and lose its `@State`.
private struct MixShadowModifier: ViewModifier {
    @Environment(\.mixChrome) private var chrome
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        let on = chrome.showsShadows
        return content.shadow(color: on ? color : .clear,
                              radius: on ? radius : 0,
                              x: on ? x : 0,
                              y: on ? y : 0)
    }
}


private struct MixSymbolPulse: ViewModifier {
    @Environment(\.mixMotion) private var motion
    let isActive: Bool
    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, isActive: isActive && !motion.isReduced)
    }
}

private struct MixSymbolVariableColor: ViewModifier {
    @Environment(\.mixMotion) private var motion
    let isActive: Bool
    func body(content: Content) -> some View {
        content.symbolEffect(.variableColor.iterative, isActive: isActive && !motion.isReduced)
    }
}

private struct MixSymbolReplace: ViewModifier {
    @Environment(\.mixMotion) private var motion
    func body(content: Content) -> some View {
        content.contentTransition(motion.isReduced ? .identity : .symbolEffect(.replace))
    }
}

/// Constant trigger when motion is reduced, so it never fires, without changing identity.
private struct MixSymbolBounce<V: Equatable>: ViewModifier {
    @Environment(\.mixMotion) private var motion
    let value: V
    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: motion.isReduced ? nil : Optional(value))
    }
}
