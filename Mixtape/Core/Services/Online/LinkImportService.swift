// Imports a song from a pasted link.
// Spotify links are metadata only, so the resolver finds the audio like a Discover save.
// YouTube links pin that video; the title is tidied and checked against the catalogue.
// Both end at importOnlineTrack.

import Foundation
import AVFoundation

/// Stateless: progress and errors live in the calling sheet.
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
        /// The song was already in the library.
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
        /// YouTube only: the video to fetch instead of searching.
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

    /// Imports the song `raw` points at. Failure messages are user-facing.
    /// Liked too, unless the account sends imports to All Songs: a file holds itself.
    public func importTrack(from raw: String) async throws -> Outcome {
        let outcome = try await fetchAndImport(raw)
        if PlaylistMetadataService.shared.likesImports { library.saveToLibrary(trackID: outcome.track.id) }
        return outcome
    }

    private func fetchAndImport(_ raw: String) async throws -> Outcome {
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

        // Already here as a file, skip the download. A saved online row gets its audio instead.
        if let existing = library.track(id: online.stableTrackID), !existing.isOnline {
            return Outcome(track: existing, alreadySaved: true)
        }

        let audio: ResolvedAudio
        do {
            audio = try await fetchAudio(for: online, pinnedVideoID: draft.pinnedVideoID)
        } catch {
            throw Failure.resolveFailed(error.localizedDescription)
        }

        // The file's runtime beats the card's.
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
        // Same audio already in the library.
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
            // Reword the playlist-flavoured Spotify errors for a song.
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

        // Use catalogue metadata when found. Only the row's details change, not the audio.
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

    /// A catalogue match, or nil. Strict because a wrong match renames the song.
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
            // Loose artist match ("Santan Dave" vs "Dave").
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

    /// YouTube oEmbed: no key or yt-dlp, so it works on iOS. Title and channel only.
    private static func oEmbed(videoID: String) async throws -> OEmbed {
        struct Response: Decodable {
            let title: String
            let author_name: String?
            let thumbnail_url: String?
        }
        // The watch URL is a query value, so escape everything but unreserved chars.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let target = "https://www.youtube.com/watch?v=\(videoID)"
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")
        else { throw Failure.lookupFailed("") }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Private, deleted and age-restricted all look the same to the user.
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

    /// Bracketed upload noise, matched lowercased.
    private static let uploadNoise: Set<String> = [
        "official video", "official music video", "official audio", "official lyric video",
        "official visualizer", "official visualiser", "official", "music video", "lyric video",
        "lyrics", "audio", "visualizer", "visualiser", "hd", "hq", "4k", "explicit", "clean",
    ]

    /// Splits a YouTube title into artist and song. "- Topic" channels are already
    /// split; otherwise "Artist - Title". Falls back to the channel as the artist.
    static func splitTitle(_ raw: String, uploader: String) -> (artist: String, title: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = uploader.trimmingCharacters(in: .whitespacesAndNewlines)

        if channel.lowercased().hasSuffix("- topic") {
            let artist = String(channel.dropLast("- topic".count)).trimmingCharacters(in: .whitespaces)
            return (artist.isEmpty ? channel : artist, cleaned(title))
        }
        // Split at the first dash only.
        for separator in [" - ", " – ", " — ", " ‒ "] {
            if let range = title.range(of: separator) {
                let artist = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let song   = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !song.isEmpty { return (artist, cleaned(song)) }
            }
        }
        return (channel.isEmpty ? "Unknown Artist" : channel, cleaned(title))
    }

    /// Removes "(Official Video)"-style groups anywhere in the title. Things like
    /// "(feat. X)" and "(Remix)" stay because they aren't on the list.
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
        // Unclosed bracket: keep it.
        if let open = opener { out.append(open); out += inner }

        // Removing a group from the middle leaves a double space behind it.
        let squeezed = out.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return squeezed.isEmpty ? title : squeezed
    }

    /// For comparing YouTube and catalogue titles.
    private static func normalised(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
