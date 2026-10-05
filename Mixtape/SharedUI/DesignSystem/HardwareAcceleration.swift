// The Hardware Acceleration switch, as in Discord and Spotify. On, the background colour
// and the drawn art run as Metal shaders and stems split on the GPU. Off, all of it
// draws on the CPU, for a GPU or driver that glitches. Read once per launch.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

nonisolated enum HardwareAcceleration {

    static let key = "app.hardwareAcceleration"

    /// What this launch runs with. Changing the setting needs a restart.
    static let isOn = stored

    static var stored: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    #if os(macOS)
    /// Saves the choice, then opens a fresh copy once this one has quit.
    @MainActor static func restart(on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
    #endif
}

extension View {
    /// Flattens the view into one Metal-drawn layer when hardware acceleration is on.
    @ViewBuilder func gpuRendered() -> some View {
        if HardwareAcceleration.isOn { drawingGroup() } else { self }
    }
}
