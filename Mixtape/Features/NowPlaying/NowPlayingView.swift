// Full-screen player sheet. State comes from PlaybackEngine and QueueService.

import SwiftUI

public struct NowPlayingView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @Environment(\.dismiss)  private var dismiss

    /// Lyrics resolution + caching.
    @StateObject private var lyricsService = LyricsService.shared

    /// Ambient background colours derived from current artwork.
    @State private var ambientColors: [Color] = ArtworkColors.brandGradient

    @State private var isLoadingLyrics = false
    /// Per-song lyrics timing, shared with karaoke and the Mac.
    @State private var lyricsOffset: TimeInterval = 0

    /// Read straight from the service (`cache` is `@Published`) so saved lyrics show immediately.
    private var lyrics: TrackLyrics? {
        guard let track = queueService.currentTrack else { return nil }
        return lyricsService.cached(for: track)
    }

    /// Sheets / panels.
    @State private var showLyrics  = false
    @State private var showUpNext  = false
    @State private var showGetInfo = false
    @State private var showLyricsEditor = false
    @State private var showLyricCard = false
    @State private var editTrack: Track?
    @State private var postTrack: Track?
    #if os(iOS)
    /// Karaoke: the same synced lyrics, full screen, at singing size.
    @State private var showKaraoke = false
    #endif

    private var karaokeIsShowing: Bool {
        #if os(iOS)
        return showKaraoke
        #else
        return false
        #endif
    }

    /// Drives the swipe-to-skip slide transition on the artwork.
    @State private var artworkSlide: CGFloat = 0

    /// How far the player has been pulled down towards dismissal (iOS).
    @State private var dismissOffset: CGFloat = 0

    /// The song being fetched, if any. Mirrored into state since nothing here observes the coordinator.
    @State private var preparing: OnlinePlaybackCoordinator.PreparingTrack?

    public var body: some View {
        ZStack {
            ambientBackground
            content
                #if os(iOS)
                // `.gesture` so the seek bar and artwork drags win; artwork forwards vertical drags.
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20)
                    .onChanged(trackDismissDrag)
                    .onEnded(endDismissDrag))
                #endif
        }
        .offset(y: dismissOffset)
        // The wash is clamped dark, so the player is always dark. Applied before the sheets so they keep the app's scheme.
        .environment(\.colorScheme, .dark)
        // React to track changes: refresh ambient colours + lyrics.
        .onChange(of: queueService.currentTrack?.id) { _, _ in
            refreshForCurrentTrack()
        }
        .onAppear { refreshForCurrentTrack() }
        .onReceive(deps.onlineCoordinator.$preparing) { preparing = $0 }
        #if os(iOS)
        // Karaoke has its own timing control; pick up what it left.
        .fullScreenCover(isPresented: $showKaraoke, onDismiss: refreshForCurrentTrack) {
            if let lyrics, lyrics.hasSynced {
                KaraokeView(lines: lyrics.synced)
                    .environmentObject(engine)
                    .environmentObject(queueService)
            }
        }
        #endif
        .sheet(isPresented: $showUpNext) {
            UpNextSheet()
                .environmentObject(engine)
        }
        .sheet(isPresented: $showLyricsEditor, onDismiss: refreshForCurrentTrack) {
            if let track = queueService.currentTrack {
                LyricsEditorSheet(track: track)
            }
        }
        .sheet(isPresented: $showLyricCard) {
            if let track = queueService.currentTrack, let lyrics, lyrics.hasAny {
                LyricCardSheet(track: track, lyrics: lyrics)
                    .environmentObject(deps)
            }
        }
        .sheet(isPresented: $showGetInfo) {
            if let track = queueService.currentTrack {
                GetInfoSheet(
                    track: track,
                    isOnline: deps.onlineCoordinator.hasActiveOnlineSession
                )
            }
        }
        .sheet(item: $editTrack) { track in
            SongEditor(track: track, onOpenPost: { code in
                #if os(iOS)
                iosAppState.openPost(code: code)
                #endif
            })
            .environmentObject(deps)
        }
        .sheet(item: $postTrack) { track in
            PostSheet(track: track, onOpen: { code in
                #if os(iOS)
                iosAppState.openPost(code: code)
                #endif
            })
            .environmentObject(deps)
        }
    }

    // MARK: - Ambient Background

    /// The cover blurred across the top, fading into its colour, then the page.
    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: ambientColors.first ?? .mixBackground, location: 0),
                        .init(color: ambientColors.last ?? .mixBackground, location: 0.55),
                        .init(color: .mixBackground, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .mixAnimation(.easeInOut(duration: 0.8), value: ambientColors)

                if let data = queueService.currentTrack?.displayArtwork,
                   let image = mixImage(from: data, displaySize: 120) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height * 0.62)
                        .clipped()
                        .blur(radius: 48, opaque: true)
                        .opacity(0.55)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.65), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .id(queueService.currentTrack?.id)
                        .transition(.opacity)
                }

                // Keeps white type readable over a bright cover.
                LinearGradient(colors: [.black.opacity(0.3), .clear, .black.opacity(0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Flattened once so the blur isn't recomposited on every seek tick.
            .gpuRendered()
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 16).frame(maxHeight: 40)
            // One square for artwork and lyrics so toggling moves nothing. Priority keeps the spacers from shrinking it.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if showLyrics { lyricsPanel } else { artworkView }
                }
                .layoutPriority(1)
            trackInfo
                .padding(.top, 40)
                .padding(.bottom, 18)
            // The fetch progress replaces the seek bar while waiting.
            if let preparing {
                preparingStrip(preparing)
                    .frame(minHeight: 44)
                    .transition(.opacity)
            } else {
                seekBar
                    .transition(.opacity)
            }
            controls
                .padding(.top, 8)
            // The only flexible gap.
            Spacer(minLength: 12)
            bottomRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .mixAnimation(.easeInOut(duration: 0.2), value: preparing == nil)
    }

    // MARK: - Preparing

    /// Shown instead of the seek bar while the next song is fetched, with a cancel.
    private func preparingStrip(_ preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        VStack(spacing: 8) {
            PreparingProgressTrack(fraction: preparing.progress.fraction)

            HStack(spacing: 6) {
                Text(preparing.phaseLabel)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)

                // Only with real progress behind it.
                if let fraction = preparing.progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.mixCaptionBold)
                        .foregroundStyle(Color.mixTextSecondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                Button("Stop") { deps.onlineCoordinator.cancelPreparing() }
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel("Stop preparing this song")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(preparing.title), \(preparing.phaseLabel)")
    }

    // MARK: - Top Bar

    /// chevron.down (dismiss) · context label · ellipsis (••• menu).
    private var topBar: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityLabel("Close")

            Spacer()

            Text(sourceName)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .accessibilityLabel("Playing from \(sourceName)")

            Spacer()

            optionsMenu
        }
        .padding(.top, 8)
    }

    private var sourceName: String {
        queueService.source.displayName
            ?? (deps.onlineCoordinator.hasActiveOnlineSession ? "Discover" : "Library")
    }

    // MARK: - Options (•••) Menu

    private var optionsMenu: some View {
        Menu {
            // Only for songs in the library; `toggleFavourite` won't act on anything else.
            if let track = queueService.currentTrack,
               deps.libraryService.track(id: track.id) != nil {
                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                Button {
                    deps.toggleFavourite(trackID: track.id)
                } label: {
                    Label(favoured ? "Remove from Liked Songs" : "Add to Liked Songs",
                          systemImage: favoured ? "heart.slash" : "heart")
                }
            }

            if let track = queueService.currentTrack {
                let targetPlaylists = deps.libraryService.playlists.filter {
                    !$0.isAllSongs && !$0.isDeleted && !$0.trackIDs.contains(track.id)
                }
                if !targetPlaylists.isEmpty {
                    Menu("Add to Playlist") {
                        ForEach(targetPlaylists) { pl in
                            Button(pl.name) {
                                deps.addTrack(id: track.id, toPlaylist: pl.id)
                            }
                        }
                    }
                }
            }

            if deps.onlineCoordinator.hasActiveOnlineSession,
               let onlineTrack = deps.onlineCoordinator.currentOnlineTrack {
                Button {
                    Task {
                        await deps.onlineCoordinator.addToLibrary(onlineTrack)
                        deps.showSavedToast(.library)
                    }
                } label: {
                    Label("Add to Liked Songs", systemImage: "heart")
                }
            }

            if let track = queueService.currentTrack, deps.onlineCoordinator.canReResolve(track) {
                Button { Task { await deps.reResolve(track) } } label: {
                    Label("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Divider()

            Menu("Playback Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        engine.setRate(Float(rate))
                    } label: {
                        Label(
                            speedLabel(rate),
                            systemImage: abs(Double(engine.playbackRate) - rate) < 0.01 ? "checkmark" : ""
                        )
                    }
                }
            }

            Menu("Sleep Timer") {
                if engine.sleepTimerRemaining != nil {
                    Button(role: .destructive) {
                        engine.cancelSleepTimer()
                    } label: {
                        Label("Cancel Timer", systemImage: "xmark")
                    }
                    Divider()
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) min") {
                        engine.setSleepTimer(TimeInterval(minutes * 60))
                    }
                }
            }

            Menu("Crossfade") {
                ForEach(CrossfadeMode.allCases) { mode in
                    Button {
                        engine.setCrossfadeMode(mode)
                    } label: {
                        Label(
                            mode.title,
                            systemImage: engine.crossfadeMode == mode ? "checkmark" : ""
                        )
                    }
                }
            }

            Divider()

            if let track = queueService.currentTrack, track.canEdit {
                Button {
                    editTrack = track
                } label: {
                    Label("Edit Song…", systemImage: "slider.horizontal.3")
                }
            }
            if let track = queueService.currentTrack, track.edit != nil {
                Button {
                    postTrack = track
                } label: {
                    Label("Post…", systemImage: "paperplane")
                }
            }

            Button {
                showGetInfo = true
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data = queueService.currentTrack?.displayArtwork,
               let image = mixImage(from: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.mixSurface2
                    .overlay(
                        Image(systemName: MixtapeIcons.track)
                            .font(.system(size: 72))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mixShadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .scaleEffect(engine.state.isPlaying ? 1.0 : 0.94)
        .offset(x: artworkSlide)
        // Not a token: the bounce on play is the point.
        .mixAnimation(.spring(response: 0.45, dampingFraction: 0.7), value: engine.state.isPlaying)
        .gesture(
            DragGesture(minimumDistance: 30)
                #if os(iOS)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) { trackDismissDrag(value) }
                }
                #endif
                .onEnded { value in
                    #if os(iOS)
                    if abs(value.translation.height) > abs(value.translation.width) { return endDismissDrag(value) }
                    #endif
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < -50 {
                        // Swipe left -> next.
                        withMixAnimation(.easeInOut(duration: 0.18)) { artworkSlide = -320 }
                        Task {
                            await engine.playNext()
                            artworkSlide = 320
                            withMixAnimation(.mixSoft) { artworkSlide = 0 }
                        }
                    } else if value.translation.width > 50 {
                        // Swipe right -> previous.
                        withMixAnimation(.easeInOut(duration: 0.18)) { artworkSlide = 320 }
                        Task {
                            await engine.playPrevious()
                            artworkSlide = -320
                            withMixAnimation(.mixSoft) { artworkSlide = 0 }
                        }
                    }
                }
        )
    }

    // MARK: - Pull to dismiss

    private func trackDismissDrag(_ value: DragGesture.Value) {
        dismissOffset = max(0, value.translation.height)
    }

    private func endDismissDrag(_ value: DragGesture.Value) {
        if value.translation.height > 140 || value.predictedEndTranslation.height > 500 {
            dismiss()
        } else {
            withMixAnimation(.mixSoft) { dismissOffset = 0 }
        }
    }

    // MARK: - Lyrics Panel

    private var lyricsPanel: some View {
        VStack(spacing: 0) {
            if isLoadingLyrics {
                Spacer()
                ProgressView()
                    .tint(Color.mixTextSecondary)
                Spacer()
            } else if let lyrics, lyrics.hasSynced {
                SyncedLyricsView(lines: lyrics.synced, clock: engine.clock,
                                 isPlaying: engine.state.isPlaying,
                                 onTapLine: { engine.seek(to: $0) },
                                 offset: lyricsOffset)
                #if os(iOS)
                // Synced lyrics only.
                Button {
                    Haptics.play(.light)
                    showKaraoke = true
                } label: {
                    Label("Karaoke", systemImage: "music.mic")
                        .font(.system(size: MixFontScale.size(13), weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.mixSurface2, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).mixHandCursor()
                .padding(.top, 10)
                #endif
            } else if let plain = lyrics?.plain, !plain.isEmpty {
                ScrollView {
                    Text(plain)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.mixTextTertiary)
                    Text("No lyrics found")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                    // All sources came back empty, so offer to add lyrics by hand.
                    if queueService.currentTrack != nil {
                        lyricsEditorButton("Add Lyrics")
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Found lyrics can be wrong too, so the edit button stays available.
        .overlay(alignment: .topTrailing) {
            if let track = queueService.currentTrack, let lyrics, lyrics.hasAny {
                HStack(spacing: 6) {
                    LyricsSourceBar(track: track, lyrics: lyrics, offset: $lyricsOffset)
                    Spacer(minLength: 0)
                    lyricsPill("Share", icon: MixtapeIcons.share) { showLyricCard = true }
                    lyricsEditorButton(lyrics.isUserProvided ? "Edit" : "Fix", compact: true)
                }
                .padding(.top, 2)
            }
        }
    }

    /// The one control that opens the editor, in its two sizes.
    private func lyricsEditorButton(_ title: String, compact: Bool = false) -> some View {
        lyricsPill(title, icon: "square.and.pencil", compact: compact) { showLyricsEditor = true }
    }

    private func lyricsPill(_ title: String, icon: String, compact: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                Text(title)
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
            }
            .foregroundStyle(compact ? Color.mixTextTertiary : Color.mixTextPrimary)
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 5 : 8)
            .background(Color.mixSurface2.opacity(compact ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
    }

    // MARK: - Track Info

    private var trackInfo: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showGetInfo = true
                } label: {
                    // Long titles scroll rather than truncate.
                    MarqueeText(text: displayTitle,
                                font: .mixTitle.weight(.bold),
                                color: .mixTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()

                HStack(spacing: 6) {
                    if queueService.currentTrack?.isExplicit == true { MixExplicitBadge() }
                    if queueService.currentTrack?.origin == .edit { MixEditBadge() }
                    artistLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            // Library membership. Liking lives in the "..." menu.
            if let track = queueService.currentTrack {
                NowPlayingSaveButton(trackID: track.id, size: 26)
            }
        }
    }

    // MARK: - Artist Line

    /// The title as printed. While a song is being fetched, names that song.
    private var displayTitle: String {
        ImportService.bareTitle(preparing?.title ?? queueService.currentTrack?.title ?? "—")
    }

    /// The printed credit: stored artist plus features named in the title.
    /// Get Info shows the stored field instead.
    private var displayCredit: [String] {
        if let preparing {
            return ImportService.displayArtists(title: preparing.title,
                                                artistName: preparing.artist)
        }
        guard let track = queueService.currentTrack else { return [] }
        return ImportService.displayArtists(title: track.title, artistName: track.artistName)
    }

    /// The artist line. Each parsed artist is a tap target on iOS, plain text
    /// elsewhere. Long credits scroll as one row.
    @ViewBuilder
    private var artistLine: some View {
        #if os(iOS)
        // Same slow scroll as the mini player's credit.
        MarqueeScroller(identity: displayCredit.joined(separator: ", "), speed: 15) {
            TappableArtistRow(targets: artistTargets, font: .mixBody, color: .mixTextSecondary)
        }
        .accessibilityLabel(displayCredit.joined(separator: ", "))
        #else
        MarqueeText(text: displayCredit.joined(separator: ", "),
                    font: .mixBody,
                    color: .mixTextSecondary,
                    speed: 15)
        #endif
    }

    #if os(iOS)
    /// One tap target per artist, each dismissing the sheet and opening its
    /// Discover page, like the mini player and macOS.
    private var artistTargets: [(name: String, action: (() -> Void)?)] {
        guard queueService.currentTrack != nil else { return [("", nil)] }
        return displayCredit.map { name in
            (name, {
                dismiss()
                iosAppState.openOnlineArtist(name: name)
            })
        }
    }
    #endif

    // MARK: - Seek Bar

    private var seekBar: some View {
        NowPlayingSeekBar(clock: engine.clock, duration: engine.duration) { time in
            engine.seek(to: time)
        }
    }

    // MARK: - Bottom Row (Output · Lyrics · Share · Queue)

    private var bottomRow: some View {
        HStack(spacing: 0) {
            #if os(iOS)
            // One control: the glyph on the built-in speaker, otherwise the output's name. Opens the picker.
            DevicesButton(continuity: deps.continuity,
                          downloads: deps.downloadManager, size: 20, showsName: true)
            #endif

            Spacer(minLength: 8)

            NPButton(icon: "quote.bubble", label: "Lyrics",
                     isActive: showLyrics || karaokeIsShowing, size: 20) {
                #if os(iOS)
                // Synced lyrics go straight to karaoke.
                if lyrics?.hasSynced == true {
                    showKaraoke = true
                    return
                }
                #endif
                withMixAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() }
            }

            if let track = queueService.currentTrack {
                Button { ShareSheet.present(.track(track), deps: deps) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.mixTextPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share")
            }

            if let track = queueService.currentTrack, track.canEdit {
                NPButton(icon: "slider.horizontal.3", label: "Edit Song", size: 20) {
                    editTrack = track
                }
            }

            NPButton(icon: MixtapeIcons.queue, label: "Queue", size: 20) {
                showUpNext = true
            }
        }
    }

    // MARK: - Playback Controls

    private var controls: some View {
        // spacing: 0 with flexible Spacers. Spacing on top of the Spacers pushes the row off-screen.
        HStack(spacing: 0) {
            NPButton(icon: MixtapeIcons.shuffle, label: "Shuffle",
                     isActive: queueService.shuffleEnabled, size: 22) {
                engine.queue.toggleShuffle()
            }

            Spacer(minLength: 8)

            NPButton(icon: MixtapeIcons.skipBack, label: "Previous", size: 30) {
                Task { await engine.playPrevious() }
            }

            Spacer(minLength: 8)

            Button {
                engine.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                    if engine.state == .loading {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: engine.state.isPlaying ? MixtapeIcons.pause : MixtapeIcons.play)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: engine.state.isPlaying ? 0 : 2)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(engine.state == .loading)
            .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 8)

            NPButton(icon: MixtapeIcons.skipForward, label: "Next", size: 30) {
                Task { await engine.playNext() }
            }

            Spacer(minLength: 8)

            NPButton(icon: queueService.repeatSystemImage,
                     label: queueService.repeatLabel,
                     isActive: queueService.repeatMode != .off, size: 22) {
                engine.queue.cycleRepeat()
            }
        }
    }

    // MARK: - Track-change side effects

    private func refreshForCurrentTrack() {
        // Ambient colours from artwork (cheap, synchronous).
        ambientColors = mixMainActivity("now-playing/ambient-colours") {
            let wash = ArtworkColors.gradientColors(from: queueService.currentTrack?.displayArtwork)
            return wash.isEmpty ? ArtworkColors.brandGradient : wash
        }

        // Cached lyrics are already on screen; this only decides whether to fetch and show a spinner.
        guard let track = queueService.currentTrack else {
            isLoadingLyrics = false
            lyricsOffset = 0
            return
        }
        lyricsOffset = LyricsOffsets.get(for: track)
        // Plain or missing results still try to upgrade to synced. The user's own lyrics are exempt.
        let cached = lyricsService.cached(for: track)
        if let cached, cached.hasSynced || cached.isUserProvided {
            isLoadingLyrics = false
            return
        }

        isLoadingLyrics = (cached == nil)
        Task {
            await lyricsService.resolve(for: track)
            // The result is cached under its own track, so a track change underneath is harmless.
            isLoadingLyrics = false
        }
    }

    // MARK: - Helpers

    private func speedLabel(_ rate: Double) -> String {
        if rate == 1.0 { return "1x" }
        // Trim trailing zeros: 0.5 -> "0.5x", 1.25 -> "1.25x"
        let str = String(format: "%g", rate)
        return "\(str)x"
    }
}

// MARK: - Seek Bar

/// The slider and time labels, split out so clock ticks only redraw this.
/// See `PlaybackClock`. `seek(to:)` writes through, so drag state stays local.
struct NowPlayingSeekBar: View {

    @ObservedObject var clock: PlaybackClock
    @EnvironmentObject private var engine: PlaybackEngine
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// The drag while scrubbing, the clock otherwise.
    private var shown: Double { isScrubbing ? scrubValue : clock.currentTime }

    private var fraction: Double {
        duration > 0 ? min(max(shown / duration, 0), 1) : 0
    }

    /// Thin track and a small knob that grows while held.
    var body: some View {
        VStack(spacing: -8) {
            GeometryReader { geo in
                let knob: CGFloat = isScrubbing ? 16 : 12
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white)
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: isScrubbing ? 6 : 4)
                .overlay {
                    CommentDots(queue: engine.queue, duration: duration, color: .mixPrimary)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .offset(x: geo.size.width * fraction - knob / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let x = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                            scrubValue = x * duration
                        }
                        .onEnded { _ in
                            onSeek(scrubValue)
                            isScrubbing = false
                        }
                )
                .mixAnimation(.easeOut(duration: 0.15), value: isScrubbing)
            }
            // Tall enough to hit; the times tuck up under it.
            .frame(height: 44)

            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(0, duration - shown)))
            }
            .font(.mixCaption)
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.65))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(shown)) of \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, clock.currentTime + 10))
            case .decrement: onSeek(max(0, clock.currentTime - 10))
            @unknown default: break
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Synced Lyrics View

