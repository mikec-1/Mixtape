// The "made for you" half of the Discover landing, shared by both platforms. Driven by callbacks
// because macOS and iOS resolve playback differently; everything here is layout.

import SwiftUI

// MARK: - Host hooks

/// What the landing needs the host to do, grouped into one value.
struct DiscoverLandingActions {
    var playMix:      (PersonalMix) -> Void
    var playTrack:    (OnlineTrack, [OnlineTrack]) -> Void
    var openMix:      (PersonalMix) -> Void
    var openArtist:   (OnlineArtist) -> Void
    var openAlbum:    (OnlineAlbum) -> Void
    var refreshRecommended: () -> Void

    /// Right-click verbs. Each nil one is left out of the menu.
    var playNext:     ((OnlineTrack) -> Void)? = nil
    var addToQueue:   ((OnlineTrack) -> Void)? = nil

    /// Play a whole album. Nil gives a hero you open, not play. Async because the first track's id isn't known
    /// until the track list is fetched, so the button holds its own spinner across the whole thing.
    var playAlbum:    ((OnlineAlbum) async -> Void)? = nil

    /// Open Generate a Mix. Nil drops the tile at the end of "Your mixes".
    var generateMix:  (() -> Void)? = nil

    /// Discover's artist and album pages, by name and song: a card only carries credits.
    var openArtistNamed: ((String, OnlineTrack) -> Void)? = nil
    var openAlbumFor:    ((OnlineTrack) -> Void)?         = nil
}

// MARK: - Sections

struct PersonalLandingSections: View {

    let landing: PersonalLanding
    let roll: Int
    let actions: DiscoverLandingActions

    /// Track the player is resolving a stream for, passed down since the coordinator differs per platform.
    /// Lets the landing's rows and cards spin like every other list.
    var resolvingID: String? = nil

    /// The two slow shelves are still in the air.
    var shelvesLoading: Bool = false

    /// Seeds whose "Because you listened to" row is expanded, per seed so expanding one doesn't expand all.
    @State private var expandedRelated: Set<String> = []

    /// One row's worth of bubbles before "Show all".
    private static let collapsedRelated = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            mixesAndRelease

            if !landing.genreMixes.isEmpty {
                mixShelf(title: "Your genres",
                         subtitle: "The scenes your library keeps coming back to",
                         mixes: landing.genreMixes)
            } else if shelvesLoading {
                placeholderShelf(title: "Your genres",
                                 subtitle: "Working out which scenes your library lives in…")
            }

            if !landing.recommendedPool.isEmpty {
                recommendedSection
            }

            if !landing.stations.isEmpty {
                mixShelf(title: "Radios",
                         subtitle: "Charts, scenes and artists — built from the week, not from you",
                         mixes: landing.stations)
            } else if shelvesLoading {
                placeholderShelf(title: "Radios", subtitle: "Tuning this week's charts…")
            }

