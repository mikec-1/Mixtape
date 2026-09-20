// AppearanceMode.swift
// Mixtape — Design System
//
// How big the app draws itself, how much it moves, and how much it decorates —
// three axes, one preset picker on top of them.
//
// They are separate on purpose. "Make it smaller" and "make it stop moving" are
// different requests that happen to arrive together, and folding them into one
// three-way switch means nobody can have a full-size window that doesn't
// animate, or a tight one that still does. The presets in Settings are the
// answer to that: most people pick a name and never see the axes.
//
// Everything here is read through the environment so a change invalidates
// exactly the views that depend on it. The one exception is `MixMotion.current`
// — `withAnimation` is an imperative call with no view to read an environment
// from, so it reads a mirror kept up to date by `ThemeManager`.

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

    // MARK: Track rows (the SwiftUI ones — macOS tables use `RowMetrics.at`)

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

/// How much the app animates.
///
/// `reduced` doesn't mean "instant everywhere": the system's own animations —
/// a sheet coming up, a navigation push, a List insert — belong to the platform
/// and are left alone. What it switches off is the app's own, which is all of
/// what costs anything.
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

    /// What `withMixAnimation` reads.
    ///
    /// A mirror rather than the source of truth: `ThemeManager` writes it on
    /// every change and at launch. It exists because an imperative
    /// `withAnimation` at the bottom of a button action has no view, and
    /// therefore no environment, to ask.
    public static var current: MixMotion = .full
}

/// `withAnimation`, honouring the motion setting.
///
/// Signature matches the original — including the bare `withMixAnimation { … }`
/// form — so call sites read the same as they always did.
@discardableResult
public func withMixAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(MixMotion.current.resolve(animation), body)
}

// MARK: - Chrome

/// How much the app decorates.
///
/// `flat` is the "simple black app" answer: no colour wash bleeding down from
/// the artwork, no drop shadows under covers, no blur materials. The background
/// stays the flat surface colour it already is, which is the look this is
/// after — the tokens don't change, only what gets painted on top of them.
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

    /// A blur material, or the flat surface that stands in for it.
    ///
    /// Live blur is the one piece of chrome with a running cost: it resamples
    /// whatever is behind it every frame that either moves. An opaque colour is
    /// the same shape and the same separation, drawn once.
    ///
    /// The system's Reduce Transparency setting overrides the axis. Someone who
    /// has asked the whole OS for opaque surfaces has already answered this
    /// question, and a per-app "Rich" preset is not permission to re-ask it.
    public func material(_ material: Material, flat colour: Color) -> AnyShapeStyle {
        showsMaterials && !MixChrome.systemWantsOpaqueSurfaces
            ? AnyShapeStyle(material)
            : AnyShapeStyle(colour)
    }

    /// Whether the OS has asked for opaque surfaces app-wide.
    ///
    /// Read imperatively rather than through `@Environment` because `material`
    /// is called from shape-style position, where there is no view to read a
    /// trait from. Both platforms expose it as a process-wide flag.
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

    /// Nil for `.custom`, which isn't a combination — it's the absence of one.
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

/// `.animation(_:value:)`, honouring the motion setting.
///
/// A modifier rather than a computed argument at the call site so the read goes
/// through the environment: flipping the setting invalidates precisely the
/// views that animate, and nothing else.
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

    /// Injects the three axes. Applied once, at the root.
    func mixAppearance(density: MixDensity, motion: MixMotion, chrome: MixChrome) -> some View {
        environment(\.mixDensity, density)
            .environment(\.mixMotion, motion)
            .environment(\.mixChrome, chrome)
    }

    /// A continuously pulsing symbol, unless the app has been asked to hold still.
    ///
    /// SF Symbol effects are the one kind of motion `withAnimation` cannot reach:
    /// they drive themselves off Core Animation and ignore the transaction
    /// entirely. They are also the only motion in the app that never stops —
    /// `.pulse` and `.variableColor` keep a timer alive for as long as the view
    /// is on screen — so leaving them out of the motion setting made "Reduced"
    /// look like it did nothing, because the animation people actually watch was
    /// still running.
    func mixPulse(isActive: Bool = true) -> some View {
        modifier(MixSymbolPulse(isActive: isActive))
    }

    /// The now-playing indicator on a row. See `mixPulse` for why it's gated.
    func mixVariableColor(isActive: Bool) -> some View {
        modifier(MixSymbolVariableColor(isActive: isActive))
    }

    /// The cross-fade between two symbols — a play glyph becoming a pause one.
    func mixSymbolReplace() -> some View {
        modifier(MixSymbolReplace())
    }

    /// A one-shot bounce when `value` changes.
    func mixBounce<V: Equatable>(value: V) -> some View {
        modifier(MixSymbolBounce(value: value))
    }

    /// A shadow that flat chrome leaves out.
    ///
    /// Only for shadows that *decorate* — under covers, cards and artwork.
    /// The ones that say "this floats above the page" (the toast, the command
    /// palette, the search suggestions, the back button, the error banners) stay
    /// plain `.shadow`: without them those read as part of the content they're
    /// sitting on top of, and flat is a look, not a loss of layering.
    func mixShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(MixShadowModifier(color: color, radius: radius, x: x, y: y))
    }
}

/// Draws a clear, zero-radius shadow rather than dropping the modifier, so the
/// view keeps its identity when the setting flips. The `if` version rebuilds
/// the subtree, which throws away the `@State` inside it — hover states,
/// scroll positions — for a shadow.
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

/// Feeds the trigger a constant when motion is reduced, so it never fires.
/// Dropping the modifier instead would change the view's identity for a bounce.
private struct MixSymbolBounce<V: Equatable>: ViewModifier {
    @Environment(\.mixMotion) private var motion
    let value: V
    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: motion.isReduced ? nil : Optional(value))
    }
}
