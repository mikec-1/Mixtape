// LyricsService.swift
// Mixtape — Core/Services
//
// Resolves lyrics for a Track, in priority order:
//   1. Track.lyrics (embedded tags)
//   2. A `.lrc` sidecar file next to the local audio file
//   3. The public LRCLIB API (https://lrclib.net) — no API key required
//
// Synced (timestamped) LRC lyrics are parsed into timed lines; plain lyrics
// are exposed as a fallback. Results are cached per track id. All network
// failures are handled silently (resolve() returns a result with nil lyrics).

import Foundation
import Combine

// MARK: - Models

/// A single timestamped lyric line.
public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let time: TimeInterval
    public let text: String
}

/// Resolved lyrics for a track. Any field may be nil/empty.
public struct TrackLyrics: Equatable, Sendable {
    /// Timestamped lines, sorted ascending. Empty when no synced lyrics exist.
    public var synced: [LyricLine]
    /// Plain (untimed) lyrics text, if available.
    public var plain: String?

    public var hasSynced: Bool { !synced.isEmpty }
    public var hasAny: Bool { hasSynced || (plain?.isEmpty == false) }

    public static let empty = TrackLyrics(synced: [], plain: nil)
}

// MARK: - Service

@MainActor
public final class LyricsService: ObservableObject {

    public static let shared = LyricsService()

    /// Cache keyed by track id. Stored value of `.empty` means "looked, found nothing".
    @Published public private(set) var cache: [UUID: TrackLyrics] = [:]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns cached lyrics only when a real hit exists (synchronous, non-fetching).
    /// A cached miss returns nil so callers fall through to `resolve` and retry.
    public func cached(for track: Track) -> TrackLyrics? {
        guard let hit = cache[track.id], hit.hasAny else { return nil }
        return hit
    }

    /// Resolves lyrics for a track, using cache when available. Never throws.
    /// Returns `nil` only conceptually — callers get a `TrackLyrics` whose
    /// `hasAny` is false when nothing was found.
    @discardableResult
    public func resolve(for track: Track) async -> TrackLyrics {
        // Only short-circuit on a cached *hit*. A cached miss is kept for the
        // synchronous `cached(for:)` path but is re-attempted here, so a transient
        // network/metadata failure on first play doesn't permanently mark a track
        // as "no lyrics".
        if let hit = cache[track.id], hit.hasAny { return hit }

        let result = await load(for: track)
        cache[track.id] = result
        return result
    }

    // MARK: - Resolution pipeline

    private func load(for track: Track) async -> TrackLyrics {
        // 1. Embedded lyrics on the track.
        if let embedded = track.lyrics, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.parse(embedded)
        }

        // 2. .lrc sidecar next to the local file.
        if let sidecar = Self.readSidecar(for: track) {
            let parsed = Self.parse(sidecar)
            if parsed.hasAny { return parsed }
        }

        // 3. Remote fetch from LRCLIB (silent on failure).
        if let remote = await fetchRemote(for: track) {
            return remote
        }

