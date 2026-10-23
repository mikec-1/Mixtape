// Library matches shown above the online results in Discover search, since
// an owned song is usually the better answer. Capped; not a replacement for
// the Library page's search.

import SwiftUI

struct LocalMatchesSection: View {

    let query: String
    let tracks: [Track]
    let onPlay: (Track, [Track]) -> Void
    /// Opens `LibraryMatchesPage`. Nil hides it.
    var onShowAll: (() -> Void)? = nil
    /// Every match, for that page.
    var showsAll = false

    /// Off when the caller draws its own header (iOS disclosure).
    var showsHeader = true

    static let limit = 6

    @Environment(AppDependencies.self) private var deps

    /// Multi-select: click, ⌘/⇧-click on the Mac; Select on iOS.
    @State private var selected: Set<Track.ID> = []
    #if os(macOS)
    @State private var anchor: Track.ID?
    #else
    @State private var isSelecting = false
    @State private var tracksForPlaylist: [Track] = []
    #endif

    private var shown: [Track] { showsAll ? tracks : Array(tracks.prefix(Self.limit)) }
    /// In screen order, which queueing and filing both follow.
    private var selection: [Track] { shown.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("In your library")
                            .font(.system(size: MixFontScale.size(20), weight: .bold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .mixTightened()
                        Text(tracks.count == 1 ? "1 song you already have"
                                               : "\(tracks.count) songs you already have")
                            .font(.system(size: MixFontScale.size(12.5)))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    Spacer(minLength: 8)
                    #if os(macOS)
                    actions
                    #endif
                    if let onShowAll, !showsAll, tracks.count > Self.limit {
                        MixPillButton(title: "Show all", action: onShowAll)
                    }
                }
            }
            #if os(iOS)
            // A line of its own: a phone header has no room beside the title.
            HStack(spacing: 8) { actions }
            #endif

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)],
                      alignment: .leading, spacing: 2) {
                ForEach(shown) { track in
                    row(track)
                }
            }
        }
        .onChange(of: query) { _, _ in clearSelection() }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { !tracksForPlaylist.isEmpty },
                                    set: { if !$0 { tracksForPlaylist = [] } })) {
            AddToPlaylistSheet(tracks: tracksForPlaylist)
                .environment(deps)
        }
        #endif
    }

    /// Only there with a selection. Songs already in the library, so "add" means a playlist.
    @ViewBuilder
    private var actions: some View {
        if !selection.isEmpty {
            selectionBar
        }
        #if os(iOS)
        MixPillButton(title: isSelecting ? "Done" : "Select") {
            if isSelecting { clearSelection() } else { isSelecting = true }
        }
        #endif
    }

    private var selectionBar: some View {
        HStack(spacing: 2) {
            Text("\(selection.count) selected")
                .font(.system(size: MixFontScale.size(12), weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
                .padding(.leading, 9)
                .padding(.trailing, 4)
            barButton(MixtapeIcons.play, "Play") { play(selection) }
            barButton("text.badge.plus", "Add to Playlist") { choosePlaylist(selection) }
            if selection.count < shown.count {
                barButton("checklist", "Select All") { selected = Set(shown.map(\.id)) }
            }
            Menu { songMenu(selection) } label: { barIcon("ellipsis") }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.plain).mixHandCursor()
                .menuIndicator(.hidden)
                #endif
                .help("More")
                .accessibilityLabel("More")
            #if os(macOS)
            // iOS's Done pill does this.
            barButton("xmark", "Deselect All", action: clearSelection)
            #endif
        }
        .padding(3)
        .background(Capsule().fill(Color.mixPrimary.opacity(0.14)))
        .fixedSize()
        .transition(.opacity)
    }

    private func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(icon) }
            .buttonStyle(.plain).mixHandCursor()
            .help(label)
            .accessibilityLabel(label)
    }

    private func barIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: MixFontScale.size(12), weight: .semibold))
            .foregroundStyle(Color.mixPrimary)
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
    }

    private func row(_ track: Track) -> some View {
        #if os(macOS)
        LibrarySongRow(track: track, isSelected: selected.contains(track.id),
                       onPlay: { play([track]) }, onSelect: { tap(track) })
            .overlay(ModifiedClickCatcher { select(track.id, modifiers: $0) })
            // Whole selection when the row is in it.
            .contextMenu { songMenu(selected.contains(track.id) ? selection : [track]) }
        #else
        LibrarySongRow(track: track, isSelected: selected.contains(track.id),
                       showsCheckmark: isSelecting, onPlay: { tap(track) })
            .contextMenu { songMenu(selected.contains(track.id) ? selection : [track]) }
        #endif
    }

    private func songMenu(_ targets: [Track]) -> some View {
        LibrarySongMenu(targets: targets, onPlay: { play(targets) },
                        onChoosePlaylist: choosePlaylist)
    }

    /// Mac: a click selects just this row. iOS: a tap plays, or toggles while selecting.
    private func tap(_ track: Track) {
        #if os(macOS)
        selected = [track.id]
        anchor = track.id
        #else
        if isSelecting { toggle(track.id) } else { play([track]) }
        #endif
    }

    /// One song plays alone so autoplay's recommendations follow it; a selection is its own list.
    private func play(_ songs: [Track]) {
        guard let first = songs.first else { return }
        onPlay(first, songs)
    }

    private func choosePlaylist(_ songs: [Track]) {
        #if os(macOS)
        deps.savedInPanel.show(tracks: songs, isSavedIn: false)
        #else
        tracksForPlaylist = songs
        #endif
    }

    private func toggle(_ id: Track.ID) {
        if selected.remove(id) == nil { selected.insert(id) }
    }

    #if os(macOS)
    /// Finder's rules: ⌘ toggles, ⇧ extends from the last row picked.
    private func select(_ id: Track.ID, modifiers: NSEvent.ModifierFlags) {
        let ids = shown.map(\.id)
        if modifiers.contains(.shift), let anchor,
           let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
            selected = Set(ids[min(from, to) ... max(from, to)])
            return
        }
        toggle(id)
        anchor = id
    }
    #endif

    private func clearSelection() {
        selected = []
        #if os(macOS)
        anchor = nil
        #else
        isSelecting = false
        #endif
    }

    /// Matcher shared by both platforms: title hits, then artist, then album;
    /// library order within a tier. Memoised by query and library size, since it
    /// runs from `body` on every Discover publish.
    @MainActor private static var memo: (key: String, result: [Track])?

    @MainActor
    static func matches(for query: String, in library: LibraryService) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        let key = "\(library.tracks.count)|\(trimmed.lowercased())"
        if let memo, memo.key == key { return memo.result }
        let result = matchesUncached(trimmed, in: library)
        memo = (key, result)
        return result
    }

    @MainActor
    private static func matchesUncached(_ trimmed: String, in library: LibraryService) -> [Track] {

        func tier(_ track: Track) -> Int {
            if track.title.localizedCaseInsensitiveContains(trimmed)      { return 0 }
            if track.artistName.localizedCaseInsensitiveContains(trimmed) { return 1 }
            if track.albumTitle.localizedCaseInsensitiveContains(trimmed) { return 2 }
            return 3
        }

        return library.tracks
            .map { (track: $0, tier: tier($0)) }
            .filter { $0.tier < 3 }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.tier == rhs.element.tier
                    ? lhs.offset < rhs.offset
                    : lhs.element.tier < rhs.element.tier
            }
            .map(\.element.track)
    }
}

