// Header for the playlist, album and artist detail pages.
// macOS: wide banner, cover left, text and controls beside it.
// iOS: centred cover, left-aligned text sharing the rows' edge. Circular
// covers (artists) centre the text instead.

import SwiftUI
import Combine

// MARK: - Artwork wash

/// Colour at the top of the current wash; macOS tints the titlebar with it.
/// Nil restores system chrome.
@MainActor
final class ArtworkWashTint: ObservableObject {

    static let shared = ArtworkWashTint()

    @Published private(set) var color: Color?

    /// Sampled colours and strength, so the sidebar can draw the same ramp.
    @Published private(set) var stops: [Color] = []
    @Published private(set) var intensity: Double = 1

    /// Only the wash that set the colour can clear it; appear/disappear order
    /// between screens isn't guaranteed.
    private var owner: UUID?

    func publish(colors: [Color], intensity: Double, from id: UUID) {
        owner = id
        let top = colors.count == 2
            ? colors[0].opacity(min(ArtworkWash.topOpacity * intensity * 1.45, 1))
            : nil
        if color != top             { color = top }
        if stops != colors          { stops = colors }
        if self.intensity != intensity { self.intensity = intensity }
    }

    /// Chrome intensity. Stronger than the page, since narrow edge surfaces read grey otherwise.
    var chromeIntensity: Double { min(intensity * 1.45, 1.6) }

    func resign(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        color = nil
        stops = []
    }
}

/// Vertical wash from a screen's artwork. A modifier because it has to run taller
/// than the hero, into the track list. Playlists apply it to the List since
/// List clips rows.
struct ArtworkWash: ViewModifier {

    let source: Data?
    /// Scales the whole ramp. 1 is the detail-page strength; Home uses less.
    var intensity: Double = 1.0
    /// Used when `source` yields nothing. Empty = no wash.
    var fallback: [Color] = []

    @State private var colors: [Color] = []
    /// Identity for the shared tint (see `ArtworkWashTint.resign`).
    @State private var id = UUID()
    @Environment(\.mixChrome) private var chrome

    /// Flat chrome skips the wash and the sampling entirely. Toggled inside one
    /// chain rather than an `if`, which would rebuild the page and lose its state.
    func body(content: Content) -> some View {
        content
            .background(alignment: .top) { gradient }
            // Keyed on the setting too, so re-enabling samples the cover.
            .task(id: WashKey(source: source, enabled: chrome.showsArtworkWash)) {
                guard chrome.showsArtworkWash else {
                    colors = []
                    ArtworkWashTint.shared.resign(id)
                    return
                }
                guard let source else {
                    colors = fallback
                    ArtworkWashTint.shared.publish(colors: colors, intensity: intensity, from: id)
                    return
                }
                // Seen before: no decode, so the fade starts straight away.
                let key = Self.cacheKey(source)
                if let cached = Self.sampled[key] {
                    colors = cached.isEmpty ? fallback : cached
                    ArtworkWashTint.shared.publish(colors: colors, intensity: intensity, from: id)
                    return
                }
                // Decode off the main thread; covers can be a megabyte.
                let sampled = await Task.detached(priority: .userInitiated) {
                    ArtworkColors.gradientColors(from: source)
                }.value
                // Colours are tiny, so the cap is only a backstop.
                if Self.sampled.count >= 512 { Self.sampled.removeAll() }
                Self.sampled[key] = sampled
                // Unreadable artwork also falls back.
                colors = sampled.isEmpty ? fallback : sampled
                ArtworkWashTint.shared.publish(colors: colors, intensity: intensity, from: id)
            }
            // Reclaim the tint on reappear (e.g. after fullscreen lyrics retinted the chrome).
            .onAppear {
                guard chrome.showsArtworkWash else { return }
                ArtworkWashTint.shared.publish(colors: colors, intensity: intensity, from: id)
            }
            .onDisappear { ArtworkWashTint.shared.resign(id) }
            .mixAnimation(.easeOut(duration: 0.4), value: colors)
    }

    @ViewBuilder
    private var gradient: some View {
        if chrome.showsArtworkWash {
            ArtworkWashGradient(colors: colors, intensity: intensity)
                .transition(.opacity)
        }
    }

    /// What `.task(id:)` watches: the cover, and whether a wash is wanted at all.
    private struct WashKey: Equatable {
        let source: Data?
        let enabled: Bool
    }

    /// Sampled colours by cover, so reopening a page skips the decode.
    private static var sampled: [Int: [Color]] = [:]

    /// Size and both ends of the image, like the library's cover fingerprint.
    private static func cacheKey(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        hasher.combine(data.suffix(64))
        return hasher.finalize()
    }

    /// Kept as a constant because the titlebar tint has to match this exactly.
    static let topOpacity: Double = 0.66