            ForEach(landing.related) { row in
                let isExpanded = expandedRelated.contains(row.seedArtist)
                let shown = isExpanded ? row.artists : Array(row.artists.prefix(Self.collapsedRelated))
                section(title: "Because you listened to \(row.seedArtist)",
                        accessory: row.artists.count > Self.collapsedRelated
                            ? AnyView(MixPillButton(title: isExpanded ? "Show less" : "Show all") {
                                withMixAnimation(.easeInOut(duration: 0.18)) {
                                    if isExpanded { expandedRelated.remove(row.seedArtist) }
                                    else { expandedRelated.insert(row.seedArtist) }
                                }
                            })
                            : nil) {
                    // Wrapped, not scrolled: artists are scanned for a name, and one off-screen may as well not be listed.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 16)],
                              alignment: .leading, spacing: 18) {
                        ForEach(shown) { artist in
                            MixArtistBubble(artist: artist) { actions.openArtist(artist) }
                                .contextMenu { OnlineCollectionMenu(.artist(artist)) }
                        }
                    }
                }
            }

        }
    }

    // MARK: Mixes + new release

    /// Top band: your mixes on the left, a fixed-width new-release hero on the right; stacked on a phone.
    /// The mixes take the spare width and wrap. Either half can be missing and the other takes the row.
    @ViewBuilder
    private var mixesAndRelease: some View {
        #if os(macOS)
        // Guarded: an empty HStack still gets spacing around it.
        if !shelfMixes.isEmpty || landing.newRelease != nil {
            Group {
                if isSideBySide { sideBySideBand } else { stackedBand }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(widthReader)
        }
        #else
        if !shelfMixes.isEmpty { mixesSection(paired: false) }
        if let release = landing.newRelease { newReleaseSection(release) }
        #endif
    }

    #if os(macOS)

    /// Measured width of the band: nothing upstream knows it.
    @State private var bandWidth: CGFloat = 0

    /// Two columns or stacked. Unmeasured counts as wide, since a Mac window almost always is.
    private var isSideBySide: Bool {
        bandWidth == 0 || bandWidth >= Self.sideBySideMinimum
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    bandWidth = width
                }
        }
    }

    /// Max width of the page header text. The hero's heading is lifted into the header's row, so this keeps
    /// the header out of the hero's lane. Applied in `personalHeader`.
    static let personalHeaderReserve: CGFloat = 520

    /// Fixed, not a share of the window, so the hero keeps one recognisable shape.
    private static let heroColumnWidth: CGFloat = 440

    /// Enough to keep the hero off the gutter without it reading as indented.
    private static let heroTrailingGap: CGFloat = 28

    private static let columnGutter: CGFloat = 30

    /// Below this the band stacks. Sum of the header lane, gutter and hero footprint; any narrower and they overlap.
    private static let sideBySideMinimum =
        personalHeaderReserve + columnGutter + heroColumnWidth + heroTrailingGap

    private var sideBySideBand: some View {
        HStack(alignment: .top, spacing: Self.columnGutter) {
            if !shelfMixes.isEmpty {
                mixesSection(paired: landing.newRelease != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let release = landing.newRelease {
                newReleaseSection(release)
                    // Fixed, not capped: a compressible hero wraps its title, and it's the mixes that should flex.
                    .frame(width: Self.heroColumnWidth, alignment: .leading)
                    // Raised by the hero's overhang so its panel lines up with the mix covers; the heading rides up into
                    // the "Made for you" line. Only when there are mixes to line up with.
                    .padding(.top, shelfMixes.isEmpty
                             ? 0
                             : -MixNewReleaseHero.overhang(against: MixMosaicCard.side))
                    // Outside the frame, so the panel keeps its width and stops short of the window edge.
                    .padding(.trailing, Self.heroTrailingGap)
            }
        }
    }

    /// Narrow window: one column, no lift, no trailing gap, and the mixes keep their subtitle (`paired: false`).
    private var stackedBand: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !shelfMixes.isEmpty { mixesSection(paired: false) }
            if let release = landing.newRelease {
                newReleaseSection(release)
                    .frame(maxWidth: Self.heroColumnWidth, alignment: .leading)
            }
        }
    }

    #endif

    /// Release Radar leads "Your mixes" rather than getting a one-card shelf of its own.
    private var shelfMixes: [PersonalMix] {
        (landing.releaseRadar.map { [$0] } ?? []) + landing.mixes
    }

    /// Holds Release Radar's seat while it loads, so its late arrival doesn't shift the shelf.
    private var awaitingRadar: Bool { shelvesLoading && landing.releaseRadar == nil }

    /// `paired`: something sits beside the row, so drop the subtitle to keep both bodies level.
    private func mixesSection(paired: Bool) -> some View {
        section(title: "Your mixes",
                subtitle: paired ? nil : "Built around the artists you play most") {
            mixesBody
        }
    }

    @ViewBuilder
    private var mixesBody: some View {
        #if os(macOS)
        // Wrapped so every mix is on screen. Fixed columns because `MixMosaicCard` is always 168pt wide;
        // leftover width collects at the trailing edge.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                               maximum: MixMosaicCard.side),
                                     spacing: 18)],
                  alignment: .leading, spacing: 20) {
            if awaitingRadar { MixCardPlaceholder() }
            ForEach(shelfMixes) { mix in mixCard(mix) }
            if let generate = actions.generateMix { GenerateMixTile(action: generate) }
        }
        #else
        // A phone is one card wide, so it stays a carousel.
        horizontalRow(spacing: 18) {
            if awaitingRadar { MixCardPlaceholder() }
            ForEach(shelfMixes) { mix in mixCard(mix) }
            if let generate = actions.generateMix { GenerateMixTile(action: generate) }
        }
        #endif
    }

    /// Same shelf as "Your mixes", for genre mixes and stations.
    private func mixShelf(title: String, subtitle: String, mixes: [PersonalMix]) -> some View {
        mixShelf(title: title, subtitle: subtitle) {
            ForEach(mixes) { mix in mixCard(mix) }
        }
    }

    /// The grid/carousel split, shared with the placeholder shelf so it draws at the real size.
    private func mixShelf<Cards: View>(title: String,
                                       subtitle: String,
                                       @ViewBuilder cards: () -> Cards) -> some View {
        section(title: title, subtitle: subtitle) {
            #if os(macOS)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                                   maximum: MixMosaicCard.side),
                                         spacing: 18)],
                      alignment: .leading, spacing: 20) {
                cards()
            }
            #else
            horizontalRow(spacing: 18) { cards() }
            #endif
        }
    }

    /// A shelf that hasn't arrived yet, drawn in outline at its real size so the page doesn't jump.
    private func placeholderShelf(title: String, subtitle: String) -> some View {
        mixShelf(title: title, subtitle: subtitle) {
            ForEach(0..<Self.placeholderCards, id: \.self) { _ in MixCardPlaceholder() }
        }
    }

    private static let placeholderCards = 4

    private func mixCard(_ mix: PersonalMix) -> some View {
        MixMosaicCard(mix: mix,
                      // A mix starts on its first track, so that's the id being resolved.
                      isResolving: mix.tracks.first.map { resolvingID == $0.id } ?? false,
                      onOpen: { actions.openMix(mix) },
                      onPlay: { actions.playMix(mix) })
            .contextMenu { OnlineCollectionMenu(.mix(mix)) }
    }

    /// Bare heading; the card names the artist next to their photo.
    private func newReleaseSection(_ release: FreshRelease) -> some View {
        section(title: "New release from") {
            MixNewReleaseHero(
                release: release,
                onOpenAlbum:  { actions.openAlbum(release.album) },
                onOpenArtist: { actions.openArtist(release.artist) },
                onPlay: actions.playAlbum.map { play in { await play(release.album) } }
            )
            .contextMenu { OnlineCollectionMenu(.album(release.album)) }
        }
    }

    // MARK: Recommended

    /// Two flat columns of songs and a refresh for a different twelve. Adaptive, so iPhone gets one column.
    private var recommendedSection: some View {
        let songs = landing.recommended(roll: roll)
        return section(title: "Recommended songs",
                       subtitle: landing.seeds.isEmpty
                                 ? nil
                                 : "From around \(landing.seeds.prefix(2).joined(separator: " and "))",
                       accessory: AnyView(
                        MixPillButton(title: "Refresh", systemImage: "arrow.triangle.2.circlepath") {
                            actions.refreshRecommended()
                        }
                       )) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)],
                      alignment: .leading, spacing: 2) {
                ForEach(songs) { song in
                    MixSongRow(song: song,
                               isResolving: resolvingID == song.id,
                               onOpenAlbum: actions.openAlbumFor.map { open in { open(song) } },
                               onOpenArtist: actions.openArtistNamed.map { open in { open($0, song) } }) {
                        actions.playTrack(song, songs)
                    }
                    .contextMenu { songMenu(song, context: songs) }
                }
            }
            // A roll swaps twelve rows at once; without this it's a jump cut.
            .mixAnimation(.easeInOut(duration: 0.22), value: roll)
        }
    }

    /// Same menu a Discover row gets everywhere else.
    private func songMenu(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        OnlineSongMenu(
            song:         song,
            onPlay:       { actions.playTrack(song, context) },
            onPlayNext:   actions.playNext.map   { next in { next(song) } },
            onAddToQueue: actions.addToQueue.map { add  in { add(song)  } },
            onOpenAlbum:  actions.openAlbumFor.map { open in { open(song) } },
            onOpenArtist: actions.openArtistNamed.map { open in { open($0, song) } }
        )
    }

    // MARK: Chrome

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        subtitle: String? = nil,
                                        accessory: AnyView? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: MixFontScale.size(20), weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .mixTightened()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: MixFontScale.size(12.5)))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
                Spacer(minLength: 8)
                if let accessory { accessory }
            }
            content()
        }
    }

    /// Horizontal rows bleed to the window edge; the inset restores the gutter for the first card.
    private func horizontalRow<Content: View>(spacing: CGFloat,
                                              @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) { content() }
                .padding(.vertical, 2)
        }
        .scrollClipDisabled(true)
    }
}

