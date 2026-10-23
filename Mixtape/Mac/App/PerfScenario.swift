// TEMP perf scenario. Delete after measuring.
// `-PerfScenario YES` drives the app like a power user in phases, muted and in a private session,
// logs each phase's main thread CPU and frame hitches, then quits. `-HangStacks NO` skips the
// hang monitor's stack captures (they suspend the app). `-PerfImport YES` also imports the
// biggest Spotify playlist not imported yet.

#if os(macOS)
import AppKit
import OSLog
import Darwin
import QuartzCore

@MainActor
enum PerfScenario {

    /// Same seed in every build, so before and after get the same input.
    private static var rng = SplitMix(state: 0x5EED)
    private static var window: NSWindow?
    private static var importRunning = false

    static func run(_ deps: AppDependencies, _ appState: MacAppState) async {
        #if DEBUG || PERFOPT
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "PerfScenario") else { return }
        let library = deps.libraryService
        let engine = deps.playbackEngine
        for _ in 0..<120 where library.tracks.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let playlist = library.playlists.max(by: { $0.trackIDs.count < $1.trackIDs.count }) else { return }
        let tracks = playlist.trackIDs.compactMap { library.track(id: $0) }
        guard tracks.count > 20 else { return }

        let wasPrivate = PrivateSession.isActive
        let wasShuffled = engine.queue.shuffleEnabled
        let volume = engine.volume
        PrivateSession.set(true)
        engine.volume = 0
        window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        window?.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window?.center()
        // Launch work settles first so every run starts from the same place.
        try? await Task.sleep(for: .seconds(30))
        MainThreadActivity.shared.resetCosts()
        MixLog.hangs.info("perf-scenario start, \(tracks.count, privacy: .public) songs")
        let current = { engine.queue.currentTrack ?? tracks[0] }

        await phase("idle") {
            appState.showPlaylist(playlist)
            try? await Task.sleep(for: .seconds(2))
            await engine.play(track: tracks[0], in: tracks)
            try? await Task.sleep(for: .seconds(12))
        }

        await phase("playlist") {
            appState.showPlaylist(playlist)
            try? await Task.sleep(for: .milliseconds(600))
            await scroll(seconds: 8)
            for i in 0..<20 {
                let a = rng.int(tracks.count - 5)
                appState.selectedTrackIDs = Set(tracks[a...(a + rng.int(4))].map(\.id))
                appState.selectionAnchorTrackID = tracks[a].id
                if i % 5 == 0 { appState.isDraggingTracks = true }
                if i % 5 == 2 { appState.isDraggingTracks = false }
                await scroll(seconds: 0.25)
            }
            appState.isDraggingTracks = false
            engine.queue.toggleShuffle()
            await scroll(seconds: 1)
            engine.queue.toggleShuffle()
            appState.showPanel(.queue)
            await scroll(seconds: 2)
            appState.showNowPlaying(for: current())
            await scroll(seconds: 2)
            appState.closePanel()
            await jump(toEnd: true)
            await jump(toEnd: false)
        }

