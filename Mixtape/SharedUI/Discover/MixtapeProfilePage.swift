// Mixtape's own profile: this week's mixes and the older ones you kept. Not a `ProfilePageView` special
// case, since Mixtape has no history or published playlists. Shared by both platforms.

import SwiftUI

struct MixtapeProfilePage: View {

    /// Open one of this week's mixes.
    let onOpenMix: (PersonalMix) -> Void
    /// Play one from its card, without opening it.
    let onPlayMix: (PersonalMix) -> Void
    /// Open a saved mix. Nil hides the tap target, since the library isn't reachable from every stack.
    var onOpenSavedMix: ((Playlist) -> Void)? = nil
    /// The mix whose first stream is being resolved, so its card can spin.
    var resolvingID: String? = nil

    @EnvironmentObject private var deps: AppDependencies

    /// Same store as the Discover landing, so this shows exactly what's on Home.
    @ObservedObject private var store = DiscoverSessionStore.shared

    private var mixes: [PersonalMix] { store.personal.mixes }

    /// Mixes saved into the library. Once a week rolls over this is the only copy.
    private var savedMixes: [Playlist] {
        deps.libraryService.playlists
            .filter { $0.origin == .mix && !$0.isDeleted }
            .sorted { $0.dateModified > $1.dateModified }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header

                if mixes.isEmpty && savedMixes.isEmpty {
                    emptyState
                } else {
                    if !mixes.isEmpty { thisWeekSection }
                    if !savedMixes.isEmpty { savedSection }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MixPageBackground())
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 22) {
            mark

            VStack(alignment: .leading, spacing: 8) {
                Text("Profile")
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixTextSecondary)
                    .textCase(.uppercase)

                Text("Mixtape")
                    .font(.system(size: MixFontScale.size(44), weight: .bold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(statLine)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    /// No shadow: the waveform is knocked out of the mark, so a shadow would show through.
    private var mark: some View {
        MixtapeMark(size: 120)
    }

    /// Mix count and how the page works. No save count: that belongs on a playlist, see `PlaylistSaveCount`.
    private var statLine: String {
        var parts: [String] = []
        if !mixes.isEmpty { parts.append(pluralised(mixes.count, "mix", plural: "mixes")) }
        parts.append("New mixes every week")
        return parts.joined(separator: "  •  ")
    }

    // MARK: - Sections

    private var thisWeekSection: some View {
        section(title: "This week",
                subtitle: "Built around the artists you play most, redrawn every Monday") {
            mixGrid
        }
    }

    @ViewBuilder
    private var mixGrid: some View {
        // Wrapped on both platforms, unlike Home: this page is about the mixes. A phone falls to one column.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                               maximum: MixMosaicCard.side),
                                     spacing: 18)],
                  alignment: .leading, spacing: 20) {
            ForEach(mixes) { mix in
                MixMosaicCard(mix: mix,
                              isResolving: mix.tracks.first.map { resolvingID == $0.id } ?? false,
                              onOpen: { onOpenMix(mix) },
                              onPlay: { onPlayMix(mix) })
                    .contextMenu { OnlineCollectionMenu(.mix(mix)) }
            }
        }
    }

    private var savedSection: some View {
        section(title: "In your library",
                subtitle: "Snapshots you kept. These don't change when the week does.") {
            LazyVStack(spacing: 2) {
                ForEach(savedMixes) { playlist in
                    savedRow(playlist)
                }
            }
        }
    }

    private func savedRow(_ playlist: Playlist) -> some View {
        Button {
            onOpenSavedMix?(playlist)
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverThumbnail(playlist: playlist, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)

                    Text(pluralised(playlist.trackIDs.count, "song"))
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(onOpenSavedMix == nil)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No mixes yet")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Mixtape builds these from the artists you play most. Listen to a few songs and they'll show up here.")
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Chrome

    private func section<Content: View>(title: String,
                                        subtitle: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                }
            }
            content()
        }
    }

    private func pluralised(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        count == 1 ? "\(count) \(noun)" : "\(count) \(plural ?? noun + "s")"
    }
}

// MARK: - Saved mix thumbnail

/// A saved mix's cover: its own artwork, or the app mark.
private struct PlaylistCoverThumbnail: View {

    let playlist: Playlist
    let size: CGFloat

    var body: some View {
        Group {
            if let data = playlist.displayArtwork, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color.mixPrimary.opacity(0.7), Color.mixPrimaryDark],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .overlay(
                        MixtapeMark(size: size * 0.44, style: Color.white.opacity(0.9))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