// MARK: - Mix card

/// Wide 2x2 mosaic: four covers read as a mix, one cover reads as an album.
struct MixMosaicCard: View {

    let mix: PersonalMix
    /// Finding the mix's first stream: the button spins.
    var isResolving: Bool = false
    let onOpen: () -> Void
    let onPlay: () -> Void

    @State private var isHovered = false

    /// Static: the band sizes the mixes column from it.
    static let side: CGFloat = 168
    private var side: CGFloat { Self.side }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                mosaic
                // Stays visible while resolving, even after the pointer leaves.
                if isHovered || isResolving {
                    Button(action: onPlay) {
                        ZStack {
                            // `mixOnAccent`, not black: black on light-mode `mixPrimary` has poor contrast.
                            Circle()
                                .fill(Color.mixPrimary)
                                .frame(width: 40, height: 40)
                                .mixShadow(color: .black.opacity(0.35), radius: 8, y: 4)
                            if isResolving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color.mixOnAccent)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color.mixOnAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .padding(10)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(mix.title)
                    .font(.system(size: MixFontScale.size(14.5), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                // Fallback line so an empty subtitle doesn't shift the title.
                Text(mix.subtitle.isEmpty ? "A mix built around \(mix.seedArtist)" : mix.subtitle)
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: side, alignment: .leading)
        }
        // Top-aligned: `LazyVGrid` centres short cells, so a wrapped subtitle would offset its neighbours.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .mixTapAction(onOpen)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
        .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
    }

    private var mosaic: some View {
        Group {
            if mix.covers.count >= 4 {
                let half = (side - 2) / 2
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        tile(mix.covers[0], side: half)
                        tile(mix.covers[1], side: half)
                    }
                    HStack(spacing: 2) {
                        tile(mix.covers[2], side: half)
                        tile(mix.covers[3], side: half)
                    }
                }
            } else {
                tile(mix.covers.first, side: side)
            }
        }
        .frame(width: side, height: side)
        .overlay(MixCoverBand(title: mix.title,
                              accent: MixCoverStyle.color(for: mix.id),
                              side: side))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mixShadow(color: .black.opacity(isHovered ? 0.32 : 0.18),
                radius: isHovered ? 14 : 7, y: isHovered ? 7 : 3)
    }

    private func tile(_ url: URL?, side: CGFloat) -> some View {
        CachedRemoteImage(url: url, points: side) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.mixSurface2
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

// MARK: - New release hero

/// One new release, drawn big: a face, a name, a large cover and the only filled surface on the landing.
struct MixNewReleaseHero: View {

    let release: FreshRelease
    let onOpenAlbum: () -> Void
    let onOpenArtist: () -> Void
    /// Nil when the host can't resolve an album's tracks; the cover still opens. Awaited so the button
    /// knows when both the fetch and the resolve are done. See `DiscoverLandingActions.playAlbum`.
    let onPlay: (() async -> Void)?

    @State private var isHovered = false
    @State private var artistHovered = false
    /// Set for as long as `onPlay` is running.
    @State private var isStarting = false

    /// Clearly bigger than the mix cards beside it.
    static let coverSide: CGFloat = 150
    static let avatarSide: CGFloat = 48

    private static let panelPadding: CGFloat = 12
    private static let stackSpacing: CGFloat = 14

    /// How much taller this is than `side`-tall covers, i.e. how far the band lifts it. Derived so it
    /// follows size changes.
    static func overhang(against side: CGFloat) -> CGFloat {
        max(0, avatarSide + stackSpacing + panelPadding * 2 + coverSide - side)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.stackSpacing) {
            artistLine
            releasePanel
        }
    }

    private var artistLine: some View {
        HStack(spacing: 11) {
            CachedRemoteImage(url: release.artist.imageURL, points: Self.avatarSide) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: "music.mic")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: Self.avatarSide, height: Self.avatarSide)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.mixPrimary, lineWidth: artistHovered ? 2 : 0))

            Text(release.artist.name)
                .font(.system(size: MixFontScale.size(17), weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .mixTapAction(onOpenArtist)
        .mixHoverCursor { artistHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: artistHovered)
    }

    private var releasePanel: some View {
        HStack(alignment: .center, spacing: 14) {
            CachedRemoteImage(url: release.album.coverURL, points: Self.coverSide) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: Self.coverSide, height: Self.coverSide)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .mixShadow(color: .black.opacity(isHovered ? 0.32 : 0.18),
                    radius: isHovered ? 14 : 7, y: isHovered ? 7 : 3)

            VStack(alignment: .leading, spacing: 5) {
                if let kind = release.album.recordTypeLabel {
                    Text(kind)
                        .font(.system(size: MixFontScale.size(11.5), weight: .semibold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .textCase(.uppercase)
                }
                Text(release.album.title)
                    .font(.system(size: MixFontScale.size(20), weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .mixTightened()
                if let released = release.album.releaseDate {
                    Text(released.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: MixFontScale.size(12)))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer(minLength: 4)

            if let onPlay {
                Button {
                    // Guarded here, not `.disabled`, which would fade the spinner. A second press would repeat the album fetch.
                    guard !isStarting else { return }
                    Task {
                        isStarting = true
                        await onPlay()
                        isStarting = false
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.mixPrimary)
                            .frame(width: 42, height: 42)
                            .mixShadow(color: .black.opacity(0.3), radius: 7, y: 3)
                        if isStarting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.mixOnAccent)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.mixOnAccent)
                        }
                    }
                }
                .buttonStyle(.plain).mixHandCursor()
                .mixHoverCursor { _ in }
                .mixAnimation(.easeInOut(duration: 0.12), value: isStarting)
            }
        }
        .padding(Self.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.mixSurface.opacity(isHovered ? 1 : 0.7))
        )
        .contentShape(Rectangle())
        .mixTapAction(onOpenAlbum)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Song row

/// Flat: no card, border or fill until hovered.
struct MixSongRow: View {

    let song: OnlineTrack
    /// 1-based position. Nil on landing shelves, where there's no real order.
    var index: Int? = nil
    /// The playing song, drawn in the brand colour.
    var isCurrent: Bool = false
    /// Finding this song's stream: scrim and spinner over the artwork, like every other list.
    var isResolving: Bool = false
    /// Clickable names on the Mac. A phone row stays one tap target.
    var onOpenAlbum:  (() -> Void)?       = nil
    var onOpenArtist: ((String) -> Void)? = nil
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
        // A real button, not a tap gesture: a stretched stack under `.contextMenu` gets a mismatched hit region
        // on AppKit. Not disabled while resolving, which would fade the whole row; the coordinator drops repeats.
        Button(action: onPlay) { rowBody }
            .buttonStyle(.plain).mixHandCursor()
            .mixHoverCursor { isHovered = $0 }
            .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
            .mixAnimation(.easeInOut(duration: 0.12), value: isResolving)
    }

    private var rowBody: some View {
        HStack(spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.system(size: MixFontScale.size(12)).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 26, alignment: .trailing)
            }

            ZStack {
                CachedRemoteImage(url: song.artworkURL, points: 44) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.mixSurface2
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if isResolving {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else if isCurrent {
                    // Marks the playing row with a shape as well as colour.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    #if os(macOS)
                    MixLinkText(text: song.title,
                                font: .system(size: MixFontScale.size(13.5), weight: .medium),
                                color: isCurrent ? Color.mixPrimary : Color.mixTextPrimary,
                                target: onOpenAlbum)
                    #else
                    Text(song.title)
                        .font(.system(size: MixFontScale.size(13.5), weight: .medium))
                        .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    #endif
                    if song.isExplicit { MixExplicitBadge() }
                }
                #if os(macOS)
                if let onOpenArtist {
                    MixArtistLine(targets: song.displayArtists.map { name in (name, { onOpenArtist(name) }) },
                                  font: .system(size: MixFontScale.size(12)))
                } else {
                    artistText(song.artistName)
                }
                #else
                artistText(song.artistName)
                #endif
            }

            Spacer(minLength: 8)

            if song.duration > 0 {
                Text(Self.formatted(song.duration))
                    .font(.system(size: MixFontScale.size(12)).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
        )
        // Inside the label so the whole row, Spacer gap included, is the hit region.
        .contentShape(Rectangle())
    }

    private func artistText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: MixFontScale.size(12)))
            .foregroundStyle(Color.mixTextSecondary)
            .lineLimit(1)
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Artist bubble

