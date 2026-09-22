// MixtapeWidgets.swift
// The widget extension: the Now Playing widget for the Home and Lock Screens,
// the novelty ones in WidgetStyles.swift, and the Live Activity. All of them
// draw from `NowPlayingSnapshot`, which the app writes whenever the song or
// the play state changes — see NowPlayingSurfaces.

import WidgetKit
import SwiftUI
import AppIntents

@main
struct MixtapeWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        CoverArtWidget()
        UpNextWidget()
        CassetteWidget()
        VinylWidget()
        BigTypeWidget()
        ClickWheelWidget()
        ReceiptWidget()
        NowPlayingLiveActivity()
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let song: NowPlayingSnapshot
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, song: .sample)
    }
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, song: NowPlayingSnapshot.load() ?? .sample))
    }
    /// Never refreshed on a schedule: the app reloads the timeline itself, and a
    /// reload while audio plays doesn't count against the budget. While a song
    /// plays there's an entry every 15 s to its end, for the drawings that
    /// can't use a self-running timer — the tape reels and the tonearm.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let song = NowPlayingSnapshot.load() ?? .idle
        var entries = [NowPlayingEntry(date: .now, song: song)]
        if song.isPlaying, song.duration > 0 {
            let end = song.startedAt.addingTimeInterval(song.duration)
            var next = Date.now.addingTimeInterval(15)
            while next < end, entries.count < 40 {
                entries.append(NowPlayingEntry(date: next, song: song))
                next += 15
            }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

extension NowPlayingSnapshot {
    static let idle = NowPlayingSnapshot(title: "Nothing playing", artist: "Open Mixtape", isPlaying: false,
                                         elapsed: 0, duration: 0, at: .now)
    /// The widget gallery, before anything has played.
    static let sample = NowPlayingSnapshot(
        title: "Songs for the Long Drive Home", artist: "Mixtape", album: "Side A", source: "Road Trip",
        isPlaying: false, isLiked: true, tint: [0.86, 0.34, 0.32],
        upNext: [.init(title: "Night Swim", artist: "The Tapes"), .init(title: "Last Exit", artist: "Side B"),
                 .init(title: "Slow Fade", artist: "Mixtape"), .init(title: "Glovebox", artist: "The Tapes"),
                 .init(title: "Headlights", artist: "Side B")],
        elapsed: 72, duration: 214, at: .now)

    var cover: UIImage? { artwork.flatMap(UIImage.init(data:)) }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max((isPlaying ? date.timeIntervalSince(startedAt) : elapsed) / duration, 0), 1)
    }

    var tintColor: Color {
        tint.count == 3 ? Color(red: tint[0], green: tint[1], blue: tint[2]) : Color(red: 0.86, green: 0.34, blue: 0.32)
    }

    /// Dark ink on a pale cover colour, white on the rest.
    var inkOnTint: Color {
        guard tint.count == 3 else { return .white }
        return 0.299 * tint[0] + 0.587 * tint[1] + 0.114 * tint[2] > 0.62 ? .black : .white
    }
}

/// "3:07", or "1:02:07" — the same shape the running timer text takes.
func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Now Playing

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(song: entry.song)
        }
        .configurationDisplayName("Now Playing")
        .description("What Mixtape is playing, with play, pause and skip.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NowPlayingWidgetView: View {
    let song: NowPlayingSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium || family == .systemLarge {
                ArtWash(song: song)
            } else {
                AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label("\(song.title) · \(song.artist)", systemImage: song.isPlaying ? "waveform" : "pause.fill")
        case .accessoryCircular:
            // The ring is the song's progress, and runs on its own while playing.
            ZStack {
                SongBar(song: song).progressViewStyle(.circular)
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: song.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain)
            }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.headline).lineLimit(1)
                    Text(song.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    SongBar(song: song)
                }
                Spacer(minLength: 0)
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Cover(data: song.artwork, size: 64)
                    Spacer(minLength: 0)
                    PlayButton(isPlaying: song.isPlaying, size: 34)
                }
                Spacer(minLength: 0)
                Titles(song: song)
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Cover(data: song.artwork, size: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        if let source = song.source {
                            Text("PLAYING FROM \(source.uppercased())")
                                .font(.caption2.weight(.semibold)).lineLimit(1).opacity(0.65)
                        }
                        Titles(song: song, font: .title3.bold())
                        if !song.album.isEmpty {
                            Text(song.album).font(.caption).lineLimit(1).opacity(0.6)
                        }
                    }
                    .foregroundStyle(.white)
                }
                TimedBar(song: song)
                HStack {
                    Button(intent: ToggleShuffleIntent()) {
                        Image(systemName: "shuffle").opacity(song.shuffle ? 1 : 0.45)
                    }
                    Spacer()
                    Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                    Spacer()
                    PlayButton(isPlaying: song.isPlaying, size: 44)
                    Spacer()
                    Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    Spacer()
                    Button(intent: ToggleLikeIntent()) {
                        Image(systemName: song.isLiked ? "heart.fill" : "heart")
                    }
                }
                .buttonStyle(.plain)
                .font(.title3)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                if !song.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UP NEXT").font(.caption2.weight(.semibold)).opacity(0.6)
                        // As many as fit: the large widget's height differs by phone.
                        ViewThatFits(in: .vertical) {
                            QueueRows(songs: song.upNext.prefix(3))
                            QueueRows(songs: song.upNext.prefix(2))
                            QueueRows(songs: song.upNext.prefix(1))
                        }
                    }
                    .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
        default:
            HStack(spacing: 14) {
                Cover(data: song.artwork, size: 118)
                VStack(alignment: .leading, spacing: 6) {
                    Titles(song: song)
                    TimedBar(song: song)
                    Spacer(minLength: 0)
                    HStack(spacing: 22) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        PlayButton(isPlaying: song.isPlaying, size: 38)
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Live Activity

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // Read at draw time: the app saves the snapshot before it updates the
            // activity, and a cover is far past the activity's 4 KB state limit.
            let art = context.state.hasArtwork ? NowPlayingSnapshot.load()?.artwork : nil
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Cover(data: art, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(2)
                        Text(context.state.artist).font(.subheadline).lineLimit(1).opacity(0.75)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 16) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        PlayButton(isPlaying: context.state.isPlaying, size: 38)
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                }
                StateBar(state: context.state)
            }
            .padding(14)
            .activityBackgroundTint(tint(context.state).opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            let art = context.state.hasArtwork ? NowPlayingSnapshot.load()?.artwork : nil
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Cover(data: art, size: 52) }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayButton(isPlaying: context.state.isPlaying, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist).font(.subheadline).lineLimit(1).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        StateBar(state: context.state)
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                }
            } compactLeading: {
                // Nothing in the pill: iOS already shows the song there from the
                // system Now Playing, and a second one beside it is noise. The
                // activity is for the Lock Screen; iOS gives it no way to skip
                // the island, so it asks for as little of it as it can.
                EmptyView()
            } compactTrailing: {
                EmptyView()
            } minimal: {
                EmptyView()
            }
        }
    }

    private func tint(_ state: NowPlayingAttributes.ContentState) -> Color {
        guard state.tint.count == 3 else { return Color(red: 0.86, green: 0.34, blue: 0.32) }
        return Color(red: state.tint[0], green: state.tint[1], blue: state.tint[2])
    }
}

