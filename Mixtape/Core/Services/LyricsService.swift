// LyricsService.swift
// Mixtape — Core/Services
//
// Resolves lyrics for a Track, in priority order:
//   0. Lyrics the user supplied themselves (`UserLyricsStore`) — always wins
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

/// One word of a line, with the span of time it is sung over.
public struct LyricWord: Equatable, Sendable {
    public let time: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(time: TimeInterval, end: TimeInterval, text: String) {
        self.time = time
        self.end = end
        self.text = text
    }
}

/// A single timestamped lyric line.
public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let time: TimeInterval
    public let text: String
    /// Real per-word timings, when the source carried them (Apple's word-timed
    /// TTML). Nil for LRC sources, which only stamp the start of a line — see
    /// `LyricSync.words(for:)`, which estimates spans for those.
    public var words: [LyricWord]? = nil
}

/// Resolved lyrics for a track. Any field may be nil/empty.
public struct TrackLyrics: Equatable, Sendable {
    /// Timestamped lines, sorted ascending. Empty when no synced lyrics exist.
    public var synced: [LyricLine]
    /// Plain (untimed) lyrics text, if available.
    public var plain: String?
    /// True when this came from `UserLyricsStore` — the user's own text rather
    /// than a tag or a lookup. Carried on the result because it changes what
    /// the UI offers (Edit and Remove instead of nothing) and because it stops
    /// `resolve` from going back to the network to "improve" on it.
    public var isUserProvided: Bool = false

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

    // MARK: - The user's own lyrics

    /// True when this song's lyrics were supplied by the user.
    ///
    /// Reads the store rather than the cache, so it's right before the track
    /// has ever been resolved — the Now Playing panel asks this to decide
    /// between "Add lyrics" and "Edit lyrics" the moment it appears.
    public func hasUserLyrics(for track: Track) -> Bool {
        UserLyricsStore.shared.contains(track)
    }

    /// The raw text behind `hasUserLyrics`, for the editor to open onto.
    public func userLyricsText(for track: Track) -> String? {
        UserLyricsStore.shared.text(for: track)
    }

