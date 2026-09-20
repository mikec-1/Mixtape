// TrackListTools.swift
// Mixtape — SharedUI/Components
//
// Filtering and ordering for a list of songs, plus the small control pair that
// drives them.
//
// A playlist is the one page in the app where the list can be long enough that
// you know the song is in there and still can't find it. The hero already
// carries everything you can *do* to a playlist — play, shuffle, keep offline,
// the overflow menu — all of it clustered on the left, so these two sit at the
// far end of the same row instead of adding a third thing to that clump.
//
// The model lives here rather than in the view because both platforms and both
// list implementations need it: iOS filters a SwiftUI `List`, macOS hands the
// finished array to an AppKit table whose own column headers write back into
// the same `TrackSort` (see `NativeTrackTable.sort`), so a header click and this
// menu can never disagree about what the list is sorted by.

import SwiftUI

// MARK: - Model

/// What a list of songs is ordered by.
enum TrackSortField: String, CaseIterable, Identifiable, Hashable {
    /// The order the list itself is in — the playlist's own running order.
    /// Always the default: a playlist someone sequenced is sequenced for a
    /// reason, and a sort that outlives the visit would quietly throw that away.
    case listOrder
    case title
    case artist
    case album
    case dateAdded
    case duration

    var id: String { rawValue }

    /// Every field except `listOrder`, which is named by the page — "Playlist
    /// Order" on a playlist, and something else anywhere this is reused.
    static var sortableFields: [TrackSortField] {
        allCases.filter { $0 != .listOrder }
    }

    var title: String {
        switch self {
        case .listOrder: return "Custom Order"
        case .title:     return "Title"
        case .artist:    return "Artist"
        case .album:     return "Album"
        case .dateAdded: return "Date Added"
        case .duration:  return "Duration"
        }
    }

    /// The `NSSortDescriptor` key the Mac table's matching column header uses.
    /// Nil for `listOrder`: no column expresses "the order it was already in",
    /// which is why picking it clears the table's descriptors outright.
    var sortDescriptorKey: String? {
        switch self {
        case .listOrder: return nil
        case .title:     return "title"
        case .artist:    return "artistName"
        case .album:     return "albumTitle"
        case .dateAdded: return "dateImported"
        case .duration:  return "duration"
        }
    }

    init?(sortDescriptorKey key: String) {
        guard let match = TrackSortField.allCases.first(where: { $0.sortDescriptorKey == key })
        else { return nil }
        self = match
    }
}

struct TrackSort: Equatable {
    var field: TrackSortField = .listOrder
    var ascending: Bool = true

    /// Which way round a field starts. Names read A→Z, but "date added" almost
    /// always means "what did I add lately", so that one starts newest-first.
    static func naturalDirection(for field: TrackSortField) -> Bool {
        field == .dateAdded ? false : true
    }

    /// Picking the field you're already on flips the direction instead — the
    /// same thing clicking a column header twice does.
    mutating func select(_ field: TrackSortField) {
        if self.field == field {
            ascending.toggle()
        } else {
            self.field = field
            ascending = Self.naturalDirection(for: field)
        }
    }

    var isDefault: Bool { field == .listOrder && ascending }
}

// MARK: - Memoising the derived list

/// One playlist page's cache of "the rows actually on screen".
///
/// `visibleTracks` is read many times per body evaluation — by the list, by the
/// Play button, by the empty state, by the count in the header — and each read
/// used to walk the playlist's ids through the library, filter, and sort, on a
/// list that routinely runs to a few thousand rows. SwiftUI re-evaluates a body
/// for reasons that have nothing to do with any of those inputs.
///
/// So the answer is kept, along with the four things it depends on, and rebuilt
/// only when one of them actually moved. `LibraryService.revision` stands in for
/// the track data itself — see its comment for why the arrays aren't compared.
///
/// A reference type held in `@State`, so the cache survives the struct being
/// rebuilt, which is the whole point.
@MainActor
final class TrackListMemo {

    private struct Key: Equatable {
        var revision: UInt64
        var ids: [UUID]
        var query: String
        var sort: TrackSort
    }

    private var key: Key?
    private(set) var tracks: [Track] = []
    private(set) var visible: [Track] = []
    private(set) var playable: [Track] = []

