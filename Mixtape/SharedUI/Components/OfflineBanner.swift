// "Offline" banner. Shows when the network is gone (`DownloadManager.isConnected`)
// or the session is running on the cached one (`SupabaseAuthService.isOffline`);
// captive-portal Wi-Fi counts as connected, so either triggers it.

import SwiftUI

struct OfflineBanner: View {

    @ObservedObject var downloads: DownloadManager
    @ObservedObject var auth: SupabaseAuthService

    /// Empty when connected, so the host can place it unconditionally.
    var body: some View {
        if !downloads.isConnected || auth.isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offline")
                        .font(.system(size: MixFontScale.size(12), weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("Downloaded music still plays. Changes sync when you reconnect.")
                        .font(.system(size: MixFontScale.size(11)))
                        .foregroundStyle(Color.mixTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.mixTextTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.mixTextTertiary.opacity(0.12))
            )
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Offline. Downloaded music still plays.")
        }
    }
}

// MARK: - Watcher

/// Reports the network to a view that doesn't observe the download manager
/// (observing it would redraw the page on every progress tick). Fires on appear too.
struct OfflineWatcher: View {
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var auth: SupabaseAuthService
    let onChange: (Bool) -> Void

    private var offline: Bool { !downloads.isConnected || auth.isOffline }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { onChange(offline) }
            .onChange(of: offline) { _, now in onChange(now) }
    }
}

// MARK: - Strip

/// A small pill above the mini player (or the tab bar when nothing plays). Coming back online
/// turns it blue for a couple of seconds, then it goes.
struct OfflineStrip: View {

    @ObservedObject var downloads: DownloadManager
    @ObservedObject var auth: SupabaseAuthService

    /// Nil while there is nothing to say. `false` = offline, `true` = just back.
    @State private var back: Bool? = nil
    /// Bumped on each change so an older timer can't clear a newer state.
    @State private var generation = 0

    private var offline: Bool { !downloads.isConnected || auth.isOffline }

    var body: some View {
        Group {
            if let back {
                Label(back ? "You're back online" : "You're offline",
                      systemImage: back ? "wifi" : "wifi.slash")
                    .font(.system(size: MixFontScale.size(12), weight: .semibold))
                    .foregroundStyle(back ? Color.white : Color.mixTextSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(back ? AnyShapeStyle(Color(red: 0.24, green: 0.57, blue: 0.96)) : AnyShapeStyle(.regularMaterial),
                                in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
            }
        }
        .mixAnimation(.snappy(duration: 0.25), value: back)
        .onAppear { if offline { back = false } }
        .onChange(of: offline) { _, isOffline in
            generation &+= 1
            let mine = generation
            back = isOffline ? false : true
            guard !isOffline else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard generation == mine else { return }
                back = nil
            }
        }
    }
}