// MARK: - Pieces

/// The cover itself, blurred, under a dark scrim: the same wash the app's
/// Now Playing screen draws, without needing a colour picked for it.
struct ArtWash: View {
    let song: NowPlayingSnapshot
    var body: some View {
        ZStack {
            Color.black
            if let image = song.cover {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 30).opacity(0.7)
            } else {
                song.tintColor.opacity(0.45)
            }
            Color.black.opacity(0.25)
        }
    }
}

struct Cover: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let image = data.flatMap(UIImage.init(data:)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // The app's own mark — the icon the menu bar and profile use.
                Image(systemName: "waveform.circle.fill").resizable().scaledToFit()
                    .padding(size * 0.2).foregroundStyle(.white.opacity(0.8))
                    .background(Color.gray.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
    }
}

struct Titles: View {
    let song: NowPlayingSnapshot
    var font: Font = .headline
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Two lines whatever the bar under it is doing — a running timer
            // measures differently from a still one and used to squeeze it.
            Text(song.title).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(song.artist).font(.subheadline).lineLimit(1).opacity(0.75)
        }
        .foregroundStyle(.white)
    }
}

struct PlayButton: View {
    let isPlaying: Bool
    let size: CGFloat
    var fill: Color = .white
    var ink: Color = .black
    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct QueueRows: View {
    let songs: ArraySlice<NowPlayingSnapshot.Song>
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                HStack(spacing: 8) {
                    Cover(data: song.artwork, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(song.artist).font(.caption2).lineLimit(1).opacity(0.65)
                    }
                }
            }
        }
    }
}

/// Runs on its own while playing — WidgetKit animates a timer interval without
/// the app — and sits still while paused.
struct Bar: View {
    let isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval, startedAt: Date
    var body: some View {
        if isPlaying, duration > 0 {
            ProgressView(timerInterval: startedAt...startedAt.addingTimeInterval(duration), countsDown: false) {
                EmptyView()
            } currentValueLabel: { EmptyView() }
        } else {
            ProgressView(value: min(elapsed, max(duration, 1)), total: max(duration, 1))
        }
    }
}

/// The bar with the time gone on its left and the song's length on its right.
struct Timed: View {
    let isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval, startedAt: Date
    var ink: Color = .white
    var body: some View {
        HStack(spacing: 6) {
            // The total, invisible, sets the width: a running timer takes all
            // the room it's offered and would push the bar off the end.
            Text(clock(duration)).hidden().overlay(alignment: .leading) {
                if isPlaying, duration > 0 {
                    Text(timerInterval: startedAt...startedAt.addingTimeInterval(duration), countsDown: false)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(clock(elapsed))
                }
            }
            Bar(isPlaying: isPlaying, elapsed: elapsed, duration: duration, startedAt: startedAt).tint(ink)
            Text(clock(duration))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(ink.opacity(0.8))
    }
}

struct SongBar: View {
    let song: NowPlayingSnapshot
    var body: some View {
        Bar(isPlaying: song.isPlaying, elapsed: song.elapsed, duration: song.duration, startedAt: song.startedAt)
    }
}

struct TimedBar: View {
    let song: NowPlayingSnapshot
    var ink: Color = .white
    var body: some View {
        Timed(isPlaying: song.isPlaying, elapsed: song.elapsed, duration: song.duration,
              startedAt: song.startedAt, ink: ink)
    }
}

private struct StateBar: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        Timed(isPlaying: state.isPlaying, elapsed: state.elapsed, duration: state.duration, startedAt: state.startedAt)
    }
}
