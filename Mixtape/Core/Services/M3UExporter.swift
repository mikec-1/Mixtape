// M3UExporter.swift
// Mixtape — Core/Services
//
// Generates a standard Extended M3U (#EXTM3U) playlist document from a Playlist
// and the Tracks that back its ordered trackIDs. Fully functional, cross-platform
// (iOS 17 / macOS 14). No UI is presented here — callers receive a String or write
// the document to a URL and decide how to share it.
//
// Format reference: https://en.wikipedia.org/wiki/M3U#Extended_M3U
//   #EXTM3U
//   #EXTINF:<duration-seconds>,<Artist> - <Title>
//   <file path or URI>

import Foundation

public enum M3UExporter {

    // MARK: - Document generation

    /// Builds an Extended M3U document for `playlist`, resolving each entry in
    /// `playlist.trackIDs` against the supplied `tracks`.
    ///
    /// - Parameters:
    ///   - playlist: The playlist whose ordered `trackIDs` define entry order.
    ///   - tracks:   The tracks available to resolve IDs. Order is irrelevant;
    ///               lookup is by `id`. Missing IDs are skipped.
    /// - Returns: A newline-terminated `#EXTM3U` document. Always valid even when
    ///   the playlist is empty (header only).
    public static func m3u(for playlist: Playlist, resolving tracks: [Track]) -> String {
        // Index tracks by id for O(1) lookup while preserving playlist order.
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var lines: [String] = ["#EXTM3U"]
        // A non-standard but widely-honoured hint that some players display.
        lines.append("#PLAYLIST:\(sanitizeLine(playlist.name))")

        for trackID in playlist.trackIDs {
            guard let track = byID[trackID] else { continue }

            // #EXTINF duration is an integer number of seconds; -1 if unknown.
            let seconds = track.duration > 0 ? Int(track.duration.rounded()) : -1
            let display = "\(sanitizeLine(track.artistName)) - \(sanitizeLine(track.title))"
            lines.append("#EXTINF:\(seconds),\(display)")

            // Path/URI line. Prefer the on-disk relative path when present; otherwise
            // fall back to a sanitized "Artist - Title.ext" filename so the document is
            // still meaningful when shared without the underlying files.
            lines.append(entryPath(for: track))
        }

        // Trailing newline — most parsers tolerate its absence, but it is conventional.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Writing / sharing

    /// Writes the generated M3U document to `url` (UTF-8, atomic).
    /// - Returns: the same `url` for convenience.
    @discardableResult
    public static func write(
        playlist: Playlist,
        resolving tracks: [Track],
        to url: URL
    ) throws -> URL {
        let document = m3u(for: playlist, resolving: tracks)
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes the playlist to a uniquely-named `.m3u8` file in the system temporary
    /// directory and returns its URL — suitable for feeding into a platform share
    /// sheet (UIActivityViewController / NSSharingServicePicker) at the call site.
    ///
    /// `.m3u8` is used as the extension because the document is UTF-8 encoded.
    public static func writeTemporaryFile(
        playlist: Playlist,
        resolving tracks: [Track]
    ) throws -> URL {
        let fileName = "\(safeFileName(playlist.name)).m3u8"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        return try write(playlist: playlist, resolving: tracks, to: url)
    }

    /// Convenience that returns the M3U document as a shareable `String`
    /// (e.g. to drop straight into a share sheet as text).
    public static func shareableText(
        playlist: Playlist,
        resolving tracks: [Track]
    ) -> String {
        m3u(for: playlist, resolving: tracks)
    }

    // MARK: - Private helpers

    /// Resolves the path/URI line for a track entry.
    private static func entryPath(for track: Track) -> String {
        let localPath = track.file.localPath
        if !localPath.isEmpty {
            // Resolve the relative path against the app's Documents directory and
            // emit a file URL so other players can locate it on this device.
            let url = URL.documentsDirectory.appending(path: localPath)
            return url.path
        }
        // No local file: emit a descriptive filename so the entry isn't blank.
        let ext = "mp3"
        return "\(safeFileName("\(track.artistName) - \(track.title)")).\(ext)"
    }

    /// Strips characters that would break a single M3U line (CR/LF).
    private static func sanitizeLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Produces a filesystem-safe name for use as a file component.
    private static func safeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|\u{0000}")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(80))
        return capped.isEmpty ? "Playlist" : capped
    }
}
