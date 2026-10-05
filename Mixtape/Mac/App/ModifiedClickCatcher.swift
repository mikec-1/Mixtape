// Shared by every list with Finder-style multi-selection.

#if os(macOS)

import SwiftUI
import AppKit


/// Delivers ⌘- and ⇧-clicks, which SwiftUI's tap gesture never sees. Hit-tests only for a
/// modified left click.
struct ModifiedClickCatcher: NSViewRepresentable {

    let onClick: (NSEvent.ModifierFlags) -> Void
    /// Called as a right-click arrives, before SwiftUI builds the context menu, so the selection
    /// follows Finder's rule first.
    var onRightClick: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onClick = onClick
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onClick = onClick
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onRightClick: (() -> Void)?

        /// AppKit calls `hitTest` several times per event; the side effect runs once.
        private var lastRightClickNumber: Int?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // `point` is in superview coordinates, and AppKit asks even for clicks on other rows.
            guard bounds.contains(convert(point, from: superview)) else { return nil }
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return Self.modifiers(of: event).isEmpty ? nil : self
            case .rightMouseDown:
                // Update the selection then return nil; returning `self` would block `.contextMenu`.
                if lastRightClickNumber != event.eventNumber {
                    lastRightClickNumber = event.eventNumber
                    onRightClick?()
                }
                return nil
            default:
                // Hover, scrolling, ctrl-click: none of ours.
                return nil
            }
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(Self.modifiers(of: event))
        }

        /// Only ⌘ and ⇧; ⌥ or ⌃ shouldn't turn a click into a selection.
        private static func modifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .shift])
        }
    }
}

#endif
