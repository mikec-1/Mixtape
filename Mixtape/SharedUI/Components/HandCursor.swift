import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Buttons show the pointing hand on hover, matching the web app. No-op on iOS.
private struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    func mixHandCursor() -> some View { modifier(HandCursor()) }

    /// `.onTapGesture` that Tab, Space and VoiceOver can reach: the same view
    /// as the label of a plain button, so it's focusable and reads as one.
    func mixTapAction(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { self }.buttonStyle(.plain)
    }
}
