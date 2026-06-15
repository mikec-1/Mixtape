// RootView.swift
// Mixtape — App
//
// Gate between the auth flow and the main app.
// Reads isAuthenticated from AppDependencies and routes accordingly.
//
// Deep links (email confirmation + password reset) are handled here via
// .onOpenURL → authService.handleDeepLink(url). The SDK fires an
// authStateChanges event which updates authState / isAwaitingPasswordReset.

import SwiftUI

public struct RootView: View {

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var exportManager: ExportManager
    @State private var showDownloadPrompt = false

    public var body: some View {
        Group {
            if deps.isRestoringSession {
                SplashView()
            } else if deps.isAuthenticated {
                #if os(macOS)
                MacRootView()
                    .transition(.opacity)
                #else
                MainTabView()
                    .transition(.opacity)
                #endif
            } else {
                #if os(macOS)
                MacAuthFlowView(authService: deps.authService)
                    .transition(.opacity)
                #else
                SignInView(authService: deps.authService)
                    .transition(.opacity)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.35), value: deps.isAuthenticated)
        .animation(.easeInOut(duration: 0.45), value: deps.isRestoringSession)
        .task {
            await deps.restoreSessionIfNeeded()
        }
        .onChange(of: deps.isAuthenticated) { _, isAuth in
            checkPrompt(isAuth: isAuth)
        }
        .onAppear {
            checkPrompt(isAuth: deps.isAuthenticated)
        }
        // ── Deep link handler — covers both email confirmation and password reset ──
        // Both flows share the same URL scheme (mixtape://) and go through
        // client.auth.session(from:), which fires the appropriate authStateChanges event.
        .onOpenURL { url in
            Task { await deps.authService.handleDeepLink(url) }
        }
        // Password reset is handled inline in MacAuthFlowView / SignInView.
        // isAwaitingPasswordReset keeps authState = .unauthenticated so the user
        // lands on the auth screen, which navigates to the Set New Password screen.
        .sheet(isPresented: $showDownloadPrompt) {
            WelcomeDownloadPrompt()
                .environmentObject(exportManager)
        }
    }

    private func checkPrompt(isAuth: Bool) {
        guard isAuth else { return }
        // Show prompt only if the user has never confirmed a location and hasn't
        // explicitly skipped. isLocationConfigured is set by ExportManager.setExportURL
        // so it survives bookmark resolution failures on subsequent launches.
        if !exportManager.isLocationConfigured && !exportManager.didSkip {
            showDownloadPrompt = true
        }
    }
}

// MARK: - Splash / Loading Screen

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color.mixBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.pulse)
                Text("Mixtape")
                    .font(.mixDisplay)
                    .foregroundStyle(Color.mixTextPrimary)
            }
        }
    }
}

// MARK: - Preview

#Preview("Unauthenticated") {
    RootView()
        .environmentObject(AppDependencies())
}