struct MixArtistBubble: View {

    let artist: OnlineArtist
    let onOpen: () -> Void

    @State private var isHovered = false

    /// Matches the grid's `minimum`; wider would overflow its column.
    private let side: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            CachedRemoteImage(url: artist.imageURL, points: side) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: "music.mic")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.mixPrimary, lineWidth: isHovered ? 2 : 0))
            .mixShadow(color: .black.opacity(isHovered ? 0.3 : 0.16),
                    radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)

            Text(artist.name)
                .font(.system(size: MixFontScale.size(13), weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .frame(width: side)
        }
        // Top-aligned: `LazyVGrid` centres short cells, so a wrapped subtitle would offset its neighbours.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .mixTapAction(onOpen)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Album card

struct MixAlbumCard: View {

    let album: OnlineAlbum
    /// The credit as links. Mac only, like the song rows.
    var onOpenArtist: ((String) -> Void)? = nil
    let onOpen: () -> Void

    @State private var isHovered = false

    /// Matches the grid's `minimum`; wider would overflow its column.
    private let side: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CachedRemoteImage(url: album.coverURL, points: side) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .mixShadow(color: .black.opacity(isHovered ? 0.3 : 0.16),
                    radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: MixFontScale.size(13.5), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                #if os(macOS)
                if let onOpenArtist {
                    MixArtistLine(targets: ImportService.creditedArtists(from: album.artistName)
                                    .map { name in (name, { onOpenArtist(name) }) },
                                  font: .system(size: MixFontScale.size(12)),
                                  color: Color.mixTextTertiary)
                } else { artistText }
                #else
                artistText
                #endif
            }
            .frame(width: side, alignment: .leading)
        }
        // Top-aligned: `LazyVGrid` centres short cells, so a wrapped subtitle would offset its neighbours.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .mixTapAction(onOpen)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }

    private var artistText: some View {
        Text(album.artistName)
            .font(.system(size: MixFontScale.size(12)))
            .foregroundStyle(Color.mixTextTertiary)
            .lineLimit(1)
    }
}

