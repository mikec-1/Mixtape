// LinkImportService.swift
// Mixtape — Core/Services/Online
//
// "Here's a link, put this song in my library."
//
// The two links people actually paste point at different things, so they take
// different routes to the same place:
//
//   Spotify  — a catalogue entry with no audio attached. Spotify will hand over
//              title / artist / album / runtime and nothing else, so the link is
//              metadata only: the resolver then goes and finds the song exactly
//              the way saving from Discover does. Same identity, too, so a song
//              saved by link and the same song saved from Discover are one row.
//
//   YouTube  — an *upload*, not a song. The user has already chosen which one,
//              so searching for "the best match" would be a way of overruling
//              them; the video id is pinned through the resolver instead. What
//              YouTube won't reliably give is clean metadata ("Dave - Sprinter
//              (Official Video)", uploaded by "Santan Dave"), so the title is
//              tidied and then checked against the catalogue for a real album
//              and cover.
//
// Both end at `importOnlineTrack`, which owns the copy, the artwork, the
// All Songs membership and the duplicate rules — none of that is re-decided here.

import Foundation
import AVFoundation

/// Stateless on purpose — one call in, one `Outcome` out. The progress spinner
/// and the error live in whichever sheet asked, so two sheets can't fight over
/// one shared "is importing" flag.
@MainActor
public final class LinkImportService {

    // MARK: - Types

