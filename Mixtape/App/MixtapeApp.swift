// MixtapeApp.swift
// Mixtape — App Entry Point
//
// Minimum deployment: iOS 17 / macOS 14
// Architecture: MVVM + Clean layers (UI / Domain / Data)

import SwiftUI
import SwiftData

@main
struct MixtapeApp: App {

    @StateObject private var dependencies = AppDependencies()
    @StateObject private var theme = ThemeManager.shared

    #if os(macOS)
    @StateObject private var updater = UpdaterController()
    #endif

    var body: some Scene {
        mainWindow
    }

    // MARK: - Main Window

    private var mainWindow: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dependencies)
                .environmentObject(dependencies.playbackEngine)
                .environmentObject(dependencies.queueService)
                .environmentObject(dependencies.libraryService)
                .environmentObject(dependencies.syncService)
                .environmentObject(ExportManager.shared)
                .environmentObject(theme)
                .modelContainer(dependencies.modelContainer)
                .tint(theme.accentColor)
                .preferredColorScheme(theme.preferredColorScheme)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 740)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
        }
        #endif
    }


}
