// The play log itself: every play, newest first, with where it was played from.
// One level down from `ListeningStatsView`, which is the summary of the same data.

import SwiftUI

public struct ListeningHistoryView: View {

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

    /// A page is a `fetchLimit` on the log, so this is the only cost knob here.
    private let pageSize = 100

    @State private var plays: [HistoryPlay] = []
    @State private var offset = 0
    @State private var reachedEnd = false
    @State private var isClearing = false
    @State private var showClearConfirm = false

    public init() {}

    public var body: some View {
        MixSheet(title: "Listening History",
                 subtitle: "Every play, newest first.",
                 size: .large) {
            content
        }
        .onAppear { if plays.isEmpty { loadMore() } }
        .mixConfirmationDialog("Clear listening history?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every play, here and on your other devices. Your mixes and stats start again from nothing. Your music is untouched.")
        }
    }

    /// No ScrollView or margins: the sheet owns both.
    @ViewBuilder
    private var content: some View {
        if plays.isEmpty {
            EmptyStateView(
                icon: MixtapeIcons.clock,
                title: "Nothing played yet",
                message: "Songs you play show up here, newest first."
            )
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayLabel(group.day))
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                        ForEach(group.plays) { row(for: $0) }
                    }
                }
                if !reachedEnd { showMoreButton }
                clearButton
            }
        }
    }

    /// Plays split into days. `plays` is already newest-first, so one pass keeps the
    /// days and the rows inside them in order.
    private var days: [(day: Date, plays: [HistoryPlay])] {
        var out: [(day: Date, plays: [HistoryPlay])] = []
        for play in plays {
            let day = Calendar.current.startOfDay(for: play.playedAt)
            if out.last?.day == day {
                out[out.count - 1].plays.append(play)
            } else {
                out.append((day, [play]))
            }
        }
        return out
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day)     { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Rows

    private func row(for play: HistoryPlay) -> some View {
        Button {
            Haptics.play(.light)
            // Plays on their own: the log is a record, not a list to keep playing through.
            Task { await engine.play(track: play.track, in: [play.track],
                                     source: .named("Listening History")) }
        } label: {
            HStack(spacing: 12) {
                ArtworkThumbnail(data: play.track.displayArtwork, size: 40, cornerRadius: 6,
                                 placeholder: MixtapeIcons.track)
                VStack(alignment: .leading, spacing: 3) {
                    Text(play.track.displayTitle)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: play))
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(play.playedAt.formatted(date: .omitted, time: .shortened))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }

    /// "Artist \u{00B7} from Liked Songs". Plays recorded before 2.0 have no source.
    private func subtitle(for play: HistoryPlay) -> String {
        let artist = play.track.displayArtistName
        guard let source = play.source else { return artist }
        return artist + " \u{00B7} from \(source)"
    }

    // MARK: Buttons

    private var showMoreButton: some View {
        Button {
            Haptics.play(.light)
            loadMore()
        } label: {
            Text("Show more")
                .font(.mixLabel)
                .foregroundStyle(Color.mixPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain).mixHandCursor()
    }

    private var clearButton: some View {
        Button {
            showClearConfirm = true
        } label: {
            HStack(spacing: 8) {
                if isClearing { ProgressView().controlSize(.small) }
                Text(isClearing ? "Clearing\u{2026}" : "Clear Listening History")
                    .font(.mixBodyBold)
            }
            .foregroundStyle(Color.mixDestructive)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(isClearing)
        .padding(.top, 8)
    }

    // MARK: Loading

    private func loadMore() {
        let page = deps.statsService.historyPage(limit: pageSize, offset: offset)
        // Step by what was asked for, not by what came back: rows whose song is gone are
        // dropped, and `rows` is the only honest answer to "was that the last page?".
        offset += pageSize
        reachedEnd = page.rows < pageSize
        plays += page.plays
    }

    private func clear() {
        isClearing = true
        Task {
            await deps.statsService.clearHistory()
            plays = []
            offset = 0
            reachedEnd = true
            isClearing = false
        }
    }
}
