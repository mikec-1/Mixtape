// UserLyricsStore.swift
// Mixtape — Core/Services
//
// Lyrics the user wrote or supplied themselves.
//
// Every other source in `LyricsService` is a guess about a song: embedded tags
// someone else typed, a sidecar next to the file, two public databases. They
// are all best-effort, and for a lot of music — anything obscure, anything
// mistagged, anything not in English — all four come back empty or wrong. The
// only fix for that is the user, so this is where their answer goes, and it
// wins over all four.
//
// Identity: the content key, not the row id
//   `Track.id` is a fresh UUID for an imported file, so keying on it would lose
//   the lyrics on the next re-import of the same song — exactly the moment
//   someone would be most annoyed to lose them. The key is instead derived from
//   the normalised title and artist, the same way `OnlineTrack.stableTrackID`
//   is derived from "title|artist": a Discover copy, a downloaded copy and a
//   local file of one song all land on one key. Two genuinely different songs
//   that share a title *and* an artist would collide, which is a description of
//   the same song.
//
// Why a directory of files and not a table
//   Same reasoning as `OfflineStore`: the directory is the whole truth, so
//   there's no index to drift. One `.lrc` per song, named by its key, in
//   Application Support — durable, backed up (this is text the user typed, and
//   it is not re-downloadable), invisible in the library.
//
// Not synced. That's a deliberate limit, not an oversight: sending these to
// Supabase means a table and a web-client change, and the feature is useful on
// day one without it. See the note in `SpotifyFollowService` for the same call.

import Foundation
import Combine
import CryptoKit

@MainActor
public final class UserLyricsStore: ObservableObject {

    public static let shared = UserLyricsStore()

    /// `Application Support/Mixtape/Lyrics`, created on first use.
    public static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        let dir = base
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Cached directory listing, keyed by content key. Nil means "not read
    /// yet"; every mutation drops it so the next read goes back to disk.
    private var cachedKeys: Set<String>?

