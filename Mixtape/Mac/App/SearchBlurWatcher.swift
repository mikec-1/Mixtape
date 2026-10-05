// Shared by MacSearchField and MixSearchField.

#if os(macOS)
import SwiftUI
import Combine

// MARK: - Click-away
// AppKit only moves first responder to views that accept it, and SwiftUI views don't,
// so a focused field kept every keystroke after clicking elsewhere. This resigns it on an
// outside click, only while the owning field is focused.

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

            // The field's rect in window points from AppKit: SwiftUI coordinates are under the zoom transform.
            // While editing, the field editor sits inside the NSTextField.
            var host: NSView? = editor
            while let view = host, !(view is NSTextField) { host = view.superview }
            let box  = host ?? editor
            let rect = box.convert(box.bounds, to: nil).insetBy(dx: -8, dy: -6)
            guard !rect.contains(event.locationInWindow) else { return event }

            // Both: AppKit's change stops the typing, the SwiftUI flag drives the border, hint and panel.
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
