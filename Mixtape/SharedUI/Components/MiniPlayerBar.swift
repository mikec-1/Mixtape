// MiniPlayerBar.swift
// Mixtape — SharedUI/Components
//
// Persistent pill that floats above the tab bar while something is playing.
// Artwork · Title/Artist · Play-Pause · Skip.
// Tap anywhere on the bar (except the two control buttons) → opens NowPlayingView.

import SwiftUI

public struct MiniPlayerBar: View {

    @EnvironmentObject private var engine: PlaybackEngine
    @EnvironmentObject private var deps:   AppDependencies
    #if os(iOS)
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    /// Only the platforms that have no `IOSAppState` to hold it. On iOS the flag
    /// lives on the app state, because a sheet owned by this bar dies with it —
    /// and this bar is unmounted whenever playback goes quiet, including the
    /// moment between asking for the next song and it starting.
    @State private var showNowPlaying = false
    @Environment(\.mixChrome) private var chrome
    /// Bumped on the tap that favourites, to fire the heart's bounce. A counter
    /// so two favourites in a row are two bounces — and never reset, because any
    /// change to a trigger animates and zeroing it on a song change would make
    /// the bar pop at every track.
    @State private var favouritePops = 0
    #if os(iOS)
    /// How far the row has been dragged sideways. See `swipe`.
    @State private var dragX: CGFloat = 0
    /// The row's width, so the incoming song can ride in exactly one row behind.
    @State private var rowWidth: CGFloat = 360
    #endif