    #if os(macOS)
    static let height: CGFloat = 520
    #else
    static let height: CGFloat = 520
    #endif
}

/// The wash ramp as a view, so the sidebar draws the identical gradient.
/// Five stops to avoid banding across wide windows.
struct ArtworkWashGradient: View {
    let colors: [Color]
    var intensity: Double = 1

    var body: some View {
        if colors.count == 2 {
            LinearGradient(
                stops: [
                    .init(color: colors[0].opacity(ArtworkWash.topOpacity * intensity), location: 0.00),
                    .init(color: colors[0].opacity(0.48 * intensity), location: 0.22),
                    .init(color: colors[1].opacity(0.28 * intensity), location: 0.48),
                    .init(color: colors[1].opacity(0.10 * intensity), location: 0.74),
                    .init(color: colors[1].opacity(0.00),             location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: ArtworkWash.height)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Tints the top of this view from `source`. Nil = no wash unless `fallback` is set.
    func artworkWash(source: Data?,
                     intensity: Double = 1.0,
                     fallback: [Color] = []) -> some View {
        modifier(ArtworkWash(source: source, intensity: intensity, fallback: fallback))
    }
}

struct DetailHero<Cover: View, Actions: View, Byline: View>: View {
    /// Small uppercase label above the title ("Playlist", "Album", "Artist").
    let eyebrow: String
    let title: String
    /// Album artist, playlist description. Nil to omit.
    var subtitle: String?
    /// Tinted with the brand colour and given more weight than `metadata`.
    var subtitleIsProminent: Bool = false
    /// Song counts, durations, years: the small grey line.
    var metadata: String?
    /// Circular on artist pages, rounded-rect everywhere else.
    var coverIsCircular: Bool = false

    /// Owner byline (faces and names), drawn in `metadata`'s place. Pages with one
    /// put their counts inside it and pass `metadata` nil.
    @ViewBuilder var byline: () -> Byline
    @ViewBuilder var cover: (CGFloat) -> Cover
    @ViewBuilder var actions: () -> Actions

    @Environment(\.mixDensity) private var density

    /// See the file header.
    private var textAlignsLeading: Bool { !coverIsCircular }

    /// The hero doesn't tint itself; each screen applies `.artworkWash` to its container.
    @ViewBuilder
    var body: some View {
        #if os(macOS)
        HStack(alignment: .bottom, spacing: density.heroSpacing) {
            cover(density.heroCoverWide)
                .mixShadow(color: .black.opacity(0.3), radius: 20, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextSecondary)
                    .textCase(.uppercase)

                Text(title)
                    .font(.system(size: density.heroTitleSize, weight: .heavy))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleIsProminent ? .mixBodyBold : .mixBody)
                        .foregroundStyle(subtitleIsProminent
                                         ? Color.mixPrimary : Color.mixTextSecondary)
                        .lineLimit(2)
                }

                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                }

                byline()

                actions()
                    .padding(.top, 6)
            }
            // Fills the banner so action rows can push controls to the far edge.
            // Fixed to the cover's height so a description can't push the track list down;
            // bottom-aligned, overflow grows upward into the padding.
            .frame(height: density.heroCoverWide, alignment: .bottomLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        // Room for the floating back button.
        .padding(.top, density.heroTopPadding)
        .padding(.bottom, density.heroBottomPadding)
        #else
        // The cover is centred on the column whichever way the text runs, so it
        // stays its own frame rather than being stretched by the alignment.
        VStack(alignment: textAlignsLeading ? .leading : .center,
               spacing: density.heroStackSpacing) {
            cover(coverIsCircular ? density.heroCoverCircular : density.heroCoverTall)
                .mixShadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(.top, density.heroCoverTop)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: textAlignsLeading ? .leading : .center,
                   spacing: density.heroTextSpacing) {
                Text(title)
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                    .multilineTextAlignment(textAlignsLeading ? .leading : .center)
                    .frame(maxWidth: .infinity,
                           alignment: textAlignsLeading ? .leading : .center)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleIsProminent ? .mixBodyBold : .mixBody)
                        .foregroundStyle(subtitleIsProminent
                                         ? Color.mixPrimary : Color.mixTextSecondary)
                        .multilineTextAlignment(textAlignsLeading ? .leading : .center)
                        .frame(maxWidth: .infinity,
                               alignment: textAlignsLeading ? .leading : .center)
                        // Centred text keeps an inset so long descriptions don't run edge to edge.
                        .padding(.horizontal, textAlignsLeading ? 0 : 32)
                }

                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(maxWidth: .infinity,
                               alignment: textAlignsLeading ? .leading : .center)
                }

                byline()
                    .frame(maxWidth: .infinity,
                           alignment: textAlignsLeading ? .leading : .center)
            }
            .padding(.horizontal, textAlignsLeading ? 20 : 0)

            actions()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        #endif
    }
}

