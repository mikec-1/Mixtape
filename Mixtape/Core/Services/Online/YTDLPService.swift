// YTDLPService.swift
// Mixtape
//
// Async wrapper around the bundled yt-dlp + ffmpeg. download(...) scores a
// flat-playlist search for the best YouTube match and extracts its audio to m4a.
// The app isn't sandboxed (see entitlements), so Process is fine here.
//
// yt-dlp is shipped as its pure-Python ZIPAPP (Contents/Resources/bin/yt-dlp.zip)
// run by a bundled relocatable CPython — NOT the `yt-dlp_macos` PyInstaller
// onefile, which re-extracts ~1500 Gatekeeper-scanned files on every launch
// (~11s of startup per invocation). The zipapp + standalone python starts in
// ~0.2s. See ytdlpInvocation().
//
// CPython ships as a single archive (Resources/bin/python.tar.gz) and is unpacked
// ONCE at first use into ~/Library/Application Support/<bundle-id>/runtime/python
// (a loose ~1800-file tree inside Resources/ collides under Xcode's flattened
// resource copy). During dev (no bundled archive) it falls back to a directly-
// executable yt-dlp on PATH / Homebrew.
//
// ffmpeg discovery order:
//   1. Bundled static binary in the .app (Contents/Resources/bin/ffmpeg)
//   2. Homebrew (/opt/homebrew/bin, /usr/local/bin) — convenient during dev.

// yt-dlp runs via Process (fork-exec), which exists only on macOS. On iOS the
// Discover audio path is served by RemoteResolverService instead, so this whole
// file is macOS-only. The shared platform seam lives in TrackResolver.swift.
#if os(macOS)
import Foundation

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

