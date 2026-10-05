// "Don't suggest this song/artist" for every track menu. Uses the same
// `title|artist` key as cross-source matching, so hiding a library row also
// hides its Deezer version. See `SuggestionFeedback`.

import SwiftUI

struct SuggestLessMenuItems: View {

    let title: String
    let artistName: String

    /// Identity spelling, not the printed one, or the key misses.
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

        // Each credited artist separately, so a feature doesn't block the main artist.
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
