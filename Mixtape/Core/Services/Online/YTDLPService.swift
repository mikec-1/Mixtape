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

public final class YTDLPService: TrackResolver {

    public init() {}

    /// Back-compat alias: callers referenced `YTDLPService.DownloadResult` before
    /// the resolver seam existed. The canonical type is now `ResolvedAudio`.
    public typealias DownloadResult = ResolvedAudio

    // MARK: - Public API

    /// Download & extract the best audio for `query`. Runs two yt-dlp passes: a
    /// flat-playlist search to score the best candidate, then a direct download of
    /// the chosen video. Downloading beats resolving a stream URL with `-g` because
    /// it skips YouTube's nsig cipher (slow ~10–20s and often throttled). The file
    /// is named by the resolved videoID, which is returned alongside the URL.
    public func download(query: String, name: String, to destinationDir: URL, expectedDuration: TimeInterval = 0, preferExplicit: Bool = false) async throws -> DownloadResult {
        let inv    = try Self.ytdlpInvocation()
        let ffmpeg = try Self.locate("ffmpeg")

        // Pick the best studio-audio upload first (explicit master when the track
        // is explicit) and name the output after its id, since we key the cache by it.
        let videoID = try await selectBestVideo(query: query, expectedDuration: expectedDuration, preferExplicit: preferExplicit)

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let template = destinationDir.appendingPathComponent("\(videoID).%(ext)s").path
        let expected = destinationDir.appendingPathComponent("\(videoID).m4a")
        let videoURL = "https://www.youtube.com/watch?v=\(videoID)"

        // The default `web` client increasingly 403s the audio download (formats
        // gated behind a Proof-of-Origin token it can't mint), so try `android_vr`
        // first — its audio is served token-free — then fall back to yt-dlp's
        // defaults. nil == omit --extractor-args.
        let clientStrategies: [String?] = ["android_vr", nil]
        var lastError: Error?

        for clients in clientStrategies {
            var args = [
                videoURL,
                // Prefer m4a (copy), fall back to any audio so a client lacking
                // format 140 still works; --audio-format re-encodes when needed.
                "-f", "bestaudio[ext=m4a]/bestaudio/best",
                "-x", "--audio-format", "m4a",
                "--no-playlist",
                "--no-warnings",
                // Self-heal transient throttling/expiry on the googlevideo CDN.
                "--retries", "3",
                "--fragment-retries", "5",
                "--extractor-retries", "2",
                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                "-o", template,
            ]
            if let clients {
                args += ["--extractor-args", "youtube:player_client=\(clients)"]
            }

            do {
                _ = try await Self.run(executable: inv.executable, args: inv.prefix + args)
                if FileManager.default.fileExists(atPath: expected.path) {
                    return DownloadResult(fileURL: expected, videoID: videoID)
                }
                lastError = YTDLPError.noResult
            } catch {
                lastError = error
                // Only a 403 or a no-usable-format error is worth another client;
                // anything else (binary missing, disk) is terminal.
                if !Self.isRetryable(error) { throw error }
            }
        }

        // Every strategy blocked — show a clear message, not yt-dlp's raw 403 dump.
        if Self.isForbidden(lastError) {
            throw YTDLPError.processFailed(
                "YouTube blocked this download. Try again in a moment."
            )
        }
        throw lastError ?? YTDLPError.noResult
    }

    /// True when an error is YouTube's anti-bot 403 on the media download.
    private static func isForbidden(_ error: Error?) -> Bool {
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        let lower = msg.lowercased()
        return lower.contains("403") || lower.contains("forbidden")
    }