    public enum Failure: LocalizedError, Equatable {
        case notATrackLink
        case lookupFailed(String)
        case resolveFailed(String)
        case importFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notATrackLink:
                return "That isn't a Spotify or YouTube song link. Copy the link to a single track and try again."
            case .lookupFailed(let why):
                return why.isEmpty ? "Couldn't read that link." : why
            case .resolveFailed(let why):
                return why.isEmpty ? "Couldn't find the audio for that song." : why
            case .importFailed(let why):
                return why.isEmpty ? "Couldn't add that song to your library." : why
            }
        }
    }

    public struct Outcome: Sendable {
        public let track: Track
        /// True when the song was already there. The sheet says so rather than
        /// claiming a save that didn't happen.
        public let alreadySaved: Bool
    }

    /// What a link resolved to before any audio was fetched.
    private struct Draft {
        var title: String
        var artistName: String
        var albumTitle: String
        var duration: TimeInterval
        var artworkURL: URL?
        var isExplicit: Bool
        var sourceID: Int?
        /// Set only for YouTube links — the upload to fetch instead of searching.
        var pinnedVideoID: String?
    }

    // MARK: - Dependencies

    private let resolver: any TrackResolver
    private let importService: ImportService
    private let spotify: SpotifyClient
    private let catalogue: ITunesSearchClient
    private let library: LibraryService

    public init(resolver: any TrackResolver,
                importService: ImportService,
                spotify: SpotifyClient,
                catalogue: ITunesSearchClient,
                library: LibraryService) {
        self.resolver      = resolver
        self.importService = importService
        self.spotify       = spotify
        self.catalogue     = catalogue
        self.library       = library
    }

    // MARK: - Public API

    /// Import whatever song `raw` points at. Throws `Failure` with a message
    /// that's safe to show as-is.
    public func importTrack(from raw: String) async throws -> Outcome {
        guard let link = MusicLink.parse(raw) else { throw Failure.notATrackLink }

        let draft: Draft
        switch link {
        case .spotifyTrack(let id):   draft = try await spotifyDraft(id: id)
        case .youTubeVideo(let id):   draft = try await youTubeDraft(id: id)
        }

        let online = OnlineTrack(
            title:      draft.title,
            artistName: draft.artistName,
            albumTitle: draft.albumTitle,
            duration:   draft.duration,
            artworkURL: draft.artworkURL,
            sourceID:   draft.sourceID,
            isExplicit: draft.isExplicit
        )

        // Already here? Answer without downloading anything — pasting a link
        // twice is common, and the second paste shouldn't cost a resolve.
        if let existing = library.track(id: online.stableTrackID) {
            return Outcome(track: existing, alreadySaved: true)
        }

        let audio: ResolvedAudio
        do {
            audio = try await fetchAudio(for: online, pinnedVideoID: draft.pinnedVideoID)
        } catch {
            throw Failure.resolveFailed(error.localizedDescription)
        }

        // The runtime on the file beats the runtime on the card: Spotify's is
        // right for the master and not necessarily for the upload we got, and a
        // YouTube link comes with no runtime at all.
        let duration = await Self.duration(of: audio.fileURL) ?? draft.duration

        let result = await importService.importOnlineTrack(
            from:        audio.fileURL,
            id:          online.stableTrackID,
            title:       online.title,
            artistName:  online.artistName,
            albumTitle:  online.albumTitle,
            duration:    duration,
            artworkURL:  online.artworkURL,
            isExplicit:  online.isExplicit
        )

        switch result {
        case .imported(let track, _):  return Outcome(track: track, alreadySaved: false)
        // A hash match means this audio is already in the library under another
        // song's row — the honest answer is "you have this", not "saved".
        case .duplicate(let track):    return Outcome(track: track, alreadySaved: true)
        case .failed(_, let error):    throw Failure.importFailed(error.localizedDescription)
        }
    }

    // MARK: - Spotify

    private func spotifyDraft(id: String) async throws -> Draft {
        do {
            let track = try await spotify.fetchTrack(id)
            return Draft(title:      track.title,
                         artistName: track.artistName,
                         albumTitle: track.albumTitle,
                         duration:   track.duration,
                         artworkURL: track.artworkURL,
                         isExplicit: track.isExplicit,
                         sourceID:   nil,
                         pinnedVideoID: nil)
        } catch let error as SpotifyPlaylistError {
            // `SpotifyPlaylistError` words itself for playlists, because that's
            // what it was written for. Re-say it for a song rather than telling
            // someone who pasted a track link to check their playlist is public.
            switch error {
            case .invalidLink:       throw Failure.notATrackLink
            case .notFoundOrPrivate: throw Failure.lookupFailed("Spotify doesn't have a song at that link.")
            case .network:           throw Failure.lookupFailed("Couldn't reach Spotify. Check your connection and try again.")
            // Already worded for a single lookup rather than a playlist.
            case .rateLimited:       throw Failure.lookupFailed(error.localizedDescription)
            // Can't happen on a read, but the compiler is right to ask.
            case .writeNotPermitted, .tokenExpired, .imageTooLarge:
                throw Failure.lookupFailed(error.localizedDescription)
            }
        } catch {
            throw Failure.lookupFailed(error.localizedDescription)
        }
    }

    // MARK: - YouTube

    private func youTubeDraft(id: String) async throws -> Draft {
        let embed = try await Self.oEmbed(videoID: id)
        let named = Self.splitTitle(embed.title, uploader: embed.authorName)

        var draft = Draft(title:      named.title,
                          artistName: named.artist,
                          albumTitle: "",
                          duration:   0,
                          artworkURL: embed.thumbnailURL,
                          isExplicit: false,
                          sourceID:   nil,
                          pinnedVideoID: id)

        // A YouTube upload has no album and its cover is a video thumbnail with
        // a face and a title card on it. If the catalogue recognises the song,
        // take its metadata — the audio still comes from the pinned video, so
        // this only changes what the row says, never what it plays.
        if let match = await catalogueMatch(title: named.title, artist: named.artist) {
            draft.title      = match.trackName
            draft.artistName = match.artistName
            draft.albumTitle = match.collectionName ?? ""
            draft.artworkURL = match.artworkUrl100.flatMap { catalogue.artworkURL(from: $0) }
                ?? draft.artworkURL
            draft.isExplicit = match.isExplicit
            draft.sourceID   = match.sourceID
        }
        return draft
    }

    /// The catalogue entry for this song, or nil if nothing came back that we're
    /// confident is the same song. Deliberately strict: a wrong match renames
    /// the user's song and files it under someone else's album, which is worse
    /// than no album at all.
    private func catalogueMatch(title: String, artist: String) async -> ITunesTrackResult? {
        let results = await catalogue.searchPopular(query: "\(artist) \(title)", limit: 8)
        let wantTitle  = Self.normalised(title)
        let wantArtist = Self.normalised(artist)
        guard !wantTitle.isEmpty else { return nil }

        return results.first { hit in
            let hitTitle  = Self.normalised(hit.trackName)
            let hitArtist = Self.normalised(hit.artistName)
            guard hitTitle == wantTitle || hitTitle.hasPrefix(wantTitle) || wantTitle.hasPrefix(hitTitle)
            else { return false }
            // The artist has to line up too, but only loosely: YouTube says
            // "Santan Dave" where the catalogue says "Dave", and a featured
            // artist shows up on one side and not the other.
            return hitArtist.contains(wantArtist) || wantArtist.contains(hitArtist)
        }
    }

    // MARK: - Audio

    private func fetchAudio(for online: OnlineTrack, pinnedVideoID: String?) async throws -> ResolvedAudio {
        let dir = OnlinePlaybackCoordinator.cacheDir
        if let pinnedVideoID {
            return try await resolver.download(videoID: pinnedVideoID,
                                               fallbackQuery: online.searchQuery,
                                               name: online.cacheStem,
                                               to: dir)
        }
        return try await resolver.download(query: online.searchQuery,
                                           name: online.cacheStem,
                                           to: dir,
                                           expectedDuration: online.duration,
                                           preferExplicit: online.isExplicit)
    }

    private static func duration(of url: URL) async -> TimeInterval? {
        guard let value = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(value)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // MARK: - oEmbed

    private struct OEmbed {
        let title: String
        let authorName: String
        let thumbnailURL: URL?
    }

    /// YouTube's public oEmbed endpoint: no key, no quota, no yt-dlp — which is
    /// what makes this work on iOS as well, where there is no subprocess to
    /// shell out to. It gives the video title and the channel and nothing else,
    /// hence the tidy-up and the catalogue lookup that follow.
    private static func oEmbed(videoID: String) async throws -> OEmbed {
        struct Response: Decodable {
            let title: String
            let author_name: String?
            let thumbnail_url: String?
        }
        // The watch URL is a *value* inside another URL's query, so every
        // reserved character in it has to go. Neither `.urlQueryAllowed` nor
        // `URLComponents.queryItems` escapes `?` — both produced
        // `…oembed?url=…/watch?v=<id>&format=json`, two query strings spliced
        // together. YouTube forgives that today; unreserved-only doesn't ask it to.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let target = "https://www.youtube.com/watch?v=\(videoID)"
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")
        else { throw Failure.lookupFailed("") }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // oEmbed 401s/404s for private, deleted, and age-restricted videos —
            // all of which mean the same thing to the user.
            guard status == 200 else {
                throw Failure.lookupFailed("That video isn't available — it may be private or removed.")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return OEmbed(title: decoded.title,
                          authorName: decoded.author_name ?? "",
                          thumbnailURL: decoded.thumbnail_url.flatMap(URL.init(string:)))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.lookupFailed(error.localizedDescription)
        }
    }

    // MARK: - Title tidy-up

    /// Bracketed suffixes that describe the *upload* rather than the song.
    /// Matched on the lowercased contents, so "(Official Video)" and
    /// "[OFFICIAL AUDIO]" go the same way.
    private static let uploadNoise: Set<String> = [
        "official video", "official music video", "official audio", "official lyric video",
        "official visualizer", "official visualiser", "official", "music video", "lyric video",
        "lyrics", "audio", "visualizer", "visualiser", "hd", "hq", "4k", "explicit", "clean",
    ]

    /// Split a YouTube title into artist and song.
    ///
    /// Two shapes cover nearly everything: auto-generated "- Topic" channels,
    /// where the title is already just the song and the channel is already just
    /// the artist; and everything else, where uploaders write "Artist - Title".
    /// When neither applies the channel is the best guess at the artist, which
    /// is wrong for compilation channels — and visibly wrong, so it's fixable in
    /// Get Info rather than quietly wrong.
    static func splitTitle(_ raw: String, uploader: String) -> (artist: String, title: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = uploader.trimmingCharacters(in: .whitespacesAndNewlines)

        if channel.lowercased().hasSuffix("- topic") {
            let artist = String(channel.dropLast("- topic".count)).trimmingCharacters(in: .whitespaces)
            return (artist.isEmpty ? channel : artist, cleaned(title))
        }
        // " - " with spaces, or the en/em dashes uploaders use instead. Split at
        // the first one: "Artist - Song - Live" is an artist and a song, not two
        // artists.
        for separator in [" - ", " – ", " — ", " ‒ "] {
            if let range = title.range(of: separator) {
                let artist = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let song   = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !song.isEmpty { return (artist, cleaned(song)) }
            }
        }
        return (channel.isEmpty ? "Unknown Artist" : channel, cleaned(title))
    }

    /// Drop the "(Official Video)" furniture.
    ///
    /// Every bracketed group is judged on its contents, wherever it sits:
    /// "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"
    /// and "SICKO MODE (Official Video) ft. Drake" both put the furniture in
    /// the middle, and an earlier trailing-only version left it there. What
    /// protects "(feat. Central Cee)" and "(Remix)" was never their position —
    /// it's that they aren't on the list.
    static func cleaned(_ title: String) -> String {
        var out = ""
        var opener: Character?
        var inner = ""

        for ch in title {
            if let open = opener {
                guard ch == (open == "(" ? ")" : "]") else { inner.append(ch); continue }
                if !uploadNoise.contains(inner.trimmingCharacters(in: .whitespaces).lowercased()) {
                    out.append(open); out += inner; out.append(ch)
                }
                opener = nil
                inner = ""
            } else if ch == "(" || ch == "[" {
                opener = ch
            } else {
                out.append(ch)
            }
        }
        // A group that never closed is a stray bracket in someone's title, not
        // furniture — put it back rather than swallowing the rest of the line.
        if let open = opener { out.append(open); out += inner }

        // Removing a group from the middle leaves a double space behind it.
        let squeezed = out.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return squeezed.isEmpty ? title : squeezed
    }

    /// Case-, accent- and punctuation-insensitive form used to compare a YouTube
    /// title against a catalogue one.
    private static func normalised(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
