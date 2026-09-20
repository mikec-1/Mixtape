// DiscoverArtistHeader.swift
// Mixtape — Features/Online
//
// The top of a Discover artist page, and the "About" block at the bottom of it.
//
// The header used to be a 140pt circle beside the name, which is what a *row*
// in a list of artists looks like — arriving on the page felt like arriving
// nowhere. This is the Spotify shape instead: the artist's picture as the page,
// their name over it, and the numbers underneath in one line.
//
// Shared by both platforms for the same reason `DiscoverArtistCounts` is.

import SwiftUI

/// Spotify's artist photo, which is the one people recognise — Deezer's is
/// often an older or lower-quality press shot. Shared (and cached inside the
/// client) by everything on the artist page that draws the picture.
@MainActor
enum ArtistPortrait {
    private static let spotify = SpotifyClient()

    static func url(for artist: OnlineArtist) async -> URL? {
        await spotify.artistImageURL(for: artist.name) ?? artist.imageURL
    }
}

struct DiscoverArtistBanner: View {

    let artist: OnlineArtist
    /// Deezer's fan count. Nil when unknown — which is not the same as zero,
    /// so the line is dropped rather than reading "0 fans".
    var fanCount: Int?
    var height: CGFloat = 300
    var onOpenLiked: (() -> Void)? = nil
    /// The page's Play control, drawn under the name so the header is one
    /// block instead of a picture with a button floating below it.
    var accessory: AnyView? = nil

    @State private var portrait: URL?

    @EnvironmentObject private var deps: AppDependencies
    @State private var likedCount = 0

    var body: some View {
        // One shape, whether or not there is a photo: the picture as a circle,
        // the name beside it, and a blown-up blur of the same picture behind
        // the lot. A wide crop of a square press photo was mostly somebody's
        // chin, and it ended in a hard black edge halfway down the window.
        HStack(alignment: .center, spacing: 28) {
            portrait(side: height * 0.52)
            identity
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        // Sits low in the banner: the picture behind it is widest at the top,
        // and nothing below moves because `minHeight` is unchanged.
        .padding(.top, 78)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .task(id: artist.id) { portrait = await ArtistPortrait.url(for: artist) }
        .task(id: fingerprint) {
            likedCount = DiscoverArtistCounts.likedTracks(by: artist.name,
                                                          in: deps.libraryService).count
        }
    }

    private var fingerprint: String {
        let count = deps.libraryService.playlists.first(where: \.isFavourites)?.trackIDs.count ?? 0
        return "\(artist.id)#\(count)"
    }

    private func portrait(side: CGFloat) -> some View {
        CachedRemoteImage(url: portrait ?? artist.imageURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.mixSurface2.overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.75), lineWidth: 3) }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// The name, and what you have of them — the follower count is a fact about
    /// the artist and lives in `DiscoverArtistAbout` at the foot of the page.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(artist.name)
                .font(.system(size: 52, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
            Button { onOpenLiked?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                    Text(likedCount == 0
                         ? "No liked songs yet"
                         : "\(likedCount) liked song\(likedCount == 1 ? "" : "s")")
                    if likedCount > 0, onOpenLiked != nil {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(likedCount == 0 ? 0.7 : 0.95))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(likedCount == 0 || onOpenLiked == nil)

            if let accessory { accessory.padding(.top, 6) }
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
    }

    /// Rewrites the size segment of a Deezer image URL
    /// (`.../1000x1000-000000-80-0-0.jpg`) to the size we actually draw.
    /// Anything that isn't shaped like one is left alone.
    static func upscaled(_ url: URL?, to side: Int = 1920) -> URL? {
        guard let url else { return nil }
        let name = url.lastPathComponent
        guard let range = name.range(of: #"^\d+x\d+"#, options: .regularExpression) else { return url }
        let renamed = name.replacingCharacters(in: range, with: "\(side)x\(side)")
        return url.deletingLastPathComponent().appendingPathComponent(renamed)
    }
}

/// The numbers, kept out of the banner so they stay legible on any photo.
struct DiscoverArtistAbout: View {

    let artist: OnlineArtist
    let songCount: Int
    let releaseCount: Int
    var fanCount: Int?
    var onOpenLiked: (() -> Void)? = nil

    @State private var bio: String?
    @State private var bioExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.mixTextPrimary)

            HStack(alignment: .top, spacing: 16) {
                CachedRemoteImage(url: artist.imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.mixSurface2
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 6) {
                    if let fans = fanCount, fans > 0 {
                        Text("\(fans.formatted(.number)) followers")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                    }
                    DiscoverArtistCounts(artistName: artist.name,
                                         songCount: songCount,
                                         releaseCount: releaseCount,
                                         onOpenLiked: onOpenLiked)
                }
                Spacer(minLength: 0)
            }

            // The catalogue we read has no biography, so this is Wikipedia's
            // opening paragraph — attributed, and simply absent when there is
            // no article rather than filled in with something invented.
            if let bio {
                Text(bio)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    // Only when there is something folded away: a "Read more"
                    // that expands nothing is the bug, not the paragraph.
                    if bio.count > 260 {
                        Button(bioExpanded ? "Show less" : "Read more") {
                            withMixAnimation(.easeInOut(duration: 0.15)) { bioExpanded.toggle() }
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                    }
                    Text("From Wikipedia")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .padding(16)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: artist.id) { bio = await ArtistBioService.shared.bio(for: artist.name) }
    }
}

/// The artist's photo, blown up and blurred, as the background of the *whole*
/// page rather than of the banner alone — as a banner background it ended in a
/// hard horizontal edge partway down the window, which is the "cut off" line.
/// It fades into the page colour over the first screenful and then stays there.
struct DiscoverArtistWash: View {
    let artist: OnlineArtist

    @State private var portrait: URL?
    /// Identity for the shared tint — see `ArtworkWashTint.resign`.
    @State private var id = UUID()
    @Environment(\.mixChrome) private var chrome

    var body: some View {
        ZStack(alignment: .top) {
            Color.mixBackground
            CachedRemoteImage(url: DiscoverArtistBanner.upscaled(portrait ?? artist.imageURL, to: 500)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(maxWidth: .infinity)
            .blur(radius: 70, opaque: true)
            .saturation(1.5)
            .overlay(Color.black.opacity(0.4))
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: artist.id) { portrait = await ArtistPortrait.url(for: artist) }
        // The rest of the window — sidebar, titlebar, queue panel, player bar —
        // already draws whatever is in `ArtworkWashTint`, so publishing the
        // artist's colours here carries the page's gradient across the whole app.
        .task(id: portrait ?? artist.imageURL) { await publishTint() }
        .onDisappear { ArtworkWashTint.shared.resign(id) }
    }

    private func publishTint() async {
        guard chrome.showsArtworkWash,
              let url = DiscoverArtistBanner.upscaled(portrait ?? artist.imageURL, to: 500)
        else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let colors = await Task.detached(priority: .userInitiated) {
            ArtworkColors.gradientColors(from: data)
        }.value
        guard colors.count == 2 else { return }
        ArtworkWashTint.shared.publish(colors: colors, intensity: 1, from: id)
    }
}
