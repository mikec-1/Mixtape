// Async wrapper around the bundled yt-dlp + ffmpeg (app isn't sandboxed).
// yt-dlp runs as a zipapp on a bundled CPython, which starts far faster than the
// PyInstaller build. CPython ships as python.tar.gz and is unpacked once into
// Application Support. Dev builds fall back to yt-dlp/ffmpeg on PATH or Homebrew.

// macOS only: needs Process. iOS uses RemoteResolverService.
#if os(macOS)
import Foundation
import AVFoundation

public enum YTDLPError: LocalizedError {
    case binaryMissing(String)
    case noResult
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let name):
            return "Couldn't find \(name). Run scripts/fetch-binaries.sh or `brew install yt-dlp ffmpeg`."
        case .noResult:
            return "No playable source was found for that song."
        case .processFailed(let msg):
            return msg.isEmpty ? "yt-dlp failed." : msg
        }
    }
}

/// Player clients YouTube refused for a given video. Demoted to the back of the
/// order, not banned, since a stall can look like a 403. Memory only.
private actor ClientPenaltyBox {
    static let shared = ClientPenaltyBox()

    private var demoted: [String: Set<String>] = [:]

    func demote(_ client: String, for videoID: String) {
        demoted[videoID, default: []].insert(client)
    }

    func isDemoted(_ client: String, for videoID: String) -> Bool {
        demoted[videoID]?.contains(client) ?? false
    }
}

public final class YTDLPService: TrackResolver {

    public init() {}

