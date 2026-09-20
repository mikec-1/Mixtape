// MixtapeApp.swift
// Mixtape — App Entry Point
//
// Minimum deployment: iOS 17 / macOS 14
// Architecture: MVVM + Clean layers (UI / Domain / Data)

import SwiftUI
import SwiftData

@main
struct MixtapeApp: App {

    init() {
        // First line of app code that runs. `LaunchTimeline` measures from the
        // kernel's process start, not from here, so the pre-main cost is
        // included — but this is where the interval opens.
        LaunchTimeline.begin()
        MainThreadHangMonitor.shared.start()
        MemoryPressureMonitor.shared.start()
        LaunchTimeline.mark("app/init")
        #if os(macOS)
        // Prevent AppKit from ever adding "Show Tab Bar" and "Show All Tabs"
        // to the View menu. Setting this in init() stops the items from being
        // created at all — more reliable than CommandGroup(replacing: .toolbar),
        // which only removes them after a multi-second delay on first launch.
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    @StateObject private var dependencies = AppDependencies()
    @StateObject private var theme = MixtapeApp.makeTheme()

    /// Only here so the launch marks can see what the theme costs.
    private static func makeTheme() -> ThemeManager {
        LaunchTimeline.mark("app/theme-begin")
        let theme = ThemeManager.shared
        LaunchTimeline.mark("app/theme-ready")
        return theme
    }

    #if os(macOS)
    @StateObject private var updater = MixtapeApp.makeUpdater()

    private static func makeUpdater() -> UpdaterController {
        let updater = UpdaterController()
        LaunchTimeline.mark("app/updater-ready")
        return updater
    }
    #endif

    var body: some Scene {
        mainWindow
    }

    // MARK: - Main Window

    private var mainWindow: some Scene {
        WindowGroup {
            let _ = LaunchTimeline.markOnce("app/scene-body")
            RootView()
                .environmentObject(dependencies)
                .environmentObject(dependencies.playbackEngine)
                .environmentObject(dependencies.queueService)
                .environmentObject(dependencies.libraryService)
                .environmentObject(dependencies.smartPlaylistService)
                .environmentObject(dependencies.syncService)
                .environmentObject(dependencies.onlineCoordinator)
                #if os(iOS)
                .environmentObject(dependencies.resolverStatus)
                #endif
                .environmentObject(ExportManager.shared)
                .environmentObject(theme)
                #if os(macOS)
                .environmentObject(updater)
                #endif
                // Density, motion and chrome, injected once. Every view that
                // cares reads them from the environment, so a change here
                // invalidates exactly those and nothing else.
                .mixAppearance(density: theme.density,
                               motion:  theme.motion,
                               chrome:  theme.chrome)
                .tint(theme.accentColor)
                // Appearance is driven globally via NSApp.appearance in
                // ThemeManager (single source of truth). Using
                // .preferredColorScheme here too pinned the window appearance
                // and left AppKit-backed controls (the appearance pop-up button)
                // failing to redraw on change.
                #if !os(macOS)
                .preferredColorScheme(theme.preferredColorScheme)
                #endif
        }
        #if os(macOS)
        // The top bar (search + add + sync) is drawn by MacTopBar inside the
        // window's own content, not by an NSToolbar. A real toolbar centres its
        // `.principal` item on the *content column*, so the search field slid
        // sideways whenever the sidebar opened, and the titlebar sits outside the
        // content's zoom transform, so ⌘+/⌘− never moved it. Hiding the titlebar
        // hands the whole window to SwiftUI and both problems go away.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 740)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // Replace File ▸ New Window (⌘N) with File ▸ New Playlist (⌘N).
            // Replacing `.newItem` also prevents a second window from opening,
            // which is what causes the extra <> navigation arrows to appear in
            // the titlebar — AppKit adds them whenever more than one window
            // exists and removes them the moment you're back to one.
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") {
                    NotificationCenter.default.post(name: .mixNewPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // ⌃⌘S came free with NavigationSplitView; the sidebar column is
            // hand-rolled now (see MacRootView), so the menu item is too. It
            // posts rather than calls: commands are built outside the window and
            // can't reach its `MacAppState`.
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .mixToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            // ── View ▸ Zoom ──────────────────────────────────────────────────
            // The zoom actions live on `MacAppState` inside the window, so they
            // are routed through NotificationCenter (same pattern as the sidebar
            // toggle). The background Cmd++ button in MacRootView still catches
            // the Shift+= variant the menu item doesn't register on its own.
            CommandGroup(after: .sidebar) {
                Button("Actual Size") {
                    NotificationCenter.default.post(name: .mixActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .mixZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .mixZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                // ── View ▸ Navigation ────────────────────────────────────────
                Button("Go Back") {
                    NotificationCenter.default.post(name: .mixGoBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Go Forward") {
                    NotificationCenter.default.post(name: .mixGoForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Sync") {
                    NotificationCenter.default.post(name: .mixSyncLibrary, object: false)
                }
                .keyboardShortcut("r", modifiers: .command)

                // Everything the plain sync does, plus every followed Spotify
                // playlist, each one forced past its own change check.
                Button("Sync Everything") {
                    NotificationCenter.default.post(name: .mixSyncLibrary, object: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Merge Duplicate Songs…") {
                    NotificationCenter.default.post(name: .mixMergeDuplicates, object: nil)
                }
            }
        }
        #endif
        #if os(iOS)
        // The only way an invite reaches a phone that isn't currently looking at
        // the app. macOS is left out on purpose: a Mac app is either running —
        // where RootView's poll already covers it — or quit, where nothing runs.
        .backgroundTask(.appRefresh(InviteNotifier.backgroundTaskID)) {
            await InviteNotifier.shared.runBackgroundRefresh()
        }
        #endif
    }


}
