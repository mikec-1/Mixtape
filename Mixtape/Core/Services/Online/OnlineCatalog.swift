// OnlineCatalog.swift
// Mixtape
//
// Value types for Discover browse — artists and albums from Deezer search.
// Songs use OnlineTrack.

import Foundation

/// `id` is the Deezer artist id, used to fetch top tracks + albums.
public struct OnlineArtist: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let imageURL: URL?

    public init(id: Int, name: String, imageURL: URL?) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
    }
}

/// `id` is the Deezer album id, used to fetch its track list.
public struct OnlineAlbum: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let artistName: String
    public let coverURL: URL?

    public init(id: Int, title: String, artistName: String, coverURL: URL?) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.coverURL = coverURL
    }
}

/// A genre/mood tile for the "Browse all" grid. `id` is the Deezer genre id.
public struct BrowseGenre: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let pictureURL: URL?

    public init(id: Int, name: String, pictureURL: URL?) {
        self.id = id
        self.name = name
        self.pictureURL = pictureURL
    }
}

/// What the Discover tab shows before any search — charts, artists, new releases
/// and genres from Deezer's free endpoints. Each leg fails soft to an empty array.
public struct BrowseLanding: Sendable {
    public var trending: [OnlineTrack]
    public var artists: [OnlineArtist]
    public var newReleases: [OnlineAlbum]
    public var genres: [BrowseGenre]

    public init(trending: [OnlineTrack] = [], artists: [OnlineArtist] = [],
                newReleases: [OnlineAlbum] = [], genres: [BrowseGenre] = []) {
        self.trending = trending
        self.artists = artists
        self.newReleases = newReleases
        self.genres = genres
    }

    public var isEmpty: Bool {
        trending.isEmpty && artists.isEmpty && newReleases.isEmpty && genres.isEmpty
    }
}

/// Grouped payload behind the sectioned search results.
public struct DiscoverResults: Sendable {
    public var songs:   [OnlineTrack]
    public var artists: [OnlineArtist]
    public var albums:  [OnlineAlbum]

    /// The matched song shown as a wide hero, for song-centric queries. Nil otherwise.
    public var topSong: OnlineTrack?
    /// Main + featured artists on `topSong`, shown beneath the hero.
    public var songArtists: [OnlineArtist]

    /// Songs matched by lyrics (NetEase search → Deezer). Filled in after the
    /// main results, shown with a "Lyrics match" badge.
    public var lyricMatches: [OnlineTrack]

    public init(songs: [OnlineTrack] = [], artists: [OnlineArtist] = [], albums: [OnlineAlbum] = [],
                topSong: OnlineTrack? = nil, songArtists: [OnlineArtist] = [],
                lyricMatches: [OnlineTrack] = []) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.topSong = topSong
        self.songArtists = songArtists
        self.lyricMatches = lyricMatches
    }

    public var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && topSong == nil && lyricMatches.isEmpty
    }
}
