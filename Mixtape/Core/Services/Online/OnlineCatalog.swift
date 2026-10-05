// Discover browse types: Deezer artists and albums. Songs use OnlineTrack.

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

    /// Only the album detail endpoint has this, so usually nil. Used for New releases.
    public let releaseDate: Date?

    /// "album" | "ep" | "single" | "compile", when known. Label only.
    public let recordType: String?

    /// Nil when unknown so the label can be left out.
    public var recordTypeLabel: String? {
        switch recordType {
        case "album":   return "Album"
        case "ep":      return "EP"
        case "single":  return "Single"
        case "compile": return "Compilation"
        default:        return nil
        }
    }

    /// From /artist/{id}/albums only. Used to total an artist's catalogue.
    public let trackCount: Int?

    public init(id: Int, title: String, artistName: String, coverURL: URL?,
                releaseDate: Date? = nil, recordType: String? = nil,
                trackCount: Int? = nil) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.coverURL = coverURL
        self.releaseDate = releaseDate
        self.recordType = recordType
        self.trackCount = trackCount
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

/// A search-as-you-type row. `kind` carries the Deezer id so a tap opens it
/// directly. `.term` just re-runs the search.
public struct SearchSuggestion: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case term                     // plain query completion, no entity behind it
        case artist(id: Int)          // Deezer artist id
        case track(id: Int)           // Deezer track id
        case album(id: Int)           // Deezer album id
    }
    public let id: String
    public let kind: Kind
    public let title: String          // primary line
    public let subtitle: String?      // "Artist", "Song • THIZZY52"
    public let imageURL: URL?
    public let isExplicit: Bool

    /// The artist behind the subtitle, kept structured so it isn't parsed back out.
    public let artistName: String?
    public let albumTitle: String?

    /// Track length. The resolver gates on duration, so 0 would mean anything goes.
    public let duration: TimeInterval?

    /// Set by SearchSuggestionsStore. Badges the row and sorts it first.
    public var inLibrary = false

    public init(id: String, kind: Kind, title: String, subtitle: String?,
                imageURL: URL?, isExplicit: Bool,
                artistName: String? = nil, albumTitle: String? = nil,
                duration: TimeInterval? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.isExplicit = isExplicit
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
    }
}

/// Discover before any search: charts, artists, new releases and genres.
/// Each part fails to an empty array.
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

    /// Lyrics matches, filled in after the main results.
    public var lyricMatches: [OnlineTrack]

    /// Whether the query named an artist, so artists.first is the top result.
    /// Decided by the search layer; don't re-derive it from the query text.
    public var anchorIsArtist: Bool

    /// Whether the songs actually match the query. False means the filter emptied
    /// the list and raw Deezer hits were kept, so the page labels them differently.
    public var songsMatched: Bool

    public init(songs: [OnlineTrack] = [], artists: [OnlineArtist] = [], albums: [OnlineAlbum] = [],
                topSong: OnlineTrack? = nil, songArtists: [OnlineArtist] = [],
                lyricMatches: [OnlineTrack] = [], anchorIsArtist: Bool = false,
                songsMatched: Bool = true) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.topSong = topSong
        self.songArtists = songArtists
        self.lyricMatches = lyricMatches
        self.anchorIsArtist = anchorIsArtist
        self.songsMatched = songsMatched
    }

    public var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && topSong == nil && lyricMatches.isEmpty
    }
}

/// Everything the artist page draws.
public struct OnlineArtistCatalogue: Sendable {
    /// Their own songs, most popular first.
    public var top: [OnlineTrack] = []
    public var albums: [OnlineAlbum] = []
    public var related: [OnlineArtist] = []
    /// Songs on other artists' releases that credit this artist.
    public var appearsOn: [OnlineTrack] = []
    /// Deezer's artist radio, seeds the station on the page.
    public var radio: [OnlineTrack] = []
    /// Nil when the lookup failed, so it never shows "0 fans".
    public var fanCount: Int?

    public var isEmpty: Bool { top.isEmpty && albums.isEmpty && appearsOn.isEmpty }

    public init() {}
}