/// Heroes with no byline.
extension DetailHero where Byline == EmptyView {
    init(eyebrow: String,
         title: String,
         subtitle: String? = nil,
         subtitleIsProminent: Bool = false,
         metadata: String? = nil,
         coverIsCircular: Bool = false,
         @ViewBuilder cover: @escaping (CGFloat) -> Cover,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(eyebrow: eyebrow,
                  title: title,
                  subtitle: subtitle,
                  subtitleIsProminent: subtitleIsProminent,
                  metadata: metadata,
                  coverIsCircular: coverIsCircular,
                  byline: { EmptyView() },
                  cover: cover,
                  actions: actions)
    }
}

/// Filled disc for secondary hero controls, so they match the primary button.
struct HeroCircleLabel: View {
    let systemImage: String
    var foreground: Color = .mixTextSecondary
    var fill: Color = .mixSurface
    var diameter: CGFloat = 40
    /// 0-1 progress drawn as a ring. Nil for most buttons.
    var progress: Double? = nil
    /// The ring's colour. Follows the icon unless told otherwise.
    var progressTint: Color? = nil

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
            .overlay(progressRing)
            .contentShape(Circle())
    }

    /// Progress ring; the exact figure lives in the tooltip and accessibility label.
    @ViewBuilder
    private var progressRing: some View {
        if let progress {
            let fraction = min(max(progress, 0), 1)
            let tint = progressTint ?? foreground
            ZStack {
                // Unfilled track.
                Circle()
                    .strokeBorder(tint.opacity(0.22), lineWidth: ringWidth)
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    // Start at 12 o'clock.
                    .rotationEffect(.degrees(-90))
            }
            // Progress arrives in jumps; animate so it fills rather than ticks.
            .mixAnimation(.easeOut(duration: 0.3), value: fraction)
        }
    }

    private var ringWidth: CGFloat { max(2, diameter * 0.07) }
}

/// Play/shuffle/extras row under a hero. macOS: big circular play, icon
/// secondaries. iOS: secondaries left, shuffle + big play on the right.
struct HeroActionBar<Extras: View>: View {
    let isPlaying: Bool
    /// Shuffle is a mode; Play obeys it.
    let isShuffling: Bool
    let isEmpty: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var extras: () -> Extras

    private var playIcon: String { isPlaying ? MixtapeIcons.pause : MixtapeIcons.play }
    private var playTitle: String { isPlaying ? "Pause" : "Play" }

    /// The tint is the state, exactly as it is on the toolbar's toggles: lit
    /// only while shuffle is actually on.
    private var shuffleHelp: String {
        isShuffling ? "Shuffle is on — click to play in order" : "Shuffle"
    }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 14) {
            Button { ResolveTrace.shared.press("play"); onPlay() } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 52, height: 52)
                    .background(Color.mixAccentFill, in: Circle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(isEmpty)
            .help(playTitle)

            Button { ResolveTrace.shared.press("shuffle"); onShuffle() } label: {
                HeroCircleLabel(systemImage: MixtapeIcons.shuffle,
                                foreground: isShuffling ? .mixPrimary : .mixTextSecondary,
                                fill: isShuffling ? Color.mixPrimary.opacity(0.18) : .mixSurface)
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(isEmpty)
            .help(shuffleHelp)
            .accessibilityAddTraits(isShuffling ? .isSelected : [])

            extras()

            Spacer(minLength: 0)
        }
        #else
        HStack(spacing: 16) {
            extras()

            Spacer(minLength: 8)

            Button { ResolveTrace.shared.press("shuffle"); onShuffle() } label: {
                Image(systemName: MixtapeIcons.shuffle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isShuffling ? Color.mixPrimary : Color.mixTextSecondary)
                    .frame(width: 44, height: 44)
                    // Dot under shuffle, since tint alone isn't enough for colour-blind users.
                    .overlay(alignment: .bottom) {
                        if isShuffling {
                            Circle().fill(Color.mixPrimary).frame(width: 4, height: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(isEmpty)
            .accessibilityLabel("Shuffle")
            .accessibilityAddTraits(isShuffling ? .isSelected : [])

            Button { ResolveTrace.shared.press("play"); onPlay() } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 56, height: 56)
                    .background(Color.mixAccentFill, in: Circle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(isEmpty)
            .accessibilityLabel(playTitle)
        }
        #endif
    }
}

extension HeroActionBar where Extras == EmptyView {
    init(isPlaying: Bool,
         isShuffling: Bool,
         isEmpty: Bool,
         onPlay: @escaping () -> Void,
         onShuffle: @escaping () -> Void) {
        self.init(isPlaying: isPlaying,
                  isShuffling: isShuffling,
                  isEmpty: isEmpty,
                  onPlay: onPlay,
                  onShuffle: onShuffle) {
            EmptyView()
        }
    }
}
