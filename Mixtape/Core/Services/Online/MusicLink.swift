// Parses a pasted string into a song link. Tolerates tracking params, locale
// segments and surrounding text. Ids must be the right shape (11 chars for
// YouTube, 22 base-62 for Spotify) rather than guessed.

import Foundation

public nonisolated enum MusicLink: Equatable, Sendable {

    /// `https://open.spotify.com/track/<id>` or `spotify:track:<id>`.
    case spotifyTrack(id: String)

    /// A single YouTube / YouTube Music video, however it was linked.
    case youTubeVideo(id: String)

    /// The best interpretation of `raw`, or nil if it isn't a track link.
    public static func parse(_ raw: String) -> MusicLink? {
        for candidate in tokens(in: raw) {
            if let id = spotifyTrackID(candidate) { return .spotifyTrack(id: id) }
            if let id = youTubeVideoID(candidate) { return .youTubeVideo(id: id) }
        }
        return nil
    }

    /// Cheap check for enabling the button.
    public static func looksLikeLink(_ raw: String) -> Bool { parse(raw) != nil }

    /// The Spotify id in any form, including a bare id, which parse refuses.
    public static func spotifyTrackID(fromAnyForm raw: String) -> String? {
        if case .spotifyTrack(let id)? = parse(raw) { return id }
        return base62ID(raw.trimmingCharacters(in: .whitespacesAndNewlines), length: 22)
    }

    // MARK: - Tokenising

    /// The whole string first, then each word.
    private static func tokens(in raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out = [trimmed]
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 { out += words }
        return out
    }

    // MARK: - Spotify

    private static func spotifyTrackID(_ token: String) -> String? {
        // URI form.
        if let range = token.range(of: "track:") {
            return base62ID(String(token[range.upperBound...]), length: 22)
        }
        guard let url = url(from: token),
              let host = url.host?.lowercased(),
              host == "spotify.com" || host.hasSuffix(".spotify.com") else { return nil }
        // Find the segment after "track", since locale and embed paths shift it.
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "track"), index + 1 < parts.count else { return nil }
        return base62ID(parts[index + 1], length: 22)
    }

    /// Exactly 22 base-62 chars.
    private static func base62ID(_ raw: String, length: Int) -> String? {
        let id = raw.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return id.count == length ? String(id) : nil
    }

    // MARK: - YouTube

    private static func youTubeVideoID(_ token: String) -> String? {
        guard let url = url(from: token),
              let host = url.host?.lowercased() else { return nil }

        let isShort = host == "youtu.be"
        let isLong  = host == "youtube.com" || host.hasSuffix(".youtube.com")
        guard isShort || isLong else { return nil }

        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // youtu.be: the path is the id.
        if isShort {
            return videoID(url.path.split(separator: "/").first.map(String.init) ?? "")
        }
        // ?v= on watch pages, otherwise the path segment after the kind.
        if let v = parts?.queryItems?.first(where: { $0.name == "v" })?.value,
           let id = videoID(v) {
            return id
        }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count >= 2,
              ["shorts", "embed", "live", "v"].contains(segments[0]) else { return nil }
        return videoID(segments[1])
    }

    /// YouTube ids are 11 characters of `[A-Za-z0-9_-]`.
    private static func videoID(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard raw.count == 11,
              raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    // MARK: - Shared

    /// Requires a scheme, except schemeless open.spotify.com.
    private static func url(from token: String) -> URL? {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”‘’(),."))
        if let url = URL(string: cleaned), url.scheme != nil, url.host != nil { return url }
        guard cleaned.contains("."), !cleaned.contains(" ") else { return nil }
        return URL(string: "https://\(cleaned)")
    }
}