    /// Recomputes only if something it depends on changed.
    ///
    /// `resolve` is the id→Track lookup, passed in rather than held, so this
    /// keeps no reference to the library and can't go stale behind its own key.
    func update(revision: UInt64,
                ids: [UUID],
                query: String,
                sort: TrackSort,
                resolve: (UUID) -> Track?,
                isPlayable: (Track) -> Bool) {
        let next = Key(revision: revision, ids: ids, query: query, sort: sort)
        guard key != next else { return }
        key = next

        tracks   = ids.compactMap(resolve)
        visible  = tracks.matching(query: query).sorted(by: sort)
        playable = visible.filter(isPlayable)
    }
}

// MARK: - Applying it

extension Array where Element == Track {

    /// Rows matching `query` across title, artist and album.
    ///
    /// Folded rather than lowercased: "beyonce" has to find "Beyoncé", or the
    /// field is only useful to people who know how to type the song's name.
    func matching(query: String) -> [Track] {
        let needle = query.folded
        guard !needle.isEmpty else { return self }
        return filter { track in
            track.title.folded.contains(needle)
                || track.artistName.folded.contains(needle)
                || track.albumTitle.folded.contains(needle)
        }
    }

    /// Sorted by `sort`, decorating first so each row's sort key is built once.
    ///
    /// `folded` is not a cheap accessor — it allocates and walks the string
    /// three times. Calling it inside the comparator meant roughly `2n log n`
    /// folds for every sort, and this runs on 2200-row playlists from a view
    /// body. Building the key once per row makes it `n`.
    func sorted(by sort: TrackSort) -> [Track] {
        guard sort.field != .listOrder else {
            return sort.ascending ? self : reversed()
        }

        let ordered: [Track]
        switch sort.field {
        case .listOrder:
            ordered = self
        case .title:
            ordered = sortedByKey { $0.title.folded }
        case .artist:
            ordered = sortedByKey { $0.artistName.folded }
        case .album:
            ordered = sortedByKey { $0.albumTitle.folded }
        case .dateAdded:
            ordered = sortedByKey { $0.dateImported }
        case .duration:
            ordered = sortedByKey { $0.duration }
        }
        return sort.ascending ? ordered : ordered.reversed()
    }

