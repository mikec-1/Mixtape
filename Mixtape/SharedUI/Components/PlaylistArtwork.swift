// A playlist's cover, drawn the same everywhere. The rule lives in
// `LibraryService.coverData(for:)`; use this instead of `ArtworkThumbnail`.

import SwiftUI

struct PlaylistArtwork: View {

    let playlist: Playlist
    /// Nil fills the container, usually a grid cell.
    var size: CGFloat?
    var cornerRadius: CGFloat = 6

    var body: some View {
        if let smart = SmartPlaylistService.current?.playlists.first(where: { $0.id == playlist.id }) {
            // A rule, not its songs. See `SmartPlaylistCover`.
            if let size {
                SmartPlaylistCover(playlist: smart, size: size)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { GeometryReader { SmartPlaylistCover(playlist: smart, size: $0.size.width) } }
            }
        } else {
            standard
        }
    }

    private var standard: some View {
        // `.playlist` loader: same rule as `coverData(for:)` (own picture, first song's,
        // else 2x2), but reads and composes off the main thread.
        artwork
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var artwork: some View {
        let image = AsyncArtworkImage(source: .playlist(playlist.id), size: size) {
            fallback
        }
        if let size {
            image.frame(width: size, height: size)
        } else {
            // `Color.clear` sets a square footprint whatever the cover's proportions.
            // A filling image otherwise reports its overflowed size, so a portrait photo
            // set the height of the grid row.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { image }
                .clipped()
        }
    }

    private var fallback: some View {
        PlaylistArtwork.background(for: playlist)
            .overlay(
                Image(systemName: PlaylistArtwork.placeholder(for: playlist))
                    .font(.system(size: (size ?? 48) * 0.45))
                    .foregroundStyle(PlaylistArtwork.tint(for: playlist))
            )
    }

    // MARK: - The identity tiles
    // Static for places that can't use the view (Mac table cells, the command palette).

    /// All Songs and Favourites use fixed icons, never a song's cover.
    static func placeholder(for playlist: Playlist) -> String {
        if playlist.isFavourites { return "heart.fill" }
        if playlist.isAllSongs   { return "music.note.list" }
        return MixtapeIcons.playlist
    }

    /// Both system rows use the brand colour.
    static func tint(for playlist: Playlist) -> Color {
        playlist.isSystem ? .mixPrimary : .mixTextTertiary
    }

    static func background(for playlist: Playlist) -> Color {
        playlist.isSystem ? Color.mixPrimary.opacity(0.15) : .mixSurface2
    }
}