        // Most of these songs aren't fetched yet, so every pick goes through the resolver.
        await phase("skips") {
            for _ in 0..<24 {
                switch rng.int(6) {
                case 0, 1:
                    let pick = tracks[rng.int(tracks.count)]
                    Task { await engine.play(track: pick, in: tracks) }
                case 2: Task { await engine.playNext() }
                case 3: Task { await engine.playPrevious() }
                case 4: engine.seek(to: Double(10 + rng.int(150)))
                default:
                    // Mashing next.
                    for _ in 0..<4 {
                        Task { await engine.playNext() }
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                }
                await scroll(seconds: 1.2)
            }
        }

        await phase("tour") {
            let sections: [MacSidebarItem] = [.home, .library, .songs, .albums, .artists, .playlists, .discover, .community, .settings]
            for item in sections {
                appState.goToSection(item)
                try? await Task.sleep(for: .milliseconds(700))
                await scroll(seconds: 2)
            }
            appState.goToSection(.library)
            for tab in LibraryTab.allCases {
                appState.libraryTab = tab
                try? await Task.sleep(for: .milliseconds(500))
                await scroll(seconds: 1.2)
            }
            for _ in 0..<3 where !library.albums.isEmpty {
                appState.showAlbum(library.albums[rng.int(library.albums.count)])
                try? await Task.sleep(for: .milliseconds(500))
                await scroll(seconds: 1)
            }
            for _ in 0..<3 where !library.artists.isEmpty {
                appState.showArtist(library.artists[rng.int(library.artists.count)])
                try? await Task.sleep(for: .milliseconds(500))
                await scroll(seconds: 1)
            }
            for _ in 0..<3 {
                appState.showPlaylist(library.playlists[rng.int(library.playlists.count)])
                try? await Task.sleep(for: .milliseconds(500))
                await scroll(seconds: 1)
            }
            for _ in 0..<6 {
                appState.goBack()
                try? await Task.sleep(for: .milliseconds(250))
            }
            for _ in 0..<3 {
                appState.goForward()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let names = (0..<3).compactMap { _ in
            library.artists.isEmpty ? nil : library.artists[rng.int(library.artists.count)].name
        } + ["the", "love"]
        await phase("search") {
            for name in names {
                appState.focusSearch()
                appState.searchText = ""
                for n in 1...min(max(name.count, 1), 12) {
                    appState.searchText = String(name.prefix(n))
                    try? await Task.sleep(for: .milliseconds(70 + rng.int(80)))
                }
                appState.showSearchResults()
                try? await Task.sleep(for: .milliseconds(800))
                await scroll(seconds: 1.5)
                appState.searchText = ""
                appState.leaveSearch()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        await phase("panels") {
            for _ in 0..<2 {
                appState.lyricsPresented = true
                try? await Task.sleep(for: .seconds(2))
                appState.lyricsFullscreen.toggle()
                try? await Task.sleep(for: .milliseconds(1500))
                appState.lyricsFullscreen.toggle()
                appState.lyricsPresented = false
                appState.showPanel(.queue)
                await scroll(seconds: 1)
                appState.showPanel(.recent)
                await scroll(seconds: 1)
                appState.showNowPlaying(for: current())
                try? await Task.sleep(for: .milliseconds(800))
                appState.closePanel()
                appState.commandPaletteOpen = true
                try? await Task.sleep(for: .milliseconds(800))
                appState.commandPaletteOpen = false
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        await phase("window") {
            appState.showPlaylist(playlist)
            for _ in 0..<2 { appState.zoomIn(); try? await Task.sleep(for: .milliseconds(600)) }
            await scroll(seconds: 1)
            for _ in 0..<3 { appState.zoomOut(); try? await Task.sleep(for: .milliseconds(600)) }
            appState.resetZoom()
            try? await Task.sleep(for: .milliseconds(600))
            appState.toggleSidebar()
            try? await Task.sleep(for: .milliseconds(800))
            await scroll(seconds: 1)
            appState.toggleSidebar()
            try? await Task.sleep(for: .milliseconds(800))
            await resize(to: CGSize(width: 1100, height: 720))
            await resize(to: CGSize(width: 1720, height: 1040))
            await resize(to: CGSize(width: 1440, height: 900))
        }

        // The floating colour, drawn per pixel on the GPU. Kept on this Mac only.
        await phase("backdrop") {
            let theme = ThemeManager.shared
            let saved = theme.backdrop, writer = theme.backdropWriter
            theme.backdropWriter = nil
            theme.backdrop = MixBackdrop(hex: "#7A3CFF", motion: .floating)
            appState.showPlaylist(playlist)
            try? await Task.sleep(for: .seconds(1))
            await scroll(seconds: 6)
            for item in [MacSidebarItem.home, .discover, .albums] {
                appState.goToSection(item)
                try? await Task.sleep(for: .milliseconds(700))
                await scroll(seconds: 2)
            }
            appState.lyricsPresented = true
            try? await Task.sleep(for: .seconds(2))
            appState.lyricsPresented = false
            MixLog.hangs.info("perf-backdrop still on: \(theme.backdrop != nil, privacy: .public)")
            theme.backdrop = saved
            // Past the debounced push, which reads the writer when it fires.
            try? await Task.sleep(for: .milliseconds(1500))
            theme.backdropWriter = writer
        }

        if defaults.bool(forKey: "PerfImport") { await importPhase(deps, appState, playlist) }

        MixLog.hangs.info("perf-scenario end")
        MainThreadActivity.shared.logReport("perf-scenario")

        engine.pause()
        engine.queue.setShuffle(wasShuffled)
        engine.volume = volume
        if !wasPrivate { PrivateSession.set(false) }
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
        #endif
    }

    /// The import picker's path, while the user keeps browsing.
    private static func importPhase(_ deps: AppDependencies, _ appState: MacAppState, _ playlist: Playlist) async {
        let ledger = deps.spotifyImportLedger
        let token: String, pick: SpotifyLibraryItem
        do {
            token = try await deps.spotifyAuth.validAccessToken()
            let lib = try await deps.spotifyClient.fetchLibrary(accessToken: token)
            guard let biggest = lib.items
                .filter({ $0.kind == .playlist && !ledger.hasImported($0) })
                .max(by: { $0.trackCount < $1.trackCount }) else {
                MixLog.hangs.info("perf-import nothing left to import")
                return
            }
            pick = biggest
        } catch {
            MixLog.hangs.error("perf-import failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        MixLog.hangs.info("perf-import \(pick.name, privacy: .public), \(pick.trackCount, privacy: .public) songs")
        await phase("import") {
            importRunning = true
            let browsing = Task {
                var flip = false
                while importRunning {
                    if flip { appState.showPlaylist(playlist) } else { appState.goToSection(.home) }
                    flip.toggle()
                    try? await Task.sleep(for: .milliseconds(500))
                    await scroll(seconds: 2.5)
                }
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let outcome = await deps.spotifyImportService.migrate([pick], using: deps.spotifyClient, accessToken: token)
            MixLog.hangs.info("perf-import migrate took \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public) ms, \(outcome.songCount, privacy: .public) songs")
            if outcome.completedItemIDs.contains(pick.id) {
                _ = ledger.record(pick, playlistID: outcome.destinations[pick.id],
                                  sourceTrackIDs: outcome.sourceTrackIDs[pick.id])
            }
            // Library work that lands after the import returns.
            try? await Task.sleep(for: .seconds(20))
            importRunning = false
            await browsing.value
        }
    }

    // MARK: - Input

    private static func phase(_ name: String, _ body: () async -> Void) async {
        let meter = FrameMeter(window?.contentView)
        let cpu0 = mainThreadCPU(), proc0 = processCPU(), t0 = CFAbsoluteTimeGetCurrent()
        MixLog.hangs.info("perf-phase \(name, privacy: .public) begin")
        await body()
        meter.stop()
        let secs = CFAbsoluteTimeGetCurrent() - t0
        let main = Int((mainThreadCPU() - cpu0) * 1000), proc = Int((processCPU() - proc0) * 1000)
        MixLog.hangs.info("""
            perf-phase \(name, privacy: .public) end secs=\(Int(secs), privacy: .public) main=\(main, privacy: .public) \
            proc=\(proc, privacy: .public) frames=\(meter.frames, privacy: .public) dropped=\(meter.dropped, privacy: .public) \
            hitch=\(Int(meter.hitch * 1000), privacy: .public) longest=\(Int(meter.longest * 1000), privacy: .public) \
            mem=\(footprintMB(), privacy: .public)
            """)
    }

    /// The page's main scroll view: flicks, reading speed and pauses, turning at the ends.
    private static func scroll(seconds: Double) async {
        let end = CFAbsoluteTimeGetCurrent() + seconds
        guard let sv = biggestScroll() else {
            try? await Task.sleep(for: .seconds(seconds))
            return
        }
        while CFAbsoluteTimeGetCurrent() < end {
            let style = rng.int(10)
            let (step, count): (CGFloat, Int) = style < 5 ? (90, 12) : style < 9 ? (14, 25) : (0, 10)
            for _ in 0..<count where CFAbsoluteTimeGetCurrent() < end {
                if step > 0, sv.window != nil { move(sv, by: step) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static var down = true

    private static func move(_ sv: NSScrollView, by step: CGFloat) {
        let clip = sv.contentView
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - clip.bounds.height)
        var y = clip.bounds.origin.y + (down ? step : -step)
        if y >= maxY { y = maxY; down = false } else if y <= 0 { y = 0; down = true }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
    }

    /// End and Home.
    private static func jump(toEnd: Bool) async {
        guard let sv = biggestScroll() else { return }
        let clip = sv.contentView
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: toEnd ? maxY : 0))
        sv.reflectScrolledClipView(clip)
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// Like dragging the window corner: a frame per display refresh.
    private static func resize(to size: CGSize) async {
        guard let window else { return }
        let from = window.frame
        for i in 1...30 {
            let t = CGFloat(i) / 30
            let w = from.width + (size.width - from.width) * t
            let h = from.height + (size.height - from.height) * t
            window.setFrame(NSRect(x: from.minX, y: from.maxY - h, width: w, height: h), display: true)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// The largest visible scroll view that can scroll.
    private static func biggestScroll() -> NSScrollView? {
        guard let root = window?.contentView else { return nil }
        var best: (NSScrollView, CGFloat)?
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if let sv = v as? NSScrollView,
               (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height + 50 {
                let area = sv.visibleRect.width * sv.visibleRect.height
                if area > (best?.1 ?? 0) { best = (sv, area) }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best?.0
    }

    // MARK: - Meters

    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// What Activity Monitor shows as Memory.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

/// Counts display refreshes the main thread missed. Pinned to 60 Hz so every Mac compares.
private final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var frames = 0, dropped = 0
    private(set) var hitch: CFTimeInterval = 0, longest: CFTimeInterval = 0

    init(_ view: NSView?) {
        super.init()
        guard let view else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { return }
        frames += 1
        let dt = now - last, frame = 1.0 / 60
        longest = max(longest, dt)
        if dt > frame * 1.5 {
            dropped += Int((dt / frame).rounded()) - 1
            hitch += dt - frame
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

private struct SplitMix {
    var state: UInt64
    mutating func int(_ n: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(n, 1)))
    }
}
#endif
