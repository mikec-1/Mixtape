// A song's title and credit as links, shared by the player bar, queue, Recent and lyrics header.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Where a name goes

@MainActor
enum TrackLinks {

    /// One target per artist: credits and "feat." names are split so each opens its own page.
    /// Always the Discover artist page, never the library row. `displayArtists` because Discover
    /// songs carry only the main artist and name the rest in the title.
    static func artists(for track: Track, appState: MacAppState) -> [(name: String, action: () -> Void)] {
        ImportService.displayArtists(title: track.title, artistName: track.artistName).map { name in
            (name, { appState.showOnlineArtist(name: name, trackID: nil) })
        }
    }

    /// The title always opens the Discover album page.
    static func album(for track: Track, appState: MacAppState) -> (() -> Void)? {
        guard !track.albumTitle.isEmpty else { return nil }
        return { appState.openDiscoverAlbum(for: track) }
    }
}

// MARK: - The link itself

/// Hover-underlined link with a pointing-hand cursor when it has a target, plain text otherwise.
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

/// Clickable artist names, comma-separated. A single artist looks like a lone `MixLinkText`.
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
                        // When the credit doesn't fit, guests truncate before the main artist.
                        .layoutPriority(Double(targets.count - idx))
                    if idx < targets.count - 1 {
                        Text(", ")
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                            // The comma shares its name's priority.
                            .layoutPriority(Double(targets.count - idx))
                    }
                }
            }
        }
    }
}

// MARK: - Ready-made lines for a track

/// The title linked to its album.
struct MixTrackTitleLink: View {
    let track: Track
    var font:  Font  = .system(size: 13)
    var color: Color = Color.mixTextPrimary

    @Environment(MacAppState.self) private var appState

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

    @Environment(MacAppState.self) private var appState

    var body: some View {
        MixArtistLine(targets: TrackLinks.artists(for: track, appState: appState),
                      font: font, color: color)
    }
}

#endif
