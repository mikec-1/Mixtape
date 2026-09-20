// ModifiedClickCatcher.swift
// Mixtape — Mac/App
//
// Shared by every list that supports Finder-style multi-selection.

#if os(macOS)

import SwiftUI
import AppKit


/// Delivers ⌘- and ⇧-clicks, which SwiftUI's tap gesture never sees.
///
/// It is layered over the row but takes part in hit testing only for a modified
/// left click; for every other event it answers `nil`, which puts it back out of
/// the way of the row's own gestures.
struct ModifiedClickCatcher: NSViewRepresentable {

    let onClick: (NSEvent.ModifierFlags) -> Void
    /// Called as a right-click arrives, before SwiftUI builds the context menu.
    ///
    /// Without it the menu is decided by a selection the click never touched,
    /// so right-clicking two different rows gave two different menus with no
    /// visible reason why. Finder's rule instead: a right-click inside the
    /// selection keeps it, one outside replaces it with the row you hit.
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

        /// AppKit asks `hitTest` several times for one event. The selection
        /// side-effect below must run once per right-click, not once per ask.
        private var lastRightClickNumber: Int?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // `point` is in the superview's coordinates, and AppKit will ask
            // even when the click landed on a different row.
            guard bounds.contains(convert(point, from: superview)) else { return nil }
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return Self.modifiers(of: event).isEmpty ? nil : self
            case .rightMouseDown:
                // Update the selection, then step out of the way: returning
                // `self` here would swallow the click and SwiftUI's
                // `.contextMenu` would never open.
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

        /// Only the two that mean something here. ⌥ or ⌃ held during a click
        /// shouldn't turn an ordinary click into a selection.
        private static func modifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .shift])
        }
    }
}

#endif
