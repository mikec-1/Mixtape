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

/// Resolves a track query into a local audio file. Concrete type is picked per
/// platform in AppDependencies.
public protocol TrackResolver: Sendable {

    /// Resolve to a streamable URL without downloading the whole file. Returns nil
    /// when the resolver can't stream, so callers fall back to `download(...)`.
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool) async throws -> StreamResolution?

    /// Resolve to `<destinationDir>/<videoID>.m4a`. `expectedDuration` (0 = unknown)
    /// picks the upload whose runtime matches; `preferExplicit` favours uncensored.
    func download(query: String,
                  name: String,
                  to destinationDir: URL,
                  expectedDuration: TimeInterval,
                  preferExplicit: Bool) async throws -> ResolvedAudio
}

public extension TrackResolver {
    func resolveStream(query: String,
                       expectedDuration: TimeInterval,
                       preferExplicit: Bool) async throws -> StreamResolution? { nil }
}