    /// Decorate–sort–undecorate: `key` is evaluated once per element.
    private func sortedByKey<K: Comparable>(_ key: (Track) -> K) -> [Track] {
        map { (key($0), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

private extension String {
    /// Case-, accent- and width-insensitive, the same fold the library's own
    /// matching uses (see `LibraryTrackIndex`).
    var folded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The controls

/// The search field and sort menu that belong at the trailing end of a hero's
/// action row.
///
/// The field starts collapsed as a single disc. A search box that is always
/// open is a box that is usually empty, and an empty box on a page whose whole
/// left side is already controls reads as one more thing to ignore.
struct TrackListTools: View {

    @Binding var query: String
    @Binding var sort: TrackSort

    /// What the list's own order is called here.
    var listOrderTitle: String = "Custom Order"

    /// Placeholder for the field. Worth naming the list — "Search in Road Trip"
    /// says which songs are being searched, which matters on a page you reached
    /// from a search of everything.
    var searchPrompt: String = "Search"

    @State private var isSearchOpen = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchControl
            sortMenu
        }
        .mixAnimation(.spring(response: 0.3, dampingFraction: 0.85), value: isSearchOpen)
    }

    // MARK: Search

    @ViewBuilder
    private var searchControl: some View {
        if isSearchOpen {
            HStack(spacing: 6) {
                Image(systemName: MixtapeIcons.search)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.mixTextSecondary)

                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextPrimary)
                    .focused($isFieldFocused)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            // A fixed field on the Mac, where the hero row has room to spare;
            // on iOS it takes what's left of the row, which is the only way it
            // ends up wide enough to read what you typed.
            #if os(macOS)
            .frame(width: 200)
            #else
            .frame(maxWidth: .infinity)
            #endif
            .background(Color.mixSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
            // Esc closes it, exactly where the cancel button would be on iOS.
            #if os(macOS)
            .onExitCommand { closeSearch() }
            #endif
            // Losing focus with nothing typed means it was opened by accident;
            // a field with a query in it stays, because the list it produced is
            // still on screen and the query is the only thing explaining why.
            .onChange(of: isFieldFocused) { _, focused in
                if !focused, query.isEmpty { isSearchOpen = false }
            }
            // Hands ⌘⌫ back to the field, where it clears the line. Without it
            // the app's delete shortcut takes the event and offers to delete
            // whichever song is selected behind the search.
            .mixEditingFocus(isFieldFocused)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        } else {
            Button {
                isSearchOpen = true
                // A hop, because the field doesn't exist yet: focus assigned in
                // the same update as the view it points at is dropped, and the
                // magnifier opens an empty box the caret never lands in.
                DispatchQueue.main.async { isFieldFocused = true }
            } label: {
                HeroCircleLabel(systemImage: MixtapeIcons.search,
                                foreground: query.isEmpty ? .mixTextSecondary : .mixPrimary,
                                fill: query.isEmpty ? .mixSurface : Color.mixPrimary.opacity(0.18),
                                diameter: 36)
            }
            .buttonStyle(.plain).mixHandCursor()
            .help("Search in this playlist")
            .accessibilityLabel("Search in this playlist")
        }
    }

    private func closeSearch() {
        query = ""
        isFieldFocused = false
        isSearchOpen = false
    }

    // MARK: Sort

    private var sortMenu: some View {
        Menu {
            Button {
                sort.select(.listOrder)
            } label: {
                label(listOrderTitle, checked: sort.field == .listOrder)
            }

            Divider()

            ForEach(TrackSortField.sortableFields) { field in
                Button {
                    sort.select(field)
                } label: {
                    label(field.title, checked: sort.field == field)
                }
            }

            // Offered for the list's own order too. This used to be hidden
            // there on the grounds that a sequenced playlist backwards is a
            // curiosity — but the playlist people most want flipped is the one
            // they've been appending to for a year, where the newest songs are
            // buried at the bottom and "reverse" is the only way to see them.
            //
            // Named for the order rather than the axis: "ascending" describes a
            // comparison, and there's no comparison behind a running order —
            // what someone wants there is the record played back to front.
            Divider()
            Button {
                sort.ascending.toggle()
            } label: {
                Label(directionTitle, systemImage: sort.ascending ? "arrow.down" : "arrow.up")
            }
        } label: {
            sortLabel
        }
        #if os(macOS)
        // Left alone, a Menu draws a bordered pop-up button with a chevron,
        // which is the wrong shape beside the hero's discs.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help("Sort this playlist")
    }

    /// What flipping the direction would give you — the state you'd land in
    /// rather than the one you're in, which is what the arrow beside it means.
    private var directionTitle: String {
        switch (sort.field, sort.ascending) {
        case (.listOrder, true):  return "Reverse Order"
        case (.listOrder, false): return "Original Order"
        case (_, true):           return "Descending"
        case (_, false):          return "Ascending"
        }
    }

    /// A checkmark drawn as part of the title, because a `Menu`'s buttons don't
    /// carry `Toggle`'s state and an unmarked list can't say what's active.
    private func label(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
            }
        }
    }

    /// Names the current order rather than showing a bare glyph: the whole point
    /// of the control is that you can tell at a glance the list isn't in the
    /// order the playlist is in.
    private var sortLabel: some View {
        HStack(spacing: 6) {
            // Neutral two-way glyph while the list is as the page left it, a
            // definite direction once it isn't — otherwise a reversed playlist
            // reads "Playlist Order" while showing anything but.
            Image(systemName: sort.isDefault
                  ? "arrow.up.arrow.down"
                  : (sort.ascending ? "arrow.up" : "arrow.down"))
                .font(.system(size: 12, weight: .bold))
            if !isSearchOpen || sort.field != .listOrder {
                Text(sort.field == .listOrder ? listOrderTitle : sort.field.title)
                    .font(.mixCaptionBold)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(sort.isDefault ? Color.mixTextSecondary : Color.mixPrimary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(sort.isDefault ? Color.mixSurface : Color.mixPrimary.opacity(0.18),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}
