// Builds an Extended M3U document for a playlist.

import Foundation

public enum M3UExporter {

    // MARK: - Document generation

    /// Entries follow playlist.trackIDs. Missing ids are skipped.
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

            // File path, else "Artist - Title.ext".
            lines.append(entryPath(for: track))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Writing / sharing

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

    /// Writes a temporary .m3u8 for a share sheet.
    public static func writeTemporaryFile(
        playlist: Playlist,
        resolving tracks: [Track]
    ) throws -> URL {
        let fileName = "\(safeFileName(playlist.name)).m3u8"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        return try write(playlist: playlist, resolving: tracks, to: url)
    }

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
            // Emit the real on-disk path so other players can locate it on this device.
            return AudioPaths.url(forLocalPath: localPath).path
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
