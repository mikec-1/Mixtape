// MacSearchSuggestions.swift
// Mixtape — Mac/App
//
// The type-ahead panel under the search field.
//
// It is hosted by MacRootView rather than by MacTopBar, even though it belongs
// to the field. SwiftUI paints a VStack's children in order, so an overlay on
// the top bar would be drawn *under* the split view sitting below it — the panel
// would be clipped to the height of the bar. Attaching it to the VStack itself
// puts it last in the paint order while keeping it inside the zoom transform,
// so it scales with ⌘+/⌘− and lines up with the field at every scale.

#if os(macOS)
import SwiftUI

struct MacSearchSuggestions: View {

    @ObservedObject var store: SearchSuggestionsStore
    let onPick: (SearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.showsRecents {
                HStack {
                    Text("Recent searches")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                    Spacer()
                    Button("Clear") { store.clearRecents() }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }

            // Scrolls rather than growing: the panel hangs over the content and
            // a list long enough to reach the player bar can't be dismissed by
            // clicking past it.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    isHighlighted: store.highlighted == index,
                    onHover: { hovering in
                        // Pointer and keyboard drive the same highlight, so the two
                        // can never show two selected rows at once. Moving off a row
                        // leaves it lit rather than clearing — otherwise Return after
                        // a stray mouse twitch would do nothing.
                        if hovering { store.highlighted = index }
                    },
                    onTap: { onPick(suggestion) },
                    onRemove: store.showsRecents ? { store.hide(suggestion) } : nil
                )
            }
                }
            }
            .frame(maxHeight: 380)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mixSurface)
                .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
        }
        .frame(maxWidth: MacTopBar.searchMaxWidth)
    }
}

// MARK: - Activation

/// What picking a row does.
///
/// Shared by the click handler and by Return on the keyboard-highlighted row, so
/// the two can't drift apart. Everything except `.term` opens the entity
/// directly — that is the whole point of the dropdown, and the reason
/// `SearchSuggestion` carries Deezer ids rather than just display text.
@MainActor
func activateSuggestion(_ suggestion: SearchSuggestion,
                        appState: MacAppState,
                        deps: AppDependencies) {
    SearchSuggestionsStore.shared.remember(suggestion)

    switch suggestion.kind {
    case .term:
        // Nothing behind it — put the completion in the field and let the search
        // that is already watching the text run it. `accept` rather than
        // `dismiss` because that write is indistinguishable from typing, and
        // would otherwise reopen the panel on the term just picked from it.
        appState.searchText = suggestion.title
        SearchSuggestionsStore.shared.accept(suggestion.title)
        // Picking a term is the same decision as pressing Return, so it does the
        // same two things: shows the results (un-parking the query if the panel
        // was reopened on a parked one — where the write above can be a no-op,
        // the text never having changed), and unwinds whatever Discover page was
        // drilled into, which is not where the term just picked belongs.
        appState.showSearchResults()
        DiscoverSessionStore.shared.commitSearch()

    case .artist:
        guard let artist = suggestion.onlineArtist else { return }
        // Opening a page is worth nothing if something is drawn over the column
        // it opens in — fullscreen lyrics, a profile, the account page.
        appState.showSearchResults()
        DiscoverSessionStore.shared.path.append(.artist(artist))

    case .album:
        guard let album = suggestion.onlineAlbum else { return }
        appState.showSearchResults()
        DiscoverSessionStore.shared.path.append(.album(album))

    // Playing something doesn't move you: lyrics stay up and follow the new
    // song, which is the reason they were open.
    case .track:
        guard let track = suggestion.onlineTrack else { return }
        Task { await deps.onlineCoordinator.play(track) }
    }
}

// MARK: - Row

private struct SuggestionRow: View {

    let suggestion: SearchSuggestion
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    /// Nil for live results: the ✕ removes a *past* search, and there is
    /// nothing to remove a result you are looking at right now from.
    let onRemove: (() -> Void)?

    @State private var hovering = false

    private static let thumb: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                // The rating belongs to the title, not to the row: it is part
                // of what the song is called, the same place it sits on every
                // track list in the app.
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)

                    if suggestion.isExplicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 14, height: 14)
                            .background(Color.mixSurface2,
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // "You have this song" — the reason the row is at the top of the
            // list. Songs only: an artist is never something you own, so a tick
            // beside their name was answering a question nobody asked.
            if suggestion.inLibrary, showsLibraryTick {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixAccentFill)
                    .help("Already in your library")
            }

            // Drop this row from the recents. On hover only — it is a
            // destructive-ish control on a list you are reading, and a column
            // of crosses would compete with the rows themselves.
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .help("Remove from recent searches")
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            // The highlight is the only colour in the panel, because it is the
            // only thing here that is state rather than content.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.mixSurface2 : Color.clear)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .onTapGesture(perform: onTap)
    }

    /// Albums and songs are things the library can hold; artists and plain
    /// terms are not.
    private var showsLibraryTick: Bool {
        switch suggestion.kind {
        case .track, .album: return true
        case .artist, .term: return false
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // A term completion has no artwork to show — a grey square where the
        // other rows have covers would read as a picture that failed to load,
        // so it gets the search glyph at the same size instead.
        if case .term = suggestion.kind {
            Image(systemName: suggestion.placeholderIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: Self.thumb, height: Self.thumb)
        } else {
            CachedRemoteImage(url: suggestion.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: suggestion.placeholderIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            .frame(width: Self.thumb, height: Self.thumb)
            .clipShape(RoundedRectangle(cornerRadius: suggestion.isCircular ? Self.thumb / 2 : 4,
                                        style: .continuous))
        }
    }
}

#endif