    /// Local downloads overlap well; capped by core count.
    public var suggestedDownloadConcurrency: Int {
        max(3, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// First client for both stream and download. `android_vr` stopped working once
    /// YouTube required PO tokens; `web_embedded` needs a JS challenge solve.
    private static let preferredClient = "web_embedded"

    /// Fallback clients in order; nil means yt-dlp's defaults. `tv_simply` only
    /// has 360p format 18, so it's a floor.
    private static let clientFallbacks: [String?] = ["tv_simply", nil]

    /// Demote the client that gave the dead URL for this video.
    public func noteStreamUnplayable(videoID: String) async {
        await ClientPenaltyBox.shared.demote(Self.preferredClient, for: videoID)
    }

    /// Old name for `ResolvedAudio`.
    public typealias DownloadResult = ResolvedAudio

    // MARK: - Public API

    /// Resolves a directly playable audio URL so AVPlayer starts on the first
    /// buffer. Throws `StreamUnavailable` when the video was found but won't stream,
    /// so callers `download` it without searching again. Bounded by a deadline so a
    /// wedged resolve can't outlast the download it's meant to beat.
    public func resolveStream(query: String,
                              expectedDuration: TimeInterval,
                              preferExplicit: Bool) async throws -> StreamResolution? {
        try await resolveStream(query: query,
                                expectedDuration: expectedDuration,
                                preferExplicit: preferExplicit,
                                excluding: [])
    }

    public func resolveStream(query: String,
                              expectedDuration: TimeInterval,
                              preferExplicit: Bool,
                              excluding: Set<String>) async throws -> StreamResolution? {
        try await resolveStream(query: query, expectedDuration: expectedDuration,
                                preferExplicit: preferExplicit, excluding: excluding,
                                pinnedVideoID: nil)
    }

    /// `pinnedVideoID` skips the search, which is most of the wait. Callers must
    /// not pin a video the user rejected (see `exclusions(for:)`).
    public func resolveStream(query: String,
                              expectedDuration: TimeInterval,
                              preferExplicit: Bool,
                              excluding: Set<String>,
                              pinnedVideoID: String?) async throws -> StreamResolution? {
        guard let inv = try? Self.ytdlpInvocation() else { return nil }
        let videoID: String
        if let pinnedVideoID, !excluding.contains(pinnedVideoID) {
            videoID = pinnedVideoID
            ResolveTrace.shared.mark("search skipped (video already known)", owner: query)
        } else {
            // Not `try?`: "no match" must propagate so the song is marked unfindable.
            videoID = try await selectBestVideo(query: query,
                                                expectedDuration: expectedDuration,
                                                preferExplicit: preferExplicit,
                                                excluding: excluding)
        }

        // This video already refused the streaming client, so go straight to download.
        if await ClientPenaltyBox.shared.isDemoted(Self.preferredClient, for: videoID) {
            ResolveTrace.shared.mark("stream skipped (client blocked for this video)", owner: query)
            throw StreamUnavailable(videoID: videoID)
        }

        let args = [
            "https://www.youtube.com/watch?v=\(videoID)",
            "-g",
            // Progressive m4a only; a DASH-only format gives a URL AVPlayer can't open.
            "-f", "bestaudio[ext=m4a]/bestaudio[protocol^=http]",
            "--no-playlist",
            "--no-warnings",
            "--extractor-args", "youtube:player_client=\(Self.preferredClient)",
        ] + Self.jsRuntimeArgs

        let extracted = try? await Self.run(executable: inv.executable,
                                            args: inv.prefix + args,
                                            timeout: Self.streamResolveTimeout)
        ResolveTrace.shared.mark("yt-dlp -g extract", owner: query)
        guard let out = extracted,
              let line = out.split(separator: "\n")
                            .map({ $0.trimmingCharacters(in: .whitespaces) })
                            .first(where: { $0.hasPrefix("http") }),
              let url = URL(string: line)
        else { throw StreamUnavailable(videoID: videoID) }

        return StreamResolution(url: url, videoID: videoID)
    }

    /// Long enough for a slow search + resolve, short enough that falling back to
    /// a full download still beats waiting out a hang.
    private static let streamResolveTimeout: TimeInterval = 10

    /// Downloads the best audio for `query`: a search pass picks the video, then
    /// it's downloaded and named by video id. Use `resolveStream` for playback only.
    public func download(query: String, name: String, to destinationDir: URL, expectedDuration: TimeInterval = 0, preferExplicit: Bool = false) async throws -> DownloadResult {
        let videoID = try await selectBestVideo(query: query, expectedDuration: expectedDuration, preferExplicit: preferExplicit)
        return try await fetchAudio(videoID: videoID, to: destinationDir, owner: query)
    }

    /// Same, with progress. Search reports a phase; `--newline` makes yt-dlp print
    /// one parseable progress line per update.
    public func download(query: String,
                         name: String,
                         to destinationDir: URL,
                         expectedDuration: TimeInterval,
                         preferExplicit: Bool,
                         onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        try await download(query: query, name: name, to: destinationDir,
                           expectedDuration: expectedDuration,
                           preferExplicit: preferExplicit,
                           excluding: [],
                           onProgress: onProgress)
    }

    public func download(query: String,
                         name: String,
                         to destinationDir: URL,
                         expectedDuration: TimeInterval,
                         preferExplicit: Bool,
                         excluding: Set<String>,
                         onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .searching, fraction: nil))
        let videoID = try await selectBestVideo(query: query,
                                                expectedDuration: expectedDuration,
                                                preferExplicit: preferExplicit,
                                                excluding: excluding)
        onProgress(ResolveProgress(phase: .downloading, fraction: 0))
        return try await fetchAudio(videoID: videoID,
                                    to: destinationDir,
                                    owner: query,
                                    onProgress: onProgress)
    }

