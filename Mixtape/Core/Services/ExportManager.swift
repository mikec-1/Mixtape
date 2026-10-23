// Manages the export directory via security-scoped bookmarks and exports tracks to it.
// ID3TagWriter lives here too.

import Foundation
import OSLog
import Combine
import Observation

// MARK: - ID3TagWriter
// Writes an ID3v2.3 tag to an MP3, replacing any existing one. Audio isn't re-encoded.
// Reference: https://id3.org/id3v2.3.0

private enum ID3TagWriter {

    static func write(
        to url: URL,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        artworkData: Data? = nil
    ) throws {
        let raw   = try Data(contentsOf: url)
        let audio = stripExistingTag(from: raw)

        var frames = Data()
        frames += textFrame("TIT2", value: title)
        frames += textFrame("TPE1", value: artist)
        if !album.isEmpty              { frames += textFrame("TALB", value: album)   }
        if let tn = trackNumber        { frames += textFrame("TRCK", value: "\(tn)") }
        if let yr = year               { frames += textFrame("TYER", value: "\(yr)") }
        if let gn = genre, !gn.isEmpty { frames += textFrame("TCON", value: gn)      }
        if let art = artworkData       { frames += apicFrame(imageData: art)          }

        // ID3v2.3 10-byte header: "ID3" + version 2.3 + flags=0 + syncsafe size
        var tag = Data("ID3".utf8)
        tag += [0x03, 0x00, 0x00]
        tag += syncsafeBytes(frames.count)
        tag += frames

        try (tag + audio).write(to: url, options: .atomic)
    }

    private static func stripExistingTag(from data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33  // "ID3"
        else { return data }

        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14)
                 | (Int(data[8]) <<  7) |  Int(data[9])
        let tagEnd = 10 + size
        guard tagEnd < data.count else { return data }
        return data[tagEnd...]
    }

    private static func syncsafeBytes(_ n: Int) -> [UInt8] {
        [ UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
          UInt8((n >>  7) & 0x7F), UInt8( n        & 0x7F) ]
    }

    private static func be32(_ n: Int) -> [UInt8] {
        [ UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
          UInt8((n >>  8) & 0xFF), UInt8( n        & 0xFF) ]
    }

    private static func textFrame(_ id: String, value: String) -> Data {
        guard !value.isEmpty,
              let idData    = id.data(using: .ascii),
              let valueData = value.data(using: .utf8) else { return Data() }
        var payload = Data([0x03])  // UTF-8 encoding flag
        payload += valueData
        var frame = idData
        frame += Data(be32(payload.count))
        frame += [0x00, 0x00]
        frame += payload
        return frame
    }

    private static func apicFrame(imageData: Data) -> Data {
        let mime = (imageData.count >= 3 &&
                    imageData[0] == 0xFF &&
                    imageData[1] == 0xD8 &&
                    imageData[2] == 0xFF) ? "image/jpeg" : "image/png"
        var payload = Data([0x03])
        payload += mime.data(using: .ascii)!
        payload += [0x00, 0x03, 0x00]  // null + front cover type + empty description
        payload += imageData
        var frame = "APIC".data(using: .ascii)!
        frame += Data(be32(payload.count))
        frame += [0x00, 0x00]
        frame += payload
        return frame
    }
}

@Observable
public final class ExportManager {
    
    public static let shared = ExportManager()
    
    public private(set) var exportURL: URL?
    
    public var currentUserID: String? = nil {
        didSet {
            loadExportURL()
        }
    }
    
    public var currentUsername: String? = nil

    /// Bumped by `setDidSkip`, so views reading `didSkip` see the defaults write.
    private var skipRevision = 0
    
    private var bookmarkKey: String {
        if let id = currentUserID {
            return "MixtapeExportDirectoryBookmark_\(id)"
        }
        return "MixtapeExportDirectoryBookmark"
    }

    private var configuredKey: String {
        if let id = currentUserID {
            return "MixtapeExportLocationConfigured_\(id)"
        }
        return "MixtapeExportLocationConfigured"
    }

    private var skipKey: String {
        if let id = currentUserID {
            return "didSkipExportPrompt_\(id)"
        }
        return "didSkipExportPrompt"
    }

    private var fallbackPathKey: String {
        return bookmarkKey + ".fallbackPath"
    }

