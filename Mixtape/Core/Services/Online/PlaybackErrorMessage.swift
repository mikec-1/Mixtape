// Turns resolve/playback errors into user-facing text. Keeps yt-dlp stderr
// and URLError codes out of the UI.

import Foundation

/// A short message for a thrown error, prefixed with the song's name since
/// the bar isn't attached to any row.
@MainActor
func userFacingPlaybackMessage(for error: Error, title: String) -> String {
    let body = userFacingPlaybackMessage(for: error)
    return title.isEmpty ? body : "\(title) — \(body)"
}

/// Map a thrown error to a short, friendly sentence.
@MainActor
func userFacingPlaybackMessage(for error: Error) -> String {
    // Offline first: a dropped connection shows up as URLError on any resolver.
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "You're offline. Connect to the internet to stream."
        case .cannotConnectToHost, .cannotFindHost, .timedOut,
             .dnsLookupFailed, .resourceUnavailable:
            return "Can't reach the streaming service. Try again in a moment."
        default:
            return "Can't reach the streaming service. Try again in a moment."
        }
    }

    #if os(iOS)
    if let remote = error as? RemoteResolverError {
        switch remote {
        case .notConfigured:
            return "Streaming isn't set up on this device yet. Add your resolver in Settings → Discover."
        case .badResponse:
            return "Couldn't find this song to stream. Try another version."
        case .busy:
            // Not "couldn't find this song": the server was just out of slots.
            return "The streaming server is busy. Try again in a moment."
        }
    }
    #endif

    #if os(macOS)
    if let ytdlp = error as? YTDLPError {
        switch ytdlp {
        case .noResult:
            return "Couldn't find this song to stream. Try another version."
        case .binaryMissing:
            return "Streaming tools are missing. Reinstall Mixtape to fix this."
        case .processFailed:
            return "Couldn't play this song right now. Please try again."
        }
    }
    #endif

    return "Couldn't play this song right now. Please try again."
}

/// True when the resolver found nothing. Network, server or tooling failures
/// say nothing about the song and never mark it unfindable.
@MainActor
func isSongNotFound(_ error: Error) -> Bool {
    #if os(macOS)
    if let ytdlp = error as? YTDLPError, case .noResult = ytdlp { return true }
    #else
    if let remote = error as? RemoteResolverError, case .badResponse = remote { return true }
    #endif
    return false
}
