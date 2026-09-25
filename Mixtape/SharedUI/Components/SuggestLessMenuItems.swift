// SuggestLessMenuItems.swift
// Mixtape — SharedUI/Components
//
// "Don't suggest this again" — one pair of items, every track menu.
//
// The only way the app could learn anything about taste was by playing
// something: skips went unrecorded, so a song you never wanted came back in
// every mix. These are the two answers worth writing down — not this song, and
// not this artist — and they go in both menus, because the song you want gone
// from your mixes is usually the one a mix just handed you.
//
// Identity is the same `title|artist` key the rest of the app matches songs
// across sources with, so hiding a library row also hides the Deezer suggestion
// it came back as. See `SuggestionFeedback`.

import SwiftUI

struct SuggestLessMenuItems: View {

    let title: String
    let artistName: String

    /// The identity spelling, not the printed one: the credit is stripped out of
    /// a title for display, and a key built from the printed one would miss.
    init(track: Track) {
        self.title = track.identityTitle
        self.artistName = track.artistName
    }

    init(song: OnlineTrack) {
        self.title = song.title
        self.artistName = song.artistName
    }

    var body: some View {
        let hidden = SuggestionFeedback.isHidden(title: title, artist: artistName)
        Button(hidden ? "Suggest This Song Again" : "Don't Suggest This Song",
               systemImage: hidden ? "eye" : "eye.slash") {
            if hidden { SuggestionFeedback.unhide(title: title, artist: artistName) }
            else      { SuggestionFeedback.hide(title: title, artist: artistName) }
        }

        // Each credited artist on its own, so "don't suggest this artist" on a
        // feature doesn't quietly block the person whose song it is.
        let credits = ImportService.creditedArtists(from: artistName)
        if credits.count > 1 {
            Menu {
                ForEach(credits, id: \.self) { name in artistButton(name) }
            } label: {
                Label("Don't Suggest an Artist", systemImage: "person.slash")
            }
        } else if let name = credits.first ?? (artistName.isEmpty ? nil : artistName) {
            artistButton(name)
        }
    }

    @ViewBuilder
    private func artistButton(_ name: String) -> some View {
        let blocked = SuggestionFeedback.isBlocked(artist: name)
        Button(blocked ? "Suggest \(name) Again" : "Don't Suggest \(name)",
               systemImage: blocked ? "person" : "person.slash") {
            if blocked { SuggestionFeedback.unblock(artist: name) }
            else       { SuggestionFeedback.block(artist: name) }
        }
    }
}
