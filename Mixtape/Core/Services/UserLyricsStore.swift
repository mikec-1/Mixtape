// User-supplied lyrics. Wins over every other source in `LyricsService`.
// Keyed by normalised title and artist rather than `Track.id` (which changes on
// re-import), so Discover, downloaded and local copies share one entry.
// One `.lrc` per key in Application Support: backed up, no index to drift.
// Not synced.

import Foundation
import Combine
import CryptoKit
import Observation

@Observable
@MainActor
public final class UserLyricsStore {

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

    /// Cached directory listing. Nil means not read yet; mutations clear it.
    @ObservationIgnored private var cachedKeys: Set<String>?
    /// Bumped on every mutation so views reading the listing redraw.
    private var revision = 0

    private init() {
        // A wipe removes lyrics too; their songs are gone.
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

    /// Storage key: a hash of the normalised title and artist. Normalisation
    /// strips feature credits, bracketed notes, case and punctuation so different
    /// sources' spellings of one song match.
    public static func key(for track: Track) -> String {
        key(title: track.title, artistName: track.artistName)
    }

    public static func key(title: String, artistName: String) -> String {
        // Credited artist only; guests move between title and artist across sources.
        let artist = ImportService.creditedArtists(from: artistName).first ?? artistName
        let raw = "\(normalise(title))|\(normalise(artist))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// Lowercased, de-parenthesised, alphanumerics-and-single-spaces only.
    private nonisolated static func normalise(_ s: String) -> String {
        var text = s.lowercased()

        // Drop bracketed asides like "(feat. X)", "[Remastered 2011]", "(Live)".
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // Unbracketed trailing credits.
        for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            if let range = text.range(of: marker) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }

        // Apostrophes removed, not split on: "Don't" == "Dont".
        text = text.filter { !"'\u{2019}\u{02BC}`".contains($0) }

        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Reads

    public func contains(_ track: Track) -> Bool { keys().contains(Self.key(for: track)) }

    /// The raw text, `.lrc` or plain; `LyricsService.parse` handles both.
    public func text(for track: Track) -> String? {
        let key = Self.key(for: track)
        guard keys().contains(key) else { return nil }
        return try? String(contentsOf: url(for: key), encoding: .utf8)
    }

    public var count: Int { keys().count }

    /// Bytes on disk, for Settings.
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

        /// All library songs with this key. Normalisation can fold several versions
        /// onto one key, and deleting removes lyrics from all of them.
        public let tracks: [Track]

        public let bytes: Int64

        /// Last saved date. Nil if the file vanished.
        public let modified: Date?

        public var id: String { key }

        /// The song to name the row after, and to hand the editor.
        public var track: Track? { tracks.first }

        /// The song is gone; only a delete is possible.
        public var isOrphaned: Bool { tracks.isEmpty }
    }

    /// Every stored set, matched back to the library by re-hashing each track
    /// (the key is one-way). No early exit: later tracks can match an already matched key.
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

        // Named songs alphabetically, orphans last.
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

    /// Saves lyrics. Blank text removes the entry, since an empty file would
    /// suppress online lookups forever.
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

    /// Deletes by key, for orphans that have no `Track` to hash.
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
        _ = revision
        if let cachedKeys { return cachedKeys }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        let built = Set(names.filter { $0.hasSuffix(".lrc") }
                             .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
        cachedKeys = built
        return built
    }

    private func invalidate() {
        cachedKeys = nil
        revision += 1
    }
}
