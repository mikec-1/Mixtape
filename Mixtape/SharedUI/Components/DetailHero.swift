//
//  DetailHero.swift
//  Mixtape
//
//  The header shared by the playlist, album and artist detail screens.
//
//  On macOS it's a wide banner — cover on the left, text and controls stacked
//  beside it — because a centred column in a 1200pt window pushes the actual
//  track list below the fold.
//
//  On iOS the cover is centred and everything under it is left aligned. Centred
//  text under a centred cover is the shape a splash screen has, not a list
//  header: a title, a byline and a metadata line each centred on their own width
//  give three different left edges, and the eye has to find the start of every
//  line separately. One left edge, shared with the rows below, is why every
//  music app that has settled on a layout has settled on this one.
//
//  The exception is a circular cover — the artist page. A left-aligned title
//  under a centred circle reads as a mistake rather than as a decision, because
//  a circle has no edge for it to line up with.
//

import SwiftUI
import Combine

// MARK: - Artwork wash

/// The colour at the very top of whatever wash is currently on screen.
///
/// macOS reads this to tint the window titlebar to match, so the gradient
/// continues up through the chrome instead of stopping dead at a straight line
/// under the traffic lights. Nil means no wash is showing and the standard
/// system chrome should come back.
@MainActor
final class ArtworkWashTint: ObservableObject {

    static let shared = ArtworkWashTint()

    @Published private(set) var color: Color?

    /// The two sampled colours behind that tint, and the strength they were
    /// drawn at — everything needed to reproduce the page's ramp exactly.
    /// The sidebar draws the same gradient from these, so the wash runs across
    /// the whole window instead of stopping at the content column's edge.
    @Published private(set) var stops: [Color] = []
    @Published private(set) var intensity: Double = 1

    /// The wash that published the current colour. Only it may clear the value,
    /// so a screen being torn down can't wipe the tint of the screen that just
    /// replaced it — the order those two events arrive in isn't guaranteed.
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

    /// What the chrome — sidebar, titlebar, queue panel — draws at.
    ///
    /// Stronger than the page's own ramp on purpose: those surfaces are narrow
    /// and sit against the window edge, where the same opacity reads as grey.
    var chromeIntensity: Double { min(intensity * 1.45, 1.6) }

    func resign(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        color = nil
        stops = []
    }
}

/// The vertical colour wash a screen takes from its artwork.
///
/// It lives as a modifier rather than inside the hero because it has to be
/// *taller* than the hero to look right — the gradient must finish somewhere
/// inside the track list, or it ends on a visible seam right under the cover.
/// Album and artist detail can host it on the hero itself (they're plain
/// ScrollViews), but a List clips each row to its own bounds, so the playlist
/// screen applies it to the List instead and lets the colour run behind the
/// first few rows.
struct ArtworkWash: ViewModifier {

    let source: Data?
    /// Scales the whole ramp. 1 is the detail-page strength; Home uses less.
    var intensity: Double = 1.0
    /// What to wash with when `source` yields nothing. Empty — the default —
    /// means no wash, which is right for a page whose subject genuinely has no
    /// picture: an invented colour there is a claim about artwork that isn't
    /// here. A surface that is meant to be tinted regardless passes its own.
    var fallback: [Color] = []

    @State private var colors: [Color] = []
    /// Identity for the shared tint — see `ArtworkWashTint.resign`.
    @State private var id = UUID()
    @Environment(\.mixChrome) private var chrome

    /// Flat chrome skips the wash entirely rather than drawing it at zero
    /// opacity, and that is most of the point: no gradient, and no cover to
    /// decode and sample either. Sampling is the expensive half — a megabyte of
    /// JPEG per page — and a wash nobody can see has no reason to pay for it.
    ///
    /// Switched off inside one chain rather than by returning `content` from the
    /// other half of an `if`. This modifier wraps entire screens, so branching
    /// would rebuild the page underneath — losing its scroll position and every
    /// piece of view state in it — because the user changed a setting.
    func body(content: Content) -> some View {
        content
            .background(alignment: .top) { gradient }
            // Keyed on the setting as well as the cover, so switching back to
            // rich chrome samples the artwork it skipped on the way out.
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
                // Decoding runs off the main thread: a screen is often pushed
                // and painted in the same frame, and a cover can be a megabyte.
                let sampled = await Task.detached(priority: .userInitiated) {
                    ArtworkColors.gradientColors(from: source)
                }.value
                // Unreadable artwork lands here too, not just missing artwork —
                // the page asked to be tinted, and "the JPEG didn't decode" is
                // not a reason to show it untinted.
                colors = sampled.isEmpty ? fallback : sampled
                ArtworkWashTint.shared.publish(colors: colors, intensity: intensity, from: id)
            }
            // Claims the tint again every time this screen comes back, without
            // waiting for the sampling to re-run — it doesn't, the source hasn't
            // changed. Fullscreen lyrics replaces the content column outright and
            // tints the chrome its own colour; without this, the page underneath
            // returned and the chrome stayed on the lyrics background, because
            // nothing here had anything left to say.
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

    /// Kept as a constant because the titlebar tint has to match this exactly.
    static let topOpacity: Double = 0.66

    #if os(macOS)
    static let height: CGFloat = 520
    #else
    static let height: CGFloat = 520
    #endif
}

