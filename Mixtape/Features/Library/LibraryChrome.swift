// LibraryChrome.swift
// Mixtape — Features/Library
//
// The furniture around the library list: the header, the sort/layout bar, and
// the grid cell that the list rows turn into.
//
// Split out of `LibraryView` because that file is the *content* of four
// sections and was already long. Everything here is chrome — it is the same on
// every section, and none of it knows what it is sitting above.
//
// Why a hand-built header instead of `navigationTitle`
// ----------------------------------------------------
// The large-title bar gives a title and a toolbar, and that is all. "Your
// Library" wants the avatar on the same line as the title, at title weight,
// with the search and add controls balanced against it — and it wants the
// filter pills to scroll away underneath rather than collapse the title into a
// small one. That is a header, not a navigation bar, so it is drawn as one and
// the navigation bar is hidden.

import SwiftUI

// MARK: - Header

/// Avatar, title, search, add — the top line of the library.
struct LibraryHeader: View {

    @Binding var isSearching: Bool
    @Binding var searchText:  String
    let onAdd: () -> Void

    /// So the field takes the keyboard the moment the magnifying glass is
    /// tapped. A search box that appears and then waits to be tapped again is a
    /// second tap for no reason.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileMenuButton(size: 30)

                Text("Your Library")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)

                Spacer(minLength: 8)

                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        isSearching.toggle()
                        // Closing the field clears it. Leaving a query behind an
                        // invisible control is how a library ends up looking
                        // half-empty with nothing on screen to explain it.
                        if !isSearching { searchText = "" }
                    }
                    if isSearching { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .accessibilityLabel(isSearching ? "Close search" : "Search library")

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .accessibilityLabel("Add")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isSearching {
                LibrarySearchField(text: $searchText, focus: $searchFocused)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct LibrarySearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)

            TextField("Search in Your Library", text: $text)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .focused(focus)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Sort / layout bar

/// The "Recents ⌄" control on the left and the grid/list toggle on the right.
///
/// A menu rather than a segmented control: the sort is a setting you change
/// rarely and read constantly, so the row's job is mostly to *say* what the
/// order currently is. The label is the current value for that reason.
struct LibrarySortBar: View {

    @Binding var order:  LibrarySortOrder
    @Binding var layout: LibraryLayout
    /// Hidden on sections that have no meaningful second layout.
    var showsLayoutToggle: Bool = true
    /// Drives the list's drag-to-reorder mode. Absent — or non-nil but with
    /// `canArrange` false — leaves the control out entirely, because dragging
    /// only means something in the custom order.
    var arranging: Binding<Bool>? = nil
    var canArrange: Bool = false

    var body: some View {
        HStack {
            Menu {
                // Flat: a titled picker inside a menu renders as a "Sort by ▸"
                // submenu, which puts every order two clicks deep to name the
                // one thing this menu could be offering. See `MacSidebarView`.
                Picker("", selection: $order) {
                    ForEach(LibrarySortOrder.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(order.rawValue)
                        .font(.mixLabel)
                }
                .foregroundStyle(Color.mixTextSecondary)
            }
            .accessibilityLabel("Sort by \(order.rawValue)")

            Spacer()

            if let arranging, canArrange {
                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        arranging.wrappedValue.toggle()
                    }
                } label: {
                    Text(arranging.wrappedValue ? "Done" : "Arrange")
                        .font(.mixLabel)
                        .foregroundStyle(arranging.wrappedValue ? Color.mixPrimary
                                                                : Color.mixTextSecondary)
                }
                .padding(.trailing, 12)
            }

            if showsLayoutToggle {
                Button {
                    withMixAnimation(.easeInOut(duration: 0.2)) {
                        layout = layout == .list ? .grid : .list
                    }
                } label: {
                    Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .accessibilityLabel(layout == .list ? "Show as grid" : "Show as list")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Playlist descriptor

/// The grey line under a playlist's name — "Playlist • mike", "Mix • Mixtape".
///
/// One place rather than two, because the row and the grid cell say the same
/// thing about the same playlist and only differ in where they put it.
enum PlaylistDescriptor {

    static func kind(_ playlist: Playlist) -> String {
        if playlist.isSystem { return "Playlist" }
        switch playlist.origin {
        case .owned:         return "Playlist"
        case .mix:           return "Mix"
        case .subscribed:    return "Playlist"
        case .spotifyMirror: return "Spotify"
        }
    }

    /// "Playlist • mike". The owner is dropped rather than guessed when the
    /// playlist has no byline — an unattributed playlist is the user's own, and
    /// naming them to themselves on every row is noise.
    static func line(_ playlist: Playlist) -> String {
        guard let owner = playlist.ownerName, !owner.isEmpty else { return kind(playlist) }
        return "\(kind(playlist)) • \(owner)"
    }
}

// MARK: - Grid cell

/// A playlist as a square tile. The grid's answer to `PlaylistRowView`.
struct PlaylistGridCell: View {

    let playlist: Playlist
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var meta = PlaylistMetadataService.shared

    private var isFullyDownloaded: Bool {
        downloads.isFullyDownloaded(playlist.trackIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistArtwork(playlist: playlist, size: nil, cornerRadius: 6)
                .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            HStack(spacing: 4) {
                if meta.isPinned(playlistID: playlist.id) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mixPrimary)
                        .rotationEffect(.degrees(45))
                }
                DownloadStateBadge(ids: playlist.trackIDs, downloads: downloads, size: 10)
                Text(PlaylistDescriptor.line(playlist))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name), \(PlaylistDescriptor.line(playlist))")
    }
}