        return .empty
    }

    // MARK: - Sidecar

    private static func readSidecar(for track: Track) -> String? {
        let audioURL = track.file.localURL
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lrcURL.path) else { return nil }
        return try? String(contentsOf: lrcURL, encoding: .utf8)
    }

    // MARK: - Remote (LRCLIB)

    private struct LRCLibResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    /// Tries the exact `/api/get` first, then the fuzzy `/api/search` as a fallback.
    /// `/api/get` requires a close metadata match (incl. duration); local files with
    /// mistagged albums or off-by-a-bit durations miss it, so search recovers them.
    private func fetchRemote(for track: Track) async -> TrackLyrics? {
        if let exact = await fetchExact(for: track) {
            return exact
        }
        return await fetchViaSearch(for: track)
    }

    private func fetchExact(for track: Track) async -> TrackLyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistName)
        ]
        // Only constrain on album/duration when we actually have them — sending
        // empty/zero values makes the exact match needlessly strict.
        if !track.albumTitle.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.albumTitle))
        }
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        guard let decoded: LRCLibResponse = await getJSON(url) else {
            print("[Lyrics] get miss for \"\(track.title)\" — \(track.artistName)")
            return nil
        }
        return Self.lyrics(from: decoded)
    }

    private func fetchViaSearch(for track: Track) async -> TrackLyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistName)
        ]
        guard let url = components?.url else { return nil }

        guard let results: [LRCLibResponse] = await getJSON(url), !results.isEmpty else {
            print("[Lyrics] search miss for \"\(track.title)\" — \(track.artistName)")
            return nil
        }

        // Prefer a result that has synced lyrics and is closest in duration.
        let ranked = results.sorted { a, b in
            let aSynced = (a.syncedLyrics?.isEmpty == false)
            let bSynced = (b.syncedLyrics?.isEmpty == false)
            if aSynced != bSynced { return aSynced }
            let aDelta = abs((a.duration ?? .greatestFiniteMagnitude) - track.duration)
            let bDelta = abs((b.duration ?? .greatestFiniteMagnitude) - track.duration)
            return aDelta < bDelta
        }
        for candidate in ranked {
            if let lyrics = Self.lyrics(from: candidate), lyrics.hasAny {
                print("[Lyrics] search hit for \"\(track.title)\" (synced: \(lyrics.hasSynced))")
                return lyrics
            }
        }
        return nil
    }

    /// Shared GET → JSON decode with the LRCLIB-requested User-Agent. Returns nil on
    /// any non-200 / transport / decode failure (silent, graceful).
    private func getJSON<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mixtape/1.0 (https://github.com/mikec-1/Mixtape)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[Lyrics] request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds TrackLyrics from a decoded LRCLIB record (synced preferred).
    private static func lyrics(from decoded: LRCLibResponse) -> TrackLyrics? {
        if let synced = decoded.syncedLyrics, !synced.isEmpty {
            let parsed = parse(synced)
            if parsed.hasSynced {
                return TrackLyrics(synced: parsed.synced, plain: decoded.plainLyrics ?? parsed.plain)
            }
        }
        if let plain = decoded.plainLyrics, !plain.isEmpty {
            return TrackLyrics(synced: [], plain: plain)
        }
        return nil
    }

    // MARK: - LRC Parsing

    /// Parses an LRC string into TrackLyrics. If no `[mm:ss.xx]` timestamps are
    /// found the whole text is returned as plain lyrics.
    static func parse(_ raw: String) -> TrackLyrics {
        var lines: [LyricLine] = []
        var plainBuffer: [String] = []
        var sawTimestamp = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let (stamps, text) = parseLRCLine(line)

            if stamps.isEmpty {
                // Non-timed line — could be metadata tag like [ar:...] or plain text.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !isMetadataTag(trimmed) {
                    plainBuffer.append(trimmed)
                }
            } else {
                sawTimestamp = true
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                for t in stamps {
                    lines.append(LyricLine(time: t, text: cleaned))
                }
                if !cleaned.isEmpty { plainBuffer.append(cleaned) }
            }
        }

        if sawTimestamp {
            lines.sort { $0.time < $1.time }
            let plain = plainBuffer.isEmpty ? nil : plainBuffer.joined(separator: "\n")
            return TrackLyrics(synced: lines, plain: plain)
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return TrackLyrics(synced: [], plain: trimmed.isEmpty ? nil : trimmed)
        }
    }

    /// Returns all timestamps on an LRC line plus the trailing text.
    /// Supports multiple leading timestamps, e.g. `[00:12.00][00:48.30]Text`.
    private static func parseLRCLine(_ line: String) -> (stamps: [TimeInterval], text: String) {
        var stamps: [TimeInterval] = []
        var rest = Substring(line)

        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            if let time = parseTimestamp(String(inner)) {
                stamps.append(time)
                rest = rest[rest.index(after: close)...]
            } else {
                // Bracketed but not a timestamp (metadata tag) — stop scanning.
                break
            }
        }
        return (stamps, String(rest))
    }

    /// Parses `mm:ss.xx` / `mm:ss.xxx` / `mm:ss` into seconds. Returns nil for tags.
    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]) else { return nil }
        let secPart = parts[1]
        guard let seconds = Double(secPart) else { return nil }
        return minutes * 60 + seconds
    }

    private static func isMetadataTag(_ line: String) -> Bool {
        // e.g. [ar:Artist] [ti:Title] [al:Album] [length:...] [by:...]
        guard line.hasPrefix("[") && line.hasSuffix("]") else { return false }
        return line.contains(":") && parseTimestamp(String(line.dropFirst().dropLast())) == nil
    }
}
