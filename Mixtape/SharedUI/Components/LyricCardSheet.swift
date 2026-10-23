// Pick up to four lines of a song and share them as a picture on the artwork's colours.
// The card links back to the song. One sheet for both platforms.

import SwiftUI

struct LyricCardSheet: View {
    let track: Track
    let lyrics: TrackLyrics

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<Int> = []
    @State private var backdrop = 0
    @State private var artwork: PlatformImage?
    @State private var palette: [Color] = []

    static let maxLines = 4

    /// Synced text when there is any, else the plain lines. Blank lines are spacing, not lyrics.
    private var lines: [String] {
        let raw = lyrics.hasSynced ? lyrics.synced.map(\.text)
                                   : (lyrics.plain ?? "").components(separatedBy: .newlines)
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var chosen: [String] { picked.sorted().map { lines[$0] } }

    var body: some View {
        MixSheet(title: "Share Lyrics",
                 subtitle: "Pick up to \(Self.maxLines) lines",
                 size: .large,
                 scroll: false,
                 primary: MixSheetAction("Share", isEnabled: !picked.isEmpty) { share() }) {
            VStack(spacing: 16) {
                card.frame(maxWidth: 300)
                backdropPicker
                lineList
            }
            .padding(.top, 12)
        }
        .task { loadArtwork() }
    }

    private var card: LyricCard {
        LyricCard(lines: chosen.isEmpty ? ["Tap the lines you want to share"] : chosen,
                  title: track.displayTitle, artist: track.displayArtistName,
                  artwork: artwork, colors: colors)
    }

    // MARK: - Lines

    private var lineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { i in
                    let on = picked.contains(i)
                    Button { toggle(i) } label: {
                        Text(lines[i])
                            .font(.mixBody.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.mixTextPrimary : Color.mixTextSecondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(on ? Color.mixSurface2 : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func toggle(_ i: Int) {
        if picked.contains(i) {
            picked.remove(i)
        } else if picked.count < Self.maxLines {
            picked.insert(i)
        } else {
            deps.showToast(.failed("A card holds up to \(Self.maxLines) lines"))
        }
    }

    // MARK: - Backdrops

    /// Artwork gradient, each artwork colour alone, then graphite. Same set as the share card.
    private var backdrops: [[Color]] {
        let art = palette.count == 2 ? palette : Self.fallback
        return [art, [art[0], art[0]], [art[1], art[1]], Self.graphite]
    }

    private var colors: [Color] { backdrops[min(backdrop, backdrops.count - 1)] }

    private static let fallback = [Color(hue: 0.72, saturation: 0.42, brightness: 0.42),
                                   Color(hue: 0.62, saturation: 0.48, brightness: 0.2)]
    private static let graphite = [Color(white: 0.24), Color(white: 0.1)]
    private static let backdropNames = ["Artwork gradient", "Artwork colour", "Second artwork colour", "Graphite"]

    private var backdropPicker: some View {
        HStack(spacing: 14) {
            ForEach(backdrops.indices, id: \.self) { index in
                Button { backdrop = index } label: {
                    Circle()
                        .fill(LinearGradient(colors: backdrops[index], startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.mixTextPrimary, lineWidth: backdrop == index ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel(Self.backdropNames[index])
                .accessibilityAddTraits(backdrop == index ? .isSelected : [])
            }
        }
    }

    // MARK: - Actions

    private func loadArtwork() {
        let data = track.displayArtwork
        artwork = data.flatMap(PlatformImage.init(data:))
        palette = ArtworkColors.gradientColors(from: data)
    }

    private func share() {
        let image = RecapExport.png(card.frame(width: 360).environment(\.colorScheme, .dark))
        guard let image else {
            deps.showToast(.failed("Couldn\u{2019}t make the card. Try again."))
            return
        }
        let item = ShareItem(url: MixtapeLink.track(track), noun: "Lyrics",
                             title: "\(track.displayTitle) lyrics", subtitle: track.displayArtistName,
                             image: image)
        dismiss()
        // The share sheet can't present while this one is still leaving.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            ShareSheet.present(item, deps: deps)
        }
    }
}

// MARK: - Card

/// The preview and the shared picture, one view so they can't drift. Fixed sizes: the
/// picture shouldn't change with the sharer's text size.
struct LyricCard: View {
    let lines: [String]
    let title: String
    let artist: String
    let artwork: PlatformImage?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Color.white.opacity(0.12)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if let artwork { Image(platformImage: artwork).resizable().scaledToFill() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(artist).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .font(.system(size: 22, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 20)

            Label("Mixtape", systemImage: MixtapeIcons.nowPlaying)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 22)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                .overlay(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}
