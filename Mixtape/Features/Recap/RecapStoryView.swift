// The monthly recap as a story: slides with 15 second clips under them, ending
// on the share card. The slides are drawn in RecapSlides.swift; this runs them.

import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import Observation

// MARK: - Clock, clips, images

/// Seconds into the current slide. Everything on a slide is drawn from it, so
/// pausing stops it all. Held outside the story's state so a tick only redraws
/// the views that watch it.
@MainActor @Observable final class StoryClock {
    private(set) var elapsed: Double = 0
    @ObservationIgnored private(set) var duration: TimeInterval?
    var progress: Double { duration.map { min(1, elapsed / $0) } ?? 1 }
    @ObservationIgnored var paused = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(for duration: TimeInterval?, onEnd: @escaping () -> Void) {
        task?.cancel()
        elapsed = 0
        self.duration = duration
        task = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                defer { last = now }
                if self.paused { continue }
                self.elapsed += now.timeIntervalSince(last)
                if let duration {
                    if self.elapsed >= duration { onEnd(); return }
                } else if self.elapsed >= RecapChange.total {
                    return // the card only needs its way in
                }
            }
        }
    }

    func stop() { task?.cancel() }
}

/// Clips from the chorus, on their own player so the queue is untouched. A song
/// that carries over to the next slides keeps playing through them.
@MainActor final class RecapClips: ObservableObject {
    @Published private(set) var playing: RecapMath.ClipSong? { didSet { showNowPlaying() } }
    @Published var muted = false { didSet { player.isMuted = muted } }
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            paused ? player.pause() : resumeClip()
            showNowPlaying()
        }
    }

    private let player = AVPlayer()
    private var task: Task<Void, Never>?
    private var warming: Task<Void, Never>?
    private weak var pausedEngine: PlaybackEngine?
    private var plan = Plan()
    /// Songs that wouldn't load, so later slides go straight to their backup.
    private var failed = Set<UUID>()
    /// The main player's lock screen details, put back when the story closes.
    private var mainInfo: [String: Any]?
    private var showingClip = false

    struct Plan: Sendable {
        /// Each slide's songs, best first.
        var picks: [[UUID]] = []
        /// Every candidate by id, for its name.
        var songs: [UUID: RecapMath.ClipSong] = [:]
        /// Songs you don't have, found in the catalogue by name.
        var lookups: [UUID: RecapSnapshot.SpotifyTop.Song] = [:]
    }

    func start(_ plan: Plan, warm: Bool, deps: AppDependencies) {
        self.plan = plan
        guard warm else { return }
        warming = Task { await Self.warm(plan, deps: deps) }
    }

    /// Plays the first of `ids` that loads.
    func play(_ ids: [UUID], for length: Double, deps: AppDependencies) {
        let engine = deps.playbackEngine
        let ids = ids.filter { !failed.contains($0) }
        guard ids.first != playing?.id else {
            // Same song on this slide too. It already runs to the end of the run, and
            // touching the end time while it plays makes it stutter, so only going
            // back a slide stretches it.
            if let item = player.currentItem {
                let end = player.currentTime().seconds + length
                if item.forwardPlaybackEndTime.seconds < end - 0.5 {
                    item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
                }
                if !paused, player.rate == 0 { player.play() }
            }
            return
        }
        task?.cancel()
        // Cleared so a slide arriving mid-load can't restart the old song.
        player.replaceCurrentItem(with: nil)
        playing = ids.first.flatMap { plan.songs[$0] }
        guard !ids.isEmpty else { return }
        task = Task {
            for id in ids {
                playing = plan.songs[id]
                let loaded = await Self.item(for: id, plan: plan, length: length, deps: deps)
                guard !Task.isCancelled else { return }
                guard let (item, start) = loaded else {
                    failed.insert(id)
                    continue
                }
                #if os(iOS)
                // The default category is silenced by the ringer switch and may not be active yet.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                item.forwardPlaybackEndTime = CMTime(seconds: start + length, preferredTimescale: 600)
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                guard !Task.isCancelled else { return }
                if engine.state.isPlaying {
                    engine.pause()
                    pausedEngine = engine
                }
                if !paused { player.play() }
                // Pausing the main player just marked its details paused.
                showNowPlaying()
                return
            }
            playing = nil
        }
    }

    /// Each slide's songs, best first, from songs you actually heard. Ones you don't
    /// have stand in for themselves until the catalogue finds them.
    static func plan(_ r: RecapSnapshot, mine: Bool, tape: Bool, deps: AppDependencies) -> Plan {
        var plan = Plan()
        var pool: [RecapMath.ClipSong] = []
        let saved = RecapClipStore.saved()
        func add(_ song: RecapMath.ClipSong) {
            guard plan.songs[song.id] == nil else { return }
            plan.songs[song.id] = song
            pool.append(song)
        }
        func add(_ id: UUID, title: String, artist: String) {
            if let t = deps.libraryService.track(id: id) {
                let location = AudioLocator.locate(t)
                if case .unavailable = location { return }
                var ready = saved.contains(id)
                if case .ready = location { ready = true }
                add(.init(id: id, title: t.displayTitle, artist: t.displayArtistName, genre: t.genre, ready: ready))
            } else {
                plan.lookups[id] = .init(title: title, artist: artist, image: nil)
                add(.init(id: id, title: title, artist: artist, genre: nil, ready: saved.contains(id)))
            }
        }
        // The month's songs, then everything you've played here.
        let payload = r.featured + (r.played ?? [])
        for song in payload { add(song.trackID, title: song.title, artist: song.artist) }
        if mine {
            for id in deps.recap.songs(in: r.month) + deps.recap.songsByPlays() {
                if let t = deps.libraryService.track(id: id) { add(id, title: t.displayTitle, artist: t.displayArtistName) }
            }
        }
        // Spotify's top list names songs that may not be in the pool yet.
        for song in r.spotifyTop?.songs ?? [] where !pool.contains(where: { RecapMath.clipMatches(song, $0) }) {
            add(RecapService.discoverID(title: song.title, artist: song.artist), title: song.title, artist: song.artist)
        }
        plan.picks = RecapMath.clipPicks(RecapSlide.slides(for: r, tape: tape).map { $0.clipWant(r) }, pool: pool)
        // The greeting plays the cassette's song, so the music runs straight through.
        if plan.picks.count > 1 { plan.picks[0] = plan.picks[1] }
        return plan
    }

    /// Cuts every slide's clip ahead of time, a few at once in slide order, then
    /// their first backups. Ignores the queue's download setting.
    static func warm(_ plan: Plan, deps: AppDependencies) async {
        guard !deps.authService.isOffline else { return }
        RecapClipStore.prune()
        var seen = RecapClipStore.saved()
        let order = (plan.picks.compactMap(\.first) + plan.picks.compactMap { $0.dropFirst().first })
            .filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            for (n, id) in order.enumerated() {
                if n >= 3 { _ = await group.next() }
                guard !Task.isCancelled else { return }
                group.addTask { _ = await cut(id, plan: plan, deps: deps) }
            }
        }
    }

    /// Puts the music back the way the story found it.
    func finish() {
        task?.cancel()
        warming?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
        if showingClip { MPNowPlayingInfoCenter.default().nowPlayingInfo = mainInfo }
        showingClip = false
        pausedEngine?.resume()
        pausedEngine = nil
    }

    private func resumeClip() {
        if playing != nil { player.play() }
    }

    /// The clip on the lock screen and in Control Centre, which also sends the
    /// media keys here when nothing else in the app has played yet.
    private func showNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if !showingClip {
            guard playing != nil else { return }
            showingClip = true
            mainInfo = center.nowPlayingInfo
        }
        center.nowPlayingInfo = playing.map {
            [MPMediaItemPropertyTitle: $0.title, MPMediaItemPropertyArtist: $0.artist,
             MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0]
        }
    }

    // MARK: Loading

    /// Catalogue hits, shared by the Home card and the story. Misses aren't kept.
    private static var found: [UUID: Track] = [:]
    /// Clips being cut, so the story waits for one instead of fetching the song twice.
    private static var cutting: [UUID: Task<URL?, Never>] = [:]

    private static func track(_ id: UUID, plan: Plan, deps: AppDependencies) async -> Track? {
        if let t = deps.libraryService.track(id: id) ?? found[id] { return t }
        guard let song = plan.lookups[id] else { return nil }
        let lead = song.artist.split(separator: ",").first.map(String.init) ?? song.artist
        let hits = await deps.itunesClient.searchPopular(query: "\(lead) \(song.title)", limit: 5)
        guard let hit = hits.first(where: {
            RecapMath.clipMatches(song, .init(id: id, title: $0.trackName, artist: $0.artistName, genre: nil))
        }) else { return nil }
        let t = OnlineTrack(
            title: hit.trackName, artistName: hit.artistName, albumTitle: hit.collectionName ?? "",
            duration: hit.trackTimeMillis.map { TimeInterval($0) / 1000 } ?? 0,
            artworkURL: hit.artworkUrl100.flatMap { URL(string: $0) },
            sourceID: hit.sourceID, isExplicit: hit.isExplicit
        ).asTrack(deviceID: AppDependencies.deviceID)
        found[id] = t
        return t
    }

    /// Downloads the song and keeps its chorus on disk.
    private static func cut(_ id: UUID, plan: Plan, deps: AppDependencies) async -> URL? {
        if let url = RecapClipStore.url(for: id) { return url }
        if let running = cutting[id] { return await running.value }
        let job = Task<URL?, Never> {
            guard let track = await track(id, plan: plan, deps: deps),
                  let file = await localFile(track, deps: deps) else { return nil }
            let start = await chorus(track, length: RecapClipStore.length)
            return await RecapClipStore.save(id, from: file, start: start)
        }
        cutting[id] = job
        defer { cutting[id] = nil }
        return await job.value
    }

    private static func localFile(_ track: Track, deps: AppDependencies) async -> URL? {
        switch AudioLocator.locate(track) {
        case .ready(let url, _):
            return url
        case .remote:
            if let url = try? await deps.fileStorage.download(track: track, accessToken: "") { return url }
            return await deps.onlineCoordinator.clipFile(for: track)?.url
        case .resolvable, .unavailable:
            return await deps.onlineCoordinator.clipFile(for: track)?.url
        }
    }

    /// The saved clip from its start, or the song at its chorus. Nil when it won't load.
    private static func item(for id: UUID, plan: Plan, length: Double, deps: AppDependencies) async -> (AVPlayerItem, Double)? {
        var saved = RecapClipStore.url(for: id)
        if saved == nil, let running = cutting[id] { saved = await running.value }
        if let saved, let item = await playable(StreamResolution(url: saved, videoID: "")) {
            RecapClipStore.touch(saved)
            return (item, 0)
        }
        guard let track = await track(id, plan: plan, deps: deps) else { return nil }
        async let chorus = chorus(track, length: length)
        var item = await playable(await source(track, deps: deps))
        if item == nil { item = await playable(await deps.onlineCoordinator.clipFile(for: track)) }
        guard let item else { return nil }
        return (item, await chorus)
    }

    private static func playable(_ source: StreamResolution?) async -> AVPlayerItem? {
        guard let source else { return nil }
        let options = source.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        let asset = AVURLAsset(url: source.url, options: options)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        return AVPlayerItem(asset: asset)
    }

    private static func source(_ track: Track, deps: AppDependencies) async -> StreamResolution? {
        switch AudioLocator.locate(track) {
        case .ready(let url, _):
            return StreamResolution(url: url, videoID: "")
        case .remote:
            if let url = try? await deps.fileStorage.download(track: track, accessToken: "") {
                return StreamResolution(url: url, videoID: "")
            }
            return await deps.onlineCoordinator.clipSource(for: track)
        case .resolvable, .unavailable:
            return await deps.onlineCoordinator.clipSource(for: track)
        }
    }

    /// The first line sung most often, or a third of the way in without lyrics.
    private static func chorus(_ track: Track, length: Double) async -> Double {
        var seen: [String: (count: Int, time: TimeInterval)] = [:]
        for line in await LyricsService.shared.resolve(for: track).synced {
            let key = line.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            seen[key, default: (0, line.time)].count += 1
        }
        let best = seen.values.filter { $0.count >= 2 }.max { ($0.count, -$0.time) < ($1.count, -$1.time) }
        return max(0, min(best?.time ?? track.duration * 0.35, track.duration - length))
    }
}

