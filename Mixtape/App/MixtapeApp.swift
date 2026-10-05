import SwiftUI
import SwiftData

@main
struct MixtapeApp: App {

    init() {
        // Launch timing is measured from process start; this just opens the interval.
        LaunchTimeline.begin()
        MainThreadHangMonitor.shared.start()
        MemoryPressureMonitor.shared.start()
        CrashReporter.shared.start()
        LaunchTimeline.mark("app/init")
        #if os(macOS)
        // Stops AppKit adding the tab bar items to the View menu at all.
        NSWindow.allowsAutomaticWindowTabbing = false
        MixSheetCorners.install()
        #endif
        // Built eagerly so a windowless Siri launch can still play.
        let dependencies = AppDependencies()
        _dependencies = StateObject(wrappedValue: dependencies)
        MixtapeIntents.deps = dependencies
        // Set before launch finishes so a tap that launched the app still arrives.
        InviteNotifier.shared.install(dependencies)
    }

    @StateObject private var dependencies: AppDependencies
    @StateObject private var theme = MixtapeApp.makeTheme()

    /// Only here so the launch marks can see what the theme costs.
    private static func makeTheme() -> ThemeManager {
        LaunchTimeline.mark("app/theme-begin")
        let theme = ThemeManager.shared
        LaunchTimeline.mark("app/theme-ready")
        return theme
    }

    #if os(macOS)
    /// Only for the Dock tile menu, which SwiftUI can't declare.
    @NSApplicationDelegateAdaptor(MacDockMenu.self) private var dockMenu
    @AppStorage(MacMenuBarPlayer.visibleKey) private var showsMenuBarPlayer = true
    @StateObject private var updater = MixtapeApp.makeUpdater()

    private static func makeUpdater() -> UpdaterController {
        let updater = UpdaterController()
        LaunchTimeline.mark("app/updater-ready")
        return updater
    }
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        // One-way on purpose: a real binding feeds back into the setting and loops on macOS 26.
        MenuBarExtra(isInserted: .constant(showsMenuBarPlayer)) {
            MacMenuBarPlayer(engine: dependencies.playbackEngine, queue: dependencies.playbackEngine.queue,
                             library: dependencies.libraryService)
        } label: {
            MacMenuBarLabel(queue: dependencies.playbackEngine.queue)
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    // MARK: - Main Window

    private var mainWindow: some Scene {
        WindowGroup {
            let _ = LaunchTimeline.markOnce("app/scene-body")
            RootView()
                #if os(macOS)
                .task { MacDockMenu.engine = dependencies.playbackEngine }
                #endif
                .environmentObject(dependencies)
                .environmentObject(dependencies.playbackEngine)
                .environmentObject(dependencies.queueService)
                .environmentObject(dependencies.libraryService)
                .environmentObject(dependencies.smartPlaylistService)
                .environmentObject(dependencies.syncService)
                .environmentObject(dependencies.onlineCoordinator)
                .environmentObject(dependencies.recap)
                #if os(iOS)
                .environmentObject(dependencies.resolverStatus)
                #endif
                .environmentObject(ExportManager.shared)
                .environmentObject(theme)
                #if os(macOS)
                .environmentObject(updater)
                #endif
                // Density, motion and chrome go in the environment so only readers redraw.
                .mixAppearance(density: theme.density,
                               motion:  theme.motion,
                               chrome:  theme.chrome)
                .tint(theme.accentColor)
                // Appearance is set globally via NSApp.appearance in ThemeManager.
                // .preferredColorScheme here breaks AppKit control redraws.
                #if !os(macOS)
                .preferredColorScheme(theme.preferredColorScheme)
                #endif
        }
        #if os(macOS)
        // MacTopBar draws the top bar in-window. An NSToolbar centres on the content
        // column and ignores the zoom transform.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 740)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // ⌘N makes a playlist. Replacing .newItem also blocks a second window.
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") {
                    NotificationCenter.default.post(name: .mixNewPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // Posted, since commands can't reach the window's MacAppState.
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .mixToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            // View > Zoom. Routed through NotificationCenter like the sidebar toggle.
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

                // View > Navigation
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

                // Plain sync plus every followed Spotify playlist, forced.
                Button("Sync Everything") {
                    NotificationCenter.default.post(name: .mixSyncLibrary, object: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Merge Duplicate Songs…") {
                    NotificationCenter.default.post(name: .mixMergeDuplicates, object: nil)
                }
            }
            ControlsCommands(engine: dependencies.playbackEngine,
                             queue: dependencies.playbackEngine.queue,
                             library: dependencies.libraryService)
        }
        #endif
        #if os(iOS)
        // Background refresh so a phone hears about invites while closed. Not needed on macOS.
        .backgroundTask(.appRefresh(InviteNotifier.backgroundTaskID)) {
            await InviteNotifier.shared.runBackgroundRefresh()
        }
        #endif
    }


}

#if os(macOS)
/// Controls menu. Space stays in MacRootView's key monitor so it doesn't
/// fire while typing in a text field.
struct ControlsCommands: Commands {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var queue: QueueService
    @ObservedObject var library: LibraryService   // only so the like title follows the heart

    var body: some Commands {
        CommandMenu("Controls") {
            let track = queue.currentTrack
            let liked = track.flatMap { engine.isLiked?($0) } ?? false
            Button(engine.state.isPlaying ? "Pause" : "Play") { engine.togglePlayPause() }
            Button("Next") { Task { await engine.playNext() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(track == nil)
            Button("Previous") { Task { await engine.playPrevious() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(track == nil)

            Divider()

            Button("Skip Forward 15 Seconds") { skip(15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(track == nil)
            Button("Skip Back 15 Seconds") { skip(-15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(track == nil)

            Divider()

            Toggle("Shuffle", isOn: Binding(get: { queue.shuffleEnabled }, set: { queue.setShuffle($0) }))
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Picker("Repeat", selection: Binding(get: { queue.repeatMode }, set: { queue.setRepeat($0) })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }

            Divider()

            Button("Increase Volume") { engine.volume = min(1, engine.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { engine.volume = max(0, engine.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            // Toggles a library song, saves anything else.
            Button(liked ? "Remove from Liked Songs" : "Add to Liked Songs") {
                guard let track else { return }
                Task { await engine.onRemoteLike?(track); engine.syncRemoteCommandState() }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(track == nil)
            Button("Get Info") { NotificationCenter.default.post(name: .mixShowInfo, object: nil) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(track == nil)
        }
    }

    private func skip(_ seconds: TimeInterval) {
        engine.seek(to: max(0, min(engine.duration, engine.currentTime + seconds)))
    }
}
#endif
