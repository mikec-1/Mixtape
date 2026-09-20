// PersonalLandingSections.swift
// Mixtape — SharedUI/Discover
//
// The "made for you" half of the Discover landing, shared by both platforms.
//
// Written platform-neutral and driven by callbacks rather than by the
// environment, because the two Discover views resolve playback differently —
// macOS plays straight through the coordinator, iOS goes via the remote
// resolver — and neither of those belongs in a card. The host passes in what
// "play this" means; everything here is layout.
//
// On the look, the brief was that Discover was "squared, boxed" and didn't
// match the app. Three things drive that impression, and all three are fixed
// here: bordered/filled containers around content that doesn't need them
// (rows are flat, hover is the only surface), uniform card sizes that turn a
// page into a spreadsheet (mixes are wide mosaics, artists are circles, albums
// are square — three silhouettes, so the eye can tell rows apart while
// scrolling), and section headings that all weigh the same (the page now has a
// display-size title and 20pt section heads under it).

import SwiftUI

// MARK: - Host hooks

/// What the landing needs the hosting view to do. Grouped into one value so
/// adding a row doesn't mean threading a seventh closure through three files.
struct DiscoverLandingActions {
    var playMix:      (PersonalMix) -> Void
    var playTrack:    (OnlineTrack, [OnlineTrack]) -> Void
    var openMix:      (PersonalMix) -> Void
    var openArtist:   (OnlineArtist) -> Void
    var openAlbum:    (OnlineAlbum) -> Void
    var refreshRecommended: () -> Void

    /// The right-click verbs. Optional, and each one omitted simply doesn't
    /// appear in the menu — a host that can't queue shouldn't be made to offer
    /// it. They're closures for the same reason everything else here is: the
    /// two platforms resolve a song differently and neither resolution belongs
    /// in a card.
    var playNext:     ((OnlineTrack) -> Void)? = nil
    var addToQueue:   ((OnlineTrack) -> Void)? = nil
    var addToLibrary: ((OnlineTrack) -> Void)? = nil

    /// Play a whole record. Optional like the verbs above, and for the same
    /// reason plus one more: it needs the album's track list, which is a fetch
    /// no card should be doing. A host that doesn't wire it gets a hero you
    /// open rather than one you play.
    ///
    /// `async` unlike the rest, because the hero has no way to watch this one
    /// finish. Every other play affordance here is started on a track, so
    /// `resolvingID` names it and the card can compare. An album's first track
    /// isn't known until the fetch this closure performs comes back — the busy
    /// window *starts* before there's an id to watch. Awaiting it lets the
    /// button hold its own spinner across the whole thing instead.
    var playAlbum:    ((OnlineAlbum) async -> Void)? = nil

    /// Open "Generate a Mix". Optional: a host without an entry point for it
    /// simply doesn't get the tile at the end of "Your mixes".
    var generateMix:  (() -> Void)? = nil
}

// MARK: - Sections

struct PersonalLandingSections: View {

    let landing: PersonalLanding
    let roll: Int
    let actions: DiscoverLandingActions

    /// The track the player is currently resolving a stream for, if any —
    /// `OnlinePlaybackCoordinator.resolvingID`, passed down rather than read,
    /// because the coordinator isn't the same object on both platforms.
    ///
    /// Pressing play here is not a fast thing: the stream has to be found
    /// before a note comes out, and a card that acknowledges nothing in the
    /// meantime reads as a card that didn't take the click. Every other list in
    /// the app already spins while this is set; this is what lets the landing's
    /// own rows and cards do the same.
    var resolvingID: String? = nil

    /// The two slow shelves are still in the air.
    var shelvesLoading: Bool = false

