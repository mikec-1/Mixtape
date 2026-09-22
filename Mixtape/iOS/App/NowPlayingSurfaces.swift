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
    private var last: NowPlayingSnapshot?
    private var liveActivityOn = UserDefaults.standard.bool(forKey: liveActivityKey)

    init(engine: PlaybackEngine) {
        self.engine = engine
        // Whatever a previous run left behind is showing a song we don't own any more.
        for stale in Activity<NowPlayingAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        engine.$state.combineLatest(engine.queue.$currentIndex, engine.queue.$queue, engine.$duration)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        // A seek moves the bar's start; late-arriving artwork fills the cover.
        engine.clock.$currentTime
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, let last = self.last, engine.state.isActive else { return }
                let drift = abs(Date().addingTimeInterval(-engine.currentTime).timeIntervalSince(last.startedAt))
                if (last.isPlaying && drift > 2) || (last.artwork == nil && engine.queue.currentTrack?.displayArtwork != nil) {
                    self.publish()
                }
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

    private func publish() {
        // Stopped keeps the last song on the widget, paused — a "last played" tile.
        guard let track = engine.queue.currentTrack else { return }
        let art = track.displayArtwork
        let playing = engine.state.isPlaying && engine.state.isActive
        let snapshot = NowPlayingSnapshot(
            title: track.displayTitle, artist: track.displayArtistName, isPlaying: playing,
            artwork: art.flatMap { ImageDownsampler.downsampledJPEG(from: $0, maxDimension: 200, compressionQuality: 0.7) },
            elapsed: engine.currentTime, duration: engine.duration > 0 ? engine.duration : track.duration, at: Date())
        let artChanged = (last?.artwork == nil) != (snapshot.artwork == nil) || last?.title != snapshot.title
        last = snapshot
        Task { await Self.write(snapshot) }
        updateActivity(snapshot, tint: artChanged || activity == nil ? Self.tint(art) : activity?.content.state.tint ?? [])
    }

    @concurrent private static func write(_ snapshot: NowPlayingSnapshot) async {
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func updateActivity(_ s: NowPlayingSnapshot, tint: [Double]) {
        let state = NowPlayingAttributes.ContentState(
            title: s.title, artist: s.artist, isPlaying: s.isPlaying, elapsed: s.elapsed,
            duration: s.duration, startedAt: s.startedAt, tint: tint)
        let wanted = liveActivityOn && engine.state.isActive && ActivityAuthorizationInfo().areActivitiesEnabled
        if !wanted {
            if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            activity = nil
        } else if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else if s.isPlaying {
            // Only succeeds while the app is in front; the next foreground play retries.
            activity = try? Activity.request(attributes: NowPlayingAttributes(),
                                             content: ActivityContent(state: state, staleDate: nil))
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