/// Story clips cut from the chorus and kept on disk, one per song, so a slide
/// starts the moment it appears.
enum RecapClipStore {
    /// Long enough for a song that carries over a few slides.
    static let length: Double = 40

    static let directory: URL = {
        var dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? URL.documentsDirectory)
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("RecapClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static func url(for id: UUID) -> URL? {
        let file = directory.appendingPathComponent("\(id.uuidString).m4a")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func save(_ id: UUID, from source: URL, start: Double) async -> URL? {
        let file = directory.appendingPathComponent("\(id.uuidString).m4a")
        let temp = directory.appendingPathComponent("\(id.uuidString).part.m4a")
        try? FileManager.default.removeItem(at: temp)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A)
        else { return nil }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        if #available(macOS 15.0, iOS 18.0, *) {
            guard (try? await session.export(to: temp, as: .m4a)) != nil else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
        } else {
            session.outputURL = temp
            session.outputFileType = .m4a
            await withCheckedContinuation { c in session.exportAsynchronously { c.resume() } }
            guard session.status == .completed else { try? FileManager.default.removeItem(at: temp); return nil }
        }
        try? FileManager.default.removeItem(at: file)
        guard (try? FileManager.default.moveItem(at: temp, to: file)) != nil else { return nil }
        return file
    }

    static func saved() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { !$0.hasSuffix(".part.m4a") }.compactMap { UUID(uuidString: String($0.prefix(36))) })
    }

    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Clips nobody has played for two months go.
    static func prune() {
        let old = Date().addingTimeInterval(-60 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (date ?? .distantPast) < old { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func removeAll() {
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Decoded up front so the card can be rendered to an image.
@MainActor final class RecapImages: ObservableObject {
    @Published private(set) var songs: [UUID: PlatformImage] = [:]
    @Published private(set) var artists: [String: PlatformImage] = [:]
    /// Spotify's top list, by image URL.
    @Published private(set) var spotify: [String: PlatformImage] = [:]
    private let store = ProfileArtworkStore()

    func load(_ r: RecapSnapshot, deps: AppDependencies) async {
        let bucket = ArtworkDecodeCache.bucket(forPointSize: 300)
        let ids = r.featured.map(\.trackID)
        for id in Set(ids) {
            if let image = await ArtworkImageLoader.shared.image(for: .row(.track(id)), bucket: bucket) {
                songs[id] = image
            }
        }
        // Songs not in the library (demo mode): search the catalogue for artwork.
        let missing = r.featured.filter { songs[$0.trackID] == nil }
        for song in missing {
            let lead = song.artist.split(separator: ",").first.map(String.init) ?? song.artist
            let hits = await deps.itunesClient.searchPopular(query: "\(lead) \(song.title)", limit: 5)
            let match = hits.first(where: {
                RecapMath.clipMatches(
                    .init(title: song.title, artist: song.artist, image: nil),
                    .init(id: song.trackID, title: $0.trackName, artist: $0.artistName, genre: nil))
            }) ?? hits.first
            if let urlStr = match?.artworkUrl100,
               let url = URL(string: urlStr.replacingOccurrences(of: "100x100", with: "600x600")),
               let image = await RemoteImageCache.shared.image(for: url) {
                songs[song.trackID] = image
            }
        }
        for link in r.spotifyTop?.songs.compactMap(\.image) ?? [] {
            if let url = URL(string: link) { spotify[link] = await RemoteImageCache.shared.image(for: url) }
        }
        let names = r.topArtists.prefix(3).map(\.name)
        await store.resolveArtists(names, library: deps.libraryService, spotify: deps.spotifyClient)
        for name in names {
            switch store.artistImages[name] {
            case .data(let data): artists[name] = ArtworkDecodeCache.shared.image(for: data, bucket: bucket)
            case .remote(let url): artists[name] = await RemoteImageCache.shared.image(for: url)
            case nil: break
            }
        }
    }
}

// MARK: - Story

/// The slide being covered, held still where it was left.
private struct Leaving {
    let index: Int
    let t: Double
    let forward: Bool
}

struct RecapStoryView: View {
    let recap: RecapService.Recap
    /// Nil for your own.
    let owner: UserProfile?
    let startAtCard: Bool
    let onClose: () -> Void

    @Environment(AppDependencies.self) private var deps
    // Not observed here: only the stage and the bars redraw per tick.
    @State private var clock = StoryClock()
    @StateObject private var clips = RecapClips()
    @StateObject private var images = RecapImages()
    @State private var index = 0
    @State private var leaving: Leaving?
    /// The songs under each slide, best first, picked once so going back hears the same one.
    @State private var picks: [[UUID]] = []
    @State private var paused = false
    @State private var held = false
    @State private var holdTask: Task<Void, Never>?
    /// Your own month's tape, looked up once so the slide list can't shift mid-story.
    @State private var tape: SmartPlaylist?
    /// How far the story has been dragged down to close.
    @State private var pull: CGFloat = 0
    @FocusState private var focused: Bool
    /// Everyone gets the full motion until they pick the gentle version here,
    /// whatever the system Reduce Motion says.
    @AppStorage("recap.gentle") private var calm = false

    #if os(macOS)
    private let mac = true
    #else
    private let mac = false
    #endif

    private var r: RecapSnapshot { recap.payload }
    private var slides: [RecapSlide] { RecapSlide.slides(for: r, tape: tape != nil) }
    private var slide: RecapSlide { slides[min(index, slides.count - 1)] }
    private var theme: RecapTheme { slide.theme }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let u = unit(size)
            ZStack {
                SlideStage(clock: clock, index: index, leaving: leaving, change: .into(index), calm: calm,
                           colours: [theme.acc, theme.shape, theme.alt, theme.fg]) { i, t in
                    page(i, t: t, u: u, size: size)
                }
                if slide != .card { tapLayer(width: size.width) }
                if slide == .tape, let tape {
                    RecapTapeButton(theme: theme, mac: mac) {
                        onClose()
                        NotificationCenter.default.post(name: .mixOpenSmartPlaylist, object: tape)
                    }
                    .mixHandCursor()
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(1.9)),
                                            removal: .identity))
                }
                chrome(u: u, size: size)
            }
            .foregroundStyle(theme.fg)
            .offset(y: pull)
            .simultaneousGesture(pullToClose)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .escape]) { press in
            switch press.key {
            case .leftArrow:  back()
            case .rightArrow: if slide != .card { forward() }
            case .space:      if slide != .card { setPaused(!paused) }
            default:          onClose()
            }
            return .handled
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
        .onAppear {
            focused = true
            if owner == nil { tape = deps.smartPlaylistService.tape(year: r.year, month: r.monthNumber) }
            let plan = RecapClips.plan(r, mine: owner == nil, tape: tape != nil, deps: deps)
            picks = plan.picks
            clips.start(plan, warm: !startAtCard, deps: deps)
            index = startAtCard ? slides.count - 1 : 0
            start()
            // Play/pause keys and headphones pause the story rather than the music under it.
            deps.playbackEngine.setupRemoteCommandsIfNeeded()
            deps.playbackEngine.remotePlayPause = { play in
                if slide != .card { setPaused(!(play ?? paused)) }
            }
        }
        .task { await images.load(r, deps: deps) }
        .onDisappear {
            clock.stop()
            clips.finish()
            deps.playbackEngine.remotePlayPause = nil
        }
    }

    private func unit(_ size: CGSize) -> CGFloat {
        mac ? min(size.height * 0.01, size.width * 0.0056) : size.width * 0.01
    }

    private var pictures: RecapPictures {
        RecapPictures(songs: images.songs, artists: images.artists, spotify: images.spotify)
    }

    private func page(_ i: Int, t: Double, u: CGFloat, size: CGSize) -> some View {
        let s = slides[i]
        return ZStack {
            RecapSlidePage(slide: s, r: r, pictures: pictures,
                           name: ownerName, mine: owner == nil, b: RecapBeat(t: t, u: u, calm: calm),
                           size: size, mac: mac)
            if s == .card && i == index {
                RecapCardSlide(recap: recap, isOwner: owner == nil, username: username,
                               images: images, mac: mac, onWatchAgain: { go(0) })
            }
        }
    }

    // MARK: Navigation

    private func go(_ i: Int) {
        guard slides.indices.contains(i) else { return }
        leaving = Leaving(index: index, t: clock.elapsed, forward: i > index)
        index = i
        start()
    }

    private func forward() { go(index + 1) }

    private func back() {
        guard index > 0 else { leaving = nil; start(); return }
        go(index - 1)
    }

    private func start() {
        setPaused(false)
        clock.run(for: slide.duration) { forward() }
        clips.play(pick(index), for: clipLength, deps: deps)
    }

    private func pick(_ i: Int) -> [UUID] { picks.indices.contains(i) ? picks[i] : [] }

    /// This slide and the ones after it that keep the same song.
    private var clipLength: Double {
        let song = pick(index).first
        return slides.indices[index...].prefix { pick($0).first == song }.compactMap { slides[$0].duration }.reduce(0, +) + 1
    }

    private func setPaused(_ p: Bool) {
        paused = p
        clock.paused = p
        clips.paused = p
    }

    /// Tap the left side to go back, the right to go on, the middle to pause. Hold to pause too.
    private func tapLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard holdTask == nil else { return }
                        holdTask = Task {
                            try? await Task.sleep(for: .milliseconds(220))
                            guard !Task.isCancelled else { return }
                            held = true
                            setPaused(true)
                        }
                    }
                    .onEnded { value in
                        holdTask?.cancel()
                        holdTask = nil
                        if held {
                            held = false
                            setPaused(false)
                        } else if hypot(value.translation.width, value.translation.height) > 12 {
                            return
                        } else if value.location.x < width * 0.3 {
                            back()
                        } else if value.location.x > width * 0.7 {
                            forward()
                        } else {
                            setPaused(!paused)
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    /// Drag down to close; the story follows the finger until it goes.
    private var pullToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let t = value.translation
                pull = t.height > abs(t.width) ? max(0, t.height) : 0
            }
            .onEnded { value in
                let t = value.translation
                if t.height > abs(t.width), t.height > 120 || value.predictedEndTranslation.height > 320 {
                    onClose()
                } else {
                    withMixAnimation(.mixSnappy) { pull = 0 }
                }
            }
    }

    // MARK: Share

    /// This slide as it ends at the size it's showing, the card, or the link. Picks up where it was after.
    private func share(size: CGSize) {
        let resume = !paused
        setPaused(true)
        let shot = RecapExport.png(
            RecapSlidePage(slide: slide, r: r, pictures: pictures, name: ownerName, mine: owner == nil,
                           b: RecapBeat(t: 60, u: unit(size), calm: calm), size: size, mac: mac)
                .frame(width: size.width, height: size.height))
        ShareSheet.present(RecapExport.choices(recap, mine: owner == nil, username: username,
                                               theme: RecapCard.themes[0].theme, artists: images.artists,
                                               slide: shot, deps: deps),
                           deps: deps) { if resume { setPaused(false) } }
    }

    // MARK: Chrome

    private func chrome(u: CGFloat, size: CGSize) -> some View {
        ZStack {
            VStack(spacing: mac ? 16 : 12) {
                StoryBars(count: slides.count, index: index, clock: clock, color: theme.fg)
                    .padding(.leading, mac ? 88 : 12)
                    .padding(.trailing, mac ? 24 : 12)
                    .padding(.top, mac ? 18 : 4)
                HStack(spacing: mac ? 4 : 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(owner == nil ? "\(monthName) recap" : "\(ownerName)'s \(monthName) Recap")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.soft)
                            .lineLimit(1)
                        if let song = clips.playing, slide != .card {
                            nowPlaying(song).id(song.id).transition(.opacity)
                        }
                    }
                    Spacer(minLength: 12)
                    iconButton(calm ? "sparkle" : "sparkles",
                               label: calm ? "Play full animations" : "Play gentle animations") { calm.toggle() }
                    if slide != .card {
                        iconButton("forward.end.fill", label: "Skip to summary") { go(slides.count - 1) }
                    }
                    // The summary has its own Share.
                    if slide != .card {
                        iconButton("square.and.arrow.up", label: "Share") { share(size: size) }
                    }
                    iconButton(clips.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                               label: clips.muted ? "Unmute clips" : "Mute clips") { clips.muted.toggle() }
                    if slide != .card {
                        iconButton(paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause") {
                            setPaused(!paused)
                        }
                    }
                    iconButton("xmark", label: "Close recap", action: onClose)
                }
                .padding(.leading, 24 - (mac ? 0 : 8))
                .padding(.trailing, mac ? 16 : 8)
                Spacer()
            }

            if paused && slide != .card {
                Text("Paused")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(theme.fg.opacity(0.16), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.25), value: clips.playing?.id)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: mac ? 36 : 33, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .help(label)
        .accessibilityLabel(label)
    }

    /// The clip under the slide, like a song on a story.
    private func nowPlaying(_ song: RecapMath.ClipSong) -> some View {
        HStack(spacing: 6) {
            EqBars(active: !paused && !clips.muted, color: theme.fg)
                .frame(width: 11, height: 9)
            Text("\(Text(song.title).foregroundStyle(theme.fg)) · \(song.artist)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.soft)
                .lineLimit(1)
        }
        .opacity(clips.muted ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing \(song.title) by \(song.artist)")
    }

    private var monthName: String { Calendar.current.monthSymbols[r.monthNumber - 1] }

    private var ownerName: String {
        let name = owner?.name ?? deps.authService.currentUser?.displayName ?? ""
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var username: String {
        owner?.username ?? deps.authService.currentUser?.username ?? ownerName.lowercased()
    }
}

// MARK: - Pieces

/// The current slide, and while it's coming in, the one it's covering.
private struct SlideStage<Page: View>: View {
    var clock: StoryClock
    let index: Int
    let leaving: Leaving?
    let change: RecapChange
    /// Reduce Motion: a crossfade instead.
    let calm: Bool
    /// The new slide's, for the bands.
    let colours: [Color]
    let page: (Int, Double) -> Page

    var body: some View {
        let t = clock.elapsed
        let from = leaving.flatMap { t < RecapChange.total ? $0 : nil }
        ZStack {
            if let from {
                page(from.index, from.t)
                if !calm {
                    RecapChange.Edges(change: change, t: t, forward: from.forward, colours: colours)
                        .padding(-150)
                        .allowsHitTesting(false)
                }
            }
            page(index, t)
                .id(index)
                .mask {
                    if let from, !calm {
                        RecapChange.Mask(change: change, t: t, forward: from.forward).padding(-150)
                    } else {
                        Color.black.padding(-150)
                    }
                }
                .opacity(from != nil && calm ? min(1, t / 0.4) : 1)
        }
    }
}

private struct StoryBars: View {
    let count: Int
    let index: Int
    var clock: StoryClock
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                GeometryReader { g in
                    Capsule().fill(color.opacity(0.28))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color)
                                .frame(width: g.size.width * (i < index ? 1 : i == index ? clock.progress : 0))
                        }
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Slide \(index + 1) of \(count)")
    }
}