    /// Seed artists whose "Because you listened to" row has been expanded.
    ///
    /// Keyed by seed name rather than one flag for all of them: there are up to
    /// five of these rows, twelve artists each, and expanding all sixty because
    /// you wanted to see the rest of one is how the page got long in the first
    /// place.
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
                    // Wrapped, not scrolled. A horizontal row is right for
                    // albums and mixes — you flick through those without a
                    // particular one in mind — but artists are scanned for a
                    // name you already have in mind, and a name three drags
                    // off-screen may as well not be listed.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 16)],
                              alignment: .leading, spacing: 18) {
                        ForEach(shown) { artist in
                            MixArtistBubble(artist: artist) { actions.openArtist(artist) }
                                .contextMenu {
                                    Button("Open Artist", systemImage: MixtapeIcons.artist) {
                                        actions.openArtist(artist)
                                    }
                                    Divider()
                                    ShareMenuItems(.artist(artist))
                                }
                        }
                    }
                }
            }

            // `landing.freshReleases` used to be drawn here — a third column in
            // the band on a Mac, its own row on a phone. It leads the page's
            // "New releases" section now instead, on both platforms: the same
            // albums, in the section whose name already describes them, rather
            // than in a corner of a band about something else.
        }
    }

    // MARK: Mixes + new release

    /// The top band: your mixes on the left, one new release blown up on the
    /// right. On a phone there is no "beside", so the two stack.
    ///
    /// Two columns, not three, and the elasticity is the other way round from
    /// where it started: **the mixes take the room and the hero is a fixed
    /// slab.** The band used to size the mixes to their own cards and hand the
    /// leftover to a third column of release rows, which meant the mixes were
    /// capped at two cards and everything past the second was hidden behind a
    /// sideways drag. With six mixes that was four of them — the exact opposite
    /// of what a section called "Your mixes" is for.
    ///
    /// So the third column moved out of the band entirely (it feeds the page's
    /// "New releases" section now), the hero took its place against the right
    /// edge, and the mixes got the width back and spend it wrapping.
    ///
    /// Either half can be missing — a thin history, nobody releasing anything
    /// lately — and the survivor takes the row.
    @ViewBuilder
    private var mixesAndRelease: some View {
        #if os(macOS)
        // Guarded rather than left to collapse on its own: an empty HStack is
        // still a view, and the enclosing stack would space around it.
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

    /// The band's own width. Measured, because nothing upstream knows it: the
    /// page is a plain `VStack` in a `ScrollView`, so the only view that can
    /// answer "how much room is there" is this one.
    @State private var bandWidth: CGFloat = 0

    /// Two columns, or one on top of the other.
    ///
    /// Unmeasured counts as wide. A Mac window is almost always past the
    /// threshold, so guessing that way costs at most one frame on the rare
    /// narrow one, where guessing the other way costs one on every window.
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

    /// What the page header is allowed to occupy, and the reason this number
    /// exists at all: the hero's heading is *lifted* out of the band and into
    /// the header's row, so the two share a line and only the gutter between
    /// their lanes keeps them apart. The header's text is capped to this so it
    /// can't grow into the hero's lane — see `personalHeader`, which applies it.
    static let personalHeaderReserve: CGFloat = 520

    /// A slab, not a share of the window: the hero's job is to be one fixed,
    /// recognisable shape, and a hero that changes width with the window is
    /// just another flexible box.
    private static let heroColumnWidth: CGFloat = 440

    /// Enough to keep the hero off the gutter without it reading as indented.
    private static let heroTrailingGap: CGFloat = 28

    private static let columnGutter: CGFloat = 30

    /// Under this the band stops being a band.
    ///
    /// Summed from its parts rather than picked as a round number, because
    /// every part is load-bearing: the header's lane, the gutter, and the
    /// hero's whole footprint. Below it the header's text and the hero's
    /// lifted heading would be sharing a line *and* overlapping, and the mixes
    /// would be down to a single card while the hero squeezed its own title to
    /// two syllables — which is precisely what a narrow window used to look
    /// like.
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
                    // Fixed, not capped. `maxWidth` let the HStack compress the
                    // hero whenever the mixes wanted room, and a compressed
                    // hero spends the loss on its text column — which is how a
                    // 20pt title ended up wrapping to "BALL / ON…" beside a
                    // cover with space to spare. It's the mixes that flex.
                    .frame(width: Self.heroColumnWidth, alignment: .leading)
                    // Lifted, not rebuilt. The hero is a heading, a face and a
                    // panel stacked 236pt tall; the mosaics beside it are 168.
                    // Left alone, the two columns start level and the panel
                    // hangs 68pt below the covers.
                    //
                    // Raising the whole column by that 68 lands the panel
                    // exactly parallel to them — bottom edge on their bottom
                    // edge, top within 6pt, because a 174pt panel and a 168pt
                    // cover are near enough the same object. What rides up
                    // above the band is the heading and the artist row, into
                    // the empty half of the "Made for you" line.
                    //
                    // Only when there's a mixes column to be parallel *to*:
                    // alone, the hero has nothing to line up with and would
                    // just be sitting 68pt too high.
                    .padding(.top, shelfMixes.isEmpty
                             ? 0
                             : -MixNewReleaseHero.overhang(against: MixMosaicCard.side))
                    // Outside the frame, so the panel keeps its full width and
                    // simply stops short of the gutter. The hero is a filled
                    // surface and the only one on the page — flush against the
                    // window edge it read as pinned there rather than laid out.
                    .padding(.trailing, Self.heroTrailingGap)
            }
        }
    }

    /// The narrow window: one column, and every rule the wide one needs is off.
    ///
    /// No lift, because there is nothing beside the hero to be parallel to and
    /// the header's text now runs the full width it would have been lifted
    /// into. No trailing gap, because it isn't against the edge. And the mixes
    /// get their subtitle back, since nothing sits level with their heading any
    /// more — the same `paired: false` the phone has always used.
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

    /// `paired` is "there's something beside me", and it costs the row its
    /// subtitle: the heading next to it is one line, and two section bodies
    /// starting at different heights looks like a mistake.
    /// Release Radar rides at the head of "Your mixes" rather than in a shelf of
    /// its own: it's the same kind of thing — a card that opens a list you can
    /// play, save and download — and a one-card row would have been mostly title.
    private var shelfMixes: [PersonalMix] {
        (landing.releaseRadar.map { [$0] } ?? []) + landing.mixes
    }

    /// Release Radar leads this shelf, and it's built off the critical path
    /// like the other two — so it lands *after* the mixes are drawn and would
    /// shove every card one place to the right as it arrived. Holding its seat
    /// keeps the shelf still.
    private var awaitingRadar: Bool { shelvesLoading && landing.releaseRadar == nil }

    private func mixesSection(paired: Bool) -> some View {
        section(title: "Your mixes",
                subtitle: paired ? nil : "Built around the artists you play most") {
            mixesBody
        }
    }

    @ViewBuilder
    private var mixesBody: some View {
        #if os(macOS)
        // Wrapped, not scrolled — the point of giving this column the width was
        // to put every mix on screen at once.
        //
        // The columns are fixed rather than stretchy because `MixMosaicCard` is
        // 168pt wide whatever it's handed: a wider column wouldn't grow the
        // card, it would just open uneven gaps between cards that are meant to
        // read as one shelf. Leftover width collects at the trailing edge,
        // where the hero already ends the row.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                               maximum: MixMosaicCard.side),
                                     spacing: 18)],
                  alignment: .leading, spacing: 20) {
            if awaitingRadar { MixCardPlaceholder() }
            ForEach(shelfMixes) { mix in mixCard(mix) }
            if let generate = actions.generateMix { GenerateMixTile(action: generate) }
        }
        #else
        // A phone is one card wide. Wrapping six mixes here would push the rest
        // of the page three screens down, so this stays the carousel it was.
        horizontalRow(spacing: 18) {
            if awaitingRadar { MixCardPlaceholder() }
            ForEach(shelfMixes) { mix in mixCard(mix) }
            if let generate = actions.generateMix { GenerateMixTile(action: generate) }
        }
        #endif
    }

    /// The same shelf as "Your mixes", for lists that aren't built from your
    /// seeds — genre mixes and stations. Same card, same grid/carousel split,
    /// so both arrive with playing, opening, saving and the context menu.
    private func mixShelf(title: String, subtitle: String, mixes: [PersonalMix]) -> some View {
        mixShelf(title: title, subtitle: subtitle) {
            ForEach(mixes) { mix in mixCard(mix) }
        }
    }

    /// The grid/carousel split itself, so the placeholder shelf below draws at
    /// exactly the real one's size without repeating it.
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

    /// A shelf that hasn't arrived yet, drawn at its real size.
    ///
    /// The alternative is nothing at all, which is what the page used to do:
    /// it looked complete, and then two rows appeared under the reader's
    /// pointer several seconds later and moved everything they were looking at.
    /// Cards drawn in outline say "more is coming, here" and keep the scroll
    /// height honest.
    private func placeholderShelf(title: String, subtitle: String) -> some View {
        mixShelf(title: title, subtitle: subtitle) {
            ForEach(0..<Self.placeholderCards, id: \.self) { _ in MixCardPlaceholder() }
        }
    }

    private static let placeholderCards = 4

    private func mixCard(_ mix: PersonalMix) -> some View {
        MixMosaicCard(mix: mix,
                      // A mix starts on its first track, so that's the id the
                      // coordinator will be resolving — the same comparison the
                      // song rows make, one indirection further in.
                      isResolving: mix.tracks.first.map { resolvingID == $0.id } ?? false,
                      onOpen: { actions.openMix(mix) },
                      onPlay: { actions.playMix(mix) })
            .contextMenu {
                Button("Play", systemImage: "play.fill") { actions.playMix(mix) }
                Button("Open Mix", systemImage: "square.stack") { actions.openMix(mix) }
            }
    }

    /// The heading is the bare phrase and the artist is named by the card, so
    /// the face and the name arrive together — "New release from" over a
    /// stranger's name is a caption; over their photo it's a recommendation.
    private func newReleaseSection(_ release: FreshRelease) -> some View {
        section(title: "New release from") {
            MixNewReleaseHero(
                release: release,
                onOpenAlbum:  { actions.openAlbum(release.album) },
                onOpenArtist: { actions.openArtist(release.artist) },
                onPlay: actions.playAlbum.map { play in { await play(release.album) } }
            )
            .contextMenu {
                if let play = actions.playAlbum {
                    Button("Play", systemImage: "play.fill") {
                        Task { await play(release.album) }
                    }
                }
                Button("Open Album", systemImage: MixtapeIcons.album) {
                    actions.openAlbum(release.album)
                }
                Button("Open Artist", systemImage: MixtapeIcons.artist) {
                    actions.openArtist(release.artist)
                }
                Divider()
                ShareMenuItems(.album(release.album))
            }
        }
    }

    // MARK: Recommended

    /// The row Monochrome does well: no cards, no borders, two flat columns of
    /// songs and a refresh that gives you a different twelve. The grid is
    /// adaptive rather than a hard two-up, so an iPhone gets one column and a
    /// wide Mac window gets two without either being told about the other.
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
                               isResolving: resolvingID == song.id) {
                        actions.playTrack(song, songs)
                    }
                    .contextMenu { songMenu(song, context: songs) }
                }
            }
            // A roll swaps twelve rows at once; without this it's a jump cut.
            .mixAnimation(.easeInOut(duration: 0.22), value: roll)
        }
    }

    /// The song verbs, in the order they read: what happens now, what happens
    /// next, what happens eventually, then keeping it. Same shape as the
    /// library's own track menu, so right-clicking a recommendation offers what
    /// right-clicking anything else does.
    @ViewBuilder
    private func songMenu(_ song: OnlineTrack, context: [OnlineTrack]) -> some View {
        Button("Play", systemImage: "play.fill") { actions.playTrack(song, context) }
        if let playNext = actions.playNext {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { playNext(song) }
        }
        if let addToQueue = actions.addToQueue {
            Button("Add to Queue", systemImage: "text.append") { addToQueue(song) }
        }
        if let addToLibrary = actions.addToLibrary {
            Divider()
            Button("Add to Library", systemImage: "plus") { addToLibrary(song) }
        }
        Divider()
        ShareMenuItems(.track(song))
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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .mixTightened()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
                Spacer(minLength: 8)
                if let accessory { accessory }
            }
            content()
        }
    }

    /// Horizontal rows bleed to the window edge on purpose — a scroller that
    /// stops short of the edge reads as a boxed-in widget, and every music app
    /// worth copying lets the row run out of the frame. The inset restores the
    /// page gutter for the first card only.
    ///
    /// Nothing shares a band with a scroller any more — the mixes wrap on a Mac
    /// and a phone has one column — so there's no longer a caller that needs
    /// this clipped.
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

