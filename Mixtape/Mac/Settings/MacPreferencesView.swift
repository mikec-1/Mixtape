// MacPreferencesView.swift
// Mixtape — Mac/Settings
//
// macOS Preferences window — opened via Cmd+, or App Menu → Settings.
// Wraps the shared SettingsView in a macOS Preferences window.

#if os(macOS)
import SwiftUI

struct MacPreferencesView: View {

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        SettingsView(
            authService:    deps.authService,
            syncService:    deps.syncService,
            libraryService: deps.libraryService,
            importService:  deps.importService
        )
        .frame(width: 560, height: 620)
    }
}

#endif