    /// True once the user has confirmed a location that exists on disk. RootView uses it
    /// to skip the welcome prompt.
    public var isLocationConfigured: Bool {
        guard UserDefaults.standard.bool(forKey: configuredKey) else {
            return false
        }
        guard let resolved = try? resolveExportURL() else {
            return false
        }
        return FileManager.default.fileExists(atPath: resolved.path)
    }

    public var hasGlobalExportPath: Bool {
        if let path = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportPath"),
           !path.isEmpty {
            return FileManager.default.fileExists(atPath: path)
        }
        return false
    }

    /// The account that chose `MixtapeLastGlobalExportPath`, so the welcome prompt can offer it to the next one.
    public var globalExportPathOwner: String? {
        if let name = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportOwner"), !name.isEmpty {
            return name
        }
        // Older installs didn't record the owner: infer it from a single other-account subfolder.
        guard let path = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportPath"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        let mine = currentUsername.map(Self.sanitizeFileName)
        let others = names.filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && name != mine
                && FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDir)
                && isDir.boolValue
        }
        return others.count == 1 ? others[0] : nil
    }

    private var syncMetadataToDiskKey: String {
        if let id = currentUserID {
            return "mix.syncMetadataToDisk_\(id)"
        }
        return "mix.syncMetadataToDisk"
    }

    public var syncMetadataToDisk: Bool {
        UserDefaults.standard.object(forKey: syncMetadataToDiskKey) as? Bool ?? true
    }

    public var didSkip: Bool {
        _ = skipRevision
        return UserDefaults.standard.bool(forKey: skipKey)
    }

    public func setDidSkip(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: skipKey)
        skipRevision += 1
    }

    public var suggestedURL: URL {
        if let path = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportPath"),
           !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return Self.defaultExportURL
    }

    /// Display path for Settings: home-relative on macOS, last component on iOS.
    public var exportURLDisplayPath: String? {
        guard let url = exportURL else { return nil }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        #else
        return url.lastPathComponent
        #endif
    }

    /// Default export directory: ~/Documents/Mixtape on macOS, Documents root on iOS
    /// (Files already shows it as "On My iPhone > Mixtape").
    public static var defaultExportURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if os(iOS)
        return docs
        #else
        return docs.appendingPathComponent("Mixtape", isDirectory: true)
        #endif
    }
    
    private init() {
        loadExportURL()
    }

    public func loadExportURL() {
        guard let resolved = try? resolveExportURL() else {
            exportURL = nil
            return
        }

        // Bookmarks follow a folder into the Trash, where fileExists is still true.
        if Self.isInTrash(resolved) {
            clearExportURL()
            return
        }

        if FileManager.default.fileExists(atPath: resolved.path) {
            exportURL = resolved
            return
        }

        // Previously-chosen folder no longer exists.
        #if os(iOS)
        // Documents is always writable on iOS, so reset silently.
        exportURL = try? setDefaultMixtapeFolder()
        #else
        // The macOS sandbox can't create the folder without NSOpenPanel, so clear it and let
        // the welcome prompt ask again.
        clearExportURL()
        #endif
    }
    
    // MARK: - Bookmarks
    
    public func setExportURL(_ url: URL) throws {
        // Start access to ensure we can create a bookmark
        let startAccess = url.startAccessingSecurityScopedResource()
        defer { if startAccess { url.stopAccessingSecurityScopedResource() } }

        // Save globally as the last selected location for account switching suggestion
        UserDefaults.standard.set(url.path, forKey: "MixtapeLastGlobalExportPath")
        UserDefaults.standard.set(currentUsername, forKey: "MixtapeLastGlobalExportOwner")

        // Plain-path fallback so resolveExportURL() works if the bookmark goes stale.
        UserDefaults.standard.set(url.path, forKey: fallbackPathKey)

        do {
            #if os(macOS)
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }

        // Stops the welcome prompt reappearing even if the bookmark fails next launch.
        UserDefaults.standard.set(true, forKey: configuredKey)

        self.exportURL = url
    }
    
    public func resolveExportURL() throws -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            do {
                #if os(macOS)
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                #else
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                #endif
                if isStale {
                    try? setExportURL(url)
                }
                return url
            } catch {
                // Ignore resolve error and fall back to path
                MixLog.exporting.error("[ExportManager] Bookmark resolution failed: \(error)")
            }
        }
        
        if let path = UserDefaults.standard.string(forKey: fallbackPathKey) {
            return URL(fileURLWithPath: path)
        }
        
        return nil
    }
    
    public func clearExportURL() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: fallbackPathKey)
        UserDefaults.standard.removeObject(forKey: configuredKey)
        self.exportURL = nil
    }

    public func useSuggestedLocation() throws {
        let url = suggestedURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try setExportURL(url)
    }

    /// Creates ~/Documents/Mixtape if needed, then saves it as the export location.
    @discardableResult
    public func setDefaultMixtapeFolder() throws -> URL {
        let url = ExportManager.defaultExportURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try setExportURL(url)
        return url
    }
    
    // MARK: - Export

    /// Exports a track's audio to the export directory at `quality`, with title, artist,
    /// album, artwork and year written into the copy.
    /// - Parameter from: explicit source URL, e.g. a just-downloaded file whose `localPath`
    /// isn't updated yet. Defaults to `track.file.localPath`.
    /// - Parameter quality: `.high` copies bytes as-is; `.normal`/`.low` re-encode to AAC at 96/64 kbps.
    public func export(track: Track,
                       from explicitSource: URL? = nil,
                       quality: DownloadQuality = .high) async throws {
        let signpost = MixSignpost.exporting.beginInterval("export-track",
                                                           id: MixSignpost.exporting.makeSignpostID())
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MixSignpost.exporting.endInterval("export-track", signpost)
            MixLog.exporting.info("export-track \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000), privacy: .public) ms")
        }
        // Prefer the resolved URL, else re-resolve from UserDefaults.
        let destDir: URL
        if let existing = exportURL {
            destDir = existing
        } else if let resolved = try resolveExportURL() {
            destDir = resolved
        } else {
            throw NSError(domain: "ExportManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No export location set. Open Settings to choose a folder."])
        }

        let startAccess = destDir.startAccessingSecurityScopedResource()
        defer { if startAccess { destDir.stopAccessingSecurityScopedResource() } }

        // Recreate the folder if it was deleted, else fall back to ~/Documents/Mixtape.
        let activeDestDir: URL
        if Self.isInTrash(destDir) {
            // Trashed after resolving: clear it so the next save asks for a folder.
            clearExportURL()
            throw NSError(domain: "ExportManager", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The download folder is in the Trash. Please choose a new location."])
        } else if FileManager.default.fileExists(atPath: destDir.path) {
            activeDestDir = destDir
        } else {
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                activeDestDir = destDir
            } catch {
                let fallback = ExportManager.defaultExportURL
                try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                try? setExportURL(fallback)
                activeDestDir = fallback
            }
        }

        // Per-account subfolder when signed in.
        var finalDestDir = activeDestDir
        if let username = currentUsername, !username.isEmpty {
            let sanitizedUsername = Self.sanitizeFileName(username)
            finalDestDir = activeDestDir.appendingPathComponent(sanitizedUsername, isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: finalDestDir.path) {
            try FileManager.default.createDirectory(at: finalDestDir, withIntermediateDirectories: true)
        }

        // Prefer an explicit source URL, else the track's recorded path.
        let sourceURL: URL
        if let explicit = explicitSource {
            guard FileManager.default.fileExists(atPath: explicit.path) else {
                throw NSError(domain: "ExportManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Track file not found at the provided path."])
            }
            sourceURL = explicit
        } else {
            guard !track.file.localPath.isEmpty else {
                throw NSError(domain: "ExportManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Track file not downloaded locally yet."])
            }
            guard let pathURL = AudioPaths.resolve(localPath: track.file.localPath) else {
                throw NSError(domain: "ExportManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Track file not downloaded locally yet."])
            }
            sourceURL = pathURL
        }

        let sourceExt    = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let safeTitle    = Self.sanitizeFileName(track.title)
        let safeArtist   = Self.sanitizeFileName(track.artistName)
        let baseName     = "\(safeArtist) - \(safeTitle)"

        // Re-encoding is what the lower two settings *are*, so it follows the
        // setting and nothing else. High keeps the container it arrived in.
        let willReencode = quality.bitRate != nil
        let outExt       = willReencode ? "m4a" : sourceExt

        // Avoid silently overwriting an existing export; append a counter instead.
        var destinationURL = finalDestDir.appendingPathComponent("\(baseName).\(outExt)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = finalDestDir.appendingPathComponent("\(baseName) (\(counter)).\(outExt)")
            counter += 1
        }

        if willReencode {
            do {
                try await AudioTranscoder.transcode(sourceURL, to: destinationURL, quality: quality)
            } catch {
                // A failed re-encode files the original instead.
                try? FileManager.default.removeItem(at: destinationURL)
                destinationURL = finalDestDir.appendingPathComponent("\(baseName).\(sourceExt)")
                var retry = 2
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    destinationURL = finalDestDir.appendingPathComponent("\(baseName) (\(retry)).\(sourceExt)")
                    retry += 1
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        // Metadata by container. Non-fatal: the audio is already saved.
        if destinationURL.pathExtension.lowercased() == "mp3" {
            try? ID3TagWriter.write(
                to:          destinationURL,
                title:       track.title,
                artist:      track.artistName,
                album:       track.albumTitle,
                trackNumber: track.trackNumber,
                year:        track.year,
                genre:       track.genre,
                artworkData: track.artworkData
            )
        } else if MP4MetadataWriter.supports(destinationURL) {
            try? await MP4MetadataWriter.write(track, to: destinationURL)
        } else {
            // FLAC/Opus/WAV at High keep their container and existing tags.
            MixLog.exporting.debug("No tagger for .\(destinationURL.pathExtension.lowercased()), copied without rewriting metadata")
        }

        rememberExport(destinationURL, for: track.id)
    }

    // MARK: - Export index

    /// Where each track's copy went, keyed by track id. Recorded at export time instead of
    /// guessing filenames, which broke on renames and duplicates.
    private static let exportIndexKey = "mix.exportedPaths"

    private var exportIndex: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.exportIndexKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.exportIndexKey) }
    }

    private func rememberExport(_ url: URL, for trackID: UUID) {
        var index = exportIndex
        index[trackID.uuidString] = url.path
        exportIndex = index
    }

    private func forgetExport(for trackID: UUID) {
        var index = exportIndex
        index.removeValue(forKey: trackID.uuidString)
        exportIndex = index
    }

    public func exportedURL(for track: Track) -> URL? {
        // Recorded but deleted or moved, drop it.
        if let path = exportIndex[track.id.uuidString], !FileManager.default.fileExists(atPath: path) {
            forgetExport(for: track.id)
        }
        return Self.exportedURL(for: track, in: lookup())
    }

    /// What `exportedURL` needs from the manager, captured on the main actor so the library
    /// scan can run in the background.
    nonisolated struct Lookup: Sendable {
        let index: [String: String]
        let root: URL?
        let userFolder: String?
    }

    func lookup() -> Lookup {
        let username = currentUsername.flatMap { $0.isEmpty ? nil : Self.sanitizeFileName($0) }
        return Lookup(index: exportIndex,
                      root: exportURL ?? (try? resolveExportURL()),
                      userFolder: username)
    }

    nonisolated static func exportedURL(for track: Track, in lookup: Lookup) -> URL? {
        // Recorded path first. A miss falls through to probing, for copies exported before the index.
        if let path = lookup.index[track.id.uuidString], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let destDir = lookup.root else { return nil }

        let startAccess = destDir.startAccessingSecurityScopedResource()
        defer { if startAccess { destDir.stopAccessingSecurityScopedResource() } }

        var finalDestDir = destDir
        if let userFolder = lookup.userFolder {
            finalDestDir = destDir.appendingPathComponent(userFolder, isDirectory: true)
        }

        // Source extension first, plus mp3 and m4a since older exports were transcoded to .mp3.
        var extensions: [String] = []
        if let remoteKey = track.file.remoteKey, !remoteKey.isEmpty {
            extensions.append(URL(fileURLWithPath: remoteKey).pathExtension.lowercased())
        }
        for fallback in ["mp3", "m4a"] where !extensions.contains(fallback) {
            extensions.append(fallback)
        }
        
        let safeTitle = Self.sanitizeFileName(track.title)
        let safeArtist = Self.sanitizeFileName(track.artistName)
        let baseName = "\(safeArtist) - \(safeTitle)"

        for ext in extensions {
            let fileURL = finalDestDir.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }

            for counter in 2...10 {
                let potentialURL = finalDestDir.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
                if FileManager.default.fileExists(atPath: potentialURL.path) {
                    return potentialURL
                }
            }
        }

        return nil
    }

    public func deleteExportedFile(for track: Track) {
        if let fileURL = exportedURL(for: track) {
            let destDir: URL
            if let existing = exportURL {
                destDir = existing
            } else if let resolved = try? resolveExportURL() {
                destDir = resolved
            } else {
                return
            }

            let startAccess = destDir.startAccessingSecurityScopedResource()
            defer { if startAccess { destDir.stopAccessingSecurityScopedResource() } }

            try? FileManager.default.removeItem(at: fileURL)
            forgetExport(for: track.id)
        }
    }

    public func updateMetadataOnDisk(for track: Track, oldArtist: String, oldTitle: String) {
        let destDir: URL
        if let existing = exportURL {
            destDir = existing
        } else if let resolved = try? resolveExportURL() {
            destDir = resolved
        } else {
            return
        }

        let startAccess = destDir.startAccessingSecurityScopedResource()
        defer { if startAccess { destDir.stopAccessingSecurityScopedResource() } }

        var finalDestDir = destDir
        if let username = currentUsername, !username.isEmpty {
            let sanitizedUsername = Self.sanitizeFileName(username)
            finalDestDir = destDir.appendingPathComponent(sanitizedUsername, isDirectory: true)
        }

        // Same extension candidates as exportedURL.
        var candidateExts: [String] = []
        if let key = track.file.remoteKey, !key.isEmpty {
            candidateExts.append(URL(fileURLWithPath: key).pathExtension.lowercased())
        }
        for fallback in ["mp3", "m4a"] where !candidateExts.contains(fallback) {
            candidateExts.append(fallback)
        }
        let safeOldTitle = Self.sanitizeFileName(oldTitle)
        let safeOldArtist = Self.sanitizeFileName(oldArtist)
        let oldBaseName = "\(safeOldArtist) - \(safeOldTitle)"

        guard let (oldFileURL, ext) = candidateExts
            .map({ (finalDestDir.appendingPathComponent("\(oldBaseName).\($0)"), $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.0.path) })
        else { return }

        let safeNewTitle = Self.sanitizeFileName(track.title)
        let safeNewArtist = Self.sanitizeFileName(track.artistName)
        let newBaseName = "\(safeNewArtist) - \(safeNewTitle)"
        
        var newFileURL = finalDestDir.appendingPathComponent("\(newBaseName).\(ext)")
        
        if newFileURL.path != oldFileURL.path && FileManager.default.fileExists(atPath: newFileURL.path) {
            var counter = 2
            while FileManager.default.fileExists(atPath: newFileURL.path) {
                newFileURL = finalDestDir.appendingPathComponent("\(newBaseName) (\(counter)).\(ext)")
                counter += 1
            }
        }

        do {
            if newFileURL.path != oldFileURL.path {
                try FileManager.default.moveItem(at: oldFileURL, to: newFileURL)
            }
            // Renames are exactly what the index has to learn.
            rememberExport(newFileURL, for: track.id)

            // ID3 is MP3-only; prepending it to an .m4a corrupts the `ftyp` atom.
            if ext == "mp3" {
                try ID3TagWriter.write(
                    to:          newFileURL,
                    title:       track.title,
                    artist:      track.artistName,
                    album:       track.albumTitle,
                    trackNumber: track.trackNumber,
                    year:        track.year,
                    genre:       track.genre,
                    artworkData: track.artworkData
                )
            }
        } catch {
            MixLog.exporting.error("[ExportManager] Failed to update file metadata on disk: \(error)")
        }
    }

    // MARK: - Private helpers

    /// True if `url` is inside the Trash or Recently Deleted. Bookmarks follow a trashed
    /// folder and `fileExists` stays true, so this has to be checked explicitly.
    private static func isInTrash(_ url: URL) -> Bool {
        #if os(macOS)
        // macOS boot-volume Trash: ~/.Trash  External drives: /Volumes/<n>/.Trashes/<uid>
        let path = url.path
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
        return path.hasPrefix(homeTrash) || path.contains("/.Trashes/")
        #else
        // Files app "Recently Deleted" lives under a /.Trash component.
        return url.path.contains("/.Trash")
        #endif
    }

    /// Replaces characters illegal in filenames with hyphens and trims whitespace/dots.
    nonisolated public static func sanitizeFileName(_ name: String) -> String {
        // ':' is allowed by APFS but gives "invalid name" errors on iOS.
        let illegal = "/:\\*?\"<>|\u{0000}"
        var result = name
        for ch in illegal {
            result = result.replacingOccurrences(of: String(ch), with: "-")
        }
        // Collapse "---" into "-".
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ".-")))
        // Cap at 80 chars per component so the full filename stays well under 255 bytes.
        result = String(result.prefix(80))
        return result.isEmpty ? "Unknown" : result
    }
}
