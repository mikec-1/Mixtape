// AudioLocator.swift
// Mixtape — Core/Services
//
// The single answer to "can this song play right now, and if not, what has to
// happen first".
//
// Before this existed the question was asked in five places with five different
// orderings. `PlaybackEngine` asked one way, `DownloadManager` another,
// `SupabaseFileStorageService.localURL` a third, and the badge in the track list
// a fourth — so a song could be playable according to the engine, undownloadable
// according to the download manager, and unbadged in the list, all at once, all
// "correctly". Every symptom that looked like a race was really just two of
// these disagreeing.
//
// One order, one place, one set of reasons.

import Foundation

// MARK: - Location

/// Where a track's audio is, from the point of view of playing it *now*.
public enum AudioLocation: Sendable, Equatable {

    /// Bytes on disk. Play immediately — no network, no wait.
    case ready(URL, kind: ReadyKind)

    /// A Supabase Storage object that has to come down first.
    case remote(key: String)

    /// A Discover song that has to be resolved from the network first.
    case resolvable(sourceRef: String)

    /// No audio and no way to get any.
    case unavailable(UnavailableReason)

    public var readyURL: URL? {
        if case .ready(let url, _) = self { return url }
        return nil
    }

    /// True when playback needs the network before a single sample can be heard.
    public var requiresNetwork: Bool {
        switch self {
        case .ready:                    return false
        case .remote, .resolvable:      return true
        case .unavailable:              return false
        }
    }
}

/// Which copy answered — the difference matters for how much we trust it.
public enum ReadyKind: Sendable, Equatable {
    /// The offline store. Ours, deliberate, never evicted.
    case offlineDownload
    /// The user's own imported file. Often the only copy in existence.
    case importedFile
    /// The playback cache. Real, but the OS or the budget may reclaim it.
    case cached
    /// A file copy the user exported. Last resort only — they may rename,
    /// re-tag or move it at any time, so it never outranks an original.
    case exportedCopy
    /// A file in one of the user's watched folders, played where it lies.
    /// Mixtape has no copy of it and never writes to the folder it's in.
    case watchedFolder
}

/// Why a track can't play, in terms a person can act on.
public enum UnavailableReason: Sendable, Equatable {
    /// An imported track from another device that never finished uploading.
    case notUploadedYet
    /// An online track with no network to resolve it.
    case needsInternet
    /// Someone else's local file, arrived via a shared playlist, with too
    /// little metadata to even look the song up. Rare, and deliberately so:
    /// anything that knows its own title goes to the resolver instead.
    case sharedFromAnotherLibrary
    /// The file the library points at is gone.
    case fileMissing

    public func message(for title: String) -> String {
        switch self {
        case .notUploadedYet:
            return "\"\(title)\" hasn't been uploaded yet. Open Mixtape on your Mac to sync."
        case .needsInternet:
            return "\"\(title)\" needs an internet connection to play."
        case .sharedFromAnotherLibrary:
            return "Couldn't find any audio for \"\(title)\" — it came from someone else's library and isn't available to look up."
        case .fileMissing:
            return "Couldn't play \"\(title)\" — its audio file is missing from this device."
        }
    }
}

// MARK: - Locator

public enum AudioLocator {

    /// Where this track's audio is. Nonisolated and filesystem-only: no network,
    /// no main actor, safe to call from a scrolling list.
    ///
    /// The order is the whole point, so it's spelled out rather than clever:
    ///
    ///   1. **Offline download.** The user asked for this song to be here. It's
    ///      the one copy the app owns outright — it can't have been renamed or
    ///      purged behind our back — so it wins even over the original import.
    ///   2. **The user's own file**, for imported tracks.
    ///   3. **The playback cache**, for either kind.
    ///   4. **A fetch**, from Supabase or the resolver.
    ///   5. **An exported file copy**, and only then. It used to sit at position
    ///      two, which meant playback silently preferred a 128 kbps MP3 export
    ///      over the lossless original beside it, and "lost" the song whenever
    ///      the user tidied their Music folder.
    ///
    /// `ignoringOfflineStore` exists for one caller: re-downloading at a new
    /// quality. The offline copy is the thing being replaced, and it has already
    /// been encoded once — handing it back as the source would re-encode an
    /// encode, and could never *raise* quality no matter what the setting says.
    public static func locate(_ track: Track, ignoringOfflineStore: Bool = false) -> AudioLocation {
        if !ignoringOfflineStore, let offline = OfflineStorePaths.fileURL(for: track.id) {
            return .ready(offline, kind: .offlineDownload)
        }

        switch track.file.origin {
        case .imported:
            return locateImported(track)
        case .online:
            return locateOnline(track)
        case .unresolvableShare:
            // Not a dead end any more. The row has no file and never will, but
            // it knows what song it is, and that is all the resolver needs —
            // `locateOnline` returns `.resolvable` whenever there's a title to
            // search with, and only says "shared from another library" for a row
            // that can't even name itself. See `Track.sourceRef`.
            return locateOnline(track)
        case .localFile:
            return locateLocalFile(track)
        }
    }

    private static func locateImported(_ track: Track) -> AudioLocation {
        // The user's own file, wherever it has historically lived.
        if let url = AudioPaths.durableURL(forLocalPath: track.file.localPath) {
            return .ready(url, kind: .importedFile)
        }
        // A copy pulled down from the server on this device.
        if let cached = PlaybackCache.fileURL(forRemoteHash: track.file.fileHash) {
            return .ready(cached, kind: .cached)
        }
        // Any other shape of stored path (absolute, legacy) that still resolves.
        if let url = AudioPaths.resolve(localPath: track.file.localPath) {
            return .ready(url, kind: .cached)
        }
        if let remoteKey = track.file.remoteKey, !remoteKey.isEmpty {
            return .remote(key: remoteKey)
        }
        if let exported = ExportManager.shared.exportedURL(for: track) {
            return .ready(exported, kind: .exportedCopy)
        }
        // Nothing here and nothing on the server: this row was imported on
        // another device and its upload never finished.
        return .unavailable(track.file.fileSize > 0 ? .notUploadedYet : .fileMissing)
    }

    /// A watched-folder file has exactly one place to be: where the scan found
    /// it. There is no cache to fall back to and no server to ask — if the user
    /// has moved or deleted it, it is gone, and the next scan will drop the row.
    private static func locateLocalFile(_ track: Track) -> AudioLocation {
        let url = URL(fileURLWithPath: track.file.localPath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .unavailable(.fileMissing)
        }
        return .ready(url, kind: .watchedFolder)
    }

    private static func locateOnline(_ track: Track) -> AudioLocation {
        guard let ref = track.sourceRef else {
            return .unavailable(.sharedFromAnotherLibrary)
        }
        if let cached = PlaybackCache.fileURL(forSourceRef: ref) {
            return .ready(cached, kind: .cached)
        }
        return .resolvable(sourceRef: ref)
    }

    /// Convenience for the many callers that only want "is there a file".
    public static func readyURL(for track: Track) -> URL? {
        locate(track).readyURL
    }
}
