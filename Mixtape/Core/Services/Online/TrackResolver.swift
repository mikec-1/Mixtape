// TrackResolver.swift
// Mixtape
//
// Platform seam for turning an OnlineTrack into a playable file. macOS shells out
// to yt-dlp (YTDLPService); iOS asks a remote resolver over HTTP since it can't
// fork-exec. Both return a file + YouTube video id, so the rest of the online
// flow is identical on either platform.

import Foundation

/// A resolved file plus the video id it came from (used as the cache key, so an
/// explicit and a clean upload of the same song stay separate).
public struct ResolvedAudio: Sendable {
    public let fileURL: URL
    public let videoID: String

    public init(fileURL: URL, videoID: String) {
        self.fileURL = fileURL
        self.videoID = videoID
    }
}

/// A URL the player can stream progressively, plus any auth headers and the video
/// id for the cache key. Resolvers that can't stream return nil from resolveStream.
public struct StreamResolution: Sendable {
    public let url: URL
    public let videoID: String
    public let headers: [String: String]

    public init(url: URL, videoID: String, headers: [String: String] = [:]) {
        self.url = url
        self.videoID = videoID
        self.headers = headers
    }
}

/// How far along a resolve is, for the one song the user is waiting on.
///
/// Deliberately coarse and deliberately optional. Only the local resolver can
/// see a byte count — the hosted one does the search *and* the download on the
/// server and answers once, so there is nothing to report from here but which
/// step is running. A `nil` fraction means exactly that, and the bar drawn from
/// it says "working" rather than inventing a number.
public struct ResolveProgress: Sendable, Equatable {

    public enum Phase: Sendable, Equatable {
        /// Working out which upload this song is.
        case searching
        /// Pulling the audio down.
        case downloading
        /// yt-dlp handing off to ffmpeg — the last few seconds of a download.
        case converting
    }

    public let phase: Phase
    /// 0…1 through `phase`, or nil when the resolver can't say.
    public let fraction: Double?

    public init(phase: Phase, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// Resolves a track query into a local audio file. Concrete type is picked per
/// platform in AppDependencies.
public protocol TrackResolver: Sendable {

    /// Resolve to a streamable URL without downloading the whole file. Returns nil
    /// when the resolver can't stream, so callers fall back to `download(...)`.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool) async throws -> StreamResolution?

    /// The same, refusing a set of uploads that have already been rejected.
    ///
    /// This is what "wrong version" means on the second press and after. One
    /// re-resolve can be answered by clearing the cache and searching again,
    /// because the cache was the only thing making the answer sticky. A second
    /// press cannot: the search is deterministic, so it returns the upload the
    /// user has just told us is wrong. Carrying the rejects into the search is
    /// the only way repeated presses walk through the alternatives instead of
    /// re-offering the first one.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>) async throws -> StreamResolution?

    /// The same again, told which upload this song resolved to last time.
    ///
    /// A resolver that can act on it skips its search, which is the larger half
    /// of a cold resolve. A resolver that can't is free to ignore it — the
    /// default below does exactly that, so the hosted resolver behaves as it
    /// always has until its server side learns the same trick.
    ///
    /// The caller withholds a pin the user has rejected; a resolver must not
    /// prefer the pin over `excluding`.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>,
                       pinnedVideoID: String?) async throws -> StreamResolution?

    /// Resolve to `<destinationDir>/<videoID>.m4a`. `expectedDuration` (0 = unknown)
    /// picks the upload whose runtime matches; `preferExplicit` favours uncensored.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool) async throws -> ResolvedAudio

    /// The same, refusing already-rejected uploads. See `resolveStream`.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  excluding: Set<String>) async throws -> ResolvedAudio

    /// Fetch one *named* video rather than searching for the best match — what a
    /// pasted YouTube link means. Search is the wrong tool here: the whole point
    /// of the link is that the user already chose, and the scorer that serves
    /// Discover so well would happily swap a live version for the studio one.
    ///
    /// `fallbackQuery` is for resolvers that can't honour an id (an older server
    /// on the other end of the HTTP seam). They search for it, which lands on
    /// the right song even when it can't land on the right upload.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL) async throws -> ResolvedAudio

    /// Same as `download(query:…)`, reporting progress as it goes.
    ///
    /// Separate from the plain form rather than an added parameter on it: only
    /// the song being waited for wants this, every prefetch and cache fill calls
    /// the quiet version, and a resolver that has no progress to report should
    /// not have to pretend otherwise.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio

    /// Same as `download(videoID:…)`, reporting progress as it goes.
    ///
    /// The pinned form needs its own reporter for the same reason the searched
    /// one does: it runs when a stream came back dead, which is exactly when
    /// somebody is sitting in front of a bar watching it, and the download it
    /// starts is the longest wait in the app.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio

    /// A URL this resolver handed out never produced audio — the player got a
    /// 403, or nothing ever buffered.
    ///
    /// Only the player finds this out: a stream URL is fetched by AVPlayer, not
    /// by the resolver, so a resolve that "succeeded" can still be a dead link
    /// and the resolver would never know. Told about it, a resolver can stop
    /// leading with whatever produced that URL for this video.
    func noteStreamUnplayable(videoID: String) async

    /// How many of this resolver's downloads may run at once.
    ///
    /// It belongs to the resolver, not to `DownloadManager`: locally, each
    /// download is a yt-dlp process plus an ffmpeg pass on the user's own Mac
    /// and the ceiling is that machine's cores; against the hosted resolver it
    /// is one small shared box, where the same number would be a self-inflicted
    /// denial of service.
    var suggestedDownloadConcurrency: Int { get }
}

public extension TrackResolver {

