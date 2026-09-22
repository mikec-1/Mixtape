// MacDockMenu.swift
// Mixtape — Mac/App
//
// The Dock tile's right-click menu: what's playing, and the transport.
//
// iTunes has had this for as long as the Dock has, and it is the one control
// surface that still works while the app is buried behind something else.
// SwiftUI has no API for it, so this is the app's only AppDelegate — kept to
// exactly that job.

#if os(macOS)
import AppKit

@MainActor
final class MacDockMenu: NSObject, NSApplicationDelegate {

    /// Set once from `MixtapeApp`. Weak and static because AppKit builds the
    /// delegate itself, outside the SwiftUI environment, and `AppDependencies`
    /// has no singleton to reach back through.
    static weak var engine: PlaybackEngine?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let engine = Self.engine else { return nil }
        let menu = NSMenu()

        // The song, as disabled header lines. Not actions: there is nowhere for
        // them to go that clicking the tile doesn't already do.
        if let track = engine.queue.currentTrack {
            for line in [track.displayTitle, track.artistName] where !line.isEmpty {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(item(engine.state.isPlaying ? "Pause" : "Play", #selector(dockPlayPause)))
        // Skipping with nothing loaded would silently do nothing, so the rows
        // only appear once there is somewhere to skip from.
        if engine.queue.currentTrack != nil {
            menu.addItem(item("Next", #selector(dockNext)))
            menu.addItem(item("Previous", #selector(dockPrevious)))
        }
        return menu
    }

    /// A Spotlight hit. SwiftUI's `onContinueUserActivity` doesn't reliably
    /// see these on macOS; the delegate does.
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
