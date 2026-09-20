// MacTrackLinks.swift
// Mixtape — Mac/Content
//
// A song's name and its credit, as links.
//
// These lived inside the player bar, which is why the bottom of the window was
// the only place in the app where clicking an artist took you to the artist.
// Everywhere else — the queue, the Recent list, the lyrics header — printed the
// same two strings as dead text. Same song, same names, two different answers
// to whether they do anything, depending on which corner of the window you
// happened to be looking at.
//
// So the two views and the two rules behind them moved here, and the player bar
// became one of their call sites rather than their owner.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Where a name goes

@MainActor
enum TrackLinks {

    /// One target per individual artist on the track. A "feat." blob or a
    /// comma-separated credit is split into separate names, so clicking a
    /// featured artist opens *their* page rather than failing on the whole
    /// "Drake feat. 21 Savage" string.
    ///
    /// Every name goes to the same place: the Discover artist page. It used to
    /// prefer a local library artist when one existed, which quietly made one
    /// credit line lead to two different kinds of page — "Franchise" sent Travis
    /// Scott and Future to the local library (they had rows) and Young Thug and
    /// M.I.A. to Discover (they didn't). Which page a name opened depended on
    /// what the user happened to have saved, which is not something anyone can
    /// predict from looking at the line. Discover is also the fuller page: it
    /// links back to what *is* saved by that artist, and a name that resolves to
    /// nothing online falls back to a search rather than a dead end. The local
    /// artist page keeps its own front doors — Library › Artists, and the track
    /// table's "Go to Artist".
    ///
    /// `displayArtists`, not `creditedArtists`: a song found through Discover
    /// carries only its main artist, and names the rest in its title.
    static func artists(for track: Track, appState: MacAppState) -> [(name: String, action: () -> Void)] {
        ImportService.displayArtists(title: track.title, artistName: track.artistName).map { name in
            (name, { appState.showOnlineArtist(name: name, trackID: nil) })
        }
    }

    /// Where the song's own name goes: the Discover album page, always.
    ///
    /// It used to prefer a local album row when one existed, which is the same
    /// split the artist rule had — a title opened a page of the songs you had
    /// saved off that record, or the record itself, depending on whether the
    /// library happened to hold an album row for it. `openDiscoverAlbum` also
    /// trims a multi-artist credit down to the first name; no catalogue files
    /// "Album X" under "c4rl, Yungpalo".
    static func album(for track: Track, appState: MacAppState) -> (() -> Void)? {
        guard !track.albumTitle.isEmpty else { return nil }
        return { appState.openDiscoverAlbum(for: track) }
    }
}

// MARK: - The link itself

/// A line of text that becomes a borderless button with a pointing-hand cursor
/// and a hover underline when it has somewhere to go, and stays plain text when
/// it doesn't.
struct MixLinkText: View {
    let text:   String
    let font:   Font
    let color:  Color
    let target: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        if let target {
            Button(action: target) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .underline(isHovered)
            }
            .buttonStyle(.plain).mixHandCursor()
            .onHover { inside in
                isHovered = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// One or more individually-clickable artist names, comma-separated. A single
/// artist keeps the exact look and behaviour of a lone `MixLinkText` (with
/// truncation); several each become their own target.
struct MixArtistLine: View {
    let targets: [(name: String, action: () -> Void)]
    var font:  Font  = .system(size: 11)
    var color: Color = Color.mixTextSecondary

    var body: some View {
        if targets.count <= 1 {
            MixLinkText(text:   targets.first?.name ?? "",
                        font:   font,
                        color:  color,
                        target: targets.first?.action)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(targets.enumerated()), id: \.offset) { idx, item in
                    MixLinkText(text: item.name, font: font, color: color, target: item.action)
                        // Four credited artists won't always fit. When they
                        // don't, the guests give up their letters before the
                        // main artist does — otherwise every name ends in an
                        // ellipsis and the line names nobody.
                        .layoutPriority(Double(targets.count - idx))
                    if idx < targets.count - 1 {
                        Text(", ")
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                            // Shares its name's priority: a comma drawn after a
                            // name that lost its letters points at nothing.
                            .layoutPriority(Double(targets.count - idx))
                    }
                }
            }
        }
    }
}

// MARK: - Ready-made lines for a track

/// The song's name, linked to its album. Reads its own targets so a call site
/// is one line wherever a track is already in hand.
struct MixTrackTitleLink: View {
    let track: Track
    var font:  Font  = .system(size: 13)
    var color: Color = Color.mixTextPrimary

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        MixLinkText(text:   track.displayTitle,
                    font:   font,
                    color:  color,
                    target: TrackLinks.album(for: track, appState: appState))
    }
}

/// The song's credit, every name on it linked to that artist's page.
struct MixTrackArtistLink: View {
    let track: Track
    var font:  Font  = .system(size: 11)
    var color: Color = Color.mixTextSecondary

    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        MixArtistLine(targets: TrackLinks.artists(for: track, appState: appState),
                      font: font, color: color)
    }
}

#endif
