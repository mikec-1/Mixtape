// Right column chrome: one tab bar and close button around Now Playing, Queue and Recently Played.

#if os(macOS)
import SwiftUI

struct MacRightPanelView: View {

    @Environment(MacAppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

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
            // Follows the playing song, falling back to the track the panel opened with.
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

/// Underlined text tabs plus close, drawn straight on the column so the window wash shows through.
private struct MacPanelTabBar: View {

    @Environment(MacAppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

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

    /// Tabs keep the column open. Now Playing opens on whatever the inspector would show.
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
                    // One weight for all; the underline marks selection.
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    // No `minimumScaleFactor`: it shrank and lowered only "Now Playing".
                    .fixedSize(horizontal: true, vertical: false)

                // One underline shape shared between tabs, so it slides.
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

/// Centred icon + line, shared by all three panels' empty states.
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