    public var body: some View {
        Button { openNowPlaying() } label: {
            VStack(spacing: 0) {

                // Which device the controls below are driving. A full-width band
                // rather than a caption under the title: at this width the device
                // name was truncating to "Playing on Mik…" against the artwork.
                WithActiveRemote(continuity: deps.continuity) { remote in
                    if let remote {
                        RemoteDeviceStrip(device: remote, alignment: .leading, hPadding: 12)
                    }
                }

                HStack(spacing: 12) {

                    // Artwork
                    artworkView

                    // Track info
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        artistLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Play / Pause
                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Group {
                            if engine.state == .loading {
                                ProgressView().tint(Color.mixTextPrimary)
                            } else {
                                Image(systemName: engine.state.isPlaying ? MixtapeIcons.pause : MixtapeIcons.play)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Color.mixTextPrimary)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).mixHandCursor()

                    #if os(iOS)
                    // Devices — only once there is somewhere else to play.
                    WithActiveRemote(continuity: deps.continuity) { remote in
                        if remote != nil || !deps.continuity.devices.isEmpty {
                            DevicesButton(continuity: deps.continuity,
                                          downloads: deps.downloadManager, size: 17)
                        }
                    }
                    #endif

                    // Heart
                    if let track = engine.queue.currentTrack {
                        let favoured = deps.libraryService.isFavourited(trackID: track.id)
                        Button {
                            // Same grammar as the save control: the add pops,
                            // the remove goes quietly. `deps` shows the card.
                            guard deps.toggleFavourite(trackID: track.id) else { return }
                            favouritePops += 1
                            Haptics.play(.success)
                        } label: {
                            Image(systemName: favoured ? "heart.fill" : "heart")
                                .font(.system(size: 17))
                                .foregroundStyle(favoured ? Color.mixPrimary : Color.mixTextSecondary)
                                .mixSymbolReplace()
                                .mixAnimation(.snappy(duration: 0.22), value: favoured)
                                .frame(width: 36, height: 36)
                                .savePop(trigger: favouritePops)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).mixHandCursor()
                    }

                    #if !os(iOS)
                    // Skip forward. Not on iOS: the bar is swiped there, and a
                    // button competing for the same 36pt made the gesture
                    // something you had to aim around. See `swipe`.
                    Button {
                        Task { await engine.playNext() }
                    } label: {
                        Image(systemName: MixtapeIcons.skipForward)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(
                                engine.queue.hasNext ? Color.mixTextPrimary : Color.mixTextTertiary
                            )
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .disabled(!engine.queue.hasNext)
                    #endif
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                #if os(iOS)
                .offset(x: dragX)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { rowWidth = $0 }
                // The song the swipe is heading for, one row-width behind the
                // current one, so the gap the drag opens has something in it.
                .overlay(alignment: .leading) { incomingPreview }
                .mixAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: dragX)
                .simultaneousGesture(swipe)
                #endif
            }
            .background(chrome.material(.ultraThinMaterial, flat: .mixSurface2))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // A pill that floats over the content takes its edge from depth,
            // not from a drawn line — the way the system's own transport bars
            // do. The stroke was reading as a cut-out against the blur.
            //
            // Flat chrome has no shadow to give, so there and only there the
            // hairline comes back, because an opaque pill on an opaque page
            // otherwise has nothing to say where it ends.
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.mixSeparator, lineWidth: 0.5)
                    .opacity(chrome.showsShadows ? 0 : 1)
            )
            .mixShadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .buttonStyle(.plain).mixHandCursor()
        #if !os(iOS)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(deps)
        }
        #endif
    }

    #if os(iOS)
    // MARK: - Swipe to skip

    /// The queue's neighbour in the drag's direction, wrapping the way
    /// `hasNext`/`hasPrevious` do under repeat.
    private func neighbour(forward: Bool) -> Track? {
        let q = engine.queue.queue
        guard !q.isEmpty else { return nil }
        if engine.queue.repeatMode == .one { return engine.queue.currentTrack }
        let i = engine.queue.currentIndex + (forward ? 1 : -1)
        if q.indices.contains(i) { return q[i] }
        return engine.queue.repeatMode == .all ? q[(i + q.count) % q.count] : nil
    }

    @ViewBuilder
    private var incomingPreview: some View {
        if dragX != 0, let next = neighbour(forward: dragX < 0) {
            HStack(spacing: 12) {
                ArtworkThumbnail(data: next.artworkData, artworkRef: .track(next.id),
                                 size: 40, cornerRadius: 6, placeholder: MixtapeIcons.track)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.displayTitle)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(ImportService.displayArtists(title: next.title, artistName: next.artistName)
                            .joined(separator: ", "))
                        .font(.mixLabel)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: rowWidth)
            .offset(x: dragX + (dragX < 0 ? rowWidth : -rowWidth))
            .allowsHitTesting(false)
        }
    }

    /// Drag the row sideways to change song, the way the system's own and
    /// Spotify's collapsed players do: the card follows the finger, and letting
    /// go past a third of the way commits. Below that it springs back, which is
    /// what makes an accidental graze on a bar you were about to tap harmless.
    ///
    /// `simultaneousGesture`, because the whole bar is one Button — a plain
    /// `.gesture` would win the tap that opens Now Playing.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // No song that way: half the travel, so the resistance is
                // visible rather than the gesture silently doing nothing.
                let canGo = value.translation.width < 0
                    ? engine.queue.hasNext : engine.queue.hasPrevious
                dragX = canGo ? value.translation.width : value.translation.width / 3
            }
            .onEnded { value in
                let dx = value.translation.width + value.predictedEndTranslation.width / 4
                let forward = dx < 0
                let canGo = forward ? engine.queue.hasNext : engine.queue.hasPrevious
                guard abs(dx) > 90, canGo else { dragX = 0; return }

                Haptics.play(.light)
                // Out, then back from the other side with the new song already
                // in place — the same read as a page turn. The snap back is
                // deliberately un-animated: animating it would drag the old
                // song's artwork across the screen in reverse.
                // All the way over, so the preview lands where the song will
                // sit; once it is playing, the swap back to zero is invisible.
                dragX = forward ? -rowWidth : rowWidth
                Task {
                    if forward { await engine.playNext() } else { await engine.playPrevious() }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { dragX = 0 }
                }
            }
    }
    #endif

    /// Raise the full player. On iOS that is a request to the app, which owns
    /// the sheet; elsewhere this bar still presents it itself.
    private func openNowPlaying() {
        #if os(iOS)
        iosAppState.showNowPlaying = true
        #else
        showNowPlaying = true
        #endif
    }

    // MARK: - Artist (per-artist tappable)

    /// The stored artist plus any feature the title names, joined for the
    /// platforms that print the line rather than making each name tappable.
    /// See `ImportService.displayArtists`.
    private var printedCredit: String {
        guard let track = engine.queue.currentTrack else { return "" }
        return ImportService.displayArtists(title: track.title,
                                            artistName: track.artistName)
            .joined(separator: ", ")
    }

    /// The artist line — plain text on every platform.
    ///
    /// iOS used to make each parsed artist its own tap target here, mirroring
    /// the full player. In a bar that is 56pt tall and entirely one button,
    /// that put small competing targets inside the thing the user is aiming at:
    /// tapping the bar to open the song landed on an artist page instead, which
    /// is not a place anyone was trying to go. The collapsed bar now does the
    /// single obvious thing, and the per-artist targets live where there is room
    /// to hit them deliberately — the full Now Playing view.
    /// A credit too long for the bar scrolls itself rather than truncating each
    /// name into a stub — three features shown as "David…, Flo Ri…, Nicki…"
    /// name nobody.
    private var artistLine: some View {
        // Slower than the title above it: four names passing is more to take
        // in than one phrase, and the two lines moving at different speeds is
        // also what stops them reading as one block sliding.
        MarqueeText(text: printedCredit, speed: 15)
    }

    // MARK: - Title

    /// The title scrolls on the same terms as the credit beneath it: a long
    /// one truncated in a 56pt bar names the song about as well as its first
    /// three words do.
    ///
    /// Set off a second after the artists rather than with them — two lines
    /// moving in lockstep read as the bar itself sliding, which is alarming in
    /// a control the user is about to tap.
    private var titleLine: some View {
        MarqueeText(text: engine.queue.currentTrack?.displayTitle ?? "—",
                    font: .mixBodyBold,
                    color: .mixTextPrimary,
                    startDelay: .seconds(1))
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data  = engine.queue.currentTrack?.displayArtwork,
               let image = mixImage(from: data, displaySize: 40) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.mixSurface2
                    .overlay(
                        Image(systemName: MixtapeIcons.track)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    let deps = AppDependencies()
    ZStack(alignment: .bottom) {
        Color.mixBackground.ignoresSafeArea()
        MiniPlayerBar()
            .padding(.horizontal, 8)
            .padding(.bottom, 57)
            .environmentObject(deps)
            .environmentObject(deps.playbackEngine)
    }
}
