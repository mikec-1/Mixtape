// Resolves lyrics for a Track, in priority order:
// 0. Lyrics the user supplied (`UserLyricsStore`), always wins
// 1. Track.lyrics (embedded tags)
// 2. A `.lrc` sidecar next to the local file
// 3. Apple word-timed TTML
// 4. LRCLIB (https://lrclib.net), no API key
// 5. NetEase (music.163.com), fallback for synced lyrics LRCLIB lacks
// Results are cached per track id. Network failures are silent.

import Foundation
import Combine
import OSLog

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
    /// Real per-word timings (Apple TTML). Nil for LRC, where `LyricSync.words(for:)` estimates them.
    public var words: [LyricWord]? = nil
}

/// Resolved lyrics for a track. Any field may be nil/empty.
public struct TrackLyrics: Equatable, Sendable {
    /// Timestamped lines, sorted ascending. Empty when no synced lyrics exist.
    public var synced: [LyricLine]
    /// Plain (untimed) lyrics text, if available.
    public var plain: String?
    /// From `UserLyricsStore`. The UI offers Edit/Remove, and `resolve` won't refetch over it.
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

    /// In-flight fetches by track id, so prefetch and resolve share one request.
    private var inFlight: [UUID: Task<TrackLyrics, Never>] = [:]

    private let session: URLSession

    /// Ephemeral, cookie-less session. A NetEase guest cookie turns search into "recommended" feeds.
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

    /// Drops the cache so the next resolve refetches (and can find synced lyrics).
    public func clearCache() { cache.removeAll() }

    // MARK: - The user's own lyrics

    /// Reads the store, not the cache, so it's right before the track has been resolved.
    public func hasUserLyrics(for track: Track) -> Bool {
        UserLyricsStore.shared.contains(track)
    }

    /// The raw text behind `hasUserLyrics`, for the editor to open onto.
    public func userLyricsText(for track: Track) -> String? {
        UserLyricsStore.shared.text(for: track)
    }