// MARK: - Page

/// All library matches ("Show all"). Pushed on the search's own stack so Back
/// returns to the results.
struct LibraryMatchesPage: View {

    let query: String
    /// Pop, for a host that draws no chrome of its own (macOS).
    var onBack: (() -> Void)? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let onBack { BackButton(action: onBack) }
                LocalMatchesSection(
                    query: query,
                    tracks: LocalMatchesSection.matches(for: query, in: deps.libraryService),
                    onPlay: { track, context in
                        Task { await engine.play(track: track, in: context, source: .named("Search results")) }
                    },
                    showsAll: true
                )
            }
            #if os(macOS)
            .padding(24)
            #else
            .padding(20)
            #endif
        }
        #if os(iOS)
        .navigationTitle(query)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Row

/// Local twin of `MixSongRow`: same layout, artwork from disk, small badge.
struct LibrarySongRow: View {

    let track: Track
    var isSelected = false
    /// iOS's Select mode: a circle in place of the library badge.
    var showsCheckmark = false
    let onPlay: () -> Void
    /// Set: a click selects, double-click or the artwork plays. Nil: a tap plays.
    var onSelect: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        taps(row)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .mixHoverCursor { isHovered = $0 }
            .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
            .mixAnimation(.easeOut(duration: 0.12), value: isSelected)
    }

    @ViewBuilder
    private func taps(_ row: some View) -> some View {
        if let onSelect {
            // Simultaneous so the select lands on the first click, not after the double-click wait.
            row.gesture(TapGesture(count: 2).onEnded(onPlay))
                .simultaneousGesture(TapGesture().onEnded(onSelect))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onPlay)
        } else {
            row.mixTapAction(onPlay)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let art = ZStack {
            ArtworkThumbnail(data: track.artworkData, artworkRef: .track(track.id),
                             size: 44,
                             cornerRadius: 6,
                             placeholder: "music.note")
            if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 44, height: 44)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        if onSelect != nil {
            art.contentShape(Rectangle()).mixTapAction(onPlay)
        } else {
            art
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                // Names are links, like the online rows above.
                #if os(macOS)
                MixTrackTitleLink(track: track,
                                  font: .system(size: 13.5, weight: .medium))
                MixTrackArtistLink(track: track, font: .system(size: 12))
                #else
                Text(track.title)
                    .font(.system(size: MixFontScale.size(13.5), weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: MixFontScale.size(12)))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                #endif
            }

            Spacer(minLength: 8)

            if showsCheckmark {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextTertiary)
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.mixTextTertiary)
                    .help("In your library")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.mixPrimary.opacity(0.18)
                                 : (isHovered ? Color.primary.opacity(0.07) : .clear))
        )
        .contentShape(Rectangle())
    }
}