/// Wide by design. A mix is a *place*, not a track, and giving it the same
/// square silhouette as an album is what made the old page read as one
/// undifferentiated grid. The 2×2 mosaic is the same trick Spotify's Daily Mix
/// uses: four covers say "a lot of things" where one cover says "an album".
struct MixMosaicCard: View {

    let mix: PersonalMix
    /// The player is finding this mix's first stream — the button spins instead
    /// of offering a play it's already been given.
    var isResolving: Bool = false
    let onOpen: () -> Void
    let onPlay: () -> Void

    @State private var isHovered = false

    /// Static because the band that lays these out has to know it: the mixes
    /// column is sized to the cards it holds rather than to the window.
    static let side: CGFloat = 168
    private var side: CGFloat { Self.side }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                mosaic
                // Resolving keeps the button on screen whether or not the
                // pointer stayed: you press play and move the mouse away, and
                // the one thing telling you the app heard you shouldn't leave
                // with the cursor.
                if isHovered || isResolving {
                    Button(action: onPlay) {
                        ZStack {
                            // The glyph is `mixOnAccent`, not a literal black.
                            // `mixPrimary` is a deep burnt orange in the light
                            // appearance and a black mark on it lands near
                            // 2.6:1; the token flips to white there and back to
                            // near-black over the brighter dark-mode orange.
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
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                // A mix whose line-up couldn't be named still gets a line: an
                // empty one collapses, and the card's title then sits a few
                // points higher than every card beside it.
                Text(mix.subtitle.isEmpty ? "A mix built around \(mix.seedArtist)" : mix.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: side, alignment: .leading)
        }
        // Top-aligned inside its grid row. `LazyVGrid` centres a short cell in
        // a tall row, so one card whose subtitle wrapped to two lines pushed
        // every one-line card beside it down by half a line — the shelf looked
        // like it was drawn on a wave.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
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
        CachedRemoteImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.mixSurface2
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

// MARK: - New release hero

/// One record, given the room a record deserves.
///
/// The rest of the page answers "what should I put on?" with a wall of equal
/// candidates. This answers a different question — "did anyone I care about put
/// something out?" — and a wall is the wrong shape for a single yes. So it gets
/// a face, a name, a cover twice the size of the album cards, and the only
/// filled surface on the landing: three signals that this is a piece of news
/// rather than another option.
struct MixNewReleaseHero: View {

    let release: FreshRelease
    let onOpenAlbum: () -> Void
    let onOpenArtist: () -> Void
    /// Nil when the host can't resolve an album's tracks — the cover still opens.
    ///
    /// Awaited rather than fired, so the button knows when it's done: starting a
    /// record is two waits back to back — fetch the track list, then resolve the
    /// first track's stream — and only the second half has an id anyone could
    /// watch. See `DiscoverLandingActions.playAlbum`.
    let onPlay: (() async -> Void)?

    @State private var isHovered = false
    @State private var artistHovered = false
    /// Set for as long as `onPlay` is running.
    @State private var isStarting = false

    /// Sized against the mix card beside it rather than against the text in it:
    /// at 118 the hero read as a slightly larger album card, which is not what
    /// a hero is for. At 150 it's unmistakably the biggest thing in the band.
    static let coverSide: CGFloat = 150
    static let avatarSide: CGFloat = 48

    private static let panelPadding: CGFloat = 12
    private static let stackSpacing: CGFloat = 14

    /// How much taller this is than a column of `side`-tall covers — the amount
    /// the band has to lift it by to stand its panel level with them.
    ///
    /// Static because the band does the lifting, and it's derived rather than
    /// written down because every number in it is a number above: change the
    /// cover or the avatar and the lift follows on its own instead of quietly
    /// going stale.
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
            CachedRemoteImage(url: release.artist.imageURL) { image in
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenArtist)
        .mixHoverCursor { artistHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: artistHovered)
    }

    private var releasePanel: some View {
        HStack(alignment: .center, spacing: 14) {
            CachedRemoteImage(url: release.album.coverURL) { image in
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
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.mixTextTertiary)
                        .textCase(.uppercase)
                }
                Text(release.album.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .mixTightened()
                if let released = release.album.releaseDate {
                    Text(released.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer(minLength: 4)

            if let onPlay {
                Button {
                    // Guarded here rather than with `.disabled`, which would
                    // fade the spinner it's meant to protect. Unlike a track,
                    // a second press on this one isn't free — the album fetch
                    // in front of the resolve has nothing deduplicating it.
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
        .onTapGesture(perform: onOpenAlbum)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Song row

/// Flat: no card, no border, no fill until you point at it. The old rows sat in
/// their own rounded rectangles, which is most of what "boxed" meant.
struct MixSongRow: View {

    let song: OnlineTrack
    /// Position in the list, 1-based. Nil on the landing shelves, where a row is
    /// one of four suggestions and a number would imply an order that isn't
    /// there; set on a playlist page, where the order is the point.
    var index: Int? = nil
    /// This row is the song the player is on, so it gets the brand colour the
    /// rest of the app uses to mean exactly that.
    var isCurrent: Bool = false
    /// The player is finding this song's stream. Same scrim-and-spinner over the
    /// artwork every other song list in the app draws, because it's the same
    /// wait — the landing was simply the one page that never said so.
    var isResolving: Bool = false
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
        // A real button, not a tap gesture on a stack.
        //
        // Every other card here gets away with `.onTapGesture` because it's
        // exactly as big as its own content — a 132pt cover, a 112pt circle.
        // This row is the only one that stretches: it fills whatever the grid
        // column happens to be, and a stretched stack under a `.contextMenu` is
        // where AppKit's hit region and SwiftUI's drawn frame stop agreeing.
        // A button has one hit region by construction, and it brings focus and
        // VoiceOver with it, neither of which a tap gesture has ever had.
        // Not disabled while it resolves: `.disabled` fades a plain button's
        // whole label, and the label here is the entire row — title, artist,
        // artwork and all. A second press costs nothing; the coordinator drops
        // a request for the track it's already resolving.
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
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 26, alignment: .trailing)
            }

            ZStack {
                CachedRemoteImage(url: song.artworkURL) { image in
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
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.mixPrimary : Color.mixTextPrimary)
                        .lineLimit(1)
                    if song.isExplicit { MixExplicitBadge() }
                }
                Text(song.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if song.duration > 0 {
                Text(Self.formatted(song.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
        )
        // Inside the label, so the button's hit region is the whole row —
        // including the gap the `Spacer` opens up between title and duration.
        .contentShape(Rectangle())
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

    /// Kept in step with the `minimum` of the grids that lay these out — a
    /// bubble wider than its column overflows into the next one.
    private let side: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            CachedRemoteImage(url: artist.imageURL) { image in
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
                .frame(width: side)
        }
        // Top-aligned inside its grid row. `LazyVGrid` centres a short cell in
        // a tall row, so one card whose subtitle wrapped to two lines pushed
        // every one-line card beside it down by half a line — the shelf looked
        // like it was drawn on a wave.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Album card

struct MixAlbumCard: View {

    let album: OnlineAlbum
    let onOpen: () -> Void

    @State private var isHovered = false

    /// Kept in step with the `minimum` of the grid that lays these out — a card
    /// wider than its column overflows into the next one.
    private let side: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CachedRemoteImage(url: album.coverURL) { image in
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
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(album.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        // Top-aligned inside its grid row. `LazyVGrid` centres a short cell in
        // a tall row, so one card whose subtitle wrapped to two lines pushed
        // every one-line card beside it down by half a line — the shelf looked
        // like it was drawn on a wave.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Small parts

/// The "E" on an explicit song, everywhere one is listed.
///
/// Filled rather than tinted: a tertiary letter on a 22%-tertiary box was legible
/// on the artwork-heavy Discover rows it started on and barely visible in a list.
/// The glyph is punched out in the page colour, which is the one combination that
/// keeps its contrast in both appearances.
struct MixExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Color.mixBackground)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.mixTextSecondary)
            )
            .accessibilityLabel("Explicit")
    }
}

/// The inline action next to a section head — "Refresh", "Show all".
/// A pill rather than a plain button so it reads as a control at 12pt without
/// needing a border drawn around it.
struct MixPillButton: View {

    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
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
    /// Hover state plus the pointing-hand cursor on macOS, no-op on iOS — so the
    /// cards above can be written once instead of twice around `#if os`.
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

/// The last tile in "Your mixes": make one yourself. Same footprint as
/// `MixMosaicCard`'s mosaic so the shelf stays a shelf, and it grows a little
/// under the pointer the way the cards lift.
private struct GenerateMixTile: View {

    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.mixSurface2)
                .overlay {
                    Image(systemName: "plus")
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
                Text("Generate a Mix")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text("Pick a mood and make your own")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: MixMosaicCard.side, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovered)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Generate a Mix")
    }
}

/// One un-arrived mix card: the mosaic's footprint and two caption bars.
///
/// Deliberately still. A shimmer would be the obvious thing, but a
/// `repeatForever` animation left on screen is what pinned the CPU and got iOS
/// to kill the app after ten minutes — and four of them would be running for as
/// long as the shelf takes. The shelf headings already say what's happening.
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
