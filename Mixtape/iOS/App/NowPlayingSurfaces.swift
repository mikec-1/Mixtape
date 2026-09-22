// NowPlayingSurfaces.swift
// Keeps the Home/Lock Screen widget and the (opt-in) Live Activity in step with
// the engine. The widget reads a keychain snapshot — see NowPlayingShared.swift.

#if os(iOS)
import Foundation
import Combine
import SwiftUI
import ActivityKit
import WidgetKit

@MainActor
final class NowPlayingSurfaces {
    /// Off by default: iOS already puts a Now Playing player on the Lock Screen
    /// and in the Dynamic Island, and this would sit beside it.
    static let liveActivityKey = "ios.liveActivity"

    private let engine: PlaybackEngine
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<NowPlayingAttributes>?
    /// What the surfaces were last told, for the seek and late-cover checks.
    private var shown: (startedAt: Date, isPlaying: Bool, hasArt: Bool)?
    private var tint: (key: String, rgb: [Double]) = ("", [])
    /// Writes run one after another, so an older song can't land last.
    private var writing: Task<Void, Never>?
    private var liveActivityOn = UserDefaults.standard.bool(forKey: liveActivityKey)

    init(engine: PlaybackEngine, library: LibraryService) {
        self.engine = engine
        // Whatever a previous run left behind is showing a song we don't own any more.
        for stale in Activity<NowPlayingAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        // `playlists` moves when a song is liked — Liked Songs is a playlist.
        engine.$state.combineLatest(engine.queue.$currentIndex, engine.queue.$queue, engine.$duration)
            .combineLatest(library.$playlists, engine.queue.$shuffleEnabled)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        // A seek moves the bar's start; late-arriving artwork fills the cover.
        engine.clock.$currentTime
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, let shown = self.shown, engine.state.isActive else { return }
                let drift = abs(Date().addingTimeInterval(-engine.currentTime).timeIntervalSince(shown.startedAt))
                if (shown.isPlaying && drift > 2) || (!shown.hasArt && engine.queue.currentTrack?.displayArtwork != nil) {
                    self.publish()
                }
            }
            .store(in: &cancellables)
        // Swiped away: an activity outlives its app and would keep counting a
        // song that has stopped. A background-audio app gets a moment here.
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { _ in
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    for activity in Activity<NowPlayingAttributes>.activities {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 1)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let on = UserDefaults.standard.bool(forKey: Self.liveActivityKey)
                guard on != self.liveActivityOn else { return }
                self.liveActivityOn = on
                self.publish()
            }
            .store(in: &cancellables)
    }

    /// Publishes now, skipping the debounce, and waits for the write. For the
    /// widget buttons: the system reloads the widget the moment the intent
    /// returns, and one that reads the old snapshot keeps the old button —
    /// a pause that looked like it hadn't happened.
    func flush() async {
        publish()
        await writing?.value
    }

    private func publish() {
        // Stopped keeps the last song on the widget, paused — a "last played" tile.
        guard let track = engine.queue.currentTrack else { return }
        let art = track.displayArtwork
        let key = "\(track.id)|\(art?.count ?? 0)"
        if key != tint.key { tint = (key, Self.tint(art)) }
        let playing = engine.state.isPlaying && engine.state.isActive
        let snapshot = NowPlayingSnapshot(
            title: track.displayTitle, artist: track.displayArtistName, album: track.albumTitle,
            source: engine.queue.source.displayName, isPlaying: playing,
            isLiked: engine.isLiked?(track) ?? false, shuffle: engine.queue.shuffleEnabled,
            artwork: art, tint: tint.rgb,
            upNext: engine.queue.upcomingRows.prefix(5).map {
                .init(title: $0.track.displayTitle, artist: $0.track.displayArtistName, artwork: $0.track.displayArtwork)
            },
            elapsed: engine.currentTime, duration: engine.duration > 0 ? engine.duration : track.duration, at: Date())
        shown = (snapshot.startedAt, playing, art != nil)
        // Saved before the activity moves: the activity reads its cover from
        // the saved snapshot, and one drawn first shows the placeholder.
        let previous = writing
        writing = Task { [weak self] in
            await previous?.value
            let saved = await Self.write(snapshot)
            self?.updateActivity(saved)
        }
    }

    /// Covers shrunk here, off the main thread: the whole snapshot has to stay
    /// small enough for the extension to decode on every redraw.
    @concurrent private static func write(_ raw: NowPlayingSnapshot) async -> NowPlayingSnapshot {
        var s = raw
        s.artwork = raw.artwork.flatMap { ImageDownsampler.downsampledJPEG(from: $0, maxDimension: 360, compressionQuality: 0.75) }
        for i in s.upNext.indices {
            s.upNext[i].artwork = raw.upNext[i].artwork.flatMap {
                ImageDownsampler.downsampledJPEG(from: $0, maxDimension: 96, compressionQuality: 0.7)
            }
        }
        s.save()
        WidgetCenter.shared.reloadAllTimelines()
        return s
    }

    private func updateActivity(_ s: NowPlayingSnapshot) {
        let state = NowPlayingAttributes.ContentState(
            title: s.title, artist: s.artist, isPlaying: s.isPlaying, elapsed: s.elapsed,
            duration: s.duration, startedAt: s.startedAt, tint: s.tint, hasArtwork: s.artwork != nil)
        // Every song change and seek moves this, so passing it means the app
        // died mid-song (a crash, jetsam): the activity then draws as stopped.
        let staleDate = s.isPlaying && s.duration > 0 ? s.startedAt.addingTimeInterval(s.duration + 5) : nil
        let wanted = liveActivityOn && engine.state.isActive && ActivityAuthorizationInfo().areActivitiesEnabled
        if !wanted {
            if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            activity = nil
        } else if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else if s.isPlaying {
            // Only succeeds while the app is in front; the next foreground play retries.
            activity = try? Activity.request(attributes: NowPlayingAttributes(),
                                             content: ActivityContent(state: state, staleDate: staleDate))
        }
    }

    private static func tint(_ art: Data?) -> [Double] {
        guard let color = ArtworkColors.gradientColors(from: art).first else { return [] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map(Double.init)
    }
}
#endif
