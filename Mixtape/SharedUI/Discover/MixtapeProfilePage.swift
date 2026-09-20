// MixtapeProfilePage.swift
// Mixtape — SharedUI/Discover
//
// Mixtape's own profile: the page behind the app's name in a mix byline.
//
// A mix says it belongs to Mixtape, and a name that claims ownership should have
// somewhere to go — the same way tapping a friend's name on a shared playlist
// opens theirs. What's behind this one is everything Mixtape has made for you:
// this week's mixes, and the older ones you kept.
//
// Deliberately NOT a `ProfilePageView` with a special case bolted on. That page
// is about a person — stats they've chosen to share, playlists they've chosen to
// publish, a follow-nothing header that still reads as social. Mixtape has no
// listening history, publishes nothing, and its "playlists" are rebuilt weekly
// from *your* taste, so nearly every row on that page would be either blank or a
// small lie.
//
// Shared by both platforms, like MixDetailPage: the layout is identical and only
// "where does a tap go" differs, which is what the closures are for.

import SwiftUI

struct MixtapeProfilePage: View {

    /// Open one of this week's mixes.
    let onOpenMix: (PersonalMix) -> Void
    /// Play one from its card, without opening it.
    let onPlayMix: (PersonalMix) -> Void
    /// Open a mix already saved into the library. Nil hides the saved section's
    /// tap target rather than offering a press that does nothing — the library
    /// isn't reachable from every stack this page can appear in.
    var onOpenSavedMix: ((Playlist) -> Void)? = nil
    /// The mix whose first stream is being resolved, so its card can spin.
    var resolvingID: String? = nil

    @EnvironmentObject private var deps: AppDependencies

    /// The same store the Discover landing draws from, so this page shows
    /// exactly the mixes that are on Home right now — no second fetch, and no
    /// chance of the two disagreeing about what this week's mixes are.
    @ObservedObject private var store = DiscoverSessionStore.shared

    private var mixes: [PersonalMix] { store.personal.mixes }

    /// Mixes that were saved into the library. Older weeks live here and nowhere
    /// else — once a week rolls over, the only copy of that mix is the snapshot
    /// the user chose to keep.
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
        .background(Color.mixBackground)
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
                    .font(.system(size: 44, weight: .bold))
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

    /// No drop shadow, unlike the covers around it: the waveform is knocked out
    /// of the mark rather than drawn on it, so a shadow behind the circle shows
    /// through the very gaps that make it legible.
    private var mark: some View {
        MixtapeMark(size: 120)
    }

    /// The count, then the one thing worth knowing about how this page behaves.
    ///
    /// Deliberately nothing about saves. How many of Mixtape's playlists you
    /// happen to be holding says nothing about Mixtape, and read as a profile
    /// stat it claimed to mean the opposite of what it did — how popular the
    /// playlists were. That number belongs on a playlist, not on a profile; see
    /// `PlaylistSaveCount`.
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
        // Wrapped on both platforms here, unlike the Home shelf. This page is
        // *about* the mixes, so burying half of them in a carousel would be the
        // one thing it exists not to do — and on a phone the grid falls to a
        // single column on its own.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                               maximum: MixMosaicCard.side),
                                     spacing: 18)],
                  alignment: .leading, spacing: 20) {
            ForEach(mixes) { mix in
                MixMosaicCard(mix: mix,
                              isResolving: mix.tracks.first.map { resolvingID == $0.id } ?? false,
                              onOpen: { onOpenMix(mix) },
                              onPlay: { onPlayMix(mix) })
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { onPlayMix(mix) }
                        Button("Open Mix", systemImage: "square.stack") { onOpenMix(mix) }
                    }
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

/// The cover of a saved mix, which is a library playlist like any other — its
/// own artwork when the save wrote one, and the app's mark when it didn't.
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
