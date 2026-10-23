// Queue and Recently Played panels in the right column (file name kept from
// when it was a popover). Sizing and tabs belong to MacRightPanelView.

#if os(macOS)
import SwiftUI

struct MacQueuePanelView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator
    /// Observed directly: `engine.queue` is a plain `let`, so its changes don't
    /// publish through the engine.
    @Environment(QueueService.self) private var queueService

    /// Drop lands above this row.
    @State private var dropTarget: QueueService.Entry.ID?

    /// Everything after the current song (whole queue if nothing plays). Rows, not
    /// tracks, so duplicates are separate rows.
    private var upcomingRows: [QueueService.Entry] { queueService.upcomingRows }

    /// Sections come from the queue so this and the iOS sheet always agree.
    private var sections: [QueueService.Section] { queueService.upcomingSections }

    /// As a row so badge logic matches the upcoming rows.
    private var currentRow: QueueService.Entry? {
        let rows = queueService.entries
        guard rows.indices.contains(queueService.currentIndex) else { return nil }
        return rows[queueService.currentIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            TapeDeckPicker(decks: deps.tapeDecks)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            queueBody
        }
    }

    private var queueBody: some View {
        Group {
            if currentRow == nil && upcomingRows.isEmpty {
                MacPanelEmptyState(icon: "music.note.list",
                                   message: "Your queue is empty",
                                   hint: "Songs you play or add with “Add to Queue” show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let sides = queueService.sideMarks()
                        if let current = currentRow {
                            sectionHeader(sides[current.id].map { "Now playing \u{00B7} \($0)" } ?? "Now playing")
                            QueuePanelRow(row: current, isCurrent: true)
                        }

                        if !upcomingRows.isEmpty {
                            // With repeat-all on, the loop group and divider replace the sections.
                            if showsRepeatDivider {
                                queueHeader(title: sections.first?.title ?? "Next in queue")
                                ForEach(loopingRows) { row in
                                    upcomingRow(row, side: sides[row.id])
                                }
                                repeatDivider
                                ForEach(afterRepeatRows) { row in
                                    upcomingRow(row, side: sides[row.id])
                                }
                            } else {
                                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                    queueHeader(title: section.title, showsControls: index == 0)
                                    ForEach(section.rows) { row in
                                        upcomingRow(row, side: sides[row.id])
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        // On the panel, not the list, so it shows even when the queue empties.
        .overlay(alignment: .bottom) { SkipNoticeBox() }
    }

    // MARK: - The repeating group

    /// Upcoming rows that are part of the loop.
    private var loopingRows: [QueueService.Entry] {
        guard let boundary = queueService.repeatBoundaryIndex else { return upcomingRows }
        return upcomingRows.filter { $0.index <= boundary }
    }

    /// Rows queued after the loop; they wait until repeat is off.
    private var afterRepeatRows: [QueueService.Entry] {
        guard let boundary = queueService.repeatBoundaryIndex else { return [] }
        return upcomingRows.filter { $0.index > boundary }
    }

    /// The divider only means something while the queue is looping.
    private var showsRepeatDivider: Bool {
        queueService.repeatMode == .all && queueService.repeatBoundaryIndex != nil
    }

    /// Marks where the loop turns around. Also a drop target: drops land at the
    /// end of the group.
    private var repeatDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.mixRepeatBoundary)
                .frame(width: 18, height: 2)
                .clipShape(Capsule())

            Text(afterRepeatRows.isEmpty ? queueService.repeatDividerLabel
                 : "\(queueService.repeatDividerLabel) · below plays once repeat is off")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.mixRepeatBoundary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(Color.mixRepeatBoundary.opacity(0.45))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            // Land just after the last looping row.
            guard let source = items.first.flatMap(Int.init),
                  let boundary = queueService.repeatBoundaryIndex else { return false }
            move(from: source, to: boundary + 1)
            return true
        }
        .help("Songs above this line repeat. Drag songs across it to change what loops.")
    }

    // MARK: - Rows

    /// Draggable onto any row, including across the repeat boundary.
    @ViewBuilder
    private func upcomingRow(_ row: QueueService.Entry, side: String?) -> some View {
        if let side {
            Label(side, systemImage: "recordingtape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
        draggableRow(row)
    }

    @ViewBuilder
    private func draggableRow(_ row: QueueService.Entry) -> some View {
        QueuePanelRow(row: row, isCurrent: false,
                      isAfterRepeat: row.index > (queueService.repeatBoundaryIndex ?? Int.max),
                      onRemove: { remove(row) })
            .draggable(String(row.index))
            .dropDestination(for: String.self) { items, _ in
                guard let source = items.first.flatMap(Int.init) else { return false }
                move(from: source, to: row.index)
                return true
            } isTargeted: { over in
                if over { dropTarget = row.id } else if dropTarget == row.id { dropTarget = nil }
            }
            .overlay(alignment: .top) {
                if dropTarget == row.id {
                    Capsule()
                        .fill(Color.mixAccent)
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                        .offset(y: -2)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Via the coordinator: in a Discover session the queue mirrors the online
    /// context, so a local-only move would be undone.
    private func move(from source: Int, to destination: Int) {
        withMixAnimation(.easeOut(duration: 0.2)) {
            coordinator.moveInQueue(from: source, to: destination)
        }
    }

    // MARK: - Headers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    /// Section heading. Repeat and Clear only on the first, since they act on the
    /// whole queue.
    @ViewBuilder
    private func queueHeader(title: String, showsControls: Bool = true) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if showsControls {
            QueueToolButton(
                icon:     queueService.repeatSystemImage,
                help:     repeatHelp,
                isActive: queueService.repeatMode != .off
            ) {
                queueService.cycleRepeat()
            }

            // Two clears: your added songs vs. the list being played.
            if coordinator.hasManualQueue {
                PanelLinkButton(title: "Clear added") {
                    withMixAnimation(.easeOut(duration: 0.2)) {
                        coordinator.clearManualQueue()
                    }
                }
            }

            PanelLinkButton(title: "Clear queue") {
                withMixAnimation(.easeOut(duration: 0.2)) {
                    coordinator.clearUpcomingQueue()
                }
            }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, showsControls ? 14 : 12)
        .padding(.bottom, 4)
    }

    private var repeatHelp: String {
        switch queueService.repeatMode {
        case .off: return "Repeat off"
        case .all: return queueService.isAutoReverse
            ? "Auto-reverse: every side, then back to Side A"
            : "Repeating the songs above the orange line"
        case .one: return "Repeat song"
        }
    }

    /// Via the coordinator, same reason as `move`.
    private func remove(_ row: QueueService.Entry) {
        withMixAnimation(.easeOut(duration: 0.2)) {
            coordinator.removeFromQueue(at: row.index)
        }
    }
}

// MARK: - Recently played

struct MacRecentPanelView: View {

    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        Group {
            if engine.recentlyPlayed.isEmpty {
                MacPanelEmptyState(icon: "clock.arrow.circlepath",
                                   message: "Nothing played yet",
                                   hint: "Songs you listen to show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // By position, since the same track can appear twice.
                        ForEach(Array(engine.recentlyPlayed.enumerated()), id: \.offset) { _, track in
                            QueuePanelRow(track: track, index: nil,
                                          isManual: false, isCurrent: false)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: - Row

private struct QueuePanelRow: View {
    let track:     Track
    /// Nil for Recent rows, which play as a fresh pick.
    let index:     Int?
    /// Queued by the user rather than coming from the playing context.
    let isManual:  Bool
    let isCurrent: Bool
    /// Below the repeat boundary: dimmed, waits for repeat to turn off.
    var isAfterRepeat: Bool = false
    /// Nil for the playing row and Recent.
    var onRemove:  (() -> Void)? = nil

    init(track: Track, index: Int?, isManual: Bool, isCurrent: Bool,
         isAfterRepeat: Bool = false, onRemove: (() -> Void)? = nil) {
        self.track = track; self.index = index; self.isManual = isManual
        self.isCurrent = isCurrent; self.isAfterRepeat = isAfterRepeat
        self.onRemove = onRemove
    }

    init(row: QueueService.Entry, isCurrent: Bool, isAfterRepeat: Bool = false,
         onRemove: (() -> Void)? = nil) {
        self.init(track: row.track, index: row.index, isManual: row.isManual,
                  isCurrent: isCurrent, isAfterRepeat: isAfterRepeat,
                  onRemove: onRemove)
    }

    @State private var isHovered = false

    @Environment(PlaybackEngine.self) private var engine
    @Environment(AppDependencies.self) private var deps
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator

    /// Online track id (stored as the file hash). Empty outside online sessions.
    private var onlineID: String { track.file.fileHash }

    /// True while this row's online track is being resolved/downloaded after a tap.
    private var isResolving: Bool {
        coordinator.hasActiveOnlineSession && coordinator.resolvingID == onlineID
    }

    /// Online sessions go through the coordinator so unresolved tracks stream,
    /// otherwise play from the local queue.
    private func playRow() {
        Task {
            if let index, await coordinator.playQueueTrack(at: index, track: track) { return }
            let ctx = engine.queue.queue.isEmpty ? [track] : engine.queue.queue
            // An online track outside the active session has no local file, so re-resolve
            // it through the coordinator.
            if coordinator.isStandaloneOnline(track) {
                await coordinator.playStandaloneOnline(track, context: ctx)
                return
            }
            // By position: this row, not the first copy of this song.
            await engine.play(track: track, in: ctx, startIndex: index, source: engine.queue.source)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    UnfindableBadge(track: track)
                    // Same links as the player bar; `displayTitle` so features move to the artist line.
                    MixTrackTitleLink(track: track,
                                      font: .system(size: 13, weight: isCurrent ? .semibold : .regular),
                                      color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                }

                HStack(spacing: 4) {
                    // Marks songs the user queued.
                    if isManual {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.mixPrimary)
                            .help("You added this to the queue")
                    }
                    MixTrackArtistLink(track: track)
                }
            }

            Spacer(minLength: 4)

            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .padding(.horizontal, 8)
        // Dimmed, not greyed out: the row is perfectly real and playable, it
        // just isn't part of what is looping.
        .opacity(isAfterRepeat ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
        .onTapGesture(count: 2) { playRow() }
        // Liking is the point of this menu: the queue is the one place you're
        // guaranteed to be looking at a song you're enjoying.
        .contextMenu {
            LibrarySongMenu(targets: [track],
                            onPlay: { playRow() },
                            removeFrom: onRemove == nil ? nil : "Queue",
                            onRemove:   onRemove.map { remove in { _ in remove() } })
            if coordinator.canReResolve(track) {
                Divider()
                Button("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await deps.reResolve(track, at: index) }
                }
            }
        }
    }

    /// Hovering the cover shows a play button.
    private var artwork: some View {
        MacArtworkView(data: track.artworkData, artworkRef: .track(track.id), size: 42, cornerRadius: 6)
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .mixTapAction { playRow() }
    }

    @ViewBuilder
    private var trailing: some View {
        if isResolving {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if isCurrent && engine.state.isPlaying {
            PlayingWave(size: 12, isPlaying: true, pulses: true)
        } else if isHovered, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .help("Remove from queue")
        } else {
            Text(track.formattedDuration)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.mixTextTertiary)
        }
    }

    private var rowFill: Color {
        if isHovered { return Color.primary.opacity(0.07) }
        if isCurrent { return Color.primary.opacity(0.04) }
        return .clear
    }
}

// MARK: - Panel link button
// Text link styled for a section header ("Clear queue").

private struct PanelLinkButton: View {
    let title:  String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.mixTextPrimary : Color.mixTextSecondary)
                .underline(isHovered)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Queue Tool Button
// Queue control button, TransportButton's look at panel scale.

private struct QueueToolButton: View {
    let icon:       String
    var help:       String  = ""
    var isActive:   Bool    = false
    var isDisabled: Bool    = false
    let action:     () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 22)
                .background(
                    isHovered && !isDisabled ? Color.primary.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(isActive ? Color.mixPrimary : Color.clear)
                        .frame(width: 3, height: 3)
                        .offset(y: 3)
                }
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(isDisabled)
        .help(help)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        if isDisabled { return Color.mixTextTertiary.opacity(0.35) }
        if isActive   { return Color.mixPrimary }
        if isHovered  { return Color.mixTextPrimary }
        return Color.mixTextSecondary
    }
}

#endif
