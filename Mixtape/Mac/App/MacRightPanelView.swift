// MacRightPanelView.swift
// Mixtape — Mac/App
//
// The right-hand column's chrome: one tab bar and one close button around the
// three panels that column can show — Now Playing (track info), Queue, and
// Recently played.
//
// They used to be three unrelated bodies, one of which carried its own
// segmented picker, and none of which had a way to close the column except the
// Esc key. Sharing the chrome means switching between them is a tab away
// (Spotify's arrangement) and the header looks the same whichever one is up.

#if os(macOS)
import SwiftUI

struct MacRightPanelView: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var engine:   PlaybackEngine

    var body: some View {
        VStack(spacing: 0) {
            MacPanelTabBar()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.rightPanel {
        case .nowPlaying:
            // The inspector follows the playing song and only falls back to the
            // track the panel was opened with, so either is enough to show it.
            if let track = engine.queue.currentTrack ?? appState.inspectorTrack {
                MacTrackInspector(fallbackTrack: track)
            } else {
                MacPanelEmptyState(icon: "music.note", message: "Nothing playing")
            }
        case .queue:
            MacQueuePanelView()
        case .recent:
            MacRecentPanelView()
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Tab bar

/// Underlined text tabs plus a close button, sitting directly on the column's
/// background — no bar, no material, nothing that would cut a rectangle out of
/// the window-wide wash behind it.
private struct MacPanelTabBar: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var engine:   PlaybackEngine

    @Namespace private var underline

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(RightPanelMode.allCases, id: \.self) { mode in
                PanelTab(title:      mode.tabTitle,
                         isSelected: appState.rightPanel == mode,
                         namespace:  underline) { select(mode) }
            }

            Spacer(minLength: 4)

            Button { appState.closePanel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .help("Close panel")
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .mixAnimation(.easeOut(duration: 0.18), value: appState.rightPanel)
    }

    /// Every tab is a lateral move — the column stays open. Now Playing needs a
    /// track to show, so it opens on whatever the inspector would display.
    private func select(_ mode: RightPanelMode) {
        switch mode {
        case .nowPlaying:
            if let track = engine.queue.currentTrack ?? appState.inspectorTrack {
                appState.showNowPlaying(for: track)
            } else {
                appState.showPanel(.nowPlaying)
            }
        case .queue, .recent:
            appState.showPanel(mode)
        }
    }
}

private struct PanelTab: View {
    let title:      String
    let isSelected: Bool
    let namespace:  Namespace.ID
    let action:     () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    // One weight for all three. Selection is the underline's
                    // job — bolding the selected tab as well made "Now Playing"
                    // read as a heading with two links after it rather than as
                    // one of three equal tabs.
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    // Deliberately no `minimumScaleFactor`: it only ever fired
                    // on the longest label, so "Now Playing" rendered smaller
                    // than the other two and — scaled glyphs sitting inside an
                    // unshrunk line box — visibly lower as well.
                    .fixedSize(horizontal: true, vertical: false)

                // The moving underline is one shape handed between tabs, so it
                // slides across instead of blinking out and in.
                Group {
                    if isSelected {
                        Capsule()
                            .fill(Color.mixPrimary)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "panelTabUnderline", in: namespace)
                    } else {
                        Capsule().fill(Color.clear).frame(height: 2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var color: Color {
        if isSelected { return Color.mixTextPrimary }
        return isHovered ? Color.mixTextPrimary : Color.mixTextSecondary
    }
}

// MARK: - Shared empty state

/// Centred icon + line, shared by all three panels so an empty Queue and an
/// empty history don't look like two different apps.
struct MacPanelEmptyState: View {
    let icon:    String
    let message: String
    var hint:    String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.mixTextTertiary)
                .frame(width: 54, height: 54)
                .background(Color.primary.opacity(0.05), in: Circle())

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 40)
    }
}

#endif
