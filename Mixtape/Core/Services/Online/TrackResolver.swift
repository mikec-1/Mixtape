// Platform seam for turning an OnlineTrack into playable audio. macOS runs
// yt-dlp locally, iOS asks the remote resolver. Both return a file + video id.

import Foundation

/// A resolved file plus its video id (the cache key, so clean and explicit
/// uploads stay separate).
public struct ResolvedAudio: Sendable {
    public let fileURL: URL
    public let videoID: String

    public init(fileURL: URL, videoID: String) {
        self.fileURL = fileURL
        self.videoID = videoID
    }
}

/// A progressively streamable URL, headers and video id. Nil from
/// `resolveStream` means the resolver can't stream.
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

/// Thrown by `resolveStream` when the search found a video but it can't be
/// streamed. The fallback download pins `videoID` instead of searching again.
public struct StreamUnavailable: Error {
    public let videoID: String
}

/// How far along a resolve is. Only the local resolver sees bytes, so a nil
/// fraction means "working".
public nonisolated struct ResolveProgress: Sendable, Equatable {

    public enum Phase: Sendable, Equatable {
        /// Working out which upload this song is.
        case searching
        /// Pulling the audio down.
        case downloading
        /// yt-dlp handed off to ffmpeg.
        case converting
    }

    public let phase: Phase
    /// 0...1 through `phase`, or nil when the resolver can't say.
    public let fraction: Double?

    public init(phase: Phase, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// Resolves a query to local audio. Concrete type chosen per platform in AppDependencies.
public protocol TrackResolver: Sendable {

    /// A streamable URL without downloading. Nil means fall back to `download(...)`.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool) async throws -> StreamResolution?

    /// Same, skipping uploads the user already rejected. The search is
    /// deterministic, so repeated "wrong version" presses only walk alternatives if
    /// the rejects go into the search.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>) async throws -> StreamResolution?

    /// Same, with the upload this song resolved to last time, so a resolver can
    /// skip its search. Resolvers may ignore it. Never prefer the pin over `excluding`.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>,
                       pinnedVideoID: String?) async throws -> StreamResolution?

    /// Same, for the song the user tapped. `live` lets a hosted resolver stream
    /// before it has the file. Only the play path asks: downloads need a real file.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>,
                       pinnedVideoID: String?,
                       live: Bool) async throws -> StreamResolution?

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

    /// Downloads one named video (a pasted link) instead of searching.
    /// `fallbackQuery` is for resolvers that can't take an id.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL) async throws -> ResolvedAudio

    /// `download(query:)` with progress. Only the song being waited on needs it.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio

    /// With exclusions too. A requirement so `any TrackResolver` reaches the
    /// resolver's own version, not the extension default. iOS keeps the default
    /// on purpose: it already forwards `excluding` to its own download.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool,
                  excluding: Set<String>,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio

    /// `download(videoID:)` with progress, used when a stream came back dead.
    func download(videoID: String,
                  fallbackQuery: String,
                  name: String,
                  to destinationDir: URL,
                  onProgress: @escaping @Sendable (ResolveProgress) -> Void) async throws -> ResolvedAudio

    /// A URL from this resolver never produced audio (403 or no buffering). Only
    /// the player can tell, so it reports back here.
    func noteStreamUnplayable(videoID: String) async

    /// Max concurrent downloads. Local means this Mac's cores; hosted means one
    /// shared server.
    var suggestedDownloadConcurrency: Int { get }
}

public extension TrackResolver {

    /// Conservative default for a resolver that hasn't said.
    var suggestedDownloadConcurrency: Int { 3 }

    /// Default: report the phase, fraction unknown.
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

    /// Default: no search, just "downloading".
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

    /// Default: ignore exclusions and resolve as before.
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

    /// Default: no live mode, resolve as before.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool,
                       excluding: Set<String>,
                       pinnedVideoID: String?,
                       live: Bool) async throws -> StreamResolution? {
        try await resolveStream(query: query,
                                expectedDuration: expectedDuration,
                                preferExplicit: preferExplicit,
                                excluding: excluding,
                                pinnedVideoID: pinnedVideoID)
    }

    /// Default: report both phases and pass exclusions through to `download`.
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

    /// Default: nothing to learn.
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

/// Resolver-wide preferences, read from UserDefaults. The hosted resolver gets
/// them as query parameters from `RemoteResolverService`.
public enum ResolverPreferences {

    private static let preferCensoredKey = "mixtape.resolver.preferCensored"

    /// Prefer the clean version, falling back to explicit. Off by default.
    public static var preferCensored: Bool {
        get { UserDefaults.standard.bool(forKey: preferCensoredKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferCensoredKey) }
    }
}
