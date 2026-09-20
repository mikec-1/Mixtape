// NowPlayingView.swift
// Mixtape — Features/NowPlaying
//
// Full-screen player sheet.
// All state comes from PlaybackEngine and QueueService (@EnvironmentObject).
//
// Overhaul: ambient album-art background, synced/plain lyrics panel, and new
// playback controls (sleep timer, playback speed, Up Next reorder).

import SwiftUI

public struct NowPlayingView: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    /// `engine.queue` is a plain `let` on the engine, so its changes don't
    /// republish through it — shuffle and repeat have to be observed here or the
    /// buttons only catch up on the next unrelated engine publish.
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

    /// Lyrics for the current track, read straight from the service.
    ///
    /// Deliberately not mirrored into `@State`: `LyricsService.cache` is
    /// `@Published`, so a write already re-runs this body, and a `@State` copy
    /// only ever updated by `refreshForCurrentTrack` meant lyrics the user had
    /// just saved didn't appear until the screen was dismissed and reopened.
    private var lyrics: TrackLyrics? {
        guard let track = queueService.currentTrack else { return nil }
        return lyricsService.cached(for: track)
    }

    /// Sheets / panels.
    @State private var showLyrics  = false
    @State private var showUpNext  = false
    @State private var showGetInfo = false
    @State private var showLyricsEditor = false
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

    /// The song being fetched right now, if any.
    ///
    /// Mirrored into local state rather than read off `deps` in `body`: nothing
    /// here holds the coordinator, so nothing here would hear it change. The
    /// mini player has had this readout for a while (`TrackPreparingBar`), but
    /// that bar is a sibling of this sheet — from in here, a skip to a song that
    /// wasn't downloaded yet looked like the app had simply stopped.
    @State private var preparing: OnlinePlaybackCoordinator.PreparingTrack?

    public var body: some View {
        ZStack {
            ambientBackground
            content
                #if os(iOS)
                // `.gesture` so the seek bar's and artwork's own drags win where
                // they are; the artwork forwards its vertical drags below.
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20)
                    .onChanged(trackDismissDrag)
                    .onEnded(endDismissDrag))
                #endif
        }
        .offset(y: dismissOffset)
        // The wash is clamped dark for white type, so the player is dark in
        // either appearance. Applied before the sheets so they keep the app's.
        .environment(\.colorScheme, .dark)
        // React to track changes: refresh ambient colours + lyrics.
        .onChange(of: queueService.currentTrack?.id) { _, _ in
            refreshForCurrentTrack()
        }
        .onAppear { refreshForCurrentTrack() }
        .onReceive(deps.onlineCoordinator.$preparing) { preparing = $0 }
        #if os(iOS)
        .fullScreenCover(isPresented: $showKaraoke) {
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
        .sheet(isPresented: $showGetInfo) {
            if let track = queueService.currentTrack {
                GetInfoSheet(
                    track: track,
                    isOnline: deps.onlineCoordinator.hasActiveOnlineSession
                )
            }
        }
    }

    // MARK: - Ambient Background

    /// Spotify's Canvas without the video: the cover, blurred into light across
    /// the top of the screen, running down into its own colour and then into
    /// the page. None of the catalogues behind the app carry looping video, so
    /// the still is what there is to extend.
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

                // Keeps white type readable over a bright cover without
                // greying the colour out of the middle.
                LinearGradient(colors: [.black.opacity(0.3), .clear, .black.opacity(0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Flattened once: the seek bar ticks several times a second, and a
            // live blur would be recomposited under every one of them.
            .drawingGroup()
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 16).frame(maxHeight: 40)
            // One square for both, so opening the lyrics moves nothing below.
            // Priority, or the spacers take their share first and the cover
            // comes out a third of the width.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if showLyrics { lyricsPanel } else { artworkView }
                }
                .layoutPriority(1)
            trackInfo
                .padding(.top, 40)
                .padding(.bottom, 18)
            // The seek bar has nothing to say about a song that hasn't been
            // fetched yet, so the wait takes its place rather than being drawn
            // somewhere else on top of it.
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
            // The only flexible gap: the player sits up under the top bar and
            // the output/lyrics/share/queue row stays on the bottom edge.
            Spacer(minLength: 12)
            bottomRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .mixAnimation(.easeInOut(duration: 0.2), value: preparing == nil)
    }

    // MARK: - Preparing

    /// What the seek bar becomes while the next song is being fetched: the same
    /// progress the mini player's card shows, in the place the user is already
    /// looking, with the way out that a modal sheet otherwise doesn't offer.
    private func preparingStrip(_ preparing: OnlinePlaybackCoordinator.PreparingTrack) -> some View {
        VStack(spacing: 8) {
            PreparingProgressTrack(fraction: preparing.progress.fraction)

            HStack(spacing: 6) {
                Text(preparing.phaseLabel)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)

                // Only when there is a real number behind it — a percentage the
                // app made up sets a clock the work isn't running against.
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
            // The heart used to be a button beside the title; it's here now
            // because saving is the thing you reach for while a song plays, and
            // favouriting is the rarer follow-up. Only offered once the song is
            // in the library — `toggleFavourite` won't act on anything else.
            if let track = queueService.currentTrack,
               deps.libraryService.track(id: track.id) != nil {
                let favoured = deps.libraryService.isFavourited(trackID: track.id)
                Button {
                    // `deps.toggleFavourite` shows the card on the way in;
                    // the way out gets a sentence instead, because "Removed"
                    // on the same green check reads as the opposite of what
                    // just happened.
                    if !deps.toggleFavourite(trackID: track.id) {
                        deps.showToast("Removed from Liked Songs")
                    }
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
                    Label("Add to Library", systemImage: "plus.circle")
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
                        // Swipe left → next.
                        withMixAnimation(.easeInOut(duration: 0.18)) { artworkSlide = -320 }
                        Task {
                            await engine.playNext()
                            artworkSlide = 320
                            withMixAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { artworkSlide = 0 }
                        }
                    } else if value.translation.width > 50 {
                        // Swipe right → previous.
                        withMixAnimation(.easeInOut(duration: 0.18)) { artworkSlide = 320 }
                        Task {
                            await engine.playPrevious()
                            artworkSlide = -320
                            withMixAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { artworkSlide = 0 }
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
            withMixAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dismissOffset = 0 }
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
                                 isPlaying: engine.state.isPlaying) { time in
                    engine.seek(to: time)
                }
                #if os(iOS)
                // Only offered for synced lyrics: without timings there is
                // nothing to sing *along* to, and this panel is already the
                // right home for a static block of text.
                Button {
                    Haptics.play(.light)
                    showKaraoke = true
                } label: {
                    Label("Karaoke", systemImage: "music.mic")
                        .font(.system(size: 13, weight: .semibold))
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
                    // Four sources came back empty; the user is the fifth.
                    // A dead end is the wrong thing to leave here when the
                    // fix is a box of text away.
                    if queueService.currentTrack != nil {
                        lyricsEditorButton("Add Lyrics")
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Lyrics that *were* found are still worth being able to correct — a
        // mismatched LRCLIB hit is as useless as no hit at all — so the way in
        // stays available in every state, just quietly, out of the way of the
        // words themselves.
        .overlay(alignment: .topTrailing) {
            if queueService.currentTrack != nil, lyrics?.hasAny == true {
                lyricsEditorButton(lyrics?.isUserProvided == true ? "Edit" : "Fix", compact: true)
                    .padding(.top, 2)
            }
        }
    }

    /// The one control that opens the editor, in its two sizes.
    private func lyricsEditorButton(_ title: String, compact: Bool = false) -> some View {
        Button { showLyricsEditor = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil")
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
                // Title — opens Get Info (unchanged).
                Button {
                    showGetInfo = true
                } label: {
                    // A title too long for the sheet scrolls itself rather than
                    // truncating. "Nothing Breaks Like a Heart (feat. …" names
                    // a song about as well as a shrug does, and this is the one
                    // screen with room to let the rest arrive.
                    MarqueeText(text: displayTitle,
                                font: .mixTitle.weight(.bold),
                                color: .mixTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()

                // Artist — each parsed artist is its own tap target.
                HStack(spacing: 6) {
                    if queueService.currentTrack?.isExplicit == true { MixExplicitBadge() }
                    artistLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            // In your library, or not. Favouriting moved to the ••• menu — it's
            // a second, narrower decision, and it can't even be made until the
            // song is saved.
            if let track = queueService.currentTrack {
                NowPlayingSaveButton(trackID: track.id, size: 26)
            }
        }
    }

    // MARK: - Artist Line

    /// The printed credit for the current song: the stored artist, plus any
    /// feature its title names. A Discover song carries only its main artist —
    /// see `ImportService.displayArtists`. The Get Info rows below deliberately
    /// keep showing the stored field instead; that panel reports what the track
    /// actually holds.
    /// The title as printed. Kept beside `displayCredit` so both halves of the
    /// line come from one place.
    /// While a song is being fetched, the line names *that* song: it is the one
    /// the user just asked for, and the queue won't catch up until it plays.
    private var displayTitle: String {
        ImportService.bareTitle(preparing?.title ?? queueService.currentTrack?.title ?? "—")
    }

    private var displayCredit: [String] {
        if let preparing {
            return ImportService.displayArtists(title: preparing.title,
                                                artistName: preparing.artist)
        }
        guard let track = queueService.currentTrack else { return [] }
        return ImportService.displayArtists(title: track.title, artistName: track.artistName)
    }

    /// The artist line beneath the title. On iOS each parsed artist is an
    /// individual tap target that dismisses the sheet and opens the right
    /// profile; elsewhere it's plain text. A single artist looks identical to
    /// the previous lone label.
    ///
    /// Long credits scroll here too, and on iOS the whole row is measured and
    /// moved as one — each name keeps its own tap target, but the line travels
    /// together instead of every name deciding separately whether it fits.
    @ViewBuilder
    private var artistLine: some View {
        #if os(iOS)
        // Same slower walk as the collapsed bar's credit — see `MiniPlayerBar`.
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
    /// One tap target per individual artist. Tapping dismisses the now-playing
    /// sheet, then opens that name's Discover artist page — every name in the
    /// line lands on the same kind of page, rather than the main artist opening
    /// the library and the features opening Discover (mirrors the mini player
    /// and macOS). The Get Info sheet further down still prefers a local artist
    /// page: that one is showing stored metadata, not the printed credit.
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
            // One control, not two: the glyph alone on the built-in speaker,
            // the remote device's or the external output's name when either has
            // the sound. Either way it opens the picker.
            DevicesButton(continuity: deps.continuity,
                          downloads: deps.downloadManager, size: 20, showsName: true)
            #endif

            Spacer(minLength: 8)

            // Lyrics — primary, on-screen access (not buried in •••).
            NPButton(icon: "quote.bubble", label: "Lyrics",
                     isActive: showLyrics || karaokeIsShowing, size: 20) {
                #if os(iOS)
                // Synced lyrics go straight to karaoke: it is the same lines at
                // a size worth reading, and the panel only ever had them small.
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

            NPButton(icon: MixtapeIcons.queue, label: "Queue", size: 20) {
                showUpNext = true
            }
        }
    }

    // MARK: - Playback Controls

    private var controls: some View {
        // spacing: 0 + flexible Spacers — the spacing must NOT be added on top of
        // the Spacers or the row's minimum width exceeds the screen and shoves the
        // whole layout off-edge. The Spacers spread the cluster evenly to fill.
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

            // Play / Pause — white disc, dark glyph.
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

            NPButton(icon: queueService.repeatMode.systemImage,
                     label: queueService.repeatMode.accessibilityLabel,
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

        // Lyrics. Whatever is cached is already on screen — `lyrics` reads the
        // service directly — so this only decides whether to go and fetch, and
        // whether to show a spinner while that happens.
        guard let track = queueService.currentTrack else {
            isLoadingLyrics = false
            return
        }
        // A plain-only (or missing) result still falls through to resolve() so
        // we keep trying to upgrade to interactive synced lyrics rather than
        // getting stuck on a plain block. The user's own lyrics are exempt:
        // there is nothing to upgrade them to.
        let cached = lyricsService.cached(for: track)
        if let cached, cached.hasSynced || cached.isUserProvided {
            isLoadingLyrics = false
            return
        }

        isLoadingLyrics = (cached == nil)
        Task {
            await lyricsService.resolve(for: track)
            // No need to check the track hasn't changed underneath us: the
            // result went into the cache keyed by *its own* track, and `lyrics`
            // reads the cache for whatever is playing now.
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

/// The slider and its two time labels.
///
/// Split out of `NowPlayingView` so the tick that moves the knob stops here.
/// The screen around it — ambient background, artwork, transport, the whole
/// bottom row — used to re-evaluate five times a second because the scrub
/// value lived up there as `@State` kept in sync by `.onChange(of:
/// engine.currentTime)`. See `PlaybackClock`.
///
/// The drag state lives here too, and nothing outside needs to know about it:
/// `seek(to:)` writes the position through immediately, so letting go of the
/// knob and reading the clock back agree without anyone holding a copy.
struct NowPlayingSeekBar: View {

    @ObservedObject var clock: PlaybackClock
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// What the labels and the knob should show: the drag while there is one,
    /// the clock otherwise.
    private var shown: Double { isScrubbing ? scrubValue : clock.currentTime }

    private var fraction: Double {
        duration > 0 ? min(max(shown / duration, 0), 1) : 0
    }

    /// Thin white track and a small knob that grows while held — the system
    /// slider's thumb is a glass capsule twice the height of the bar.
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

/// Auto-scrolling synced lyrics with the active line highlighted.
///
/// Two sizes from one view: the panel inside Now Playing, and the karaoke
/// screen, which is the same lyrics drawn big enough to read from across a
/// room. Only the type scale and the colours differ, so they are parameters
/// rather than a second copy of the sweep-and-autoscroll logic.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    /// Observed rather than handed down as a number: the highlight has to move
    /// on every tick, and this is where that redraw should stop. See
    /// `PlaybackClock`.
    @ObservedObject var clock: PlaybackClock
    /// Stops the per-frame sweep redrawing a line that isn't moving.
    let isPlaying: Bool
    let onTapLine: (TimeInterval) -> Void

    /// Karaoke draws in white over the album wash and leans on weight for the
    /// sung/unsung split; the panel sits on the app's own surface.
    var lineFont: Font = .mixBody
    var activeFont: Font = .mixBody.weight(.bold)
    var sung: Color = .mixTextPrimary
    var unsung: Color = Color.mixTextSecondary.opacity(0.6)
    var gapSize: CGFloat = 26
    var lineSpacing: CGFloat = 14
    /// Per-song timing correction, in seconds: positive holds the lyrics back.
    var offset: TimeInterval = 0
    /// Side inset *inside* the scroll view rather than around it. The active
    /// line swells and carries a glow, so a line drawn hard against the scroll
    /// view's own bounds gets its first and last glyphs clipped.
    var hPadding: CGFloat = 0

    /// Index of the line whose timestamp is the latest <= the current position.
    /// Per-word spans, so the active line can be swept rather than flipped on.
    /// Held in state because this view's body re-runs on every clock tick, and
    /// the spans only change when the lyrics do.
    @State private var words: [[LyricWord]] = []

    private var activeIndex: Int? {
        // No lead — see `MacSyncedLyrics.activeIndex`. A line holds until the
        // next one starts, so the last word of a line isn't cut short.
        let now = clock.interpolatedTime() - offset
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= now { idx = i } else { break }
        }
        return idx
    }

    /// See `MacSyncedLyrics.scrollTarget` — the dots hold the view while an
    /// instrumental plays.
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
                        // Only present while it's actually playing (plus a beat of lead-in
                        // so the entry animation has somewhere to start). Outside that the
                        // row doesn't exist at all — three dim dots parked mid-song read as
                        // a stray bullet list.
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
                            if isActive, i < words.count, !words[i].isEmpty {
                                // Only the line being sung is drawn word by
                                // word — it's the only one whose fill moves.
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
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(lineFont)
                                    .foregroundStyle(unsung)
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

/// Per-song lyric timing corrections. A dictionary in `UserDefaults`, keyed the
/// same way as the user's own lyrics — small enough that a store of its own
/// would be more machinery than data.
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

/// Spotify's queue, adapted: what's playing, then each lane under its own
/// heading, then shuffle / repeat / timer as tiles along the bottom.
///
/// Reorder is always on (the handles are the list's own); removing is behind
/// Edit, so the red minuses only show when you've asked for them. Taps route
/// through the coordinator's context during an online session, mirroring the
/// macOS queue panel.
private struct UpNextSheet: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var deps:   AppDependencies
    /// `engine.queue` is a plain `let` on the engine, so its changes don't
    /// republish through it — shuffle and repeat have to be observed here or the
    /// buttons only catch up on the next unrelated engine publish.
    @EnvironmentObject private var queueService: QueueService

    @State private var isEditing = false

    /// Upcoming rows (after the current index). Rows rather than tracks: each
    /// has its own identity, so a song queued twice is two rows the list can
    /// tell apart — and its position, which is how it is played and moved.
    private var upcoming: [QueueService.Entry] { queueService.upcomingRows }

    /// While repeat-all is on, the loop and its divider are how the queue reads
    /// — "these songs repeat, those wait" — so the lane headings stand down
    /// rather than being crossed with it.
    private var isRepeatGrouping: Bool {
        queueService.repeatMode == .all && queueService.repeatBoundaryIndex != nil
    }

    /// A row of the list: a song, or the heading that starts its lane ("Next in
    /// queue", "Next up: <Playlist>", "Next up: recommended songs").
    ///
    /// Headings are rows in the same `ForEach` rather than `Section`s: a drag
    /// has to move a song from any lane to any other, and `onMove` doesn't
    /// cross section boundaries. Rows of their own (not drawn inside the first
    /// song) so edit mode's handles line up with the song, not the heading.
    private enum QueueItem: Identifiable {
        case heading(String, QueueOrigin, id: String)
        case entry(QueueService.Entry)

        var id: String {
            switch self {
            case .heading(_, _, let id): id
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
        for row in upcoming {
            if !isRepeatGrouping, row.origin != previous {
                let n = lanesSeen[row.origin, default: 0]
                lanesSeen[row.origin] = n + 1
                items.append(.heading(queueService.title(for: row.origin), row.origin,
                                      id: "lane-\(row.origin.rawValue)-\(n)"))
            }
            previous = row.origin
            items.append(.entry(row))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Over the list rather than in it: the notice has to survive the
            // queue emptying, which is exactly what a run of skips does.
            list.overlay(alignment: .bottom) { SkipNoticeBox() }
            tiles
        }
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
                    Text("Playing \(Text(name).foregroundStyle(Color.mixTextPrimary))")
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
        // Always in edit mode so the reorder handles are there to grab; with
        // no delete action outside Edit, that is all edit mode draws.
        .environment(\.editMode, .constant(.active))
        #endif
    }

    /// Swipe/minus delete exists only while editing, so the list's own
    /// edit mode draws just the reorder handles the rest of the time.
    private var deleteAction: ((IndexSet) -> Void)? {
        isEditing ? { remove(at: $0) } : nil
    }

    private func queueRow(_ item: QueueService.Entry) -> some View {
        row(item)
        .opacity(isAfterRepeatGroup(item) ? 0.6 : 1)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Drawn on the row rather than as a row of its own so the
        // list stays one ForEach and dragging still works across it.
        .overlay(alignment: .bottom) {
            if isRepeatBoundary(item) { repeatDivider }
        }
        .contextMenu {
            Button { play(item) } label: { Label("Play", systemImage: MixtapeIcons.play) }
            // A queue row is often a Discover song the library doesn't hold —
            // the offer any menu makes for one of those. Mirrors the Mac queue.
            if deps.libraryService.track(id: item.track.id) == nil {
                Button {
                    Task {
                        await deps.onlineCoordinator.addToLibrary(unsaved: item.track)
                        deps.showSavedToast(.library)
                    }
                } label: { Label("Add to Library", systemImage: "plus.circle") }
            }
            Button(role: .destructive) { removeRow(item) } label: {
                Label("Remove from queue", systemImage: "minus.circle")
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
                    // The mark the app's own picks don't get: this row is here
                    // because the user asked for it.
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
            tileButton(title: queueService.repeatMode == .one ? "Repeat one" : "Repeat",
                       icon: queueService.repeatMode.systemImage,
                       isOn: queueService.repeatMode != .off) {
                engine.queue.cycleRepeat()
            }
            .accessibilityLabel(queueService.repeatMode.accessibilityLabel)
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

    /// The last row of the loop — the divider is drawn beneath it.
    private func isRepeatBoundary(_ row: QueueService.Entry) -> Bool {
        queueService.repeatBoundaryIndex == row.index
    }

    /// Rows queued for after the loop: they wait for repeat to be switched off.
    private func isAfterRepeatGroup(_ row: QueueService.Entry) -> Bool {
        queueService.isAfterRepeatGroup(index: row.index)
    }

    /// The line that answers "what exactly is repeating?" — everything above it.
    /// Labelled, because an unexplained rule between two songs reads as trim.
    private var repeatDivider: some View {
        HStack(spacing: 6) {
            Text("Repeats from here")
                .font(.system(size: 10, weight: .semibold))
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

    /// Jump straight to a queued track. Online sessions resolve through the
    /// coordinator (spinner + on-demand download); local queues play in place.
    private func play(_ row: QueueService.Entry) {
        guard !isEditing else { return }
        Task {
            if await deps.onlineCoordinator.playQueueTrack(at: row.index, track: row.track) { return }
            // By position, so tapping the second copy of a song plays that row
            // rather than jumping back to the first.
            await engine.play(track: row.track, in: engine.queue.queue, startIndex: row.index,
                              source: engine.queue.source)
        }
    }

    private func removeRow(_ row: QueueService.Entry) {
        withMixAnimation(.easeOut(duration: 0.2)) {
            deps.onlineCoordinator.removeFromQueue(at: row.index)
        }
    }

    /// Take rows out of the queue. Routed through the coordinator: during an
    /// online session the queue is a mirror of the context, so removing rows
    /// here alone would last until the next push.
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
        // Through the coordinator, and with the same destination semantics: in an
        // online session the queue is a mirror of the context, so a move applied
        // to it alone would be undone by the next push — which is why reordering
        // used to be switched off entirely during Discover playback.
        deps.onlineCoordinator.moveInQueue(from: fromIndex, to: toIndex)
    }
}

// MARK: - Helper Views

/// Icon button used inside the controls row. An active toggle turns the accent
/// colour and gains a dot beneath, so its state isn't carried by colour alone.
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

/// Metadata for the current track. Follows the *live* current track (so it
/// stays correct across auto-advance instead of freezing on the song it was
/// opened with) and mirrors the macOS inspector's richer content: artwork,
/// individually tappable artists, and file details.
private struct GetInfoSheet: View {
    /// Track the sheet was opened with — only a fallback when playback stops.
    let track: Track
    let isOnline: Bool
    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    /// `engine.queue` is a plain `let` on the engine, so its changes don't
    /// republish through it — shuffle and repeat have to be observed here or the
    /// buttons only catch up on the next unrelated engine publish.
    @EnvironmentObject private var queueService: QueueService
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @Environment(\.dismiss) private var dismiss

    /// Always reflect the currently playing track; fall back to the opening
    /// track when playback has stopped.
    private var currentTrack: Track { queueService.currentTrack ?? track }

    var body: some View {
        let track = currentTrack
        // This was an `.insetGrouped` List, which is the exact shape of an iOS
        // Settings screen — grey field, floating white cards, a nav bar on top.
        // It's a metadata panel, so it reads as one surface: the artwork, then
        // the facts, separated by hairlines rather than by cards.
        MixSheet(title: "Song Info", size: .medium) {
            VStack(alignment: .leading, spacing: 22) {
                artworkHeader(track)
                    .frame(maxWidth: .infinity)

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

                if let (format, size) = fileInfo(track) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FILE")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.mixTextTertiary)
                            .tracking(0.8)
                        infoGroup {
                            row("Format", format)
                            if let size { row("Size", size) }
                        }
                    }
                }
            }
        }
    }

    /// Rows on one surface, hairline-separated. `VStack(spacing: 0)` plus a
    /// divider between every pair — no card per row, no card per section.
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

    /// Artist row — on iOS each parsed artist is its own tap target that closes
    /// the sheet and opens the matching profile (mirrors the Now Playing view).
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
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mixTextSecondary)
            Spacer(minLength: 0)
            TappableArtistRow(targets: targets, font: .system(size: 13), color: .mixPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        #else
        row("Artist", track.artistName)
        #endif
    }

    /// Format + size of the local copy, when one exists. Falls back to the
    /// recorded import size when the file isn't on this device.
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

    /// No rule between rows — the label/value contrast and the spacing already
    /// separate them, and nine hairlines in a 300pt panel is a spreadsheet.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mixTextSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13))
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