    /// Saves `text` as this song's lyrics and writes it straight into the cache.
    /// Empty text removes the override, see `UserLyricsStore.set`.
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
        // Otherwise a pending fetch would land over what the user just typed.
        inFlight[track.id]?.cancel()
        inFlight[track.id] = nil
        cache[track.id] = parsed
        return parsed
    }

    /// Drops the user's lyrics so the next resolve goes back through tags, sidecar and lookups.
    public func removeUserLyrics(for track: Track) {
        UserLyricsStore.shared.remove(for: track)
        inFlight[track.id]?.cancel()
        inFlight[track.id] = nil
        cache[track.id] = nil
    }

    /// Cached lyrics only on a real hit. A cached miss returns nil so callers go to `resolve`.
    public func cached(for track: Track) -> TrackLyrics? {
        guard let hit = cache[track.id], hit.hasAny else { return nil }
        return hit
    }

    /// Resolves lyrics, using the cache when it has synced lyrics. Never throws; `hasAny` is false on a miss.
    @discardableResult
    public func resolve(for track: Track) async -> TrackLyrics {
        // Only synced or user lyrics short-circuit. Misses and plain-only results are retried so
        // a track can pick up synced lyrics later.
        if let hit = cache[track.id], hit.hasSynced || hit.isUserProvided { return hit }

        return await fetchTask(for: track).value
    }

    /// Starts resolving on song tap so lyrics are cached by the time Now Playing opens.
    /// Shares the fetch with a concurrent `resolve`.
    public func prefetch(for track: Track) {
        if let hit = cache[track.id], hit.hasSynced || hit.isUserProvided { return }
        _ = fetchTask(for: track)
    }

    /// Returns the in-flight fetch for `track`, starting one if needed.
    private func fetchTask(for track: Track) -> Task<TrackLyrics, Never> {
        if let existing = inFlight[track.id] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { return TrackLyrics.empty }
            let result = await self.load(for: track)
            // `load` never checks cancellation, so a fetch started before the user saved lyrics
            // is dropped here instead of overwriting them.
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
        // 0. The user's own lyrics, ahead of tags so the override always wins.
        MixLog.lyrics.debug("resolving \"\(track.title)\", \(track.artistName) (album: \(track.albumTitle), \(Int(track.duration))s)")
        if let own = UserLyricsStore.shared.text(for: track) {
            var parsed = Self.parse(own)
            parsed.isUserProvided = true
            if parsed.hasAny { return parsed }
        }

        // An edit sings the original's words, faster or slower, trimmed or rearranged.
        if let edit = track.edit {
            let original = Self.original(of: track, edit: edit)
            var lyrics: TrackLyrics
            if let hit = cache[original.id], hit.hasAny { lyrics = hit } else { lyrics = await load(for: original) }
            lyrics.synced = lyrics.synced.flatMap { line in
                edit.times(of: line.time).map { at in
                    let move = { (t: Double) in at + (t - line.time) / edit.speed }
                    return LyricLine(time: at, text: line.text,
                                     words: line.words?.map { LyricWord(time: move($0.time), end: move($0.end), text: $0.text) })
                }
            }.sorted { $0.time < $1.time }
            return lyrics
        }

        // 1. Embedded lyrics on the track.
        if let embedded = track.lyrics, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MixLog.lyrics.debug("source: embedded tags")
            return Self.parse(embedded)
        }

        // 2. .lrc sidecar next to the local file.
        if let sidecar = Self.readSidecar(for: track) {
            let parsed = Self.parse(sidecar)
            if parsed.hasAny { MixLog.lyrics.debug("source: .lrc sidecar"); return parsed }
        }

        // 3. Word-timed TTML, ahead of LRCLIB since every word has its own timing.
        if let wordTimed = await fetchWordTimed(for: track) {
            MixLog.lyrics.debug("source: TTML (word-timed)")
            return wordTimed
        }

        // 4. Remote fetch from LRCLIB (silent on failure).
        if let remote = await fetchRemote(for: track) {
            MixLog.lyrics.debug("source: LRCLIB/NetEase")
            return remote
        }

        return .empty
    }

    /// The original's title, artist and length from an edit's recipe, under the original's id so its cached
    /// lyrics are reused. Only for lookups; it has no file.
    private static func original(of track: Track, edit: SongEdit) -> Track {
        let title = edit.sourceRef.split(separator: "|", maxSplits: 1).first.map(String.init) ?? track.title
        return Track(id: edit.of, title: title, artistName: track.artistName, albumTitle: track.albumTitle,
                     // A cut edit's length says nothing about the original's; zero skips the length check.
                     duration: edit.sections == nil ? track.duration * edit.speed : 0, sync: SyncMetadata(deviceID: ""),
                     file: FileProvenance(fileHash: "", fileSize: 0, localPath: ""))
    }

    // MARK: - Word-timed (Apple TTML)

    /// Apple Music TTML index. Same source as the web client (`src/pages/api/lyrics.ts`).
    private static let ttmlIndex = "https://lyrics-api.binimum.org/"

    private struct TTMLIndexResponse: Decodable {
        struct Entry: Decodable {
            let lyricsUrl: String?
            let timingType: String?
            let duration: Double?
            /// The index matches on name, so this catches a remix answered with the original.
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

        // Only word timing is worth it here; a line-timed hit would skip LRCLIB and NetEase.
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

    /// Parses Apple's word-timed TTML (one `<p>` per line, one `<span>` per word).
    /// Background vocals (`ttm:role="x-bg"`) are dropped.
    static func parseTTML(_ xml: String) -> TrackLyrics {
        let delegate = TTMLParserDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return .empty }
        let lines = delegate.lines.sorted { $0.time < $1.time }
        return TrackLyrics(synced: lines, plain: lines.map(\.text).joined(separator: "\n"))
    }

    /// `12.5`, `1:00.216` or `1:02:03.4` -> seconds.
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

    /// LRCLIB and NetEase run concurrently, then the best result is picked.
    private func fetchRemote(for track: Track) async -> TrackLyrics? {
        // Both providers run in parallel. Only the final re-skin needs LRCLIB's plain text.
        async let lrclibTask = fetchLRCLib(for: track)
        async let neteaseTask = fetchNetEaseCandidates(for: track)

        let (exact, searched) = await lrclibTask

        // LRCLIB synced wins; the NetEase task is cancelled on scope exit.
        if let exact, exact.hasSynced { return exact }
        if let searched, searched.hasSynced { return searched }

        // No LRCLIB synced: use NetEase's timeline re-skinned with LRCLIB's plain text.
        let accuratePlain = (searched?.plain) ?? (exact?.plain)
        let candidates = await neteaseTask
        if let netease = Self.selectNetEase(from: candidates, accuratePlain: accuratePlain),
           netease.hasSynced {
            return netease
        }

        // No synced lyrics anywhere: LRCLIB plain, then NetEase plain.
        return exact ?? searched ?? candidates.first.map(Self.collapseEchoes)
    }

    /// Runs the LRCLIB chain (exact, exact without duration, search) and picks the record
    /// most uploads agree on. Metadata alone isn't enough: a correctly labelled record can
    /// carry another song's words.
    private func fetchLRCLib(for track: Track) async -> (exact: TrackLyrics?, searched: TrackLyrics?) {
        // iTunes/Deezer durations are often a couple of seconds off, so retry without duration.
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

    /// The record most uploads agree with, then the best copy in that group (synced, then closest duration).
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
            MixLog.lyrics.debug("consensus overruled the exact match (\(group.value.count) uploads vs \(groups[exactPrint]?.count ?? 0))")
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

    /// First few lines of text with timestamps and punctuation stripped, so uploads of the same words match.
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
        // Empty album or zero duration makes the exact match needlessly strict.
        if !track.albumTitle.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.albumTitle))
        }
        if includeDuration, track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        guard let decoded: LRCLibResponse = await getJSON(url) else {
            MixLog.lyrics.debug("get miss for \"\(track.title)\", \(track.artistName)")
            return nil
        }
        guard Self.isSameSong(decoded, as: track) else {
            MixLog.lyrics.debug("get returned \"\(decoded.trackName ?? "?")\", \(decoded.artistName ?? "?"); rejected")
            return nil
        }
        return decoded
    }

    /// Titles compared without punctuation or bracketed suffixes like `(feat. ...)` or `- Remaster`.
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
            MixLog.lyrics.debug("search miss for \"\(track.title)\", \(track.artistName)")
            return []
        }

        // Artist and title must match; duration is only a sanity check on top.
        return results.filter { r in
            guard Self.isSameSong(r, as: track) else { return false }
            guard track.duration > 0, let d = r.duration else { return true }
            return abs(d - track.duration) <= 20
        }
    }

    // MARK: - Remote (NetEase, synced fallback)

    private static let neteaseReferer = "https://music.163.com"

    /// NetEase returns junk results for non-browser User-Agents.
    private static let neteaseUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// NetEase timestamps run about 1s ahead of the audio.
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

    /// Searches NetEase and downloads the top matches' LRC in parallel. Returns synced
    /// candidates, closest duration first. `selectNetEase` picks one later.
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
            MixLog.lyrics.debug("netease search miss for \"\(track.title)\", \(track.artistName)")
            return []
        }

        // Artist must match: NetEase search can return unrelated songs with the same title or
        // a similar length. Duration is only a sanity check.
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

        // NetEase duration is in ms, track.duration in seconds.
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

    /// Picks the best NetEase candidate. With LRCLIB plain text, each is re-skinned and the
    /// best-aligned wins. Otherwise uncensored first, then any synced.
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
            MixLog.lyrics.debug("netease hit (LRCLIB-reskinned, overlap \(String(format: "%.2f", best.score)))")
            return collapseEchoes(best.lyrics)
        }
        if let uncensored {
            MixLog.lyrics.debug("netease hit (uncensored)")
            return collapseEchoes(uncensored)
        }
        MixLog.lyrics.debug("netease hit (censored fallback, synced)")
        return collapseEchoes(candidates[0])
    }

    /// Drops adjacent synced lines that are an echo of their neighbour (NetEase lists
    /// background vocals as separate lines). Keeps the fuller text on the earlier timestamp.
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

    /// Minimum mean token overlap (0...1) to trust a re-skin.
    private static let reskinAcceptScore = 0.55

    /// Plain lyric lines without blanks and section headers ("[Intro]", "(Chorus)").
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

    /// Lowercased, punctuation-stripped tokens for overlap scoring.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    /// One LRCLIB word: comparison tokens plus its original spelling for display.
    private struct PlainWord {
        let tokens: Set<String>
        let display: String
    }

    /// Re-skins NetEase's timeline with LRCLIB's words at the word level. Returns the lyrics
    /// and mean alignment score, or nil when they don't correspond.
    /// Word-level because NetEase splits lines finer than LRCLIB: each timestamp takes the
    /// span of words that best matches it.
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

        // Jaccard overlap between a line's tokens and plain words [start, start+len).
        func spanScore(_ lineTokens: Set<String>, _ start: Int, _ len: Int) -> Double {
            guard start < words.count, len > 0 else { return 0 }
            var span = Set<String>()
            for i in start..<min(start + len, words.count) { span.formUnion(words[i].tokens) }
            guard !span.isEmpty else { return 0 }
            let inter = lineTokens.intersection(span).count
            return Double(inter) / Double(lineTokens.union(span).count)
        }

        // Best (score, start, len) over starts in [lo, hi]. Ties keep the earliest/shortest.
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
            // Spacer line, keep it without consuming words.
            if lineTokens.isEmpty { newLines.append(line); continue }

            let n = max(1, line.text.split(separator: " ").count)
            var (score, start, len) = bestMatch(lineTokens, wordCount: n, lo: cursor, hi: cursor + 2)

            // LRCLIB sometimes embeds Genius junk mid-lyrics, so on a weak match scan further ahead.
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

    /// True if any line looks masked ("f****in'").
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

    /// Drops NetEase's CJK credit lines and shifts timestamps to match playback.
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

    /// GET + JSON decode. Nil on any non-200, transport or decode failure.
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
        // NetEase's CDN sometimes caches a trending-songs response for search.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Lyrics are shown live, so a slow request is abandoned rather than stalling the pipeline.
        request.timeoutInterval = 6
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            MixLog.lyrics.error("request failed: \(error.localizedDescription)")
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
            MixLog.lyrics.error("request failed: \(error.localizedDescription)")
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

    /// Parses LRC. Without `[mm:ss.xx]` stamps the whole text is plain lyrics.
    static func parse(_ raw: String) -> TrackLyrics {
        var lines: [LyricLine] = []
        var plainBuffer: [String] = []
        var sawTimestamp = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let (stamps, text) = parseLRCLine(line)

            if stamps.isEmpty {
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

    /// All timestamps on a line plus the text, e.g. `[00:12.00][00:48.30]Text`.
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
                // Metadata tag, not a timestamp.
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

/// Parses Apple's word-timed TTML. Spans with no whitespace between them are one word
/// split up ("ba" "byyy"), so a new word starts only after a space.
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
                // Continuation of the previous word, merged into one timed span.
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
