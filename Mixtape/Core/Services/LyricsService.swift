// LyricsService.swift
// Mixtape — Core/Services
//
// Resolves lyrics for a Track, in priority order:
//   1. Track.lyrics (embedded tags)
//   2. A `.lrc` sidecar file next to the local audio file
//   3. The public LRCLIB API (https://lrclib.net) — no API key required
//   4. NetEase Cloud Music (music.163.com) — fallback for synced lyrics LRCLIB
//      lacks; no API key, just needs a Referer/User-Agent header
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

    /// In-flight fetches keyed by track id, so a prefetch (fired when a song is
    /// tapped) and the later view-appear `resolve` coalesce into a single network
    /// fetch instead of racing two.
    private var inFlight: [UUID: Task<TrackLyrics, Never>] = [:]

    private let session: URLSession

    /// Default session for lyric lookups. Uses an ephemeral, cookie-less config so
    /// providers (notably NetEase) can't pin a guest-session cookie that flips the
    /// search endpoint into returning rotating "recommended" feeds instead of real
    /// search results. Behaves like a fresh `curl` on every request.
    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()
    }

    /// Drop all cached lyrics so the next resolve refetches (and can re-attempt
    /// finding synced lyrics for a track previously found with plain-only text).
    public func clearCache() { cache.removeAll() }

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
        // Short-circuit only when we already have synced lyrics. A plain-only or
        // empty cached result is re-attempted so a track can later pick up synced
        // (interactive) lyrics instead of staying stuck on the plain text block.
        if let hit = cache[track.id], hit.hasSynced { return hit }

        return await fetchTask(for: track).value
    }

    /// Starts resolving lyrics for `track` the moment it's chosen (song tap), so
    /// they're cached by the time the Now Playing screen opens. Best-effort and
    /// non-blocking: never affects playback. Coalesces with a concurrent `resolve`
    /// for the same track id so only one network fetch runs.
    public func prefetch(for track: Track) {
        if let hit = cache[track.id], hit.hasSynced { return }
        _ = fetchTask(for: track)
    }

    /// Returns the in-flight fetch for `track`, starting one if none is running.
    /// The task writes its result into `cache` and clears itself from `inFlight`
    /// on completion, so prefetch + view-appear resolve share a single fetch.
    private func fetchTask(for track: Track) -> Task<TrackLyrics, Never> {
        if let existing = inFlight[track.id] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { return TrackLyrics.empty }
            let result = await self.load(for: track)
            self.cache[track.id] = result
            self.inFlight[track.id] = nil
            return result
        }
        inFlight[track.id] = task
        return task
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
        // LRCLIB and NetEase are independent providers, so fetch from both
        // *concurrently* rather than only consulting NetEase after LRCLIB has
        // fully resolved. NetEase's network work (search + candidate downloads)
        // doesn't depend on LRCLIB — only the final re-skin needs LRCLIB's plain
        // text, and that's a cheap local step. Running them in parallel makes the
        // worst case `max(LRCLIB, NetEase)` instead of their sum.
        async let lrclibTask = fetchLRCLib(for: track)
        async let neteaseTask = fetchNetEaseCandidates(for: track)

        let (exact, searched) = await lrclibTask

        // LRCLIB synced wins outright — return immediately (the NetEase task is
        // cancelled as this scope exits, so we don't wait on it).
        if let exact, exact.hasSynced { return exact }
        if let searched, searched.hasSynced { return searched }

        // LRCLIB had no real synced lyrics. Use NetEase's timeline, re-skinned
        // with the best accurate plain text LRCLIB *did* return so NetEase's
        // (often wrong/masked) transcription is corrected.
        let accuratePlain = (searched?.plain) ?? (exact?.plain)
        let candidates = await neteaseTask
        if let netease = Self.selectNetEase(from: candidates, accuratePlain: accuratePlain),
           netease.hasSynced {
            return netease
        }

        // No provider has synced lyrics. Fall back to the best plain text we
        // found, preferring LRCLIB (exact → search) then NetEase.
        // Order: LRCLIB synced → NetEase synced → LRCLIB plain → NetEase plain.
        return exact ?? searched ?? candidates.first.map(Self.collapseEchoes)
    }

    /// Runs the LRCLIB lookup chain (exact → exact-without-duration → fuzzy
    /// search). Returns the exact record and, when it lacks synced lyrics, the
    /// best search result. Skips the search entirely once exact has synced lyrics.
    private func fetchLRCLib(for track: Track) async -> (exact: TrackLyrics?, searched: TrackLyrics?) {
        // Strict exact match (album + duration), then a looser one without
        // duration (iTunes/Deezer durations are often a couple seconds off).
        var exact = await fetchExact(for: track, includeDuration: true)
        if exact == nil, track.duration > 0 {
            exact = await fetchExact(for: track, includeDuration: false)
        }
        if let exact, exact.hasSynced { return (exact, nil) }

        // Exact is plain-only or missing: a *different* LRCLIB upload of the same
        // song often carries synced lyrics, so the fuzzy search recovers it.
        let searched = await fetchViaSearch(for: track)
        return (exact, searched)
    }

    private func fetchExact(for track: Track, includeDuration: Bool) async -> TrackLyrics? {
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
        if includeDuration, track.duration > 0 {
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

    // MARK: - Remote (NetEase Cloud Music — synced fallback)

    private static let neteaseReferer = "https://music.163.com"

    /// NetEase returns a different (junk) result set for non-browser User-Agents,
    /// so its requests must look like a normal browser.
    private static let neteaseUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// NetEase's synced timestamps consistently run ~1s ahead of the audio, so
    /// each line is pushed back by this many seconds to line up with playback.
    private static let neteaseTimingOffset: TimeInterval = 1.0

    private struct NetEaseSearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                let id: Int
                let name: String?
                let artists: [Artist]?
                /// Track length in milliseconds.
                let duration: Int?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    private struct NetEaseLyricResponse: Decodable {
        struct Lyric: Decodable { let lyric: String? }
        let lrc: Lyric?
    }

    /// Fallback provider: searches NetEase for the closest match (title + artist +
    /// duration) and fetches its timestamped LRC. Returns nil on any failure.
    /// Searches NetEase for the track and downloads the LRC of the top matches
    /// **concurrently**, returning the cleaned synced candidates in rank order
    /// (closest duration first). The four downloads previously ran sequentially —
    /// the single biggest contributor to slow lyric loads — so they're now issued
    /// in parallel. Selection (re-skin / uncensored preference) happens later in
    /// `selectNetEase`, once LRCLIB's plain text is available.
    private func fetchNetEaseCandidates(for track: Track) async -> [TrackLyrics] {
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "s", value: "\(track.title) \(track.artistName)")
        ]
        guard let url = components?.url else { return [] }

        guard let decoded: NetEaseSearchResponse = await getJSON(url, referer: Self.neteaseReferer, userAgent: Self.neteaseUserAgent),
              let songs = decoded.result?.songs, !songs.isEmpty else {
            print("[Lyrics] netease search miss for \"\(track.title)\" — \(track.artistName)")
            return []
        }

        // Keep only records that are genuinely the same song. The artist MUST
        // match — NetEase's search sometimes returns unrelated tracks (a different
        // song that shares the title, or, when rate-limited/degraded, a single
        // random song that merely has a similar length). Duration alone is far too
        // weak to identify a song, so it's only a sanity check on top of the artist
        // match, never a way to qualify a non-matching artist. When NetEase returns
        // junk, nothing matches and we correctly fall back to LRCLIB's plain text.
        let wantArtist = track.artistName.lowercased()
        let matches = songs.filter { song in
            let artistOK = (song.artists ?? []).contains {
                let name = ($0.name ?? "").lowercased()
                return !name.isEmpty && (name.contains(wantArtist) || wantArtist.contains(name))
            }
            guard artistOK else { return false }
            guard track.duration > 0, let ms = song.duration else { return true }
            return abs((Double(ms) / 1000) - track.duration) <= 20
        }
        guard !matches.isEmpty else { return [] }

        // Rank the surviving matches by duration closeness.
        // NetEase duration is in milliseconds; track.duration is in seconds.
        let ranked = matches.sorted { a, b in
            let aDelta = abs((Double(a.duration ?? 0) / 1000) - track.duration)
            let bDelta = abs((Double(b.duration ?? 0) / 1000) - track.duration)
            return aDelta < bDelta
        }

        // Download the top candidates' LRC concurrently, preserving rank order.
        let ids = ranked.prefix(4).map { $0.id }
        let slots: [TrackLyrics?] = await withTaskGroup(of: (Int, TrackLyrics?).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask { (i, await self.fetchNetEaseLyric(songID: id)) }
            }
            var result = [TrackLyrics?](repeating: nil, count: ids.count)
            for await (i, lyrics) in group { result[i] = lyrics }
            return result
        }
        return slots.compactMap { $0 }.filter { $0.hasSynced }
    }

    /// Picks the best NetEase candidate. When accurate LRCLIB plain text is
    /// available, each candidate's timeline is re-skinned with it (fixing
    /// transcription errors and censorship) and the closest-aligned one wins.
    /// Otherwise it prefers an uncensored record, then any synced record.
    private static func selectNetEase(from candidates: [TrackLyrics], accuratePlain: String?) -> TrackLyrics? {
        guard !candidates.isEmpty else { return nil }
        let plainLines = accuratePlain.map { plainLyricLines($0) } ?? []

        var bestReskinned: (lyrics: TrackLyrics, score: Double)?
        var uncensored: TrackLyrics?
        for lyrics in candidates {
            if !plainLines.isEmpty, let (reskinned, score) = reskin(lyrics, with: plainLines) {
                if score > (bestReskinned?.score ?? -1) { bestReskinned = (reskinned, score) }
            }
            if uncensored == nil, !isCensored(lyrics) { uncensored = lyrics }
        }

        // A strongly-aligned re-skin is the best possible outcome: accurate,
        // uncensored words on NetEase's timestamps.
        if let best = bestReskinned, best.score >= reskinAcceptScore {
            print("[Lyrics] netease hit (LRCLIB-reskinned, overlap \(String(format: "%.2f", best.score)))")
            return collapseEchoes(best.lyrics)
        }
        if let uncensored {
            print("[Lyrics] netease hit (uncensored)")
            return collapseEchoes(uncensored)
        }
        print("[Lyrics] netease hit (censored fallback, synced)")
        return collapseEchoes(candidates[0])
    }

    /// Collapses adjacent synced lines where one is essentially a fragment/echo
    /// of the other — NetEase often lists background-vocal echoes as their own
    /// timestamped line (e.g. the full bar followed by just its tail), which the
    /// re-skin can't always merge because only one side matches LRCLIB. We detect
    /// these by containment: when the shorter line's tokens are almost entirely
    /// present in the adjacent longer line, the shorter is a duplicate and is
    /// dropped, keeping the more complete text on the earlier timestamp.
    private static func collapseEchoes(_ lyrics: TrackLyrics) -> TrackLyrics {
        let synced = lyrics.synced
        guard synced.count > 1 else { return lyrics }

        var kept: [LyricLine] = []
        for line in synced {
            let nTokens = tokens(line.text)
            if nTokens.isEmpty { kept.append(line); continue }
            if let prev = kept.last, !prev.text.isEmpty {
                let pTokens = tokens(prev.text)
                if !pTokens.isEmpty {
                    let inter = Set(nTokens).intersection(Set(pTokens)).count
                    let containment = Double(inter) / Double(min(nTokens.count, pTokens.count))
                    if containment >= 0.8 {
                        // Echo: keep the more complete line on the earlier timestamp.
                        if nTokens.count > pTokens.count {
                            kept[kept.count - 1] = LyricLine(time: prev.time, text: line.text)
                        }
                        continue
                    }
                }
            }
            kept.append(line)
        }
        guard kept.count != synced.count else { return lyrics }
        return TrackLyrics(synced: kept, plain: lyrics.plain)
    }

    /// Minimum mean token-overlap (0…1) between NetEase lines and their aligned
    /// LRCLIB plain lines required to trust a re-skin. Below this the
    /// correspondence is too weak and we keep NetEase's original text.
    private static let reskinAcceptScore = 0.55

    /// Splits accurate plain lyrics into comparable lines, dropping blanks and
    /// section headers like "[Intro]" / "[Verse 1]" / "(Chorus)" that LRCLIB
    /// includes but NetEase's synced timeline does not.
    private static func plainLyricLines(_ plain: String) -> [String] {
        plain.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if isCreditLine(line) { return false }
                // Section header: whole line wrapped in [] or () (e.g. "[Verse 1]").
                if (line.hasPrefix("[") && line.hasSuffix("]")) ||
                   (line.hasPrefix("(") && line.hasSuffix(")")) { return false }
                return true
            }
    }

    /// Normalises a lyric line to a set of comparison tokens (lowercased,
    /// punctuation stripped) for overlap scoring and alignment.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    /// A single ground-truth word from LRCLIB: its comparison tokens plus the
    /// original spelling/punctuation/casing used for display.
    private struct PlainWord {
        let tokens: Set<String>
        let display: String
    }

    /// Re-skins NetEase's synced timeline with LRCLIB's accurate words at the
    /// **word** level. Returns the re-skinned lyrics plus the mean alignment score
    /// across substituted lines, or nil when the two clearly don't correspond.
    ///
    /// Why word-level: NetEase splits the song into more, finer lines than LRCLIB
    /// (e.g. NetEase's "You not 'bout to squeeze" + "You not in the streets" is a
    /// single LRCLIB line). A one-line→one-line match leaves the extra NetEase
    /// line stuck with its own (wrong/censored) text. Instead we flatten LRCLIB
    /// into an ordered word stream and let each NetEase timestamp consume the span
    /// of accurate words that best matches it, so one LRCLIB line can split across
    /// several NetEase timestamps and vice-versa.
    private static func reskin(_ netease: TrackLyrics, with plainLines: [String]) -> (TrackLyrics, Double)? {
        let synced = netease.synced
        guard !synced.isEmpty, !plainLines.isEmpty else { return nil }

        // Flatten LRCLIB into an ordered ground-truth word stream.
        var words: [PlainWord] = []
        for line in plainLines {
            for w in line.split(separator: " ") {
                let t = Set(tokens(String(w)))
                if !t.isEmpty { words.append(PlainWord(tokens: t, display: String(w))) }
            }
        }
        guard !words.isEmpty else { return nil }

        // Jaccard overlap between a NetEase line's tokens and the span of plain
        // words [start, start+len).
        func spanScore(_ lineTokens: Set<String>, _ start: Int, _ len: Int) -> Double {
            guard start < words.count, len > 0 else { return 0 }
            var span = Set<String>()
            for i in start..<min(start + len, words.count) { span.formUnion(words[i].tokens) }
            guard !span.isEmpty else { return 0 }
            let inter = lineTokens.intersection(span).count
            return Double(inter) / Double(lineTokens.union(span).count)
        }

        // Best (score, start, len) for a line over starts in [lo, hi] and spans
        // sized around the line's own word count. Ties keep the earliest/shortest.
        func bestMatch(_ lineTokens: Set<String>, wordCount n: Int, lo: Int, hi: Int) -> (Double, Int, Int) {
            var best = (-1.0, lo, n)
            let upper = min(hi, words.count - 1)
            guard lo <= upper else { return best }
            for s in lo...upper {
                for len in max(1, n - 1)...(n + 2) {
                    let sc = spanScore(lineTokens, s, len)
                    if sc > best.0 { best = (sc, s, len) }
                }
            }
            return best
        }

        var newLines: [LyricLine] = []
        var cursor = 0
        var scoreSum = 0.0
        var scoreCount = 0

        for line in synced {
            let lineTokens = Set(tokens(line.text))
            // Empty NetEase line (spacer) — keep as-is, don't consume any words.
            if lineTokens.isEmpty { newLines.append(line); continue }

            let n = max(1, line.text.split(separator: " ").count)
            var (score, start, len) = bestMatch(lineTokens, wordCount: n, lo: cursor, hi: cursor + 2)

            // Resync after junk blocks (LRCLIB sometimes embeds Genius's "You
            // might also like" + related-song titles mid-lyrics): when the local
            // window is weak, scan farther ahead for where the stream realigns.
            if score < 0.5 {
                let (rScore, rStart, rLen) = bestMatch(lineTokens, wordCount: n, lo: cursor + 3, hi: cursor + 25)
                if rScore >= 0.55, rScore > score { (score, start, len) = (rScore, rStart, rLen) }
            }

            if score >= 0.34, start < words.count {
                let end = min(start + len, words.count)
                let text = words[start..<end].map(\.display).joined(separator: " ")
                newLines.append(LyricLine(time: line.time, text: text))
                cursor = end
                scoreSum += score
                scoreCount += 1
            } else {
                // No confident match: keep NetEase's text, hold the word cursor.
                newLines.append(line)
            }
        }

        guard scoreCount > 0 else { return nil }
        let mean = scoreSum / Double(scoreCount)
        let result = TrackLyrics(synced: newLines, plain: netease.plain)
        return result.hasSynced ? (result, mean) : nil
    }

    /// True if any line looks masked (e.g. "f****in'") — NetEase's censorship.
    private static func isCensored(_ lyrics: TrackLyrics) -> Bool {
        lyrics.synced.contains { $0.text.contains("**") }
            || (lyrics.plain?.contains("**") ?? false)
    }

    private func fetchNetEaseLyric(songID: Int) async -> TrackLyrics? {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components?.url else { return nil }
        guard let decoded: NetEaseLyricResponse = await getJSON(url, referer: Self.neteaseReferer, userAgent: Self.neteaseUserAgent),
              let raw = decoded.lrc?.lyric, !raw.isEmpty else { return nil }
        return Self.cleanNetEase(Self.parse(raw))
    }

    /// Post-processes a parsed NetEase LRC: drops the CJK credit lines
    /// ("作词 : …", "作曲 : …", etc.) and shifts timestamps to match playback.
    private static func cleanNetEase(_ lyrics: TrackLyrics) -> TrackLyrics? {
        let synced = lyrics.synced
            .filter { !isCreditLine($0.text) }
            .map { LyricLine(time: max(0, $0.time + neteaseTimingOffset), text: $0.text) }
        let plain = lyrics.plain?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isCreditLine(String($0)) }
            .joined(separator: "\n")
        let result = TrackLyrics(synced: synced, plain: (plain?.isEmpty == false) ? plain : nil)
        return result.hasAny ? result : nil
    }

    /// A NetEase credit line carries CJK text plus a colon, e.g. "作词 : Name".
    /// Real (English) lyric lines have no CJK, so this leaves them untouched.
    private static func isCreditLine(_ text: String) -> Bool {
        let hasColon = text.contains(":") || text.contains("：")
        guard hasColon else { return false }
        return text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// Shared GET → JSON decode with the LRCLIB-requested User-Agent. Returns nil on
    /// any non-200 / transport / decode failure (silent, graceful).
    private func getJSON<T: Decodable>(_ url: URL, referer: String? = nil, userAgent: String? = nil) async -> T? {
        var request = URLRequest(url: url)
        request.setValue(
            userAgent ?? "Mixtape/1.0 (https://github.com/mikec-1/Mixtape)",
            forHTTPHeaderField: "User-Agent"
        )
        // NetEase's endpoints reject requests without a matching Referer.
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        // Always hit the network: URLSession.shared's cache can otherwise replay a
        // stale/edge-cached search response (NetEase's CDN sometimes serves generic
        // trending songs for the search path), which produced wrong-song results.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Lyrics are a nice-to-have shown live during playback — a request that
        // hasn't answered in a few seconds is better abandoned than left to stall
        // the whole pipeline. Providers that are up respond well under this.
        request.timeoutInterval = 6
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