    /// Saves `text` as this song's lyrics and shows them immediately.
    ///
    /// The cache is written straight through instead of being invalidated: a
    /// plain invalidate would leave the panel empty until the next resolve,
    /// and that resolve would race the network for a song whose lyrics are now
    /// sitting on disk. Empty text removes the override — see `UserLyricsStore.set`.
    @discardableResult
    public func saveUserLyrics(_ text: String, for track: Track) -> TrackLyrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeUserLyrics(for: track)
            return .empty
        }

        UserLyricsStore.shared.set(trimmed, for: track)

        var parsed = Self.parse(trimmed)
        parsed.isUserProvided = true
        // Any fetch still in flight would otherwise land after this and write
        // the looked-up result over the one the user just typed.
        inFlight[track.id]?.cancel()
        inFlight[track.id] = nil
        cache[track.id] = parsed
        return parsed
    }

    /// Drops the user's lyrics for this song and forgets the cached result, so
    /// the next resolve goes back through tags, sidecar and the databases.
    public func removeUserLyrics(for track: Track) {
        UserLyricsStore.shared.remove(for: track)
        inFlight[track.id]?.cancel()
        inFlight[track.id] = nil
        cache[track.id] = nil
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
        // Short-circuit only when we already have synced lyrics. A plain-only or
        // empty cached result is re-attempted so a track can later pick up synced
        // (interactive) lyrics instead of staying stuck on the plain text block.
        // The user's own lyrics are the answer, synced or not. Refetching to
        // look for a synced version would replace what they typed with what a
        // database guessed — the exact thing they overrode.
        if let hit = cache[track.id], hit.hasSynced || hit.isUserProvided { return hit }

        return await fetchTask(for: track).value
    }

    /// Starts resolving lyrics for `track` the moment it's chosen (song tap), so
    /// they're cached by the time the Now Playing screen opens. Best-effort and
    /// non-blocking: never affects playback. Coalesces with a concurrent `resolve`
    /// for the same track id so only one network fetch runs.
    public func prefetch(for track: Track) {
        if let hit = cache[track.id], hit.hasSynced || hit.isUserProvided { return }
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
            // A fetch started before the user saved their own lyrics must not
            // land on top of them. `Task.cancel` alone can't prevent this —
            // nothing in `load` checks for cancellation — so the decision is
            // made here, where the write actually happens.
            if let own = self.cache[track.id], own.isUserProvided {
                self.inFlight[track.id] = nil
                return own
            }
            self.cache[track.id] = result
            self.inFlight[track.id] = nil
            return result
        }
        inFlight[track.id] = task
        return task
    }

    // MARK: - Resolution pipeline

    private func load(for track: Track) async -> TrackLyrics {
        // 0. The user's own lyrics. Ahead of the embedded tags on purpose: a
        // file whose tags carry the wrong words is one of the reasons someone
        // reaches for this, and an override that loses to the thing it was
        // meant to override isn't an override.
        print("[Lyrics] resolving \"\(track.title)\" — \(track.artistName) (album: \(track.albumTitle), \(Int(track.duration))s)")
        if let own = UserLyricsStore.shared.text(for: track) {
            var parsed = Self.parse(own)
            parsed.isUserProvided = true
            if parsed.hasAny { return parsed }
        }

        // 1. Embedded lyrics on the track.
        if let embedded = track.lyrics, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("[Lyrics] source: embedded tags")
            return Self.parse(embedded)
        }

        // 2. .lrc sidecar next to the local file.
        if let sidecar = Self.readSidecar(for: track) {
            let parsed = Self.parse(sidecar)
            if parsed.hasAny { print("[Lyrics] source: .lrc sidecar"); return parsed }
        }

        // 3. Word-timed lyrics (Apple's TTML). Ahead of LRCLIB because it is a
        // strictly better document when it exists: every word carries its own
        // start and end, so a held note holds. Falls through when the song
        // isn't in the index or is only line-timed.
        if let wordTimed = await fetchWordTimed(for: track) {
            print("[Lyrics] source: TTML (word-timed)")
            return wordTimed
        }

        // 4. Remote fetch from LRCLIB (silent on failure).
        if let remote = await fetchRemote(for: track) {
            print("[Lyrics] source: LRCLIB/NetEase")
            return remote
        }

        return .empty
    }

    // MARK: - Word-timed (Apple TTML)

    /// The index that maps a song to an Apple Music TTML document. Same source
    /// the web client uses (`src/pages/api/lyrics.ts`), so all three platforms
    /// show the same words with the same timings.
    private static let ttmlIndex = "https://lyrics-api.binimum.org/"

    private struct TTMLIndexResponse: Decodable {
        struct Entry: Decodable {
            let lyricsUrl: String?
            let timingType: String?
            let duration: Double?
            /// The index matches on name, so it answers a remix query with the
            /// original. Optional because not every record carries it.
            let name: String?

            enum CodingKeys: String, CodingKey {
                case lyricsUrl
                case timingType = "timing_type"
                case duration
                case name
            }
        }
        let results: [Entry]?
    }

    private func fetchWordTimed(for track: Track) async -> TrackLyrics? {
        guard !track.title.isEmpty, !track.artistName.isEmpty else { return nil }
        var components = URLComponents(string: Self.ttmlIndex)
        components?.queryItems = [
            URLQueryItem(name: "track", value: track.title),
            URLQueryItem(name: "artist", value: track.artistName)
        ]
        guard let url = components?.url,
              let index: TTMLIndexResponse = await getJSON(url) else { return nil }

        // Only word timing is worth taking this path for — a line-timed hit is
        // no better than LRCLIB and would skip the providers below.
        let hit = (index.results ?? []).first { entry in
            guard entry.timingType == "word", entry.lyricsUrl != nil else { return false }
            if let name = entry.name, !name.isEmpty,
               !LyricVersion.sameVersion(track.title, name) { return false }
            guard track.duration > 0, let duration = entry.duration else { return true }
            return abs(duration - track.duration) <= 20
        }
        guard let urlString = hit?.lyricsUrl, let documentURL = URL(string: urlString),
              let xml = await getText(documentURL) else { return nil }

        let parsed = Self.parseTTML(xml)
        return parsed.hasSynced ? parsed : nil
    }

    /// Parses Apple's word-timed TTML: one `<p>` per line, one `<span>` per
    /// word. Background-vocal subtrees (`ttm:role="x-bg"`) are dropped — they
    /// are a second voice printed alongside the line, and the app draws one.
    static func parseTTML(_ xml: String) -> TrackLyrics {
        let delegate = TTMLParserDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return .empty }
        let lines = delegate.lines.sorted { $0.time < $1.time }
        return TrackLyrics(synced: lines, plain: lines.map(\.text).joined(separator: "\n"))
    }

    /// `12.5`, `1:00.216` or `1:02:03.4` → seconds.
    static func parseTTMLTime(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        var total: TimeInterval = 0
        for part in trimmed.split(separator: ":") {
            guard let value = TimeInterval(part) else { return nil }
            total = total * 60 + value
        }
        return total
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
        let trackName: String?
        let artistName: String?
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
    /// search) and picks the record the uploads *agree* on.
    ///
    /// Metadata gates aren't enough on their own: LRCLIB's record for VULTURES 1
    /// "DO IT" is labelled correctly — right title, right artist, right album,
    /// right duration — and carries the words to "NEW BODY". Nothing about that
    /// record looks wrong, so the only thing that catches it is the other
    /// uploads of the same song: fifteen of them start "Do it stay waxed" and
    /// five start "Oh my God, Ronny". The majority wins.
    private func fetchLRCLib(for track: Track) async -> (exact: TrackLyrics?, searched: TrackLyrics?) {
        // Strict exact match (album + duration), then a looser one without
        // duration (iTunes/Deezer durations are often a couple seconds off).
        var exact = await fetchExact(for: track, includeDuration: true)
        if exact == nil, track.duration > 0 {
            exact = await fetchExact(for: track, includeDuration: false)
        }
        let searched = await searchCandidates(for: track)

        let pool = [exact].compactMap { $0 } + searched
        guard let winner = Self.consensus(among: pool, preferring: exact, track: track),
              let lyrics = Self.lyrics(from: winner), lyrics.hasAny else {
            return (exact.flatMap(Self.lyrics(from:)), nil)
        }
        return (lyrics, nil)
    }

    /// The record the most uploads agree with, then the best copy inside that
    /// group (synced first, closest duration next). `nil` when the pool is empty.
    private static func consensus(among pool: [LRCLibResponse],
                                  preferring exact: LRCLibResponse?,
                                  track: Track) -> LRCLibResponse? {
        let groups = Dictionary(grouping: pool.filter { !fingerprint($0).isEmpty },
                                by: { fingerprint($0) })
        guard !groups.isEmpty else { return pool.first }

        let exactPrint = exact.map(fingerprint)
        let best = groups.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            // A tie goes to the record LRCLIB itself called the exact match.
            return b.key == exactPrint
        }
        guard let group = best else { return pool.first }
        if let exactPrint, group.key != exactPrint {
            print("[Lyrics] consensus overruled the exact match (\(group.value.count) uploads vs \(groups[exactPrint]?.count ?? 0))")
        }
        return group.value.sorted { a, b in
            let aSynced = (a.syncedLyrics?.isEmpty == false)
            let bSynced = (b.syncedLyrics?.isEmpty == false)
            if aSynced != bSynced { return aSynced }
            let aDelta = abs((a.duration ?? .greatestFiniteMagnitude) - track.duration)
            let bDelta = abs((b.duration ?? .greatestFiniteMagnitude) - track.duration)
            return aDelta < bDelta
        }.first
    }

    /// What a record *says*, with nothing about who uploaded it: the first few
    /// lines of text, timestamps and punctuation stripped. Two uploads of the
    /// same words fingerprint the same however differently they were timed.
    private static func fingerprint(_ r: LRCLibResponse) -> String {
        let raw = (r.syncedLyrics?.isEmpty == false ? r.syncedLyrics : r.plainLyrics) ?? ""
        let lines = raw.split(separator: "\n").compactMap { line -> String? in
            let text = line.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "",
                                                 options: .regularExpression)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return lines.prefix(3).joined(separator: " ")
    }

    private func fetchExact(for track: Track, includeDuration: Bool) async -> LRCLibResponse? {
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
        guard Self.isSameSong(decoded, as: track) else {
            print("[Lyrics] get returned \"\(decoded.trackName ?? "?")\" — \(decoded.artistName ?? "?"); rejected")
            return nil
        }
        return decoded
    }

    /// Does this LRCLIB record name the song we asked for? Titles are compared
    /// after stripping punctuation and any bracketed suffix (`(feat. …)`,
    /// `- Remaster`), since every uploader spells those differently.
    private static func isSameSong(_ r: LRCLibResponse, as track: Track) -> Bool {
        let want = bareTitle(track.title)
        let got  = bareTitle(r.trackName ?? "")
        guard !got.isEmpty, got.contains(want) || want.contains(got) else { return false }
        guard LyricVersion.sameVersion(track.title, r.trackName ?? "") else { return false }
        let wantArtist = bareTitle(track.artistName)
        let gotArtist  = bareTitle(r.artistName ?? "")
        guard !gotArtist.isEmpty else { return false }
        return gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist)
            || !Set(gotArtist.split(separator: " ")).isDisjoint(with: Set(wantArtist.split(separator: " ")))
    }

    private static func bareTitle(_ s: String) -> String {
        var t = s.lowercased()
        if let cut = t.firstIndex(where: { "([-".contains($0) }) { t = String(t[t.startIndex..<cut]) }
        return t.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Every search result that is plausibly this song, for the consensus vote.
    private func searchCandidates(for track: Track) async -> [LRCLibResponse] {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistName)
        ]
        guard let url = components?.url else { return [] }

        guard let results: [LRCLibResponse] = await getJSON(url), !results.isEmpty else {
            print("[Lyrics] search miss for \"\(track.title)\" — \(track.artistName)")
            return []
        }

        // The artist and title MUST match — a common title returns a page of
        // unrelated uploads and duration alone is far too weak to tell them
        // apart. Duration is only a sanity check on top of the name match.
        return results.filter { r in
            guard Self.isSameSong(r, as: track) else { return false }
            guard track.duration > 0, let d = r.duration else { return true }
            return abs(d - track.duration) <= 20
        }
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
            guard LyricVersion.sameVersion(track.title, song.name ?? "") else { return false }
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

    /// Fetches a document as text, on the same terms as `getJSON`.
    private func getText(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("Mixtape/1.0 (https://github.com/mikec-1/Mixtape)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 6
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
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

// MARK: - TTML parsing

/// Pulls timed lines and words out of Apple's word-timed TTML.
///
/// The whitespace *between* spans is meaningful: Apple splits a held word into
/// several spans with nothing between them ("ba" "byyy"), and separate words
/// with a space. Dropping that distinction glues syllables into gibberish, so
/// the text between spans is carried and a word starts a new one only when a
/// space preceded it.
private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var lines: [LyricLine] = []

    private var lineStart: TimeInterval?
    private var words: [LyricWord] = []
    private var wordStart: TimeInterval?
    private var wordEnd: TimeInterval?
    private var buffer = ""
    private var between = ""
    /// Depth of the background-vocal subtree we're inside, if any.
    private var backgroundDepth = 0

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if backgroundDepth > 0 {
            backgroundDepth += 1
            return
        }
        switch element {
        case "p":
            lineStart = LyricsService.parseTTMLTime(attributes["begin"])
            words = []
            between = ""
        case "span":
            if attributes["ttm:role"] == "x-bg" || attributes["role"] == "x-bg" {
                backgroundDepth = 1
                return
            }
            wordStart = LyricsService.parseTTMLTime(attributes["begin"])
            wordEnd = LyricsService.parseTTMLTime(attributes["end"])
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard backgroundDepth == 0 else { return }
        if wordStart != nil {
            buffer += string
        } else {
            between += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        if backgroundDepth > 0 {
            backgroundDepth -= 1
            return
        }
        switch element {
        case "span":
            defer {
                wordStart = nil
                wordEnd = nil
                between = ""
            }
            guard let start = wordStart, let end = wordEnd else { return }
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let spaced = words.isEmpty || between.contains(where: \.isWhitespace)
            if spaced {
                words.append(LyricWord(time: start, end: end, text: text))
            } else {
                // A continuation of the word before it: one word, one span of
                // time, so the sweep runs across the whole of it.
                let previous = words.removeLast()
                words.append(LyricWord(time: previous.time, end: end, text: previous.text + text))
            }
        case "p":
            defer { lineStart = nil }
            guard let start = lineStart else { return }
            let text = words.map(\.text).joined(separator: " ")
            guard !text.isEmpty else { return }
            lines.append(LyricLine(time: start, text: text, words: words))
        default:
            break
        }
    }
}
