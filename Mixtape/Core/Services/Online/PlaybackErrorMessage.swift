// PlaybackErrorMessage.swift
// Mixtape
//
// Turns internal resolve/playback errors into something we can actually show the
// user. Keeps yt-dlp stderr and URLError codes out of the UI.

import Foundation

/// Map a thrown error to a short, friendly sentence.
@MainActor
func userFacingPlaybackMessage(for error: Error) -> String {
    // Offline first — a dropped connection shows up as URLError no matter the resolver.
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
