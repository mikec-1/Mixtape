// LocalMatchesSection.swift
// Mixtape — SharedUI/Discover
//
// Your own songs, in the online search results.
//
// The app had two search boxes: one that searched the library and one that
// searched the catalogue, and which one you got depended on which section you
// happened to be in. That is a distinction the app cares about and the person
// typing does not — "play that Fontaines song" is one intent whether the file
// is on the disk or on Deezer's server.
//
// So the Discover field answers both now, and this is the local half: a section
// pinned above the online results, because a song you already own is almost
// always the better answer to a query that matches it. It's deliberately capped
// — this is a shortcut into the library, not a replacement for the Library
// page's own search.

import SwiftUI

struct LocalMatchesSection: View {

    let query: String
    let tracks: [Track]
    let onPlay: (Track, [Track]) -> Void
    /// "Show all" — opens `LibraryMatchesPage`. Optional: the pages that have
    /// nowhere to send you simply don't draw it.
    var onShowAll: (() -> Void)? = nil
    /// Every match rather than the first six — that page's own list.
    var showsAll = false

    /// Six rows. Enough that the section is worth reading, few enough that it
    /// never pushes the online results off the screen — which would just be the
    /// old two-search-boxes problem wearing one box.
    /// Off where the caller already drew one (iOS collapses the whole section
    /// under its own disclosure header).
    var showsHeader = true

    static let limit = 6

    @EnvironmentObject private var deps: AppDependencies

    /// Rows picked for the actions that take several songs: ⌘/⇧-click on the
    /// Mac, the way the Playlists page picks playlists, and Select on iOS. Kept
    /// here because a selection belongs to one set of results.
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
                .environmentObject(deps)
        }
        #endif
    }

    /// "Add All" files every match, not just the six on show: "all" is the
    /// count the header states. These songs are already in the library, so a
    /// playlist is the add that means something, and the picker's New Playlist
    /// row makes one.
    @ViewBuilder
    private var actions: some View {
        if selection.isEmpty {
            MixPillButton(title: "Add All to Playlist", systemImage: "text.badge.plus") {
                choosePlaylist(tracks)
            }
        } else {
            Menu {
                songMenu(selection)
                Divider()
                Button("Deselect All", action: clearSelection)
            } label: {
                HStack(spacing: 5) {
                    Text("\(selection.count) Selected")
                        .font(.system(size: MixFontScale.size(12), weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: MixFontScale.size(9), weight: .bold))
                }
                .foregroundStyle(Color.mixPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.mixPrimary.opacity(0.14)))
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
        }
        #if os(iOS)
        MixPillButton(title: isSelecting ? "Done" : "Select") {
            if isSelecting { clearSelection() } else { isSelecting = true }
        }
        #endif
    }

    private func row(_ track: Track) -> some View {
        #if os(macOS)
        LibrarySongRow(track: track, isSelected: selected.contains(track.id),
                       onPlay: { tap(track) })
            .overlay(ModifiedClickCatcher { select(track.id, modifiers: $0) })
            // On the whole selection when the row is part of it, as in the
            // Library's own table.
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

    /// A plain click still plays, as it always has here, and as the online rows
    /// right beside these do; picking is the modified click.
    private func tap(_ track: Track) {
        #if os(iOS)
        if isSelecting { toggle(track.id); return }
        #endif
        clearSelection()
        play([track])
    }

    /// One song plays in the results' order; a selection is its own list.
    private func play(_ songs: [Track]) {
        guard let first = songs.first else { return }
        onPlay(first, songs.count > 1 ? songs : shown)
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

    /// The matcher, in one place so both platforms rank identically.
    ///
    /// Title hits sort above artist hits above album hits: someone typing a
    /// song name wants that song, not the eleven other tracks by whoever made
    /// it. Within a tier the library's own order stands.
    ///
    /// Last answer, keyed by the query and the size of the library it was
    /// asked of.
    ///
    /// Both callers run this straight out of `body`, which SwiftUI re-evaluates
    /// on every publish from anything the Discover page observes — playback
    /// state included. The scan is three ICU substring tests per track plus a
    /// sort, so on a couple of thousand songs it was several milliseconds
    /// *per frame* while music was playing. The answer only depends on the
    /// query and the library, so it is computed once per pair.
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

/// Every library song matching a search — what "Show all" opens. Pushed onto
/// the search's own stack rather than handing the query to the Library page,
/// so it is a page of the results: Back returns to them, and the history can
/// bring it back.
struct LibraryMatchesPage: View {

    let query: String
    /// Pop, for a host that draws no chrome of its own (macOS).
    var onBack: (() -> Void)? = nil

    @EnvironmentObject private var deps:   AppDependencies
    @EnvironmentObject private var engine: PlaybackEngine

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

/// The local twin of `MixSongRow`. Same flat geometry so the two sections read
/// as one list; the difference is that artwork comes off the disk rather than
/// the network, and there's a small badge saying so.
struct LibrarySongRow: View {

    let track: Track
    var isSelected = false
    /// iOS's Select mode: a circle in place of the library badge.
    var showsCheckmark = false
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
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

            VStack(alignment: .leading, spacing: 2) {
                // The online rows directly above these have always been links;
                // a library row sitting in the same list had dead names.
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
        .mixTapAction(onPlay)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
        .mixAnimation(.easeOut(duration: 0.12), value: isSelected)
    }
}
