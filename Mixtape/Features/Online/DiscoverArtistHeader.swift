// The top of a Discover artist page, and the "About" block at the bottom. Shared by both platforms.

import SwiftUI

/// Spotify's artist photo, which is usually better than Deezer's. Cached in the client.
@MainActor
enum ArtistPortrait {
    private static let spotify = SpotifyClient()

    static func url(for artist: OnlineArtist) async -> URL? {
        await spotify.artistImageURL(for: artist.name) ?? artist.imageURL
    }
}

struct DiscoverArtistBanner: View {

    let artist: OnlineArtist
    /// Deezer's fan count. Nil when unknown, and then the line is dropped.
    var fanCount: Int?
    var height: CGFloat = 300
    var onOpenLiked: (() -> Void)? = nil
    /// The page's Play control, under the name.
    var accessory: AnyView? = nil

    @State private var portrait: URL?

    @EnvironmentObject private var deps: AppDependencies
    @State private var likedCount = 0

    var body: some View {
        // Circle photo beside the name, over a blurred blow-up of the same picture.
        HStack(alignment: .center, spacing: 28) {
            portrait(side: height * 0.52)
            identity
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        // Sits low in the banner, where the picture is narrower.
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

    /// The name and your counts. Followers are in `DiscoverArtistAbout`.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(artist.name)
                .font(.system(size: MixFontScale.size(52), weight: .heavy))
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
                        Image(systemName: "chevron.right").font(.system(size: MixFontScale.size(11), weight: .bold))
                    }
                }
                .font(.system(size: MixFontScale.size(14), weight: .semibold))
                .foregroundStyle(.white.opacity(likedCount == 0 ? 0.7 : 0.95))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(likedCount == 0 || onOpenLiked == nil)

            if let accessory { accessory.padding(.top, 6) }
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
    }

    /// Rewrites a Deezer image URL's size segment (`.../1000x1000-000000-80-0-0.jpg`).
    /// Other URLs are left alone.
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
                .font(.system(size: MixFontScale.size(18), weight: .bold))
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
                            .font(.system(size: MixFontScale.size(15), weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                    }
                    DiscoverArtistCounts(artistName: artist.name,
                                         songCount: songCount,
                                         releaseCount: releaseCount,
                                         onOpenLiked: onOpenLiked)
                }
                Spacer(minLength: 0)
            }

            // Wikipedia's opening paragraph, attributed. Absent when there's no article.
            if let bio {
                Text(bio)
                    .font(.system(size: MixFontScale.size(13)))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    // "Read more" only when something is actually folded away.
                    if bio.count > 260 {
                        Button(bioExpanded ? "Show less" : "Read more") {
                            withMixAnimation(.easeInOut(duration: 0.15)) { bioExpanded.toggle() }
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.system(size: MixFontScale.size(12), weight: .semibold))
                        .foregroundStyle(Color.mixPrimary)
                    }
                    Text("From Wikipedia")
                        .font(.system(size: MixFontScale.size(11)))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .padding(16)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: artist.id) { bio = await ArtistBioService.shared.bio(for: artist.name) }
    }
}

/// The artist photo, blurred, behind the whole page. Fades into the page colour over the first screen.
struct DiscoverArtistWash: View {
    let artist: OnlineArtist

    @State private var portrait: URL?
    /// Identity for the shared tint. See `ArtworkWashTint.resign`.
    @State private var id = UUID()
    @Environment(\.mixChrome) private var chrome

    var body: some View {
        ZStack(alignment: .top) {
            MixPageBackground()
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
        // The window chrome already draws `ArtworkWashTint`, so publishing here tints the whole app.
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
