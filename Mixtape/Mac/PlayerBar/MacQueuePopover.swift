// MacQueuePanelView.swift  (file kept as MacQueuePopover.swift for build continuity)
// Mixtape — Mac/PlayerBar
//
// The Queue and Recently-played panels inside the shared right-side column.
// Not a popover — sizing, background and the tab bar above them belong to
// MacRightPanelView.

#if os(macOS)
import SwiftUI

struct MacQueuePanelView: View {

    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    /// Observed directly rather than reached through `engine.queue`: the engine
    /// holds the queue as a plain `let`, so its `objectWillChange` never fires
    /// through the engine and a view watching only the engine kept showing the
    /// old repeat icon until some unrelated engine publish happened to repaint
    /// it — which is what made pressing Repeat look like it took seconds.
    @EnvironmentObject private var queueService: QueueService

    /// Everything after the current song — and the whole queue when nothing is
    /// playing yet. Rows, not tracks: each carries its own identity and its
    /// position, so the same song queued three times is three rows that can be
    /// listed, clicked and dragged independently.
    private var upcomingRows: [QueueService.Entry] { queueService.upcomingRows }

    /// The upcoming queue split into "Next in queue" / "Next up: <list>" /
    /// "Next up: recommended songs". Derived by the queue itself so this panel
    /// and the iOS sheet can never disagree about what section a song is in.
    private var sections: [QueueService.Section] { queueService.upcomingSections }

    /// The playing row, as a row rather than a bare track — so the badge logic
    /// is the same one the upcoming rows use.
    private var currentRow: QueueService.Entry? {
        let rows = queueService.entries
        guard rows.indices.contains(queueService.currentIndex) else { return nil }
        return rows[queueService.currentIndex]
    }

    var body: some View {
        Group {
            if currentRow == nil && upcomingRows.isEmpty {
                MacPanelEmptyState(icon: "music.note.list",
                                   message: "Your queue is empty",
                                   hint: "Songs you play or add with “Add to Queue” show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let current = currentRow {
                            sectionHeader("Now playing")
                            QueuePanelRow(row: current, isCurrent: true)
                        }

                        if !upcomingRows.isEmpty {
                            // Repeat-all is its own way of reading the queue —
                            // "these songs loop, those wait" — so while it is on
                            // the group and its divider replace the sections
                            // rather than being crossed with them.
                            if showsRepeatDivider {
                                queueHeader(title: sections.first?.title ?? "Next in queue")
                                ForEach(loopingRows) { row in
                                    draggableRow(row)
                                }
                                repeatDivider
                                ForEach(afterRepeatRows) { row in
                                    draggableRow(row)
                                }
                            } else {
                                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                    queueHeader(title: section.title, showsControls: index == 0)
                                    ForEach(section.rows) { row in
                                        draggableRow(row)
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
        // A skipped song is worth saying even when it was the last one and the
        // queue is now empty, so the notice hangs off the whole panel rather
        // than off the list inside it.
        .overlay(alignment: .bottom) { SkipNoticeBox() }
        // No background of its own: the panel column paints the window's
        // colour (and the page's wash) behind it, and an opaque fill here would
        // cut a flat rectangle out of it.
    }

    // MARK: - The repeating group

    /// Upcoming rows that are part of the loop.
    private var loopingRows: [QueueService.Entry] {
        guard let boundary = queueService.repeatBoundaryIndex else { return upcomingRows }
        return upcomingRows.filter { $0.index <= boundary }
    }

    /// Upcoming rows queued for *after* the loop — they wait until repeat is
    /// switched off rather than joining it.
    private var afterRepeatRows: [QueueService.Entry] {
        guard let boundary = queueService.repeatBoundaryIndex else { return [] }
        return upcomingRows.filter { $0.index > boundary }
    }

    /// The divider only means something while the queue is looping.
    private var showsRepeatDivider: Bool {
        queueService.repeatMode == .all && queueService.repeatBoundaryIndex != nil
    }

    /// The line that says where the loop turns around. Drawn in the accent
    /// orange and labelled, because a bare rule between two songs would read as
    /// decoration rather than as the answer to "what exactly is repeating?".
    /// It is also a drop target: dragging a row onto it puts that row at the end
    /// of the group.
    private var repeatDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.mixRepeatBoundary)
                .frame(width: 18, height: 2)
                .clipShape(Capsule())

            Text(afterRepeatRows.isEmpty ? "Repeats from here" : "Repeats from here · below plays once repeat is off")
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
            // Dropped on the line: land just after the last looping row, i.e.
            // still inside the group.
            guard let source = items.first.flatMap(Int.init),
                  let boundary = queueService.repeatBoundaryIndex else { return false }
            move(from: source, to: boundary + 1)
            return true
        }
        .help("Songs above this line repeat. Drag songs across it to change what loops.")
    }

    // MARK: - Rows

    /// One upcoming row, draggable onto any other row to reorder it — which is
    /// also how a song is moved into or out of the repeating group.
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
            }
    }

    /// Reorder through the coordinator: during a Discover session the queue is
    /// only a mirror of the online context, so a move applied to it alone would
    /// last until the next push.
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

