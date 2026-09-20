// TrackOrigin.swift
// Mixtape — Core Domain Models
//
// Where a track's audio comes from. This used to be guessed from the shape of
// `FileProvenance` — an empty file size here, an "OnlineCache" substring there —
// and the guess stopped being true the moment a Discover song was saved with a
// real file behind it. Everything downstream (badges, download eligibility,
// error copy, cache accounting) was reading that guess, so all of it was wrong
// in the same way at the same time.
//
// It's stored now. A row says what it is.

import Foundation

/// Where a library row's audio comes from — and therefore who is responsible
/// for putting it on disk.
public enum TrackOrigin: String, Codable, Hashable, Sendable, CaseIterable {

    /// The user's own audio file. Imported from disk, uploaded to Supabase, and
    /// synced down to their other devices. The file is the point; it is always
    /// available once it has landed.
    case imported

    /// A song saved from Discover. The library row is *metadata only* — the
    /// audio is fetched on demand from `sourceRef`, cached for replay, and only
    /// stored permanently if the user explicitly downloads it for offline use.
    ///
    /// Mixtape never uploads this audio to the user's Supabase storage: it isn't
    /// theirs, it costs them quota, and it can always be resolved again.
    case online

    /// Metadata for a song this library can neither find nor resolve — minted by
    /// `LibraryService.importSharedTrack` from a collaborator's snapshot. It
    /// exists so a shared playlist reads correctly on a device that doesn't own
    /// the music, and it upgrades in place when the real track arrives.
    case unresolvableShare

    /// A file sitting in one of the user's watched folders.
    ///
    /// Mixtape does not hold a copy of this audio and never writes to the folder
    /// it lives in. Rows with this origin are *derived*: they are built by
    /// scanning the folders and thrown away on the next scan, never persisted.
    /// Delete the file and the song is gone; put it back and it returns.
    ///
    /// That is the whole point. A scanner that mints permanent library rows can
    /// resurrect songs the user deleted somewhere else — which is exactly what
    /// the old export-folder scan did. A derived view cannot.
    ///
    /// Nothing here syncs and nothing here uploads. To get a local file onto the
    /// phone or the web the user promotes it, which runs the ordinary import
    /// path and produces an honest `.imported` row.
    case localFile

    /// True when audio has to be fetched from the network before it can play.
    public var requiresResolution: Bool { self == .online }

    /// True when the audio is not Mixtape's to copy, upload, or sync — either
    /// because it belongs to a streaming source or because it is a file the user
    /// keeps somewhere of their own choosing.
    public var isOutsideLibraryStorage: Bool { self == .online || self == .localFile }
}