/// Auto-scrolling synced lyrics with the active line highlighted. Used by the
/// Now Playing panel and karaoke; only type and colours differ.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    /// Observed directly so clock ticks redraw only this. See `PlaybackClock`.
    @ObservedObject var clock: PlaybackClock
    /// Stops the per-frame sweep redrawing a line that isn't moving.
    let isPlaying: Bool
    let onTapLine: (TimeInterval) -> Void

    /// Karaoke draws white over the wash; the panel sits on the app surface.
    var lineFont: Font = .mixBody
    var activeFont: Font = .mixBody.weight(.bold)
    var sung: Color = .mixTextPrimary
    var unsung: Color = Color.mixTextSecondary.opacity(0.6)
    var gapSize: CGFloat = 26
    var lineSpacing: CGFloat = 14
    /// Per-song timing correction, in seconds: positive holds the lyrics back.
    var offset: TimeInterval = 0
    /// Inset inside the scroll view so the active line's glow isn't clipped.
    var hPadding: CGFloat = 0

    /// Per-word spans, cached in state since the body runs on every clock tick.
    @State private var words: [[LyricWord]] = []
    @AppStorage(LyricsSourceBar.byLineKey) private var byLine = false

    private var activeIndex: Int? {
        // No lead (see `MacSyncedLyrics.activeIndex`): a line holds until the next starts.
        let now = clock.interpolatedTime() - offset
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= now { idx = i } else { break }
        }
        return idx
    }

    /// See `MacSyncedLyrics.scrollTarget`: the dots hold the view during instrumentals.
    private var scrollTarget: String? {
        let next = (activeIndex ?? -1) + 1
        if next < lines.count,
           let gap = LyricSync.instrumentalGap(before: next, lines: lines, words: words) {
            let now = clock.interpolatedTime() - offset
            if now >= gap.start, now < gap.end { return "gap-\(next)" }
        }
        guard let idx = activeIndex else { return nil }
        return "line-\(idx)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lineSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        // Only while the gap is playing, plus a short lead-in for the animation.
                        if let gap = LyricSync.instrumentalGap(before: i, lines: lines, words: words),
                           clock.currentTime - offset >= gap.start - 0.2,
                           clock.currentTime - offset < gap.end {
                            TimelineView(.animation(paused: !isPlaying)) { _ in
                                LyricGapDots(start: gap.start, end: gap.end,
                                             time: clock.interpolatedTime() - offset,
                                             color: sung,
                                             fontSize: gapSize)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("gap-\(i)")
                        }
                        let isActive = (i == activeIndex)
                        Group {
                            if isActive, !byLine, i < words.count, !words[i].isEmpty {
                                // Only the active line sweeps word by word.
                                TimelineView(.animation(paused: !isPlaying)) { _ in
                                    WordSweepLine(
                                        words: words[i],
                                        time: clock.interpolatedTime() - offset + LyricSync.sweepOffset,
                                        font: activeFont,
                                        sung: sung,
                                        unsung: unsung
                                    )
                                }
                            } else {
                                // Line by line lights the whole active line at once.
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(isActive && byLine ? activeFont : lineFont)
                                    .foregroundStyle(isActive && byLine ? sung : unsung)
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("line-\(i)")
                            .contentShape(Rectangle())
                            .onTapGesture { onTapLine(line.time + offset) }
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, hPadding)
            }
            .onAppear { words = LyricSync.words(for: lines) }
            .onChange(of: lines) { _, new in
                words = LyricSync.words(for: new)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withMixAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }
}

/// Per-song lyric timing offsets in `UserDefaults`, keyed like the user's own lyrics.
enum LyricsOffsets {
    private static let key = "lyricsOffsets"

    static func get(for track: Track) -> TimeInterval {
        (UserDefaults.standard.dictionary(forKey: key)?[UserLyricsStore.key(for: track)] as? Double) ?? 0
    }

    static func set(_ value: TimeInterval, for track: Track) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        let k = UserLyricsStore.key(for: track)
        if value == 0 { all.removeValue(forKey: k) } else { all[k] = value }
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Queue Sheet

/// The queue: now playing, each lane under a heading, then shuffle/repeat/timer
/// tiles. Reorder is always on; delete needs Edit. Online taps route through the coordinator.
private struct UpNextSheet: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var deps:   AppDependencies
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    @State private var isEditing = false

    /// Upcoming rows. Rows have their own identity, so a song queued twice is two rows.
    private var upcoming: [QueueService.Entry] { queueService.upcomingRows }

    /// With repeat-all on, the loop divider replaces the lane headings.
    private var isRepeatGrouping: Bool {
        queueService.repeatMode == .all && queueService.repeatBoundaryIndex != nil
    }

    /// A song row or a lane heading. Headings are rows in one `ForEach` so drags
    /// can cross lanes (`onMove` can't cross sections).
    private enum QueueItem: Identifiable {
        case heading(String, QueueOrigin, id: String)
        case side(String, id: String)
        case entry(QueueService.Entry)

        var id: String {
            switch self {
            case .heading(_, _, let id), .side(_, let id): id
            case .entry(let row): row.id.uuidString
            }
        }

        var entry: QueueService.Entry? {
            if case .entry(let row) = self { row } else { nil }
        }
    }

    private var items: [QueueItem] {
        var items: [QueueItem] = []
        var lanesSeen: [QueueOrigin: Int] = [:]
        var previous: QueueOrigin?
        let sides = queueService.sideMarks()
        for row in upcoming {
            if !isRepeatGrouping, row.origin != previous {
                let n = lanesSeen[row.origin, default: 0]
                lanesSeen[row.origin] = n + 1
                items.append(.heading(queueService.title(for: row.origin), row.origin,
                                      id: "lane-\(row.origin.rawValue)-\(n)"))
            }
            previous = row.origin
            if let side = sides[row.id] { items.append(.side(side, id: "side-\(row.id)")) }
            items.append(.entry(row))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TapeDeckPicker(decks: deps.tapeDecks)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            // Over the list so the notice survives the queue emptying.
            list.overlay(alignment: .bottom) { SkipNoticeBox() }
            tiles
        }
        #if os(iOS)
        // Get Info from a row's menu. The app can't present it over this sheet's player.
        .sheet(item: $iosAppState.infoTrack) { track in
            GetInfoSheet(track: track,
                         isOnline: deps.onlineCoordinator.hasActiveOnlineSession,
                         followsPlayback: false)
        }
        #endif
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.mixSurface)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Queue")
                    .font(.mixHeadline)
                    .foregroundStyle(Color.mixTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let name = queueService.source.displayName {
                    Text("Playing \(Text(name).foregroundStyle(Color.mixTextPrimary))\(currentSide.map { " \u{00B7} \($0)" } ?? "")")
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                if isRepeatGrouping {
                    Text("Songs above the orange line repeat. Drag across it to change what loops.")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if isEditing, !upcoming.isEmpty {
                pill("Clear all") {
                    withMixAnimation(.easeOut(duration: 0.2)) { deps.onlineCoordinator.clearUpcomingQueue() }
                }
            }
            // Stays while editing so an emptied list can still be left.
            if !upcoming.isEmpty || isEditing {
                pill(isEditing ? "Done" : "Edit") {
                    withMixAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    // MARK: List

    private var list: some View {
        List {
            if let track = queueService.currentTrack {
                nowPlayingRow(track)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if upcoming.isEmpty {
                Text("Nothing up next")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(items) { item in
                switch item {
                case .heading(let title, let origin, _): laneHeading(title, origin: origin)
                case .side(let title, _): sideHeading(title)
                case .entry(let row): queueRow(row)
                }
            }
                .onMove(perform: move)
                .onDelete(perform: deleteAction)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // Always in edit mode for the reorder handles.
        .environment(\.editMode, .constant(.active))
        #endif
    }

    /// Delete only while editing.
    private var deleteAction: ((IndexSet) -> Void)? {
        isEditing ? { remove(at: $0) } : nil
    }

    private func queueRow(_ item: QueueService.Entry) -> some View {
        row(item)
        .opacity(isAfterRepeatGroup(item) ? 0.6 : 1)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // On the row, not a separate row, so dragging still works across it.
        .overlay(alignment: .bottom) {
            if isRepeatBoundary(item) { repeatDivider }
        }
        // The shared song menu, as on the Mac queue.
        .contextMenu {
            LibrarySongMenu(targets: [item.track],
                            onPlay: { play(item) },
                            removeFrom: "Queue",
                            onRemove: { _ in removeRow(item) })
            if deps.onlineCoordinator.canReResolve(item.track) {
                Divider()
                Button { Task { await deps.reResolve(item.track, at: item.index) } } label: {
                    Label("Wrong Version? Re-resolve", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(data: track.artworkData, artworkRef: .track(track.id),
                             size: 56, cornerRadius: 6, placeholder: MixtapeIcons.track)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { engine.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.mixTextPrimary).frame(width: 40, height: 40)
                    if engine.state == .loading {
                        ProgressView().tint(Color.mixBackground)
                    } else {
                        Image(systemName: engine.state.isPlaying ? MixtapeIcons.pause : MixtapeIcons.play)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.mixBackground)
                            .offset(x: engine.state.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(engine.state == .loading)
            .accessibilityLabel(engine.state.isPlaying ? "Pause" : "Play")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(track.title), \(track.artistName)")
    }

    /// The playing row's side, for the header.
    private var currentSide: String? {
        queueService.entryID(at: queueService.currentIndex).flatMap { queueService.sideMarks()[$0] }
    }

    private func sideHeading(_ title: String) -> some View {
        Label(title, systemImage: "recordingtape")
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
    }

    private func laneHeading(_ title: String, origin: QueueOrigin) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.mixTitle2.bold())
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            // The songs you added; "Clear all" lives in the header while editing.
            if origin == .manual {
                pill("Clear queue") {
                    withMixAnimation(.easeOut(duration: 0.2)) { deps.onlineCoordinator.clearManualQueue() }
                }
            }
        }
        .padding(.top, 8)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private func row(_ item: QueueService.Entry) -> some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(data: item.track.artworkData, artworkRef: .track(item.track.id),
                             size: 48, cornerRadius: 5, placeholder: MixtapeIcons.track)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    UnfindableBadge(track: item.track)
                    Text(item.track.title)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    // Marks songs the user queued.
                    if item.isManual {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.mixPrimary)
                            .accessibilityLabel("Added by you")
                    }
                    Text(item.track.artistName)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { play(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Remove from queue") { removeRow(item) }
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 10) {
            tileButton(title: "Shuffle", icon: MixtapeIcons.shuffle,
                       isOn: queueService.shuffleEnabled) {
                engine.queue.toggleShuffle()
            }
            tileButton(title: queueService.isAutoReverse ? "Auto-reverse"
                              : queueService.repeatMode == .one ? "Repeat one" : "Repeat",
                       icon: queueService.repeatSystemImage,
                       isOn: queueService.repeatMode != .off) {
                engine.queue.cycleRepeat()
            }
            .accessibilityLabel(queueService.repeatLabel)
            Menu {
                if engine.sleepTimerRemaining != nil {
                    Button(role: .destructive) { engine.cancelSleepTimer() } label: {
                        Label("Cancel Timer", systemImage: "xmark")
                    }
                    Divider()
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) min") { engine.setSleepTimer(TimeInterval(minutes * 60)) }
                }
            } label: {
                tile(title: engine.sleepTimerRemaining.map { "\(Int(($0 / 60).rounded(.up))) min" } ?? "Timer",
                     icon: "timer", isOn: engine.sleepTimerRemaining != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep timer")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func tileButton(title: String, icon: String, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.selection)
            action()
        } label: {
            tile(title: title, icon: icon, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func tile(title: String, icon: String, isOn: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
            Text(title)
                .font(.mixLabel)
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? Color.mixPrimary : Color.mixTextPrimary)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A ring, so "on" isn't carried by the tint alone.
        .overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.mixPrimary, lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.light)
            action()
        } label: {
            Text(title)
                .font(.mixButtonSmall)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Color.mixSurface2, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Repeat group

    /// The last row of the loop; the divider is drawn under it.
    private func isRepeatBoundary(_ row: QueueService.Entry) -> Bool {
        queueService.repeatBoundaryIndex == row.index
    }

    /// Rows queued for after the loop: they wait for repeat to be switched off.
    private func isAfterRepeatGroup(_ row: QueueService.Entry) -> Bool {
        queueService.isAfterRepeatGroup(index: row.index)
    }

    /// Labelled divider under the repeating songs.
    private var repeatDivider: some View {
        HStack(spacing: 6) {
            Text(queueService.repeatDividerLabel)
                .font(.system(size: MixFontScale.size(10), weight: .semibold))
                .foregroundStyle(Color.mixRepeatBoundary)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(Color.mixRepeatBoundary.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.top, 4)
        .offset(y: 6)
    }

    // MARK: Actions

    /// Plays a queued row. Online sessions go through the coordinator; local queues play in place.
    private func play(_ row: QueueService.Entry) {
        guard !isEditing else { return }
        Task {
            if await deps.onlineCoordinator.playQueueTrack(at: row.index, track: row.track) { return }
            // By position, so a second copy of a song plays that row.
            await engine.play(track: row.track, in: engine.queue.queue, startIndex: row.index,
                              source: engine.queue.source)
        }
    }

    private func removeRow(_ row: QueueService.Entry) {
        withMixAnimation(.easeOut(duration: 0.2)) {
            deps.onlineCoordinator.removeFromQueue(at: row.index)
        }
    }

    /// Removes rows through the coordinator, since online the queue mirrors the context.
    private func remove(at offsets: IndexSet) {
        let items = items
        // Descending, so removing one row doesn't shift the ones still to go.
        for index in offsets.compactMap({ items[$0].entry?.index }).sorted(by: >) {
            deps.onlineCoordinator.removeFromQueue(at: index)
        }
    }

    /// Maps the list's offsets (which count headings) back to absolute queue indices.
    private func move(from source: IndexSet, to destination: Int) {
        let items = items
        guard let first = source.first, let fromIndex = items[first].entry?.index else { return }
        let toIndex = queueService.currentIndex + 1
            + items[..<destination].filter { $0.entry != nil }.count
        // Through the coordinator: online the queue mirrors the context and the next push would undo a local move.
        deps.onlineCoordinator.moveInQueue(from: fromIndex, to: toIndex)
    }
}

// MARK: - Helper Views

/// Controls-row button. Active toggles get the accent colour and a dot beneath.
private struct NPButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? Color.mixPrimary : Color.mixTextPrimary)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Circle()
                            .fill(Color.mixPrimary)
                            .frame(width: 4, height: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Get Info Sheet

/// Metadata for the current track: artwork, tappable artists, file details.
struct GetInfoSheet: View {
    /// The track the sheet was opened with, used when playback stops.
    let track: Track
    let isOnline: Bool
    /// Whether the sheet follows playback. True from the player, false from a row.
    var followsPlayback: Bool = true
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    /// Observed directly: `engine.queue` doesn't republish through the engine.
    @EnvironmentObject private var queueService: QueueService
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @Environment(\.dismiss) private var dismiss

    /// This song's own history. Loaded in `.task`, since ranking the artist reads the log.
    @State private var standing: SongStanding?

    /// The playing track, or the opening track when playback has stopped.
    private var currentTrack: Track {
        followsPlayback ? (queueService.currentTrack ?? track) : track
    }

    var body: some View {
        let track = currentTrack
        // One surface with hairlines, not an inset grouped list.
        MixSheet(title: "Song Info", size: .medium) {
            #if os(macOS)
            // Side by side on the Mac.
            HStack(alignment: .top, spacing: 20) {
                artworkHeader(track)
                details(track)
            }
            #else
            VStack(alignment: .leading, spacing: 22) {
                artworkHeader(track)
                    .frame(maxWidth: .infinity)
                details(track)
            }
            #endif
        }
        .task(id: track.id) { standing = deps.statsService.songStanding(for: track) }
    }

    private func details(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            infoGroup {
                row("Title", track.title)
                artistRow(track)
                if !track.albumTitle.isEmpty { row("Album", track.albumTitle) }
                row("Duration", formatTime(track.duration))
                if let year = track.year { row("Year", String(year)) }
                if let genre = track.genre, !genre.isEmpty { row("Genre", genre) }
                if let tn = track.trackNumber { row("Track", String(tn)) }
                if let composer = track.composer, !composer.isEmpty { row("Composer", composer) }
                row("Source", isOnline ? "Streaming (Discover)" : "Library")
            }

            if let standing, standing.hasData {
                labelledGroup("LISTENING") {
                    row("Plays", "\(standing.plays)")
                    if let first = standing.firstPlay {
                        row("First played", first.formatted(.dateTime.month(.wide).year()))
                    }
                    if let last = standing.lastPlay {
                        row("Last played", last.formatted(.relative(presentation: .named)))
                    }
                    if let artist = standing.artist, let rank = artist.rank {
                        row("Artist rank", "#\(rank) \(artist.period.sentenceSuffix)")
                    }
                }
            }

            if let (format, size) = fileInfo(track) {
                labelledGroup("FILE") {
                    row("Format", format)
                    if let size { row("Size", size) }
                }
            }
        }
    }

    /// An `infoGroup` under a small caps heading.
    private func labelledGroup<C: View>(_ title: String,
                                        @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: MixFontScale.size(10.5), weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
                .tracking(0.8)
            infoGroup(rows)
        }
    }

    /// Rows on one surface, hairline-separated.
    private func infoGroup<C: View>(@ViewBuilder _ rows: () -> C) -> some View {
        VStack(spacing: 0) { rows() }
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func artworkHeader(_ track: Track) -> some View {
        Group {
            if let data = track.displayArtwork,
               let image = mixImage(from: data) {
                image.resizable().scaledToFill()
            } else {
                Color.mixSurface2.overlay(
                    Image(systemName: MixtapeIcons.track)
                        .font(.system(size: 44))
                        .foregroundStyle(Color.mixTextTertiary)
                )
            }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mixShadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    /// Artist row. On iOS each artist is a tap target that closes the sheet and opens its profile.
    @ViewBuilder
    private func artistRow(_ track: Track) -> some View {
        #if os(iOS)
        let targets: [(name: String, action: (() -> Void)?)] =
            ImportService.creditedArtists(from: track.artistName).map { name in
                (name, {
                    dismiss()
                    iosAppState.openOnlineArtist(name: name)
                })
            }
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("Artist")
                .font(.system(size: MixFontScale.size(12.5)))
                .foregroundStyle(Color.mixTextSecondary)
            Spacer(minLength: 0)
            TappableArtistRow(targets: targets, font: .system(size: MixFontScale.size(13)), color: .mixPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        #else
        row("Artist", track.artistName)
        #endif
    }

    /// Format and size of the local copy, or the recorded import size if not on this device.
    private func fileInfo(_ track: Track) -> (format: String, size: String?)? {
        let resolved = deps.fileStorage.localURL(for: track)
        let ext = (resolved?.pathExtension
                   ?? URL(fileURLWithPath: track.file.localPath).pathExtension).uppercased()
        var size: String? = nil
        if let resolved,
           let bytes = (try? FileManager.default.attributesOfItem(atPath: resolved.path(percentEncoded: false)))?[.size] as? Int64 {
            size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else if track.file.fileSize > 0 {
            size = ByteCountFormatter.string(fromByteCount: track.file.fileSize, countStyle: .file)
        }
        if ext.isEmpty && size == nil { return nil }
        return (ext.isEmpty ? "Audio" : ext, size)
    }

    /// No dividers between rows; spacing separates them.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: MixFontScale.size(12.5)))
                .foregroundStyle(Color.mixTextSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    NowPlayingView()
        .environmentObject(deps)
        .environmentObject(deps.playbackEngine)
}