    /// A section heading, with the controls that act on the whole queue —
    /// repeat, and a Clear link rather than a bare trash icon — on the first
    /// one. Only the first: they empty and loop the queue, not the section, and
    /// three Clear links would say otherwise.
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
                icon:     queueService.repeatMode.systemImage,
                help:     repeatHelp,
                isActive: queueService.repeatMode != .off
            ) {
                queueService.cycleRepeat()
            }

            // Two clears, because they mean different things: one drops the
            // songs you asked for, the other drops the list you are playing.
            // Only shown when there is something of yours to drop.
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
        case .all: return "Repeating the songs above the orange line"
        case .one: return "Repeat song"
        }
    }

    /// Remove one upcoming row. Routed through the coordinator because during an
    /// online session the queue is only a mirror of the context — removing it
    /// here alone would last until the next push.
    private func remove(_ row: QueueService.Entry) {
        withMixAnimation(.easeOut(duration: 0.2)) {
            coordinator.removeFromQueue(at: row.index)
        }
    }
}

// MARK: - Recently played

struct MacRecentPanelView: View {

    @EnvironmentObject private var engine: PlaybackEngine

    var body: some View {
        Group {
            if engine.recentlyPlayed.isEmpty {
                MacPanelEmptyState(icon: "clock.arrow.circlepath",
                                   message: "Nothing played yet",
                                   hint: "Songs you listen to show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Keyed by position for the same reason the queue is keyed
                        // by row: playing a song twice puts the same track id in
                        // this list twice.
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
    /// Where this row sits in the queue. Nil for rows that aren't in it — the
    /// Recent tab — which play as a fresh choice rather than as a position.
    let index:     Int?
    /// The user put this song in the queue themselves, rather than it arriving
    /// as part of the mix, album or search results being played.
    let isManual:  Bool
    let isCurrent: Bool
    /// This row sits below the repeat boundary: it waits for repeat to be
    /// switched off instead of joining the loop. Dimmed to say so.
    var isAfterRepeat: Bool = false
    /// Non-nil for rows that can be taken out of the queue — an upcoming row.
    /// The playing row and the Recent tab have nothing to remove.
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

    @EnvironmentObject private var engine:      PlaybackEngine
    @EnvironmentObject private var deps:        AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator

    /// The online-track id this row maps to (asTrack stores it as the file hash).
    /// Non-empty only for online-session tracks.
    private var onlineID: String { track.file.fileHash }

    /// True while this row's online track is being resolved/downloaded after a tap.
    private var isResolving: Bool {
        coordinator.hasActiveOnlineSession && coordinator.resolvingID == onlineID
    }

    /// Play this row. During an online session, route through the coordinator so
    /// not-yet-downloaded tracks resolve (with a spinner) exactly like Discover;
    /// otherwise play locally from the queue.
    private func playRow() {
        Task {
            if let index, await coordinator.playQueueTrack(at: index, track: track) { return }
            let ctx = engine.queue.queue.isEmpty ? [track] : engine.queue.queue
            // An online track replayed outside the active online session (no live
            // context match above) has no local file — routing it through the
            // engine would falsely report "hasn't been uploaded yet". Re-resolve
            // and stream it through the coordinator instead.
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
                    // Same two links as the player bar, so a song's name means
                    // the same thing here as it does six inches below.
                    // `displayTitle` with it: the feature credit moves out of
                    // the title and onto the artist line, where each guest is
                    // its own target.
                    MixTrackTitleLink(track: track,
                                      font: .system(size: 13, weight: isCurrent ? .semibold : .regular),
                                      color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                }

                HStack(spacing: 4) {
                    // The mark the app's own picks don't get: this one is here
                    // because the user asked for it.
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
        .contextMenu {
            Button("Play Now") { playRow() }
            Button("Play Next")    { engine.queue.insertNext(track) }
            Button("Add to Queue") { engine.queue.append(track) }
            // A queue row is often a Discover song the library doesn't hold —
            // the offer any menu makes for one of those.
            if deps.libraryService.track(id: track.id) == nil {
                Divider()
                Button("Add to Library", systemImage: "plus") {
                    Task {
                        await coordinator.addToLibrary(unsaved: track)
                        deps.showSavedToast(.library)
                    }
                }
            }
            if let onRemove {
                Divider()
                Button("Remove from Queue", action: onRemove)
            }
            Divider()
            ShareMenuItems(.track(track))
            Divider()
            DownloadMenuItems(track: track, downloads: deps.downloadManager)
        }
    }

    /// Hovering the cover turns it into a play button — one click instead of the
    /// double-click the whole row still takes.
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
            .onTapGesture { playRow() }
    }

    @ViewBuilder
    private var trailing: some View {
        if isResolving {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if isCurrent && engine.state.isPlaying {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixPrimary)
                .mixPulse()
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
//
// A text action that reads as part of a section header — Spotify's "Clear
// queue" — rather than a bordered control dropped into the list.

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
//
// Small icon button for the queue's own controls. Matches the player bar's
// TransportButton (hover plate, accent + dot when active) at panel scale;
// that one is private to its file and sized for the transport row.

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