/// The wash ramp itself, as a view.
///
/// Its own type so that surfaces which aren't the page — the sidebar — can draw
/// the *identical* gradient from the shared tint rather than an approximation of
/// it. Two ramps that are nearly the same colour read as a seam, which is the
/// whole thing this is trying not to be.
///
/// Five stops rather than three: a long ramp between two colours bands badly
/// across a wide window, and the extra stops let it fade out on a curve instead
/// of a straight line.
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
    /// Tints the top of this view with colours sampled from `source`.
    /// A nil source means no wash at all unless `fallback` says otherwise —
    /// nothing invented by default.
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
    /// Secondary line — album artist, playlist description. Nil to omit.
    var subtitle: String?
    /// Tinted with the brand colour and given more weight than `metadata`.
    var subtitleIsProminent: Bool = false
    /// Song counts, durations, years — the small grey line.
    var metadata: String?
    /// Circular on artist pages, rounded-rect everywhere else.
    var coverIsCircular: Bool = false

    /// Whose page this is, drawn where `metadata` would be — faces and names,
    /// which no amount of string can express. A page that has one passes its
    /// counts *inside* the byline and leaves `metadata` nil, so the two never
    /// stack into two grey lines saying overlapping things.
    @ViewBuilder var byline: () -> Byline
    @ViewBuilder var cover: (CGFloat) -> Cover
    @ViewBuilder var actions: () -> Actions

    @Environment(\.mixDensity) private var density

    /// See the file header: everything under a rectangular cover shares one left
    /// edge with the rows below it; a circular cover has no edge to share.
    private var textAlignsLeading: Bool { !coverIsCircular }

    /// The hero doesn't tint itself — every screen applies `.artworkWash` to its
    /// own container so the colour can reach the window chrome and the rows
    /// below, neither of which the hero can paint into.
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
            // Takes the rest of the banner rather than being followed by a
            // Spacer that does. Same look for the text, which is still leading
            // aligned — but it means an action row can push something out to the
            // far edge of the page (the playlist's search and sort controls) as
            // well as clustering at the near one.
            //
            // The height is the cover's, so the cover alone decides how tall the
            // banner is. Without that, a playlist *with* a description built a
            // text column a few points taller than the cover and pushed the whole
            // track list down with it — so switching between two playlists moved
            // the column headers and the first row, for no reason a person could
            // see. Text that outgrows the frame still draws (it is bottom
            // aligned, so it grows up into the banner's own top padding); it just
            // no longer drags the page down behind it.
            .frame(height: density.heroCoverWide, alignment: .bottomLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        // Drill-down pages float their back control over this corner rather
        // than stacking a bar above the hero, so the cover starts below it.
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
                        // The centred layout kept its inset so a long
                        // description doesn't run the full width of the phone;
                        // left-aligned text already has a margin.
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

/// The overwhelming majority of heroes are one thing's page — an album, an
/// artist, your own playlist — and have nobody to name. They keep the call site
/// they always had.
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

/// The look every secondary control in a hero row wears: a filled disc beside
/// the big primary button.
///
/// It started on the public playlist page, where an overflow menu had to sit
/// next to a capsule and a loose glyph would have looked like a stray. It's here
/// so the rest of the hero rows can wear it too — a row of one solid circle and
/// two bare icons reads as three unrelated things, which is exactly what it
/// looked like on the playlist page.
struct HeroCircleLabel: View {
    let systemImage: String
    var foreground: Color = .mixTextSecondary
    var fill: Color = .mixSurface
    var diameter: CGFloat = 40
    /// How far along whatever this button started is, 0 to 1, drawn as a ring
    /// around the disc. Nil on a button that isn't measuring anything, which is
    /// nearly all of them.
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

    /// The disc's own edge, redrawn as a dial.
    ///
    /// A ring rather than a number: at forty points across there is no room for
    /// "45%" that anyone could read, and the thing people actually want off a
    /// progress indicator at this size is "roughly how far, and is it moving".
    /// The exact figure lives in the tooltip and the accessibility label.
    @ViewBuilder
    private var progressRing: some View {
        if let progress {
            let fraction = min(max(progress, 0), 1)
            let tint = progressTint ?? foreground
            ZStack {
                // The unfilled part of the dial, so a download that has barely
                // started reads as a ring with a little colour in it rather
                // than as a stray green tick floating at the top of a disc.
                Circle()
                    .strokeBorder(tint.opacity(0.22), lineWidth: ringWidth)
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    // A trim starts at 3 o'clock. Turned a quarter back so the
                    // ring fills from midnight and closes clockwise, the way
                    // every other dial anyone has watched does.
                    .rotationEffect(.degrees(-90))
            }
            // Progress arrives in jumps — one song landing at a time — and an
            // unanimated ring would tick rather than fill.
            .mixAnimation(.easeOut(duration: 0.3), value: fraction)
        }
    }

    private var ringWidth: CGFloat { max(2, diameter * 0.07) }
}

/// The play / shuffle / extras row under a hero.
///
/// macOS gets a large circular primary button with icon-only secondaries.
///
/// iOS used to stack two full-width pills, Play and Shuffle, which gave equal
/// weight to the thing everyone presses and the thing some people press, and
/// pushed the secondary controls onto a second row of their own. It now reads
/// the way the rest of the category does: the secondary controls cluster on the
/// left as bare discs, and the right end carries shuffle and then one large
/// filled play button — the biggest target on the screen, under the thumb, at
/// the edge where the thumb already is.
struct HeroActionBar<Extras: View>: View {
    let isPlaying: Bool
    /// Whether shuffle is currently on. Shuffle is a *mode*, not a one-shot
    /// action: pressing it used to jump straight into a random song, so there
    /// was no way to turn it back off from here and no way to tell whether it
    /// was on. Now it sets the mode and Play obeys it.
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
