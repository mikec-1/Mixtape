// PlaybackErrorMessage.swift
// Mixtape
//
// Turns internal resolve/playback errors into something we can actually show the
// user. Keeps yt-dlp stderr and URLError codes out of the UI.

import Foundation

/// Map a thrown error to a short, friendly sentence, prefixed with the song it
/// is about.
///
/// The song name is not decoration. These messages appear in a bar that is not
/// attached to any row, so an unqualified "Couldn't find this song" leaves the
/// user guessing which of the songs on screen it means.
@MainActor
func userFacingPlaybackMessage(for error: Error, title: String) -> String {
    let body = userFacingPlaybackMessage(for: error)
    return title.isEmpty ? body : "\(title) — \(body)"
}

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
        case .busy:
            // Deliberately not "couldn't find this song": the song is fine, and
            // telling someone to try another version of a song the server simply
            // had no free slot for sends them looking for a problem that is not
            // there.
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

/// True when the resolver came back empty — nothing out there matches this song
/// — as opposed to a network, server or tooling failure, which says nothing
/// about the song at all and must never mark it unfindable.
@MainActor
func isSongNotFound(_ error: Error) -> Bool {
    #if os(macOS)
    if let ytdlp = error as? YTDLPError, case .noResult = ytdlp { return true }
    #else
    if let remote = error as? RemoteResolverError, case .badResponse = remote { return true }
    #endif
    return false
}