    /// True when a download failure is worth retrying on a different player
    /// client: either a 403 block or a client that exposed no usable format.
    private static func isRetryable(_ error: Error?) -> Bool {
        if isForbidden(error) { return true }
        guard case let .processFailed(msg)? = (error as? YTDLPError) else { return false }
        return msg.lowercased().contains("requested format is not available")
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
    private func selectBestVideo(query: String, expectedDuration: TimeInterval, preferExplicit: Bool = false) async throws -> String {
        // Try YouTube Music first: its "songs" results are official catalog uploads
        // with a real videoId, so they dodge the fan edits / AI verses / leaks that
        // slip past the title+duration heuristics below (a bootleg verse can keep
        // the runtime in tolerance). It also carries a per-track isExplicit flag for
        // the real uncensored master. Falls through to the YouTube search if YT
        // Music is unavailable or has no close match.
        if let ytmID = try? await ytmusicVideoID(query: query,
                                                 expectedDuration: expectedDuration,
                                                 preferExplicit: preferExplicit) {
            return ytmID
        }

        let inv = try Self.ytdlpInvocation()

        // Nudge YouTube toward the uncensored upload for explicit tracks; the
        // scoring below still does the final pick so a clean-only result is fine.
        let searchQuery = preferExplicit ? "\(query) explicit" : query

        // --flat-playlist reads the listing only (id/title/duration/channel) with
        // no per-video extraction — fast, and avoids the unreliable nsig cipher.
        let args = [
            "ytsearch8:\(searchQuery)",
            "--flat-playlist",
            "--no-warnings",
            "--print", "%(id)s\t%(duration)s\t%(channel)s\t%(title)s",
        ]

        let out = try await Self.run(executable: inv.executable, args: inv.prefix + args)
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

        guard let best = candidates.min(by: { Self.score($0, expectedDuration: expectedDuration, preferExplicit: preferExplicit)
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
    private func ytmusicVideoID(query: String, expectedDuration: TimeInterval, preferExplicit: Bool = false) async throws -> String {
        guard let python = try Self.bundledPython() ?? (try? Self.locate("python3")) else {
            throw YTDLPError.binaryMissing("python3")
        }
        Self.ensureExecutable(python)

        // Print one `videoId\tisExplicit\tduration_seconds` row per song hit. Tiny
        // and dependency-light so it runs under the bundled interpreter.
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
            print("%s\\t%s\\t%s" % (vid, exp, dur))
        """

        let out = try await Self.run(executable: python, args: ["-c", script, query])

        struct YTMHit { let id: String; let explicit: Bool; let duration: TimeInterval }
        let hits = out.split(separator: "\n").compactMap { raw -> YTMHit? in
            let cols = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, !cols[0].isEmpty else { return nil }
            return YTMHit(id: String(cols[0]),
                          explicit: String(cols[1]) == "1",
                          duration: TimeInterval(cols[2]) ?? 0)
        }

        // Explicit tracks: keep only explicit hits so we don't land on the clean
        // master. Then pick the closest duration to avoid a remix/extended cut.
        let qualifying = preferExplicit ? hits.filter(\.explicit) : hits
        guard !qualifying.isEmpty else { throw YTDLPError.noResult }

        if expectedDuration > 0 {
            let best = qualifying.min {
                abs($0.duration - expectedDuration) < abs($1.duration - expectedDuration)
            }!
            guard best.duration == 0 || abs(best.duration - expectedDuration) <= 20 else {
                throw YTDLPError.noResult
            }
            return best.id
        }
        return qualifying[0].id
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

        // Steer away from censored uploads (the usual cause of "it's bleeped").
        // Heavy enough that a clean "- Topic" upload (-120) still loses to an
        // explicit non-Topic one when preferExplicit is set.
        let censored = ["clean", "censored", "radio edit", "radio version",
                        "no swearing", "family friendly", "clean version",
                        "clean edit", "no cuss", "bleeped"]
        for word in censored where title.contains(word) { score += 150 }

        // For an explicit track, actively prefer the version that says so.
        if preferExplicit, title.contains("explicit") { score -= 120 }

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

    /// Run `executable` with `args` off the main thread, returning stdout.
    /// Throws `YTDLPError.processFailed` with stderr text on a non-zero exit.
    static func run(executable: URL, args: [String]) async throws -> String {
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

                // Drain stdout and stderr on separate queues. Reading sequentially
                // deadlocks: if the child fills the ~64KB stderr buffer while we're
                // blocked reading stdout, it can't progress and stdout never hits
                // EOF. yt-dlp's large, variable stderr made this hang intermittent.
                var outData = Data()
                var errData = Data()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
                drainGroup.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: outData, as: UTF8.self))
                } else {
                    let msg = String(decoding: errData, as: UTF8.self)
                    continuation.resume(throwing: YTDLPError.processFailed(msg))
                }
            }
        }
    }
}
#endif