    /// Conservative default for a resolver that hasn't said.
    var suggestedDownloadConcurrency: Int { 3 }

    /// Default: no visibility into the work, so say which step is running and
    /// leave the fraction unknown.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .downloading, fraction: nil))
        return try await download(query: query,
                                  name: name,
                                  to: destinationDir,
                                  expectedDuration: expectedDuration,
                                  preferExplicit: preferExplicit)
    }

    /// Default: the video is already chosen, so there is no search to narrate —
    /// say the bytes are moving and leave the number to resolvers that can see one.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .downloading, fraction: nil))
        return try await download(videoID: videoID,
                                  fallbackQuery: fallbackQuery,
                                  name: name,
                                  to: destinationDir)
    }

    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool) async throws -> StreamResolution? { nil }

    /// Default: a resolver that can't honour exclusions answers as though there
    /// were none. Repeated re-resolves then behave as they did before — the
    /// same pick each time — rather than failing.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>) async throws -> StreamResolution? {
        try await resolveStream(query: query,
                                expectedDuration: expectedDuration,
                                preferExplicit: preferExplicit)
    }

    /// Default: ignore the pin and resolve exactly as before.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>,
                       pinnedVideoID: String?) async throws -> StreamResolution? {
        try await resolveStream(query: query,
                                expectedDuration: expectedDuration,
                                preferExplicit: preferExplicit,
                                excluding: excluding)
    }

    /// Default: narrate the two steps, and carry the exclusions into whichever
    /// `download` the resolver actually implements.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  excluding: Set<String>,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio {
        onProgress(ResolveProgress(phase: .searching, fraction: nil))
        return try await download(query: query,
                                  name: name,
                                  to: destinationDir,
                                  expectedDuration: expectedDuration,
                                  preferExplicit: preferExplicit,
                                  excluding: excluding)
    }

    /// Default: as above, for the download path.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  excluding: Set<String>) async throws -> ResolvedAudio {
        try await download(query: query,
                           name: name,
                           to: destinationDir,
                           expectedDuration: expectedDuration,
                           preferExplicit: preferExplicit)
    }

    /// Default: nothing to learn. A resolver that doesn't choose between sources
    /// has no choice to correct — the hosted one serves its own bytes, so a dead
    /// stream there is an outage rather than a wrong pick.
    func noteStreamUnplayable(videoID: String) async {}

    /// Default: no way to pin a video, so search for it like anything else.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL) async throws -> ResolvedAudio {
        try await download(query: fallbackQuery,
                           name: name,
                           to: destinationDir,
                           expectedDuration: 0,
                           preferExplicit: false)
    }
}

// MARK: - Preferences

/// Resolver-wide choices that aren't a property of the song being resolved.
///
/// Read straight out of `UserDefaults` rather than threaded through the
/// `TrackResolver` calls: it is the same answer for every track, and every one
/// of those signatures already carries five arguments. The hosted resolver
/// can't read this process's defaults, so `RemoteResolverService` sends it as a
/// query parameter instead.
public enum ResolverPreferences {

    private static let preferCensoredKey = "mixtape.resolver.preferCensored"

    /// Look for the clean version first and fall back to the explicit one.
    /// Off by default — the uncensored master is what the catalogue means by
    /// "the song".
    public static var preferCensored: Bool {
        get { UserDefaults.standard.bool(forKey: preferCensoredKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferCensoredKey) }
    }
}