private struct EqBars: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach([0.0, 0.4, 0.7, 0.2], id: \.self) { phase in
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color)
                            .frame(height: g.size.height * (0.25 + 0.75 * (0.5 - 0.5 * cos(2 * .pi * (t + phase)))))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// An artist photo in a circle, or their initials.
struct ArtistDisc: View {
    let image: PlatformImage?
    let name: String
    let size: CGFloat
    let font: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: "5A5A66"), Color(hex: "26262C")],
                                         center: UnitPoint(x: 0.34, y: 0.28), startRadius: 0, endRadius: size * 0.72))
                    .overlay {
                        Text(Self.initials(name))
                            .font(.system(size: font, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

// MARK: - Presenter

/// Full screen cover on iOS; on the Mac the story covers the window.
struct RecapPresenter: View {
    @Bindable var recap: RecapService
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        #if os(macOS)
        ZStack {
            if let r = recap.presented {
                story(r).ignoresSafeArea().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: recap.presented?.month)
        #else
        Color.clear
            // Clear, so dragging the story down shows the app under it.
            .fullScreenCover(item: $recap.presented) { story($0).environment(deps).presentationBackground(.clear) }
        #endif
    }

    private func story(_ r: RecapService.Recap) -> some View {
        RecapStoryView(recap: r, owner: recap.presentedOwner, startAtCard: recap.presentedAtCard) {
            recap.presented = nil
        }
        .id(r.month)
    }
}

extension Notification.Name {
    /// Posted with a `SmartPlaylist` for whichever window is showing to open it.
    static let mixOpenSmartPlaylist = Notification.Name("mix.openSmartPlaylist")
}