    private init() {
        // A wipe takes the songs with it, and lyrics with no song behind them
        // are orphans nothing can ever show again. Settings also offers this on
        // its own, so nobody has to delete their library to clear these.
        NotificationCenter.default.addObserver(
            forName: .mixUserDataReset, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard UserDataReset.from(note).clearedLibrary else { return }
                self?.removeAll()
            }
        }
    }

    // MARK: - Identity

    /// The storage key for a song: a hash of its normalised title and artist.
    ///
    /// Normalisation strips the things that differ between sources for one
    /// song and mean nothing about which song it is — a feature credit Deezer
    /// keeps out of the title and iTunes puts in, bracketed remaster notes,
    /// case, punctuation, runs of whitespace. See `mixtape-discover-identity`:
    /// two spellings of one song is the failure mode this exists to survive.
    public static func key(for track: Track) -> String {
        key(title: track.title, artistName: track.artistName)
    }

    public static func key(title: String, artistName: String) -> String {
        // The *credited* artist only. Guests move between the title and the
        // artist field depending on the source, so neither side of the pair can
        // be allowed to carry them.
        let artist = ImportService.creditedArtists(from: artistName).first ?? artistName
        let raw = "\(normalise(title))|\(normalise(artist))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// Lowercased, de-parenthesised, alphanumerics-and-single-spaces only.
    private nonisolated static func normalise(_ s: String) -> String {
        var text = s.lowercased()

        // Drop bracketed asides: "(feat. X)", "[Remastered 2011]", "(Live)".
        // These are the single biggest source of one song having two spellings.
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // An unbracketed trailing credit — "Song feat. X", "Song ft X".
        for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            if let range = text.range(of: marker) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }

        // Apostrophes are *removed*, not turned into separators: "Don't" and
        // "Dont" are one song, and a source that drops the mark (or uses a
        // curly one) must land on the same key as one that doesn't.
        text = text.filter { !"'\u{2019}\u{02BC}`".contains($0) }

        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Reads

    public func contains(_ track: Track) -> Bool { keys().contains(Self.key(for: track)) }

    /// The raw text the user supplied, or nil. `.lrc` or plain — the caller
    /// hands it to `LyricsService.parse`, which tells the two apart.
    public func text(for track: Track) -> String? {
        let key = Self.key(for: track)
        guard keys().contains(key) else { return nil }
        return try? String(contentsOf: url(for: key), encoding: .utf8)
    }

    public var count: Int { keys().count }

    /// Total bytes on disk, for the Settings row. Lyrics are kilobytes, so this
    /// stats a listing it already has and doesn't need to be kept off a body.
    public var totalBytes: Int64 {
        keys().reduce(into: Int64(0)) { total, key in
            let size = try? url(for: key).resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
    }

    // MARK: - Listing what's stored

    /// One stored set of lyrics, paired with the song (or songs) it belongs to.
    public struct Entry: Identifiable, Sendable {

        /// The filename key. The only thing that exists when no song matches.
        public let key: String

        /// Every library song that hashes to `key`, in library order.
        ///
        /// Plural on purpose. Normalisation folds "Song", "Song (Live)" and
        /// "Song (feat. X)" by one artist onto a single key, so one stored set
        /// can be the lyrics for several rows — and deleting it takes the
        /// lyrics off all of them. The list is here so the page can say so
        /// rather than quietly showing the first title and hiding the rest.
        public let tracks: [Track]

        public let bytes: Int64

        /// When the user last saved them, from the file. Nil if the file has
        /// gone missing between the listing and the stat.
        public let modified: Date?

        public var id: String { key }

        /// The song to name the row after, and to hand the editor.
        public var track: Track? { tracks.first }

        /// Lyrics whose song has left the library. Nothing can show them again,
        /// and there is no `Track` to edit them through — only a delete.
        public var isOrphaned: Bool { tracks.isEmpty }
    }

    /// Every stored set, matched back to the library.
    ///
    /// The key is a one-way hash, so there is no title stored anywhere to read
    /// back: the only way to name these songs is to re-derive the key for each
    /// track the library holds and see which ones land on a file. That is one
    /// hash per song, on opening a Settings sub-page, for a set that is a
    /// handful of entries — cheap enough to do plainly and not worth a cache
    /// that could go stale behind an edit.
    ///
    /// Deliberately no early exit once every key has been claimed: a later
    /// track can still be *another* match for a key already matched, and those
    /// duplicates are the whole reason `tracks` is a list.
    public func entries(in tracks: [Track]) -> [Entry] {
        let stored = keys()
        guard !stored.isEmpty else { return [] }

        var matches: [String: [Track]] = [:]
        for track in tracks {
            let key = Self.key(for: track)
            guard stored.contains(key) else { continue }
            matches[key, default: []].append(track)
        }

        let entries = stored.map { key -> Entry in
            let values = try? url(for: key).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Entry(key: key,
                         tracks: matches[key] ?? [],
                         bytes: Int64(values?.fileSize ?? 0),
                         modified: values?.contentModificationDate)
        }

        // Named songs first, alphabetically — the list reads as a list of
        // songs, and the ones with no song left to point at sit under their own
        // heading at the end rather than interrupting it.
        return entries.sorted { lhs, rhs in
            switch (lhs.track, rhs.track) {
            case let (l?, r?):
                let byTitle = l.title.localizedStandardCompare(r.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return l.artistName.localizedStandardCompare(r.artistName) == .orderedAscending
            case (nil, nil): return lhs.key < rhs.key
            case (_?, nil):  return true
            case (nil, _?):  return false
            }
        }
    }

    // MARK: - Writes

    /// Stores `text` as this song's lyrics. Empty (or whitespace-only) text
    /// removes the entry instead — "delete everything in the box and save" is
    /// the same wish as "remove these", and leaving a blank file behind would
    /// suppress the online lookup forever.
    public func set(_ text: String, for track: Track) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(for: track) }
        try? trimmed.write(to: url(for: Self.key(for: track)), atomically: true, encoding: .utf8)
        invalidate()
    }

    /// Drops this song's stored lyrics, so the normal lookup takes over again.
    public func remove(for track: Track) {
        let key = Self.key(for: track)
        guard keys().contains(key) else { return }
        try? FileManager.default.removeItem(at: url(for: key))
        invalidate()
    }

    /// Drops a stored set by its key. The only way to delete lyrics whose song
    /// has left the library — `remove(for:)` needs a `Track` to hash.
    public func remove(key: String) {
        guard keys().contains(key) else { return }
        try? FileManager.default.removeItem(at: url(for: key))
        invalidate()
    }

    /// Deletes every stored set. Only from an explicit Settings action, or a wipe.
    public func removeAll() {
        guard !keys().isEmpty else { return }
        for key in keys() {
            try? FileManager.default.removeItem(at: url(for: key))
        }
        invalidate()
    }

    // MARK: - Directory listing

    private func url(for key: String) -> URL {
        Self.directory.appendingPathComponent("\(key).lrc")
    }

    private func keys() -> Set<String> {
        if let cachedKeys { return cachedKeys }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        let built = Set(names.filter { $0.hasSuffix(".lrc") }
                             .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
        cachedKeys = built
        return built
    }

    private func invalidate() {
        cachedKeys = nil
        objectWillChange.send()
    }
}
