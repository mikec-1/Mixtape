import SwiftUI

#if os(macOS)
import AppKit

struct MacWindowZoomer: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.applyZoom(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.applyZoom(to: nsView)
        }
    }

    private func applyZoom(to view: NSView) {
        guard let window = view.window else { return }
        if let contentView = window.contentView {
            // By scaling the bounds of the window's root contentView, AppKit natively
            // scales all rendering and hit-testing (including hovers and gestures)
            // for the entire SwiftUI hierarchy inside it.
            let physicalSize = contentView.frame.size
            contentView.bounds = CGRect(
                x: 0,
                y: 0,
                width: physicalSize.width / scale,
                height: physicalSize.height / scale
            )
            contentView.needsLayout = true
            contentView.needsDisplay = true
        }
    }
}
#endif
