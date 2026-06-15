// MacQueuePanelView.swift  (file kept as MacQueuePopover.swift for build continuity)
// Mixtape — Mac/PlayerBar
//
// Content of the Queue panel inside the shared right-side inspector column.
// Not a popover — sizing and background are set by MacRightPanelView.

#if os(macOS)
import SwiftUI

struct MacQueuePanelView: View {

    @EnvironmentObject private var engine: PlaybackEngine

    @State private var tab: QueueTab = .queue

    enum QueueTab: String, CaseIterable {
        case queue  = "Queue"
        case recent = "Recently Played"
    }

    private var upcomingTracks: [Track] {
        let q   = engine.queue.queue
        let idx = engine.queue.currentIndex
        guard idx >= 0, idx + 1 < q.count else { return [] }
        return Array(q[(idx + 1)...])
    }

    var body: some View {
        VStack(spacing: 0) {

            // Tab picker
            Picker("", selection: $tab) {
                ForEach(QueueTab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if tab == .queue  { queueContent  }
                    else              { recentContent }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color.mixBackground)
    }

    // MARK: - Queue tab

    @ViewBuilder
    private var queueContent: some View {
        if engine.queue.currentTrack == nil && upcomingTracks.isEmpty {
            emptyState(icon: "music.note.list", message: "Nothing in queue")
        } else {
            if let current = engine.queue.currentTrack {
                sectionLabel("NOW PLAYING")
                QueueRow(track: current, isCurrent: true)
            }
            if !upcomingTracks.isEmpty {
                sectionLabel("NEXT UP").padding(.top, 4)
                ForEach(upcomingTracks) { track in QueueRow(track: track, isCurrent: false) }
            }
        }
    }

    // MARK: - Recent tab

    @ViewBuilder
    private var recentContent: some View {
        if engine.recentlyPlayed.isEmpty {
            emptyState(icon: "clock", message: "Nothing played yet")
        } else {
            ForEach(engine.recentlyPlayed) { track in QueueRow(track: track, isCurrent: false) }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.mixTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Color.mixTextTertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.mixTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

// MARK: - Queue Row

private struct QueueRow: View {
    let track:     Track
    let isCurrent: Bool

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies

    var body: some View {
        HStack(spacing: 10) {
            MacArtworkView(data: track.artworkData, size: 36, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent && engine.state.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.pulse, isActive: true)
            } else {
                Text(track.formattedDuration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            let ctx = engine.queue.queue.isEmpty ? [track] : engine.queue.queue
            Task { await engine.play(track: track, in: ctx) }
        }
        .contextMenu {
            Button("Play Now") {
                let ctx = engine.queue.queue.isEmpty ? [track] : engine.queue.queue
                Task { await engine.play(track: track, in: ctx) }
            }
            Button("Play Next")    { engine.queue.insertNext(track) }
            Button("Add to Queue") { engine.queue.append(track) }
            
            if deps.downloadManager.status(for: track.id) != .notDownloaded {
                Divider()
                Button("Remove Download") {
                    deps.downloadManager.removeDownload(for: track.id)
                }
            }
        }
    }
}

#endif
