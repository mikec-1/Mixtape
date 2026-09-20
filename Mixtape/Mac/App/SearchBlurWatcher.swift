// SearchBlurWatcher.swift
// Mixtape — Mac/App
//
// Shared by MacSearchField (the window's own search box) and MixSearchField
// (Settings, Find People, the Spotify picker) — see below for what AppKit does
// not do for us.

#if os(macOS)
import SwiftUI
import Combine

// MARK: - Click-away
//
// AppKit only moves the first responder when a click lands on a view that wants
// to be one — and nothing SwiftUI draws does. So once the search field had the
// caret, clicking the sidebar, a song, or the window background left it there:
// the field kept every keystroke, Space included, until Tab or Return moved it
// on. This watches for a click outside the field and resigns it, which is what
// clicking away is supposed to do.
//
// It only runs while the field that owns it is focused, so a field that has not
// asked for this behaviour — the command palette, a rename box — is untouched.

@MainActor
final class SearchBlurWatcher: ObservableObject {

    private var monitor: Any?
    private var onOutsideClick: (() -> Void)?

    func start(onOutsideClick: @escaping () -> Void) {
        self.onOutsideClick = onOutsideClick
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let window = event.window,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor
            else { return event }

            // The field's rect in window points, read from AppKit rather than a
            // SwiftUI GeometryReader: the whole interface sits under the zoom
            // transform, so SwiftUI's coordinates and the event's are not the
            // same scale. While editing, the field editor is hosted inside the
            // NSTextField, which is the rect the user sees as "the box".
            var host: NSView? = editor
            while let view = host, !(view is NSTextField) { host = view.superview }
            let box  = host ?? editor
            let rect = box.convert(box.bounds, to: nil).insetBy(dx: -8, dy: -6)
            guard !rect.contains(event.locationInWindow) else { return event }

            // Both, deliberately: AppKit's responder change is what actually
            // stops the typing, and the SwiftUI flag is what the border, the
            // ⌘F hint and the suggestions panel watch.
            window.makeFirstResponder(nil)
            self.onOutsideClick?()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onOutsideClick = nil
    }
}

#endif
