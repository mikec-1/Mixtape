// MusicLink.swift
// Mixtape — Core/Services/Online
//
// Turns a pasted string into "which song does this point at".
//
// Pure and platform-free, and deliberately generous about what it accepts: a
// link arrives by whatever route the user shared it, so it can carry an `?si=`
// tracking suffix, a `&list=` playlist, an `intl-de` locale segment, or a
// sentence wrapped around it ("this one 🔥 https://…"). None of that changes
// which song is meant, so none of it is a reason to refuse.
//
// What it will *not* do is guess. An id has to be the right shape — 11 URL-safe
// characters for YouTube, 22 base-62 for Spotify — because the alternative is
// resolving a plausible-looking mistake into someone else's song.

import Foundation

public enum MusicLink: Equatable, Sendable {

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

    /// True when `raw` contains something worth trying. Used to enable the
    /// button without doing the parse twice.
    public static func looksLikeLink(_ raw: String) -> Bool { parse(raw) != nil }

    /// The Spotify id in `raw`, in any of its forms — for callers that already
    /// know they have a track link and just want the id.
    ///
    /// "Any form" includes a bare id, which `parse` deliberately refuses: on a
    /// pasted string a naked 22-character word is far more likely to be junk
    /// than a track, but a caller that has already been handed an id is not
    /// guessing. Leaving that out was a real bug — `LinkImportService` parses
    /// the link, then passes the extracted id to `SpotifyClient.fetchTrack`,
    /// which re-parsed it and got nil back, so *every* Spotify link failed.
    public static func spotifyTrackID(fromAnyForm raw: String) -> String? {
        if case .spotifyTrack(let id)? = parse(raw) { return id }
        return base62ID(raw.trimmingCharacters(in: .whitespacesAndNewlines), length: 22)
    }

    // MARK: - Tokenising

    /// The parts of `raw` that could be a link, longest-shot last: the whole
    /// trimmed string first (the overwhelmingly common paste), then each
    /// whitespace-separated word, so a link buried in a shared message still
    /// resolves.
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
        // spotify:track:<id> — the URI form, copied by the desktop app.
        if let range = token.range(of: "track:") {
            return base62ID(String(token[range.upperBound...]), length: 22)
        }
        guard let url = url(from: token),
              let host = url.host?.lowercased(),
              host == "spotify.com" || host.hasSuffix(".spotify.com") else { return nil }
        // /track/<id>, but also /intl-de/track/<id> and /embed/track/<id> — so
        // find the segment *after* "track" rather than assuming a position.
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "track"), index + 1 < parts.count else { return nil }
        return base62ID(parts[index + 1], length: 22)
    }

    /// Spotify ids are exactly 22 base-62 characters. Anything shorter is a
    /// truncated paste and anything longer has query junk still attached.
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
        // youtu.be/<id> — the whole path is the id.
        if isShort {
            return videoID(url.path.split(separator: "/").first.map(String.init) ?? "")
        }
        // The watch page carries it in ?v=; everything else (shorts, embeds,
        // live, the old /v/) puts it in the path directly after the kind.
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

    /// `URL(string:)` accepts almost anything, including bare words, so this
    /// also insists on a scheme — a token has to look like a link before it can
    /// be one. Schemeless `open.spotify.com/track/…` still gets a chance,
    /// because that's what a browser address bar hands you.
    private static func url(from token: String) -> URL? {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”‘’(),."))
        if let url = URL(string: cleaned), url.scheme != nil, url.host != nil { return url }
        guard cleaned.contains("."), !cleaned.contains(" ") else { return nil }
        return URL(string: "https://\(cleaned)")
    }
}
