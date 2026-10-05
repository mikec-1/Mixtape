// Decides where a song's audio is and what has to happen before it can play.
// Everything asks here so the engine, downloads and badges agree.

import Foundation

// MARK: - Location

/// Where a track's audio is, from the point of view of playing it *now*.
public enum AudioLocation: Sendable, Equatable {

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

public enum ReadyKind: Sendable, Equatable {
    /// The offline store. Ours, deliberate, never evicted.
    case offlineDownload
    /// The user's own imported file. Often the only copy in existence.
    case importedFile
    /// The playback cache. Real, but the OS or the budget may reclaim it.
    case cached
    /// A user export. Last resort, it may be moved or edited.
    case exportedCopy
    /// A watched-folder file, played in place.
    case watchedFolder
}

/// Why a track can't play, in terms a person can act on.
public enum UnavailableReason: Sendable, Equatable {
    /// An imported track from another device that never finished uploading.
    case notUploadedYet
    /// An online track with no network to resolve it.
    case needsInternet
    /// A shared song with too little metadata to look up.
    case sharedFromAnotherLibrary
    /// The file the library points at is gone.
    case fileMissing

    nonisolated public func message(for title: String) -> String {
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

    /// Filesystem only, safe from a scrolling list. Priority order:
    /// offline download, the user's file, playback cache, a fetch, an exported copy.
    /// ignoringOfflineStore is for re-downloading at a new quality.
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
            // Resolvable if it has a title, see Track.sourceRef.
            return locateOnline(track)
        case .localFile:
            return locateLocalFile(track)
        case .edit:
            if let url = AudioPaths.durableURL(forLocalPath: track.file.localPath) {
                return .ready(url, kind: .importedFile)
            }
            // Studio edits upload their file; quick ones rebuild from the recipe.
            if let cached = PlaybackCache.fileURL(forRemoteHash: track.file.fileHash) {
                return .ready(cached, kind: .cached)
            }
            if let remoteKey = track.file.remoteKey, !remoteKey.isEmpty {
                return .remote(key: remoteKey)
            }
            return .unavailable(.fileMissing)
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
        // Imported elsewhere and never uploaded.
        return .unavailable(track.file.fileSize > 0 ? .notUploadedYet : .fileMissing)
    }

    /// Only where the scan found it. No cache, no server.
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
