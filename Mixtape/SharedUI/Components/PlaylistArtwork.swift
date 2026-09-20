// PlaylistArtwork.swift
// Mixtape — SharedUI/Components
//
// The picture a playlist wears, drawn the same way everywhere.
//
// Every surface that shows a playlist used to reach for `playlist.artworkData`
// itself and pick its own fallback, which is why the sidebar could show a grey
// tile for a playlist whose page showed a cover: the page had learned to borrow
// the first song's artwork and nothing else had. Same reason All Songs sat next
// to Favourites wearing a different-looking tile — the heart was special-cased
// in one place and the note wasn't.
//
// The rule lives in `LibraryService.coverData(for:)`; this is the view half of
// it, so a row gets both halves by using this instead of `ArtworkThumbnail`.

import SwiftUI

struct PlaylistArtwork: View {

    let playlist: Playlist
    /// Nil lets the tile fill whatever it's put in — a grid cell, usually.
    var size: CGFloat?
    var cornerRadius: CGFloat = 6

    var body: some View {
        if let smart = SmartPlaylistService.current?.playlists.first(where: { $0.id == playlist.id }) {
            // A rule, not its songs — see `SmartPlaylistCover`.
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
        // `.playlist` rather than `.row(.playlist(…))`: the loader applies the
        // same rule `LibraryService.coverData(for:)` does — the playlist's own
        // picture, else the first song's, else the 2×2 — but it reads the songs
        // and composes the mosaic on a background thread instead of inside
        // `body`. Composing a 2×2 means decoding four JPEGs, which is not
        // something a sidebar row should do while it draws.
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
            // A square the cover is drawn *into*, rather than one it is asked
            // politely to be.
            //
            // `AsyncArtworkImage` fills (`scaledToFill`), and a filling image
            // overflows whichever dimension it has to in order to cover — then
            // reports that overflowed size to its parent. With no frame to stop
            // it (the `size: nil` case is exactly that), a portrait photo made
            // the grid cell as tall as the photo, which is why one uploaded
            // picture could set the shape of a whole row.
            //
            // `Color.clear` does the sizing, so the footprint is square no
            // matter what the cover's proportions are, and the overlay is
            // clipped to it.
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
    //
    // Static because a few places can't use the view — a Mac table cell drawing
    // an `NSImage`, the command palette's own row type — and they still have to
    // agree about what Favourites looks like.

    /// All Songs is the library itself and Favourites is the heart; both are
    /// stand-ins on purpose, and neither ever borrows a song's cover.
    static func placeholder(for playlist: Playlist) -> String {
        if playlist.isFavourites { return "heart.fill" }
        if playlist.isAllSongs   { return "music.note.list" }
        return MixtapeIcons.playlist
    }

    /// Both system rows wear the brand colour. Favourites always did; All Songs
    /// didn't, which left the top row of the sidebar looking like the one item
    /// that had failed to load rather than the one that can't have a cover.
    static func tint(for playlist: Playlist) -> Color {
        playlist.isSystem ? .mixPrimary : .mixTextTertiary
    }

    static func background(for playlist: Playlist) -> Color {
        playlist.isSystem ? Color.mixPrimary.opacity(0.15) : .mixSurface2
    }
}
