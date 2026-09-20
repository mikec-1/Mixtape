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

    /// When it came out, where that's known. Only the album *detail* endpoint
    /// carries it — search and chart listings don't — so this is nil for most
    /// albums and non-nil exactly where it's needed: deciding whether something
    /// belongs in "New releases". Optional rather than defaulted to a date, so
    /// "we don't know" can't masquerade as "released in 1970".
    public let releaseDate: Date?

    /// "album" | "ep" | "single" | "compile", where the endpoint said. Nil where
    /// it didn't. Only used to label a release — "Single • Drake" — so an
    /// unknown one simply goes unlabelled rather than being guessed at.
    public let recordType: String?

    /// The label for `recordType`, in the app's capitalisation. Nil when we
    /// don't know, so callers can leave the line out entirely.
    public var recordTypeLabel: String? {
        switch recordType {
        case "album":   return "Album"
        case "ep":      return "EP"
        case "single":  return "Single"
        case "compile": return "Compilation"
        default:        return nil
        }
    }

    /// How many songs are on it, where the endpoint said so — `/artist/{id}/
    /// albums` carries it, search and the charts don't. Used to total up an
    /// artist's catalogue without opening every release.
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

/// One row in the search-as-you-type dropdown.
///
/// `kind` carries the Deezer id so a tap can open the entity directly instead of
/// re-running the text search — except `.term`, which is a plain query completion
/// with nothing behind it and should just re-run the search.
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

    /// The same names the subtitle renders, kept structured.
    ///
    /// `subtitle` is a display string and nothing else — picking a row has to
    /// build an `OnlineTrack`/`OnlineAlbum` to play or open, and splitting
    /// "Song • THIZZY52" back apart on a bullet would break on the first artist
    /// with one in their name. Nil where the kind has no such name.
    public let artistName: String?
    public let albumTitle: String?

    /// The song's length, when the row is a track. Optional so recents saved
    /// before it existed still decode — and carried at all because the
    /// resolver gates its pick on the catalogue duration: handing it 0 is
    /// handing it "anything goes".
    public let duration: TimeInterval?

    /// True when this is something the library already has. Set by
    /// `SearchSuggestionsStore` after the fetch — the catalogue layer knows
    /// nothing about the user — and used both to badge the row and to float it
    /// above the strangers.
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

    /// True when the query named an ARTIST (so `artists.first` is the anchor the
    /// whole page was built from and belongs in "Top result"), false when it named
    /// a song. The search layer decides this from name-match strength, popularity
    /// and which artist owns the matching songs; a view re-deriving it from the raw
    /// query text will disagree on abbreviations like "wknd" → The Weeknd.
    public var anchorIsArtist: Bool

    /// True when the songs genuinely answer the query — either they belong to
    /// the anchor artist, or their titles/credits contain what was typed.
    ///
    /// False means the relevance filter emptied the list and the raw Deezer
    /// full-text hits were kept instead, which is deliberate (a strange query
    /// showing *something* beats a blank page) but is not the same claim. The
    /// page has to say which it is: presenting a guess under a plain "Songs"
    /// heading is exactly how a search reads as broken.
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
///
/// A struct rather than the tuple this used to be, because the page grew an
/// "Appears On" shelf and a fan count and a five-field tuple is where that
/// stops being readable.
public struct OnlineArtistCatalogue: Sendable {
    /// Their own songs, most popular first.
    public var top: [OnlineTrack] = []
    public var albums: [OnlineAlbum] = []
    public var related: [OnlineArtist] = []
    /// Songs released under someone else's name that credit this artist —
    /// Spotify's "Appears On", which for a features-heavy artist is most of
    /// what you actually came looking for.
    public var appearsOn: [OnlineTrack] = []
    /// Deezer's own "fans also like" radio for this artist — the seed for the
    /// "<name> Radio" station on the page.
    public var radio: [OnlineTrack] = []
    /// Deezer's fan count, for the header. Nil when the lookup failed —
    /// a missing number must not render as "0 fans".
    public var fanCount: Int?

    public var isEmpty: Bool { top.isEmpty && albums.isEmpty && appearsOn.isEmpty }

    public init() {}
}
