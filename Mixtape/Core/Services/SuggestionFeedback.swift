// SuggestionFeedback.swift
// Mixtape — Core/Services
//
// "Don't suggest this again."
//
// Every recommendation the app makes is built from two things: what you play and
// what Deezer's radio says goes with it. Neither has a way of hearing "no". A
// song you skip every single time keeps coming back in next week's mix, because
// nothing was ever written down when you skipped it — the engine only ever got
// positive signal, so its idea of your taste could only grow.
//
// This is the negative half. Two lists, both small by nature: songs that should
// never be suggested, and artists that should never be suggested. They filter
// the radio the mixes are built from, the queue's autoplay top-up, and the
// seeds themselves, so a blocked artist can't come back as the reason for a
// whole mix.
//
// Read from any thread, so the lists live in UserDefaults rather than behind the
// main actor: a filter sits in the middle of a catalogue fetch, and a hop to the
// main actor per Deezer response is a hop per row of the landing page.
//
// ponytail: local to this device — hiding a song on the Mac doesn't hide it on
// iOS. Move both lists into `user_metadata` alongside the sort order if that
// starts to matter.

import Foundation

public enum SuggestionFeedback {

    private static let songsKey   = "mix.suggestions.hiddenSongs"
    private static let artistsKey = "mix.suggestions.blockedArtists"

    /// `title|artist`, lowercased — the same key every other cross-source list
    /// here uses, because the same song arrives as a library row, a queue mirror
    /// and a Deezer suggestion with three different ids.
    public static func key(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    // MARK: - Reading

    public static var hiddenSongs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: songsKey) ?? [])
    }

    /// Folded through `ArtistAliases`, so blocking "Digga D" also blocks the
    /// library's "Digga".
    public static var blockedArtists: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: artistsKey) ?? [])
    }

    public static func isHidden(title: String, artist: String) -> Bool {
        hiddenSongs.contains(key(title: title, artist: artist))
    }

    public static func isBlocked(artist: String) -> Bool {
        blockedArtists.contains(ArtistAliases.fold(artist))
    }

    /// Whether a suggestion may be made. Every credited artist counts: a feature
    /// by a blocked artist is still a song with them on it.
    public static func allows(title: String, artist: String) -> Bool {
        let songs = hiddenSongs, artists = blockedArtists
        guard !songs.contains(key(title: title, artist: artist)) else { return false }
        guard !artists.isEmpty else { return true }
        return !ImportService.creditedArtists(from: artist)
            .contains { artists.contains(ArtistAliases.fold($0)) }
    }

    public static func allows(_ track: Track) -> Bool {
        allows(title: track.identityTitle, artist: track.artistName)
    }

    public static func allows(_ track: OnlineTrack) -> Bool {
        allows(title: track.title, artist: track.artistName)
    }

    // MARK: - Writing

    public static func hide(title: String, artist: String) {
        var songs = hiddenSongs
        guard songs.insert(key(title: title, artist: artist)).inserted else { return }
        UserDefaults.standard.set(Array(songs), forKey: songsKey)
    }

    public static func unhide(title: String, artist: String) {
        var songs = hiddenSongs
        guard songs.remove(key(title: title, artist: artist)) != nil else { return }
        UserDefaults.standard.set(Array(songs), forKey: songsKey)
    }

    public static func block(artist: String) {
        let folded = ArtistAliases.fold(artist)
        guard !folded.isEmpty else { return }
        var artists = blockedArtists
        guard artists.insert(folded).inserted else { return }
        UserDefaults.standard.set(Array(artists), forKey: artistsKey)
    }

    public static func unblock(artist: String) {
        var artists = blockedArtists
        guard artists.remove(ArtistAliases.fold(artist)) != nil else { return }
        UserDefaults.standard.set(Array(artists), forKey: artistsKey)
    }

    /// Both lists name songs and artists that were in the library. A wipe takes
    /// the reason for them with it — see `UserDataReset`.
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: songsKey)
        UserDefaults.standard.removeObject(forKey: artistsKey)
    }
}