// MARK: - Small parts

/// The "E" on explicit songs. Filled, with the glyph cut out in the page colour, so it reads in both appearances.
struct MixExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: MixFontScale.size(9), weight: .heavy))
            .foregroundStyle(Color.mixBackground)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.mixTextSecondary)
            )
            .accessibilityLabel("Explicit")
    }
}

/// Marks a song edit, styled like the "E".
struct MixEditBadge: View {
    var body: some View {
        Text("EDIT")
            .font(.system(size: MixFontScale.size(8), weight: .heavy))
            .foregroundStyle(Color.mixBackground)
            .padding(.horizontal, 3)
            .frame(height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.mixTextSecondary)
            )
            .accessibilityLabel("Edit")
    }
}

/// Inline action beside a section head ("Refresh", "Show all"). A pill so it reads as a control at 12pt.
struct MixPillButton: View {

    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: MixFontScale.size(10.5), weight: .semibold))
                }
                Text(title).font(.system(size: MixFontScale.size(12), weight: .semibold))
            }
            .foregroundStyle(isHovered ? Color.mixTextPrimary : Color.mixTextSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.primary.opacity(isHovered ? 0.12 : 0.07))
            )
        }
        .buttonStyle(.plain).mixHandCursor()
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Hover

extension View {
    /// Hover state plus the pointing-hand cursor on macOS, no-op on iOS.
    @ViewBuilder
    func mixHoverCursor(_ update: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        onHover { hovering in
            update(hovering)
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #else
        self
        #endif
    }
}


// MARK: - Generate tile

/// Last tile in "Your mixes": make your own. Same footprint as the mosaic, grows on hover.
/// Blend's invite tile reuses it with its own words.
struct GenerateMixTile: View {

    var icon = "plus"
    var title = "Generate a Mix"
    var subtitle = "Pick a mood and make your own"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.mixSurface2)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.mixPrimary : Color.mixTextSecondary)
                        .scaleEffect(isHovered ? 1.18 : 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isHovered ? Color.mixPrimary : Color.mixSeparator,
                                      lineWidth: 1)
                }
                .frame(width: MixMosaicCard.side, height: MixMosaicCard.side)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: MixFontScale.size(14.5), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: MixMosaicCard.side, alignment: .leading)
        }
        .contentShape(Rectangle())
        .mixTapAction(action)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.mixSnappy, value: isHovered)
        .accessibilityLabel(title)
    }
}

/// Placeholder mix card. No shimmer: a `repeatForever` animation left running can get the app killed on iOS.
private struct MixCardPlaceholder: View {

    private var side: CGFloat { MixMosaicCard.side }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.mixTextPrimary.opacity(0.07))
                .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 6) {
                bar(width: side * 0.62, height: 10)
                bar(width: side * 0.92, height: 8)
            }
            .frame(width: side, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.mixTextPrimary.opacity(0.05))
            .frame(width: width, height: height)
    }
}
