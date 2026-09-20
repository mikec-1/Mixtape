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
}
