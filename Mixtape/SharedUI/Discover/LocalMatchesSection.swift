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
    /// "Show all in Library". Optional: the pages that have nowhere to send you
    /// simply don't draw it.
    var onShowAll: (() -> Void)? = nil

    /// Six rows. Enough that the section is worth reading, few enough that it
    /// never pushes the online results off the screen — which would just be the
    /// old two-search-boxes problem wearing one box.
    /// Off where the caller already drew one (iOS collapses the whole section
    /// under its own disclosure header).
    var showsHeader = true

    static let limit = 6

    private var shown: [Track] { Array(tracks.prefix(Self.limit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("In your library")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .mixTightened()
                        Text(tracks.count == 1 ? "1 song you already have"
                                               : "\(tracks.count) songs you already have")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    Spacer(minLength: 8)
                    if let onShowAll, tracks.count > Self.limit {
                        MixPillButton(title: "Show all", action: onShowAll)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)],
                      alignment: .leading, spacing: 2) {
                ForEach(shown) { track in
                    LibrarySongRow(track: track) { onPlay(track, shown) }
                }
            }
        }
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

// MARK: - Row

/// The local twin of `MixSongRow`. Same flat geometry so the two sections read
/// as one list; the difference is that artwork comes off the disk rather than
/// the network, and there's a small badge saying so.
struct LibrarySongRow: View {

    let track: Track
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
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                #endif
            }

            Spacer(minLength: 8)

            Image(systemName: "internaldrive")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.mixTextTertiary)
                .help("In your library")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}
