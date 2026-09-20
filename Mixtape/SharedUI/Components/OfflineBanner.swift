// OfflineBanner.swift
// Mixtape — SharedUI/Components
//
// "Offline" — the one line that explains why a song won't start.
//
// Two different facts read the same way to a listener: the network is gone
// (`DownloadManager.isConnected`), or the session could not be refreshed and
// the app is running on the cached one (`SupabaseAuthService.isOffline`). The
// second usually implies the first, but not always — a captive-portal Wi-Fi
// counts as connected — so the banner shows for either.

import SwiftUI

struct OfflineBanner: View {

    @ObservedObject var downloads: DownloadManager
    @ObservedObject var auth: SupabaseAuthService

    /// Collapses to nothing when there's a connection, so the host can place it
    /// unconditionally next to `DownloadStatusBar`.
    var body: some View {
        if !downloads.isConnected || auth.isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("Downloaded music still plays. Changes sync when you reconnect.")
                        .font(.system(size: 11))
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

/// Reports the network to a view that can't observe it: a screen reached
/// through `AppDependencies` holds the download manager but doesn't watch it,
/// and observing it there would redraw the whole page on every progress tick.
/// Fires on appear too, so a screen opened while already offline hears about it.
struct OfflineWatcher: View {
    @ObservedObject var downloads: DownloadManager
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { onChange(!downloads.isConnected) }
            .onChange(of: downloads.isConnected) { _, connected in onChange(!connected) }
    }
}

// MARK: - Strip

/// The same fact as a band on the player, opposite the continuity strip: that
/// one names the device playing and sits above the controls, this one names the
/// network and sits below them. Coming back is worth saying too — a green line
/// for a couple of seconds, then gone, because "online" is the normal state and
/// a permanent badge for it is noise.
struct OfflineStrip: View {

    @ObservedObject var downloads: DownloadManager
    @ObservedObject var auth: SupabaseAuthService

    /// Nil while there is nothing to say. `false` = offline, `true` = just back.
    @State private var back: Bool? = nil
    /// Discarded when a newer change arrives, so a flap doesn't leave the green
    /// line to be cleared by a timer that belongs to an older state.
    @State private var generation = 0

    private var offline: Bool { !downloads.isConnected || auth.isOffline }

    var body: some View {
        Group {
            if let back {
                Text(back ? "You're back online" : "You're offline")
                    .font(.system(size: 13, weight: back ? .semibold : .regular))
                    .foregroundStyle(back ? Color.black : Color.mixTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(back ? Color(red: 0.24, green: 0.57, blue: 0.96) : Color.mixBackground)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel(back ? "You're back online" : "You're offline")
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
