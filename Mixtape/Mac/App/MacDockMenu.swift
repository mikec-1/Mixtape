// Dock tile right-click menu: now playing and transport.
// SwiftUI has no API for it, so this is the app's only AppDelegate.

#if os(macOS)
import AppKit

@MainActor
final class MacDockMenu: NSObject, NSApplicationDelegate {

    /// Set from `MixtapeApp`. Static because AppKit creates the delegate outside the SwiftUI environment.
    static weak var engine: PlaybackEngine?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let engine = Self.engine else { return nil }
        let menu = NSMenu()

        // The song as disabled header lines.
        if let track = engine.queue.currentTrack {
            for line in [track.displayTitle, track.artistName] where !line.isEmpty {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(item(engine.state.isPlaying ? "Pause" : "Play", #selector(dockPlayPause)))
        // Transport rows only when something is loaded.
        if engine.queue.currentTrack != nil {
            menu.addItem(item("Next", #selector(dockNext)))
            menu.addItem(item("Previous", #selector(dockPrevious)))
        }
        return menu
    }

    /// Spotlight hits: `onContinueUserActivity` misses these on macOS.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        SpotlightIndex.open(userActivity)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockPlayPause() { Self.engine?.togglePlayPause() }
    @objc private func dockNext()      { Task { if let e = Self.engine { await e.playNext() } } }
    @objc private func dockPrevious()  { Task { if let e = Self.engine { await e.playPrevious() } } }
}
#endif