    /// Parses a yt-dlp output line: `[download] 42.7% ...` or `[ExtractAudio]`.
    /// Everything else is ignored.
    nonisolated static func progress(fromLine line: String) -> ResolveProgress? {
        if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[Merger]") {
            return ResolveProgress(phase: .converting, fraction: nil)
        }
        guard line.hasPrefix("[download]"), let percentIndex = line.firstIndex(of: "%") else { return nil }
        // Walk back from the % over the number attached to it.
        var start = percentIndex
        while start > line.startIndex {
            let previous = line.index(before: start)
            let character = line[previous]
            guard character.isNumber || character == "." else { break }
            start = previous
        }
        guard start < percentIndex,
              let value = Double(line[start..<percentIndex]) else { return nil }
        return ResolveProgress(phase: .downloading, fraction: min(max(value / 100, 0), 1))
    }

    /// A pasted link names the video, so skip the search. `fallbackQuery` is unused here.
    public func download(videoID: String,
                         fallbackQuery: String,
                         name: String,
                         to destinationDir: URL) async throws -> ResolvedAudio {
        try await fetchAudio(videoID: videoID, to: destinationDir, owner: fallbackQuery)
    }

    /// Pinned download with progress.
    public func download(videoID: String,
                         fallbackQuery: String,
                         name: String,
                         to destinationDir: URL,
                         onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .downloading, fraction: 0))
        return try await fetchAudio(videoID: videoID, to: destinationDir,
                                    owner: fallbackQuery, onProgress: onProgress)
    }

    /// Extracts `videoID`'s audio to `<destinationDir>/<videoID>.m4a`. `owner` is
    /// for trace attribution only.
    private func fetchAudio(videoID: String, to destinationDir: URL,
                            owner: String? = nil,
                            onProgress: (@Sendable (ResolveProgress) -> Void)? = nil) async throws -> DownloadResult {
        let inv    = try Self.ytdlpInvocation()
        let ffmpeg = try Self.locate("ffmpeg")

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let template = destinationDir.appendingPathComponent("\(videoID).%(ext)s").path
        let expected = destinationDir.appendingPathComponent("\(videoID).m4a")
        let videoURL = "https://www.youtube.com/watch?v=\(videoID)"

        // Lead with `web_embedded`, then clients that need no signature solve (nil =
        // no --extractor-args). A video that refused `web_embedded` tries it last.
        var clientStrategies: [String?] = [Self.preferredClient] + Self.clientFallbacks
        if await ClientPenaltyBox.shared.isDemoted(Self.preferredClient, for: videoID) {
            clientStrategies = Self.clientFallbacks + [Self.preferredClient]
            ResolveTrace.shared.mark("client order flipped (\(Self.preferredClient) blocked here)",
                                     owner: owner)
        }
        var lastError: Error?

        for (attempt, clients) in clientStrategies.enumerated() {
            // Only the last strategy retries; earlier ones fail fast to the next client.
            let isLastResort = attempt == clientStrategies.count - 1
            var args = [
                videoURL,
                // Prefer m4a (copy), else any audio (re-encoded).
                "-f", "bestaudio[ext=m4a]/bestaudio/best",
                "-x", "--audio-format", "m4a",
                "--no-playlist",
                "--no-warnings",
                // Retry transient CDN errors, and fetch fragments in parallel since the
                // download is latency-bound.
                "--concurrent-fragments", "4",
                "--retries", isLastResort ? "3" : "1",
                "--fragment-retries", isLastResort ? "5" : "1",
                "--extractor-retries", isLastResort ? "2" : "1",
                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                "-o", template,
            ] + Self.jsRuntimeArgs
            // Progress lines only when someone is watching.
            if onProgress != nil { args += ["--newline"] }
            if let clients {
                args += ["--extractor-args", "youtube:player_client=\(clients)"]
            }

            let client = clients ?? "default"
            do {
                _ = try await Self.run(executable: inv.executable, args: inv.prefix + args,
                                       onLine: onProgress.map { report in
                                           { @Sendable line in
                                               if let step = Self.progress(fromLine: line) { report(step) }
                                           }
                                       })
                if Self.hasAudio(expected) {
                    ResolveTrace.shared.mark("download+ffmpeg [\(client)]", owner: owner)
                    return DownloadResult(fileURL: expected, videoID: videoID)
                }
                // Some clients hand back a stub format with no audio track.
                try? FileManager.default.removeItem(at: expected)
                ResolveTrace.shared.mark("download [\(client)] no audio", owner: owner)
                lastError = YTDLPError.noResult
            } catch {
                // Cancellation isn't a failure. Real failures log yt-dlp's reason.
                ResolveTrace.shared.mark(error is CancellationError
                                         ? "download [\(client)] cancelled"
                                         : "download [\(client)] FAILED: \(Self.reason(error))",
                                         owner: owner)
                lastError = error
                // Remember the refusal so the next play skips this client.
                if let clients, Self.isForbidden(error) {
                    await ClientPenaltyBox.shared.demote(clients, for: videoID)
                }
                // Only a 403 or missing format is worth another client.
                if !Self.isRetryable(error) { throw error }
            }
        }

        // Every strategy blocked: show a clear message, not yt-dlp's dump.
        if Self.isForbidden(lastError) || Self.isBotChecked(lastError) {
            throw YTDLPError.processFailed(
                "YouTube blocked this download. Try again in a moment."
            )
        }
        throw lastError ?? YTDLPError.noResult
    }

    /// The file exists and CoreAudio can read at least one frame from it.
    private static func hasAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// yt-dlp's stderr reduced to its `ERROR:` line.
    private static func reason(_ error: Error) -> String {
        guard case let .processFailed(msg) = (error as? YTDLPError) ?? .noResult else {
            return error.localizedDescription
        }
        let line = msg.split(separator: "\n")
            .last(where: { $0.contains("ERROR:") })
            ?? msg.split(separator: "\n").last(where: { !$0.isEmpty })
            ?? ""
        let text = line.replacingOccurrences(of: "ERROR: ", with: "")
                       .trimmingCharacters(in: .whitespaces)
        return text.count > 90 ? String(text.prefix(90)) + "…" : text
    }

    /// True when an error is YouTube's anti-bot 403 on the media download.
    private static func isForbidden(_ error: Error?) -> Bool {
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        let lower = msg.lowercased()
        return lower.contains("403") || lower.contains("forbidden")
    }

    /// YouTube's anti-bot wall: the extract got no formats at all.
    private static func isBotChecked(_ error: Error?) -> Bool {
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        return msg.lowercased().contains("sign in to confirm")
    }

    /// A 403 or no usable format: worth trying another client.
    private static func isRetryable(_ error: Error?) -> Bool {
        if isForbidden(error) { return true }
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        if isBotChecked(error) { return true }
        let lower = msg.lowercased()
        // A gated client reports this instead of the block.
        return lower.contains("requested format is not available")
            || lower.contains("only images are available")
    }

    /// Whether yt-dlp can run (gates the UI). Only checks the payloads exist, no
    /// Python extraction.
    public static var isAvailable: Bool {
        if bundledPythonArchive() != nil, bundledZipapp() != nil { return true }
        return (try? locate("yt-dlp")) != nil
    }

    // MARK: - Candidate selection

    /// One YouTube search hit with the metadata we score it on.
    private struct Candidate {
        let id: String
        let duration: TimeInterval   // seconds; 0 if unknown
        let channel: String
        let title: String
        let rank: Int                // original search position (0 = top hit)
    }

    /// Searches YouTube for the best song upload of `query`: prefers "- Topic"
    /// and "Audio" uploads over videos, rejects runtimes far from `expectedDuration`.
    private func selectBestVideo(query: String,
                                 expectedDuration: TimeInterval,
                                 preferExplicit: Bool = false,
                                 excluding: Set<String> = []) async throws -> String {
        // YouTube Music first: its song results are official uploads with an
        // explicit flag. Falls back to YouTube search on no match.
        let ytmID = try? await ytmusicVideoID(query: query,
                                              expectedDuration: expectedDuration,
                                              preferExplicit: preferExplicit,
                                              excluding: excluding)
        ResolveTrace.shared.mark("ytmusicapi search (hit=\(ytmID != nil))", owner: query)
        if let ytmID { return ytmID }

        let inv = try Self.ytdlpInvocation()

        // Nudge the search toward the wanted version; scoring still decides.
        let searchQuery: String
        if ResolverPreferences.preferCensored { searchQuery = "\(query) clean" }
        else if preferExplicit                { searchQuery = "\(query) explicit" }
        else                                  { searchQuery = query }

        // --flat-playlist reads the listing only, no per-video extraction.
        let args = [
            "ytsearch8:\(searchQuery)",
            "--flat-playlist",
            "--no-warnings",
            "--print", "%(id)s\t%(duration)s\t%(channel)s\t%(title)s",
        ]

        let out = try await Self.run(executable: inv.executable, args: inv.prefix + args)
        ResolveTrace.shared.mark("yt-dlp search (fallback)", owner: query)
        let candidates = out
            .split(separator: "\n")
            .enumerated()
            .compactMap { (idx, raw) -> Candidate? in
                let cols = raw.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard cols.count >= 4, !cols[0].isEmpty else { return nil }
                return Candidate(
                    id:       String(cols[0]),
                    duration: TimeInterval(cols[1]) ?? 0,
                    channel:  String(cols[2]),
                    title:    String(cols[3]),
                    rank:     idx
                )
            }

        // Same identity gate as the YT Music path. With no identifiable match we
        // throw `noResult` rather than play a different artist's song.
        let identified = candidates.filter {
            !excluding.contains($0.id)
                && Self.matchesIdentity(title: $0.title, channel: $0.channel, query: query)
        }
        guard let best = identified.min(by: { Self.score($0, expectedDuration: expectedDuration, preferExplicit: preferExplicit)
                                              < Self.score($1, expectedDuration: expectedDuration, preferExplicit: preferExplicit) })
        else {
            throw YTDLPError.noResult
        }
        return best.id
    }

    /// Official song upload of `query` via the vendored `ytmusicapi`. Picks the
    /// closest runtime within ~20s among identity-matched hits. Throws when there's
    /// no match so the caller falls back to YouTube search.
    private func ytmusicVideoID(query: String,
                                expectedDuration: TimeInterval,
                                preferExplicit: Bool = false,
                                excluding: Set<String> = []) async throws -> String {
        guard let python = try Self.bundledPython() ?? (try? Self.locate("python3")) else {
            throw YTDLPError.binaryMissing("python3")
        }
        Self.ensureExecutable(python)

        // One `videoId\tisExplicit\tduration\ttitle\tartists` row per song hit.
        // Title and artists feed the identity gates below.
        let script = """
        import sys
        from ytmusicapi import YTMusic
        yt = YTMusic()
        for r in yt.search(sys.argv[1], filter="songs", limit=10):
            vid = r.get("videoId")
            if not vid:
                continue
            dur = r.get("duration_seconds") or 0
            exp = "1" if r.get("isExplicit") else "0"
            title = (r.get("title") or "").replace("\\t", " ")
            arts = " | ".join((a.get("name") or "") for a in (r.get("artists") or []))
            print("%s\\t%s\\t%s\\t%s\\t%s" % (vid, exp, dur, title, arts.replace("\\t", " ")))
        """

        let out = try await Self.run(executable: python, args: ["-c", script, query])

        struct YTMHit {
            let id: String
            let explicit: Bool
            let duration: TimeInterval
            let title: String
            let artists: [String]
        }
        let hits = out.split(separator: "\n").compactMap { raw -> YTMHit? in
            let cols = raw.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard cols.count >= 5, !cols[0].isEmpty else { return nil }
            return YTMHit(id: String(cols[0]),
                          explicit: String(cols[1]) == "1",
                          duration: TimeInterval(cols[2]) ?? 0,
                          title: String(cols[3]),
                          artists: cols[4].components(separatedBy: " | ")
                                          .map { $0.trimmingCharacters(in: .whitespaces) }
                                          .filter { !$0.isEmpty })
        }

        // Identity gates before scoring. Searches return covers and remixes at
        // nearly the same length, so duration is only a tiebreak. `query` is
        // "<artist> <title>", so both gates test containment in it.
        let queryWords = Self.words(query)
        let plausible = hits.filter { hit in
            // Any credited artist must be in the query, so features and duos pass.
            guard hit.artists.contains(where: { Self.isContained(Self.words($0), in: queryWords) }) else {
                return false
            }
            // Extra title words mark remixes, karaoke, sped-up edits etc.
            return Self.isContained(Self.words(Self.stripFeaturedGroup(hit.title)), in: queryWords)
        }

        // Tier by explicitness instead of picking by duration, which made clean vs
        // explicit a coin flip. First tier with a candidate wins.
        let wantCensored = ResolverPreferences.preferCensored
        let censored   = plausible.filter {  !$0.explicit || Self.isCensoredTitle($0.title) }
        let uncensored = plausible.filter { $0.explicit && !Self.isCensoredTitle($0.title) }

        // Catalogue-explicit and user wants explicit: no clean fallback, so we reach
        // the YouTube search for a real uncensored upload.
        var tiers = wantCensored ? [censored, uncensored] : [uncensored, censored]
        if preferExplicit && !wantCensored { tiers = [uncensored] }

        for tier in tiers {
            let qualifying = tier.filter { !excluding.contains($0.id) }
            guard !qualifying.isEmpty else { continue }
            guard expectedDuration > 0 else { return qualifying[0].id }
            // Closest duration, to avoid a remix or an extended cut.
            let best = qualifying.min {
                abs($0.duration - expectedDuration) < abs($1.duration - expectedDuration)
            }!
            if best.duration == 0 || abs(best.duration - expectedDuration) <= 20 { return best.id }
        }
        // No genuine match: let the caller fall back to YouTube search.
        throw YTDLPError.noResult
    }

    // MARK: - Identity matching

    /// Whether a YouTube upload is plausibly the requested song: every query word
    /// must appear in the title or channel. Substring match on a flattened haystack,
    /// so "TateMcRaeVEVO" satisfies "tate" and "mcrae".
    private static func matchesIdentity(title: String, channel: String, query: String) -> Bool {
        let haystack = "\(title) \(channel)"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !haystack.isEmpty else { return false }

        // Words of two letters or fewer carry no identity.
        let required = words(query).filter { $0.count > 2 }
        guard !required.isEmpty else { return false }

        return required.allSatisfy { haystack.contains($0) }
    }

    /// `isSubset(of:)` that rejects the empty set.
    private static func isContained(_ candidate: Set<String>, in whole: Set<String>) -> Bool {
        !candidate.isEmpty && candidate.isSubset(of: whole)
    }

    /// Lowercased word set, punctuation as a separator ("It's ok" == "Its ok").
    /// One-character words dropped unless nothing else is left.
    private static func words(_ s: String) -> Set<String> {
        let flattened = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let all = Set(flattened)
        let meaningful = all.filter { $0.count > 1 }
        return meaningful.isEmpty ? all : meaningful
    }

    /// Drops a trailing "(feat. ...)" / "(with ...)" group. Bracketed and end-anchored
    /// so "Dancing With Myself" survives.
    private static func stripFeaturedGroup(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]?\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Title words marking a censored cut. Shared by YT Music tiering and YouTube scoring.
    private static let censoredWords = ["clean", "censored", "radio edit", "radio version",
                                        "no swearing", "family friendly", "clean version",
                                        "clean edit", "no cuss", "bleeped"]

    static func isCensoredTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return censoredWords.contains { lower.contains($0) }
    }

    /// Lower is better. Combines duration match with channel/title heuristics.
    private static func score(_ c: Candidate, expectedDuration: TimeInterval, preferExplicit: Bool = false) -> Double {
        var score = Double(c.rank) * 2

        if expectedDuration > 0, c.duration > 0 {
            let delta = abs(c.duration - expectedDuration)
            score += delta
            if delta > 20 { score += 80 }
        }

        let channel = c.channel.lowercased()
        let title   = c.title.lowercased()

        if channel.hasSuffix("- topic") { score -= 120 }
        if title.contains("official audio") || title.contains("(audio)") || title.contains("[audio]") {
            score -= 40
        }

        // Penalise censored uploads, or favour them when the user wants clean.
        // Outweighs a clean "- Topic" upload's bonus.
        let censoredWeight: Double = ResolverPreferences.preferCensored ? -150 : 150
        if isCensoredTitle(title) { score += censoredWeight }

        // Actively prefer the version that says which one it is.
        if title.contains("explicit") {
            if ResolverPreferences.preferCensored { score += 120 }
            else if preferExplicit                { score -= 120 }
        }

        let noise = ["official video", "music video", "lyric video",
                     "live", "cover", "remix", "sped up", "slowed",
                     "reverb", "mashup", "intro", "trailer", "8d", "extended"]
        for word in noise where title.contains(word) { score += 50 }

        // Bootleg uploads often keep the real runtime and title. High-signal words
        // only, so "feat."/"version" aren't hit.
        let bootleg = ["ai cover", "ai verse", "leak", "unreleased", "snippet",
                       "bootleg", "fan made", "fanmade", "concept", "remake",
                       "reimagined", "open verse", "added verse"]
        for word in bootleg where title.contains(word) { score += 120 }

        return score
    }

    // MARK: - yt-dlp invocation

    /// How to launch yt-dlp: the executable to run plus any leading args.
    private struct Invocation {
        let executable: URL
        let prefix: [String]
    }

    /// The bundled CPython + zipapp, or yt-dlp on PATH / Homebrew in dev.
    private static func ytdlpInvocation() throws -> Invocation {
        if let python = try bundledPython(), let zipapp = bundledZipapp() {
            ensureExecutable(python)
            return Invocation(executable: python, prefix: [zipapp.path])
        }
        // No bundled runtime: use a directly executable yt-dlp.
        let yt = try locate("yt-dlp")
        return Invocation(executable: yt, prefix: [])
    }

    /// Args for solving YouTube's `n` challenge. Without them every audio format
    /// is filtered out. Needs a JS engine (we bundle deno, since Finder apps get a
    /// minimal PATH) plus solver scripts yt-dlp fetches via `--remote-components`.
    /// Empty when no deno exists, so dev builds behave as before.
    private static var jsRuntimeArgs: [String] {
        guard let deno = try? locate("deno") else { return [] }
        return ["--js-runtimes", "deno:\(deno.path)", "--remote-components", "ejs:github"]
    }

    /// Bump with fetch-binaries.sh's PY_VERSION/PY_RELEASE to re-extract the runtime.
    private static let pythonBuildID = "cpython-3.12.8-20241219-ytm1"

    /// Bundled CPython, extracted once from `python.tar.gz` into Application
    /// Support (a loose tree collides in Xcode's flat resource copy). Nil in dev builds.
    private static func bundledPython() throws -> URL? {
        guard let archive = bundledPythonArchive() else { return nil }

        let runtimeDir = applicationSupportDir().appendingPathComponent("runtime", isDirectory: true)
        let python = runtimeDir.appendingPathComponent("python/bin/python3")
        let stamp  = runtimeDir.appendingPathComponent(".python-build")
        let fm = FileManager.default

        // Already extracted at the current build? Use it.
        if fm.isExecutableFile(atPath: python.path),
           (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == pythonBuildID {
            return python
        }

        // (Re)extract: clear any stale tree, unpack the archive, stamp the build.
        try? fm.removeItem(at: runtimeDir.appendingPathComponent("python"))
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        // /usr/bin/tar is always present and preserves symlinks + exec bits.
        _ = try Self.runSync(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                             args: ["-xzf", archive.path, "-C", runtimeDir.path])
        guard fm.isExecutableFile(atPath: python.path) else { return nil }
        try? pythonBuildID.write(to: stamp, atomically: true, encoding: .utf8)
        return python
    }

    /// Bundled CPython archive at Contents/Resources/bin/python.tar.gz.
    private static func bundledPythonArchive() -> URL? { bundledResource("bin/python.tar.gz") }

    /// A bundled file by path relative to Resources/, or at the flattened root.
    private static func bundledResource(_ relativePath: String) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let nested = res.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        let flat = res.appendingPathComponent((relativePath as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath: flat.path) ? flat : nil
    }

    /// ~/Library/Application Support/<bundle-id>/ (created if missing).
    private static func applicationSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Mixtape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bundled yt-dlp zipapp at Contents/Resources/bin/yt-dlp.zip.
    private static func bundledZipapp() -> URL? { bundledResource("bin/yt-dlp.zip") }

    // MARK: - Binary discovery

    private static func locate(_ name: String) throws -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) {
            ensureExecutable(bundled)
            return bundled
        }
        if let bundledBin = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin") {
            ensureExecutable(bundledBin)
            return bundledBin
        }
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw YTDLPError.binaryMissing(name)
    }

    private static func ensureExecutable(_ url: URL) {
        let path = url.path
        if !FileManager.default.isExecutableFile(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    // MARK: - Process runner

    /// Synchronous Process run for one-shot setup. Throws `processFailed` with stderr.
    @discardableResult
    static func runSync(executable: URL, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw YTDLPError.processFailed(String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// Set once when the watchdog fires, safe across the timer and drain queues.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire()      { lock.lock(); fired = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Forwards Task cancellation to the child. A cancel can arrive before the
    /// process is spawned; `adopt` reports that so the caller kills it immediately.
    nonisolated private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Returns false if cancellation already arrived; caller must terminate.
        func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running, running.isRunning { running.terminate() }
        }

        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// Runs `executable` off the main thread and returns stdout. Throws
    /// `processFailed` with stderr on non-zero exit. `timeout` kills a wedged child
    /// (nil = no limit). Cancelling the Task also kills the child.
    static func run(executable: URL,
                    args: [String],
                    timeout: TimeInterval? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let child = ChildProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError  = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: YTDLPError.processFailed(error.localizedDescription))
                    return
                }
                if !child.adopt(process) { process.terminate() }

                // Killing the child closes its pipes, which unblocks the drains below.
                let timedOut = TimeoutFlag()
                var watchdog: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem {
                        timedOut.fire()
                        if process.isRunning { process.terminate() }
                    }
                    watchdog = item
                    DispatchQueue.global(qos: .utility)
                        .asyncAfter(deadline: .now() + timeout, execute: item)
                }

                // Drain stdout and stderr on separate queues, or a full stderr buffer deadlocks.
                var outData = Data()
                var errData = Data()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let onLine {
                        // Read in chunks so progress lines arrive as they're printed.
                        let handle = outPipe.fileHandleForReading
                        var pending = Data()
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            outData.append(chunk)
                            pending.append(chunk)
                            // Lines end in \n or \r depending on --newline.
                            while let cut = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                                let line = String(decoding: pending[pending.startIndex..<cut], as: UTF8.self)
                                pending.removeSubrange(pending.startIndex...cut)
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty { onLine(trimmed) }
                            }
                        }
                    } else {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
                drainGroup.wait()
                process.waitUntilExit()
                watchdog?.cancel()

                if child.wasCancelled {
                    // Deliberate teardown, not an error.
                    continuation.resume(throwing: CancellationError())
                } else if timedOut.didFire {
                    // A killed child's stderr is truncated, so report the reason instead.
                    continuation.resume(throwing: YTDLPError.processFailed(
                        "Timed out after \(Int(timeout ?? 0))s."))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: outData, as: UTF8.self))
                } else {
                    let msg = String(decoding: errData, as: UTF8.self)
                    continuation.resume(throwing: YTDLPError.processFailed(msg))
                }
            }
            }
        } onCancel: {
            child.cancel()
        }
    }
}
#endif