/// Player clients YouTube has been seen refusing for a particular video.
///
/// `web_embedded` is the app's first choice everywhere: it is the client whose
/// audio still resolves without cookies, once the signature challenge in front
/// of it is solved (see `jsRuntimeArgs`). Some videos refuse it anyway, and the
/// app used to discover that twice per play: once when the streamed URL wouldn't
/// open, then again when the fallback download led with the same client and
/// spent ~10s of yt-dlp retries earning the same 403.
///
/// Demoted, not banned. A 403 is the usual cause but a stalled stream looks
/// identical from outside, and a client dropped on that evidence would be a
/// client unavailable when the other one is the blocked one. Last place still
/// gets tried; it just stops being the one the listener waits behind.
///
/// Memory only: YouTube's gating moves, and a fresh launch deserves a fresh
/// opinion.
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

    /// Downloads run on this Mac, so the ceiling is the machine rather than a
    /// server's patience. Each one is a network fetch with a short ffmpeg pass
    /// at the end, so they overlap well; capped against core count so a batch
    /// doesn't take the whole machine away from whoever started it.
    public var suggestedDownloadConcurrency: Int {
        max(3, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// The client both the stream resolve and the first download attempt use.
    ///
    /// Was `android_vr`, which needed no signature solving — until YouTube began
    /// requiring a Proof-of-Origin token for its media URLs too (extraction still
    /// succeeds; the googlevideo fetch 403s). `web_embedded` is what is left that
    /// serves full-bitrate m4a to a signed-out client, and it costs a JS
    /// challenge solve to reach.
    private static let preferredClient = "web_embedded"

    /// The clients tried in order when `preferredClient` is refused. `nil` means
    /// yt-dlp's own defaults. `tv_simply` is last-but-one on purpose: it answers
    /// without a signature solve but only exposes format 18 (a 360p mp4 whose
    /// audio has to be re-encoded), so it is a floor, not a preference.
    private static let clientFallbacks: [String?] = ["tv_simply", nil]

    /// The player couldn't open a URL we handed it. Demote the client that
    /// produced it for this video, so the fallback download leads with the other
    /// one and a replay skips the doomed stream entirely.
    public func noteStreamUnplayable(videoID: String) async {
        await ClientPenaltyBox.shared.demote(Self.preferredClient, for: videoID)
    }

    /// Back-compat alias: callers referenced `YTDLPService.DownloadResult` before
    /// the resolver seam existed. The canonical type is now `ResolvedAudio`.
    public typealias DownloadResult = ResolvedAudio

    // MARK: - Public API

    /// Ask YouTube for a directly-playable audio URL instead of downloading the
    /// file, so AVPlayer can start on the first buffer. Returns nil on any
    /// failure — every caller treats that as "fall back to `download`".
    ///
    /// Cost, measured against this app's own binaries and format selector
    /// (2026-09-02), because the number here was stale and the stale number was
    /// what made the resolve look like somebody else's problem:
    ///
    ///   yt-dlp interpreter start   ~0.6s
    ///   `-g` extract, web_embedded  3.1s without the signature solve,
    ///                               3.7s warm with it, 4.8s cold
    ///
    /// So the nsig solve is ~0.6s, not the 10–20s the old `web`-client note
    /// described, and it is not what to attack. The extract itself is, and the
    /// search in front of it is larger still — which is why `pinnedVideoID`
    /// exists.
    ///
    /// (The previous note claimed `android_vr` returned pre-signed URLs in
    /// ~1.5s. That client is gone; `preferredClient` is `web_embedded` and has
    /// been since the bot-check fix, so the note was describing code that no
    /// longer existed.)
    ///
    /// The deadline matters more than the speed: a wedged resolve must not out-
    /// last the download it is supposed to be faster than.
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

    /// `pinnedVideoID` skips the search entirely.
    ///
    /// Which is most of the wait. Measured with this app's own binaries and
    /// format selector: the YouTube Music search and the `ytsearch8` fallback
    /// are a process spawn and a round trip each (~2s and ~2.7s), and the `-g`
    /// extract that follows is ~3.7s. A song whose video is already known — a
    /// replay, a completed download, a warm — was paying all three, every time,
    /// to arrive at an id it had written down the first time.
    ///
    /// The caller is responsible for not pinning a video the user has rejected;
    /// see `exclusions(for:)`. Pinning one would make "wrong version" unfixable,
    /// because the press that is supposed to walk to an alternative would keep
    /// resolving the same one.
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
            // Not `try?`. "No video matches this song" is the answer the whole
            // unfindable path is built on, and swallowing it into `nil` meant
            // the caller read it as "can't stream, go and download instead" —
            // so nothing was ever marked unfindable, and a song with no source
            // sat in the download loop trying every client for a video that
            // does not exist. nil below still means "found it, can't stream it".
            videoID = try await selectBestVideo(query: query,
                                                expectedDuration: expectedDuration,
                                                preferExplicit: preferExplicit,
                                                excluding: excluding)
        }

        // This video already refused the only client we can stream from, so
        // there is no stream to resolve — returning nil sends the caller
        // straight to the download it was going to end up doing anyway, minus
        // the ~3.5s extract and the dead handoff in front of it.
        if await ClientPenaltyBox.shared.isDemoted(Self.preferredClient, for: videoID) {
            ResolveTrace.shared.mark("stream skipped (client blocked for this video)", owner: query)
            return nil
        }

        let args = [
            "https://www.youtube.com/watch?v=\(videoID)",
            "-g",
            // One format in, one URL out. A progressive m4a is what AVPlayer
            // wants; `bestaudio` alone could select a DASH-only format whose
            // "URL" is a fragment base AVPlayer can't open.
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
        else { return nil }

        // android_vr's URLs are pre-signed and need no User-Agent (verified: a
        // bare range request returns 206), so there are no headers to pass on.
        return StreamResolution(url: url, videoID: videoID)
    }

    /// Long enough for a slow search + resolve, short enough that falling back to
    /// a full download still beats waiting out a hang.
    private static let streamResolveTimeout: TimeInterval = 10

    /// Download & extract the best audio for `query`. Runs two yt-dlp passes: a
    /// flat-playlist search to score the best candidate, then a direct download of
    /// the chosen video. The file is named by the resolved videoID, which is
    /// returned alongside the URL. Prefer `resolveStream` when the audio is only
    /// going to be played; this is for when a real file is the point.
    public func download(query: String, name: String, to destinationDir: URL, expectedDuration: TimeInterval = 0, preferExplicit: Bool = false) async throws -> DownloadResult {
        // Pick the best studio-audio upload first (explicit master when the track
        // is explicit) and name the output after its id, since we key the cache by it.
        let videoID = try await selectBestVideo(query: query, expectedDuration: expectedDuration, preferExplicit: preferExplicit)
        return try await fetchAudio(videoID: videoID, to: destinationDir, owner: query)
    }

    /// Same two passes, narrated.
    ///
    /// The search pass has no percentage to give — it is one request that either
    /// answers or doesn't — so it reports itself as a phase and the download
    /// pass supplies the number. That number is yt-dlp's own: `--newline` makes
    /// it print one progress line per update instead of redrawing a carriage
    /// return, which is the difference between a stream we can read and a blob
    /// that only makes sense on a terminal.
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

    /// Reads one line of yt-dlp output and turns it into progress, or nothing.
    ///
    /// Two shapes matter: `[download]  42.7% of 3.51MiB at …`, and the
    /// `[ExtractAudio]` line that marks the handoff to ffmpeg. Everything else
    /// yt-dlp prints — and it prints a lot — is deliberately ignored rather than
    /// guessed at.
    static func progress(fromLine line: String) -> ResolveProgress? {
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

    /// A pasted link names the video, so there is nothing to search for — this
    /// skips straight to the download. `fallbackQuery` is unused here and only
    /// exists for resolvers that can't take an id.
    public func download(videoID: String,
                         fallbackQuery: String,
                         name: String,
                         to destinationDir: URL) async throws -> ResolvedAudio {
        try await fetchAudio(videoID: videoID, to: destinationDir, owner: fallbackQuery)
    }

    /// The pinned download, narrated. Same two-pass output reader as the
    /// searched form — minus the search, which is what pinning buys.
    public func download(videoID: String,
                         fallbackQuery: String,
                         name: String,
                         to destinationDir: URL,
                         onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .downloading, fraction: 0))
        return try await fetchAudio(videoID: videoID, to: destinationDir,
                                    owner: fallbackQuery, onProgress: onProgress)
    }

    /// Extract `<videoID>`'s audio into `<destinationDir>/<videoID>.m4a`.
    /// `owner` is the query this download serves, for trace attribution only.
    private func fetchAudio(videoID: String, to destinationDir: URL,
                            owner: String? = nil,
                            onProgress: (@Sendable (ResolveProgress) -> Void)? = nil) async throws -> DownloadResult {
        let inv    = try Self.ytdlpInvocation()
        let ffmpeg = try Self.locate("ffmpeg")

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let template = destinationDir.appendingPathComponent("\(videoID).%(ext)s").path
        let expected = destinationDir.appendingPathComponent("\(videoID).m4a")
        let videoURL = "https://www.youtube.com/watch?v=\(videoID)"

        // The default `web` client increasingly 403s the audio download (formats
        // gated behind a Proof-of-Origin token it can't mint), so lead with
        // `web_embedded`, then step down through the clients that answer without
        // a signature solve. nil == omit --extractor-args.
        //
        // Unless this video is one of the ones that refuses `web_embedded`, in
        // which case the order flips and the client that was going to fail waits
        // at the back instead of in front.
        var clientStrategies: [String?] = [Self.preferredClient] + Self.clientFallbacks
        if await ClientPenaltyBox.shared.isDemoted(Self.preferredClient, for: videoID) {
            clientStrategies = Self.clientFallbacks + [Self.preferredClient]
            ResolveTrace.shared.mark("client order flipped (\(Self.preferredClient) blocked here)",
                                     owner: owner)
        }
        var lastError: Error?

        for (attempt, clients) in clientStrategies.enumerated() {
            // Retries are for transient CDN throttling, and only the last
            // strategy has anything to gain by grinding through them: earlier
            // ones have a whole other client waiting behind them, which is both
            // likelier to work and faster than a third retry of one that's being
            // refused. Three retries plus fragment retries is what turned a
            // dead-on-arrival 403 into a 9951ms wait before the client that
            // worked got a turn.
            let isLastResort = attempt == clientStrategies.count - 1
            var args = [
                videoURL,
                // Prefer m4a (copy), fall back to any audio so a client lacking
                // format 140 still works; --audio-format re-encodes when needed.
                "-f", "bestaudio[ext=m4a]/bestaudio/best",
                "-x", "--audio-format", "m4a",
                "--no-playlist",
                "--no-warnings",
                // Self-heal transient throttling/expiry on the googlevideo CDN.
                // Fetch a fragmented stream's pieces in parallel. This is the
                // single biggest win per song: the download is latency-bound on
                // many small fragments, not bandwidth-bound on one big file.
                "--concurrent-fragments", "4",
                "--retries", isLastResort ? "3" : "1",
                "--fragment-retries", isLastResort ? "5" : "1",
                "--extractor-retries", isLastResort ? "2" : "1",
                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                "-o", template,
            ] + Self.jsRuntimeArgs
            // Only when somebody is watching. `--newline` costs a line of output
            // per update, which is noise in a log nobody reads and the entire
            // point when a progress bar is on screen.
            if onProgress != nil { args += ["--newline"] }
            if let clients {
                args += ["--extractor-args", "youtube:player_client=\(clients)"]
            }

            let client = clients ?? "default"
            do {
                _ = try await Self.run(executable: inv.executable, args: inv.prefix + args,
                                       onLine: onProgress.map { report in
                                           { line in
                                               if let step = Self.progress(fromLine: line) { report(step) }
                                           }
                                       })
                if FileManager.default.fileExists(atPath: expected.path) {
                    ResolveTrace.shared.mark("download+ffmpeg [\(client)]", owner: owner)
                    return DownloadResult(fileURL: expected, videoID: videoID)
                }
                ResolveTrace.shared.mark("download [\(client)] no file", owner: owner)
                lastError = YTDLPError.noResult
            } catch {
                // A cancellation is us stopping this on purpose; calling it a
                // failure in the trace sends the next reader hunting a bug. A
                // real failure names its reason — a first-client failure costs
                // seconds of dead time, and "FAILED" alone can't tell a 403 from
                // a missing format from a network drop.
                ResolveTrace.shared.mark(error is CancellationError
                                         ? "download [\(client)] cancelled"
                                         : "download [\(client)] FAILED: \(Self.reason(error))",
                                         owner: owner)
                lastError = error
                // Remember a refusal, so the next play of this video — the
                // stream resolve included — doesn't lead with this client again.
                if let clients, Self.isForbidden(error) {
                    await ClientPenaltyBox.shared.demote(clients, for: videoID)
                }
                // Only a 403 or a no-usable-format error is worth another client;
                // anything else (binary missing, disk) is terminal.
                if !Self.isRetryable(error) { throw error }
            }
        }

        // Every strategy blocked — show a clear message, not yt-dlp's raw 403 dump
        // or the wall of extractor chatter YouTube's anti-bot page produces.
        if Self.isForbidden(lastError) || Self.isBotChecked(lastError) {
            throw YTDLPError.processFailed(
                "YouTube blocked this download. Try again in a moment."
            )
        }
        throw lastError ?? YTDLPError.noResult
    }

    /// yt-dlp's stderr, reduced to the one line worth reading. It emits a banner,
    /// a stack of extractor chatter and then the actual complaint; the complaint
    /// is the only part that identifies the failure, and it is prefixed `ERROR:`.
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

    /// True when YouTube answered with its anti-bot wall instead of the video.
    /// Distinct from a 403: nothing was refused mid-download — the extract never
    /// got a format list to begin with.
    private static func isBotChecked(_ error: Error?) -> Bool {
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        return msg.lowercased().contains("sign in to confirm")
    }

    /// True when a download failure is worth retrying on a different player
    /// client: either a 403 block or a client that exposed no usable format.
    private static func isRetryable(_ error: Error?) -> Bool {
        if isForbidden(error) { return true }
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        if isBotChecked(error) { return true }
        let lower = msg.lowercased()
        // How a gated client reports having nothing to offer: the format list
        // came back empty apart from the storyboards yt-dlp always keeps, so the
        // complaint names the format rather than the block behind it.
        return lower.contains("requested format is not available")
            || lower.contains("only images are available")
    }

    /// True when yt-dlp can be invoked (used to gate the UI). Cheap: only checks
    /// that the payloads exist — does NOT trigger the one-time Python extraction
    /// (that happens lazily on first download, off the main thread).
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

    /// Search YouTube for `query` and return the 11-char video id of the best
    /// *song* upload — preferring clean studio audio (auto-generated "- Topic"
    /// channels and "Audio" uploads) over music videos, and rejecting candidates
    /// whose runtime is far from `expectedDuration` (the canonical iTunes length).
    private func selectBestVideo(query: String,
                                 expectedDuration: TimeInterval,
                                 preferExplicit: Bool = false,
                                 excluding: Set<String> = []) async throws -> String {
        // Try YouTube Music first: its "songs" results are official catalog uploads
        // with a real videoId, so they dodge the fan edits / AI verses / leaks that
        // slip past the title+duration heuristics below (a bootleg verse can keep
        // the runtime in tolerance). It also carries a per-track isExplicit flag for
        // the real uncensored master. Falls through to the YouTube search if YT
        // Music is unavailable or has no close match.
        let ytmID = try? await ytmusicVideoID(query: query,
                                              expectedDuration: expectedDuration,
                                              preferExplicit: preferExplicit,
                                              excluding: excluding)
        ResolveTrace.shared.mark("ytmusicapi search (hit=\(ytmID != nil))", owner: query)
        if let ytmID { return ytmID }

        let inv = try Self.ytdlpInvocation()

        // Nudge YouTube toward the version we want; the scoring below still does
        // the final pick, so a search that only turns up the other cut is fine.
        let searchQuery: String
        if ResolverPreferences.preferCensored { searchQuery = "\(query) clean" }
        else if preferExplicit                { searchQuery = "\(query) explicit" }
        else                                  { searchQuery = query }

        // --flat-playlist reads the listing only (id/title/duration/channel) with
        // no per-video extraction — fast, and avoids the unreliable nsig cipher.
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

        // The same identity gate the YT Music path applies, before any scoring.
        //
        // Without it this fallback ranks by search position, runtime and title
        // keywords alone — nothing in `score` ever asks whether the upload is
        // the song that was requested. So whenever YT Music missed (which is
        // most of the time for an artist outside the big catalogues) the top
        // YouTube hit was served on trust, and a search for one artist's "Plug"
        // returned a different artist's "Plug" at a believable length. Playing
        // a stranger's song is a worse failure than playing nothing, so a
        // search with no identifiable match now falls through to `noResult`.
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

    /// Ask YouTube Music (vendored `ytmusicapi`) for the official song upload of
    /// `query`. Each hit has a real videoId and isExplicit flag, so we get the
    /// catalog master instead of inferring from YouTube titles. With preferExplicit
    /// we keep only explicit hits; among the rest we pick the closest runtime to
    /// `expectedDuration` and reject if nothing's within ~20s. Throws (→ caller
    /// falls back to the YouTube search) when YT Music can't produce a match.
    private func ytmusicVideoID(query: String,
                                expectedDuration: TimeInterval,
                                preferExplicit: Bool = false,
                                excluding: Set<String> = []) async throws -> String {
        guard let python = try Self.bundledPython() ?? (try? Self.locate("python3")) else {
            throw YTDLPError.binaryMissing("python3")
        }
        Self.ensureExecutable(python)

        // Print one `videoId\tisExplicit\tduration\ttitle\tartists` row per song
        // hit. Tiny and dependency-light so it runs under the bundled interpreter.
        //
        // Title and artists are not decoration: without them the pick below is
        // duration proximity alone, and a search is full of same-length decoys.
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

        // Identity gates, before anything is scored.
        //
        // "songs" results are catalog uploads, which made them look trustworthy,
        // but a search for one song returns the whole neighbourhood: other
        // artists' versions, karaoke and string-quartet covers, remixes, sped-up
        // and slowed edits, and the rest of the same artist's catalogue. A pick
        // by nearest duration walks straight into them — a real search for
        // "Tate McRae Sports car" (166s) offers covers at 165s, 167s and 168s,
        // and that is how the user got a stranger's cover. Runtime is a
        // tiebreaker between candidates that are already the same song; it can
        // never establish that they are.
        //
        // `query` is "<artist> <title>", so both gates test containment in it.
        let queryWords = Self.words(query)
        let plausible = hits.filter { hit in
            // Someone credited on the upload has to be who was asked for. Any
            // one of them, so a feature or a duo still passes.
            guard hit.artists.contains(where: { Self.isContained(Self.words($0), in: queryWords) }) else {
                return false
            }
            // Same song, not merely the same artist. Extra words in the upload's
            // title are what mark remixes, karaoke and sped-up edits, so a title
            // carrying words the query never asked for is a different recording.
            return Self.isContained(Self.words(Self.stripFeaturedGroup(hit.title)), in: queryWords)
        }

        // Uncensored first, censored second — never a coin flip between them.
        //
        // A clean master and an explicit one are the same recording to within a
        // fraction of a second, so choosing across both by nearest duration
        // decided it at random, and half the time the app served a bleeped
        // upload while insisting it was the original. Tier the hits instead and
        // take the first tier that yields a candidate: the wanted version when
        // it exists, the other one when it doesn't. `preferExplicit` is now only
        // an override for which tier is wanted, not the only thing that
        // separates the two.
        let wantCensored = ResolverPreferences.preferCensored
        let censored   = plausible.filter {  !$0.explicit || Self.isCensoredTitle($0.title) }
        let uncensored = plausible.filter { $0.explicit && !Self.isCensoredTitle($0.title) }

        // A track the catalogue already calls explicit, for a user who hasn't
        // asked for clean: no second tier at all. Settling for the clean master
        // here would stop the caller ever reaching the YouTube search, which is
        // where a real uncensored upload is found when YT Music carries only
        // the radio edit.
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
        // Nothing here is genuinely this song — say so and let the caller fall
        // back to the YouTube search rather than serving the closest stranger.
        throw YTDLPError.noResult
    }

    // MARK: - Identity matching

    /// Whether a YouTube upload is plausibly the song that was asked for.
    ///
    /// The YT Music gate tests that the *hit's* words are contained in the
    /// query, because a catalogue row is clean metadata. A YouTube title is
    /// not: it is "Artist - Title (Official Video) [4K]" on a channel called
    /// "ArtistVEVO", so that direction rejects almost everything. This tests
    /// the other way round — every word the query asked for has to appear
    /// somewhere in the upload's title or channel.
    ///
    /// Matching is by substring against a flattened, punctuation-free haystack
    /// rather than by word, so "TateMcRaeVEVO" still satisfies "tate" and
    /// "mcrae". That is looser than word equality, and deliberately: the gate
    /// exists to exclude a different song, not to grade the spelling of a
    /// channel name.
    private static func matchesIdentity(title: String, channel: String, query: String) -> Bool {
        let haystack = "\(title) \(channel)"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !haystack.isEmpty else { return false }

        // Words of two characters or fewer carry no identity ("of", "a") and
        // match everything by accident, so they cannot be evidence either way.
        let required = words(query).filter { $0.count > 2 }
        guard !required.isEmpty else { return false }

        return required.allSatisfy { haystack.contains($0) }
    }

    /// `isSubset(of:)` with the vacuous case closed: the empty set is a subset
    /// of everything, so an unparseable title or a hit with no credited artist
    /// would otherwise pass the very gate it fails to provide evidence for.
    private static func isContained(_ candidate: Set<String>, in whole: Set<String>) -> Bool {
        !candidate.isEmpty && candidate.isSubset(of: whole)
    }

    /// Comparable word set: lowercased, punctuation treated as a separator so
    /// "It's ok, I'm ok" and "Its ok Im ok" agree. One-character words are
    /// dropped as noise ("a", "&" → "") unless that would leave nothing.
    private static func words(_ s: String) -> Set<String> {
        let flattened = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let all = Set(flattened)
        let meaningful = all.filter { $0.count > 1 }
        return meaningful.isEmpty ? all : meaningful
    }

    /// Drops a trailing "(feat. …)" / "(with …)" group. YouTube Music spells the
    /// feature out in the title where the source metadata often doesn't, and
    /// without this every collaboration fails the title gate. Bracketed and
    /// end-anchored on purpose: a bare "with" strip would eat "Dancing With
    /// Myself".
    private static func stripFeaturedGroup(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]?\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Title words that mark an upload as a censored cut. Shared by the YT Music
    /// tiering and the YouTube scoring so the two can't disagree about what
    /// "clean" looks like.
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

        // Steer away from censored uploads (the usual cause of "it's bleeped"),
        // or towards them when the user has asked for clean. Heavy enough that
        // a clean "- Topic" upload (-120) still loses to an explicit non-Topic
        // one when preferExplicit is set.
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

        // Bootleg uploads (fan edits, AI verses, leaks, snippets) often keep the
        // real runtime and a plausible title, so duration alone misses them.
        // High-signal words only, so legit "feat."/"version" titles aren't hit.
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

    /// How to run yt-dlp: the bundled CPython + zipapp in the .app, or a
    /// directly-executable yt-dlp on PATH / Homebrew during dev. (See the file
    /// header for why we avoid the PyInstaller onefile.)
    private static func ytdlpInvocation() throws -> Invocation {
        if let python = try bundledPython(), let zipapp = bundledZipapp() {
            ensureExecutable(python)
            return Invocation(executable: python, prefix: [zipapp.path])
        }
        // No bundled runtime (e.g. running from sources) — fall back to a
        // standalone/Homebrew yt-dlp that can be executed directly.
        let yt = try locate("yt-dlp")
        return Invocation(executable: yt, prefix: [])
    }

    /// Args that let yt-dlp solve YouTube's `n` signature challenge.
    ///
    /// Without them every audio format is filtered out before we ever see it —
    /// yt-dlp reports "Only images are available", which surfaces as a bare
    /// "Requested format is not available" (or, on the default client, YouTube's
    /// "Sign in to confirm you're not a bot"). Two halves are needed: a JS
    /// engine, and the solver scripts that run on it. yt-dlp fetches the scripts
    /// itself given `--remote-components ejs:github`; the engine we ship, because
    /// an app launched from Finder inherits `PATH=/usr/bin:/bin` and would never
    /// find a user's node/deno. Same fix the hosted resolver runs (server/Dockerfile).
    ///
    /// Empty when no deno is bundled or installed — dev builds from source then
    /// behave exactly as before rather than failing on a missing binary.
    private static var jsRuntimeArgs: [String] {
        guard let deno = try? locate("deno") else { return [] }
        return ["--js-runtimes", "deno:\(deno.path)", "--remote-components", "ejs:github"]
    }

    /// Identifies the bundled CPython build. Bump when fetch-binaries.sh changes
    /// PY_VERSION/PY_RELEASE so the runtime re-extracts the new interpreter.
    private static let pythonBuildID = "cpython-3.12.8-20241219-ytm1"

    /// Relocatable CPython, extracted once from the bundled `python.tar.gz` into
    /// Application Support. We ship Python as a single archive (not a loose tree)
    /// because Xcode's flattened resource copy collides on the ~1800 same-named
    /// files inside it. Returns nil if the archive isn't bundled (dev builds).
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

    /// Locate a bundled file by its path relative to Resources/ (also tries the
    /// flattened Resources root, since Xcode may flatten single files).
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

    /// Synchronous Process run (used for one-shot setup like unpacking Python).
    /// Throws `YTDLPError.processFailed` with stderr on a non-zero exit.
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

    /// One-way "the watchdog fired" flag. A plain captured `var` can't carry the
    /// answer back out of the timer closure without tripping over concurrent
    /// access from the timer queue and the drain queue.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire()      { lock.lock(); fired = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Carries `Task` cancellation across to the child, which the `Process` API
    /// gives no way to do on its own.
    ///
    /// The child is spawned on a background queue *after* the cancellation
    /// handler is installed, so a cancel can land before there is anything to
    /// kill. The box remembers that, and `adopt` reports it so the spawning side
    /// can tear the process down the instant it exists.
    private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Returns false if cancellation already arrived — caller must terminate.
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

    /// Run `executable` with `args` off the main thread, returning stdout.
    /// Throws `YTDLPError.processFailed` with stderr text on a non-zero exit.
    ///
    /// `timeout` (nil = wait forever, the default every existing caller wants)
    /// terminates the child if it outlives the deadline. Without it a wedged
    /// yt-dlp hangs its caller indefinitely.
    ///
    /// Cancelling the calling `Task` also terminates the child. It has to be
    /// wired explicitly, because this runs a `Process` on a global queue and
    /// nothing about structured concurrency reaches across that boundary — an
    /// abandoned download would otherwise keep pulling bytes to a file no one
    /// waits for, competing with whatever the user asked for instead.
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

                // Terminating the child closes its pipe ends, which is what
                // releases the drain reads below — so the deadline unblocks the
                // whole function, not just the wait.
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

                // Drain stdout and stderr on separate queues. Reading sequentially
                // deadlocks: if the child fills the ~64KB stderr buffer while we're
                // blocked reading stdout, it can't progress and stdout never hits
                // EOF. yt-dlp's large, variable stderr made this hang intermittent.
                var outData = Data()
                var errData = Data()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let onLine {
                        // Same drain, read in chunks so whole lines can be handed
                        // over as they arrive. `readDataToEndOfFile` gives the
                        // identical bytes — just all of them, once, long after
                        // the progress they describe stopped being news.
                        let handle = outPipe.fileHandleForReading
                        var pending = Data()
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            outData.append(chunk)
                            pending.append(chunk)
                            // yt-dlp ends a progress line with either, depending
                            // on whether --newline is in play.
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
                    // Deliberate teardown, not a failure. Reported as such so it
                    // can't reach the user as an error toast.
                    continuation.resume(throwing: CancellationError())
                } else if timedOut.didFire {
                    // A killed child exits non-zero with truncated stderr, so say
                    // what actually happened rather than echoing the debris.
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
