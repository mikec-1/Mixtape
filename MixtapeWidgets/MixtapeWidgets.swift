// MixtapeWidgets.swift
// The widget extension: a Now Playing widget for the Home and Lock Screens,
// and the Live Activity. Both draw from `NowPlayingSnapshot`, which the app
// writes whenever the song or the play state changes — see NowPlayingSurfaces.

import WidgetKit
import SwiftUI
import AppIntents

@main
struct MixtapeWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let song: NowPlayingSnapshot?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, song: NowPlayingSnapshot(title: "Song", artist: "Artist", isPlaying: false,
                                                              elapsed: 0, duration: 1, at: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, song: NowPlayingSnapshot.load() ?? placeholder(in: context).song))
    }
    /// One entry, never refreshed on a schedule: the app reloads the timeline
    /// itself, and a reload while audio plays doesn't count against the budget.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now, song: NowPlayingSnapshot.load())], policy: .never))
    }
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(song: entry.song)
        }
        .configurationDisplayName("Now Playing")
        .description("What Mixtape is playing, with play, pause and skip.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NowPlayingWidgetView: View {
    let song: NowPlayingSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text(song.map { "\($0.title) · \($0.artist)" } ?? "Mixtape")
        case .accessoryCircular:
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: song?.isPlaying == true ? "pause.fill" : "play.fill").font(.title2)
            }
            .buttonStyle(.plain)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song?.title ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text(song?.artist ?? "Mixtape").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    if let song { SongProgress(song: song) }
                }
                Spacer(minLength: 0)
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Cover(data: song?.artwork, size: 64)
                    Spacer(minLength: 0)
                    PlayButton(isPlaying: song?.isPlaying == true, size: 34)
                }
                Spacer(minLength: 0)
                Titles(song: song)
            }
        default:
            HStack(spacing: 14) {
                Cover(data: song?.artwork, size: 118)
                VStack(alignment: .leading, spacing: 8) {
                    Titles(song: song)
                    if let song { SongProgress(song: song).tint(.white) }
                    Spacer(minLength: 0)
                    HStack(spacing: 22) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        PlayButton(isPlaying: song?.isPlaying == true, size: 38)
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The cover itself, blurred, under a dark scrim: the same wash the app's
    /// Now Playing screen draws, without needing a colour picked for it.
    @ViewBuilder private var background: some View {
        if family == .systemSmall || family == .systemMedium {
            ZStack {
                Color.black
                if let image = song?.artwork.flatMap(UIImage.init(data:)) {
                    Image(uiImage: image).resizable().scaledToFill().blur(radius: 30).opacity(0.7)
                }
                Color.black.opacity(0.25)
            }
        } else {
            AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0)
        }
    }
}

// MARK: - Live Activity

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // Read at draw time: the app saves the snapshot before it updates the
            // activity, and a cover is far past the activity's 4 KB state limit.
            let art = NowPlayingSnapshot.load()?.artwork
            HStack(spacing: 12) {
                Cover(data: art, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(context.state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    StateProgress(state: context.state)
                }
                PlayButton(isPlaying: context.state.isPlaying, size: 36)
            }
            .padding(14)
            .activityBackgroundTint(tint(context.state).opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            let art = NowPlayingSnapshot.load()?.artwork
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Cover(data: art, size: 52) }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayButton(isPlaying: context.state.isPlaying, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 16) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        StateProgress(state: context.state)
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                }
            } compactLeading: {
                Cover(data: art, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(tint(context.state))
            } minimal: {
                Cover(data: art, size: 22)
            }
            .keylineTint(tint(context.state))
        }
    }

    private func tint(_ state: NowPlayingAttributes.ContentState) -> Color {
        guard state.tint.count == 3 else { return .accentColor }
        return Color(red: state.tint[0], green: state.tint[1], blue: state.tint[2])
    }
}

// MARK: - Pieces

private struct Cover: View {
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

private struct Titles: View {
    let song: NowPlayingSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(song?.title ?? "Nothing playing").font(.headline).lineLimit(2)
            Text(song?.artist ?? "Tap to open Mixtape").font(.subheadline).lineLimit(1).opacity(0.75)
        }
        .foregroundStyle(.white)
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let size: CGFloat
    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Runs on its own while playing — WidgetKit animates a timer interval without
/// the app — and sits still while paused.
private struct SongProgress: View {
    let song: NowPlayingSnapshot
    var body: some View {
        Bar(isPlaying: song.isPlaying, elapsed: song.elapsed, duration: song.duration, startedAt: song.startedAt)
    }
}

private struct StateProgress: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        Bar(isPlaying: state.isPlaying, elapsed: state.elapsed, duration: state.duration, startedAt: state.startedAt)
    }
}

private struct Bar: View {
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
