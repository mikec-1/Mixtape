// ExportManager.swift
// Mixtape — Core/Services
//
// Manages the user's chosen export/download directory using Security-Scoped Bookmarks.
// Allows exporting a Track's local audio file to the chosen directory.
// ID3TagWriter (below) is kept in this file to avoid needing a separate Xcode target entry.

import Foundation
import OSLog
import Combine

// MARK: - ID3TagWriter
// Writes an ID3v2.3 tag to an MP3 file, replacing any pre-existing tag.
// The audio payload is never re-encoded; only the metadata header is rebuilt.
// Frame layout reference: https://id3.org/id3v2.3.0

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
        payload += [0x00, 0x03, 0x00]   // null + Cover(front) type + empty description null
        payload += imageData
        var frame = "APIC".data(using: .ascii)!
        frame += Data(be32(payload.count))
        frame += [0x00, 0x00]
        frame += payload
        return frame
    }
}

public final class ExportManager: ObservableObject {
    
    public static let shared = ExportManager()
    
    @Published public private(set) var exportURL: URL?
    
    public var currentUserID: String? = nil {
        didSet {
            objectWillChange.send()
            loadExportURL()
        }
    }
    
    public var currentUsername: String? = nil {
        didSet {
            objectWillChange.send()
        }
    }
    
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

    /// True once the user has confirmed a location (even if the bookmark later fails to resolve),
    /// and that location exists on disk.
    /// Used by RootView to suppress the welcome prompt on subsequent launches.
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

    /// The account that chose `MixtapeLastGlobalExportPath` — the welcome prompt
    /// offers that folder to the *next* account, so it has to name the previous one.
    public var globalExportPathOwner: String? {
        if let name = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportOwner"), !name.isEmpty {
            return name
        }
        // Chosen before the owner was recorded: the per-account subfolders say
        // whose it was, when there is exactly one that isn't the current account.
        guard let path = UserDefaults.standard.string(forKey: "MixtapeLastGlobalExportPath"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        let mine = currentUsername.map(sanitizeFileName)
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
        UserDefaults.standard.bool(forKey: skipKey)
    }

    public func setDidSkip(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: skipKey)
        objectWillChange.send()
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

    /// Human-readable path for the current export location, suitable for display in Settings.
    /// - macOS: `~/Documents/Mixtape` style (home-relative, full path visible)
    /// - iOS:   last path component only
    public var exportURLDisplayPath: String? {
        guard let url = exportURL else { return nil }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        #else
        return url.lastPathComponent
        #endif
    }

    /// The default export directory.
    /// - macOS: ~/Documents/Mixtape (a named subfolder the user can find in Finder)
    /// - iOS: the app's Documents root, which the Files app already shows as
    ///   "On My iPhone › Mixtape". Adding a "Mixtape" subfolder would display
    ///   "On My iPhone › Mixtape › Mixtape", so we avoid the extra component.
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

        // Security-scoped bookmarks track moves, so a folder sent to Trash resolves
        // to its new Trash path and fileExists returns true — catch it explicitly.
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
        // The app's Documents dir is always writable on iOS — silently reset.
        exportURL = try? setDefaultMixtapeFolder()
        #else
        // On macOS the sandbox blocks creating ~/Documents/Mixtape without user
        // consent via NSOpenPanel. Clear the stored location so the welcome prompt
        // reappears and the user can pick a new folder themselves.
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

        // Always persist the plain path as a fallback so resolveExportURL() never
        // returns nil just because the security-scoped bookmark failed or went stale.
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
            // Bookmark failed — plain-path fallback already saved above.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }

        // Mark that the user has confirmed a location so the welcome prompt
        // never reappears, even if the bookmark fails to resolve next launch.
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
                print("[ExportManager] Bookmark resolution failed: \(error)")
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

    /// Exports a track's audio to the chosen export directory, at `quality`, with
    /// its metadata (title, artist, album, artwork, year) written into the copy.
    ///
    /// - Parameter from: Optional explicit source URL. When omitted the source is
    ///   derived from `track.file.localPath` inside the app's Documents folder.
    ///   Pass the URL returned by `SupabaseFileStorageService.download(track:)` when
    ///   you have just fetched the file and the track's `localPath` isn't updated yet.
    /// - Parameter quality: The Downloads setting. `.high` copies the bytes as they
    ///   arrived; `.normal`/`.low` re-encode to AAC at 96/64 kbps.
    ///
    /// What this deliberately no longer does is transcode every non-MP3 source to
    /// MP3. That was here to get artwork and titles showing in Finder, and it
    /// worked — at the cost of a lossy re-encode on every single Discover song,
    /// including when the user had asked for High. `MP4MetadataWriter` gets the
    /// same result by rewriting the container's metadata atoms instead.
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
        // Prefer the already-resolved in-memory URL; fall back to re-resolving from
        // UserDefaults (handles cases where exportURL wasn't set in this process).
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

        // Ensure the destination directory is valid (not trashed, exists, writable).
        // If it was deleted since launch, try to recreate it at the original path.
        // If that also fails (e.g. the volume was removed), fall back to the default
        // ~/Documents/Mixtape folder and update the stored location.
        let activeDestDir: URL
        if Self.isInTrash(destDir) {
            // Folder was trashed after we resolved the bookmark — clear it so the
            // next "Save to Disk" triggers the folder picker rather than writing to Trash.
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

        // Create a user-specific subfolder if logged in to prevent mixing songs from different accounts
        var finalDestDir = activeDestDir
        if let username = currentUsername, !username.isEmpty {
            let sanitizedUsername = sanitizeFileName(username)
            finalDestDir = activeDestDir.appendingPathComponent(sanitizedUsername, isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: finalDestDir.path) {
            try FileManager.default.createDirectory(at: finalDestDir, withIntermediateDirectories: true)
        }

        // Resolve source: prefer an explicitly supplied URL (e.g. freshly downloaded),
        // otherwise fall back to the path recorded on the track.
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
        let safeTitle    = sanitizeFileName(track.title)
        let safeArtist   = sanitizeFileName(track.artistName)
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
                // A failed re-encode means "file the original", not "the save
                // failed" — the user asked for a copy of their song, and a
                // bigger copy is a far better answer than none.
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

        // Metadata, by container. Errors are non-fatal — the audio is already
        // saved, and a copy with no cover art still beats no copy.
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
            // FLAC/Opus/WAV imports kept at High keep their original container,
            // and there's no tagger here for those. The copy is correct audio
            // with whatever tags it already carried.
            print("[Export] No tagger for .\(destinationURL.pathExtension.lowercased()) — copied without rewriting metadata")
        }

        rememberExport(destinationURL, for: track.id)
    }

    // MARK: - Export index

    /// Where each track's file copy actually went, keyed by track id.
    ///
    /// `exportedURL` used to reconstruct this by guessing: rebuild the filename
    /// from the current title and artist, guess the extension, then try ten
    /// numbered variants of each. It got the answer wrong in every case the
    /// guess didn't hold — a renamed song, a file the user renamed themselves,
    /// an eleventh duplicate — and "wrong" here means the app believes a copy
    /// it did make doesn't exist. Writing down the path at the moment we choose
    /// it costs one dictionary entry and is simply correct.
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
        // The recorded path first. A miss falls through to the probe below,
        // which is what finds copies exported before this index existed.
        if let path = exportIndex[track.id.uuidString] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            // Recorded but gone — the user deleted or moved it. Drop the entry
            // so it stops being consulted.
            forgetExport(for: track.id)
        }

        let destDir: URL
        if let existing = exportURL {
            destDir = existing
        } else if let resolved = try? resolveExportURL() {
            destDir = resolved
        } else {
            return nil
        }

        let startAccess = destDir.startAccessingSecurityScopedResource()
        defer { if startAccess { destDir.stopAccessingSecurityScopedResource() } }

        var finalDestDir = destDir
        if let username = currentUsername, !username.isEmpty {
            let sanitizedUsername = sanitizeFileName(username)
            finalDestDir = destDir.appendingPathComponent(sanitizedUsername, isDirectory: true)
        }

        // Candidate extensions: the source's own extension first, but ALWAYS
        // also mp3 and m4a — export() transcodes non-mp3 sources to .mp3 on
        // macOS, so an .m4a-sourced track's exported copy is a .mp3 and a
        // remoteKey-only lookup would never find it.
        var extensions: [String] = []
        if let remoteKey = track.file.remoteKey, !remoteKey.isEmpty {
            extensions.append(URL(fileURLWithPath: remoteKey).pathExtension.lowercased())
        }
        for fallback in ["mp3", "m4a"] where !extensions.contains(fallback) {
            extensions.append(fallback)
        }
        
        let safeTitle = sanitizeFileName(track.title)
        let safeArtist = sanitizeFileName(track.artistName)
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
            let sanitizedUsername = sanitizeFileName(username)
            finalDestDir = destDir.appendingPathComponent(sanitizedUsername, isDirectory: true)
        }

        // Probe the same extension candidates as exportedURL — the exported copy
        // may be a transcoded .mp3 even when the source/remoteKey is .m4a.
        var candidateExts: [String] = []
        if let key = track.file.remoteKey, !key.isEmpty {
            candidateExts.append(URL(fileURLWithPath: key).pathExtension.lowercased())
        }
        for fallback in ["mp3", "m4a"] where !candidateExts.contains(fallback) {
            candidateExts.append(fallback)
        }
        let safeOldTitle = sanitizeFileName(oldTitle)
        let safeOldArtist = sanitizeFileName(oldArtist)
        let oldBaseName = "\(safeOldArtist) - \(safeOldTitle)"

        guard let (oldFileURL, ext) = candidateExts
            .map({ (finalDestDir.appendingPathComponent("\(oldBaseName).\($0)"), $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.0.path) })
        else { return }

        let safeNewTitle = sanitizeFileName(track.title)
        let safeNewArtist = sanitizeFileName(track.artistName)
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
            // The rename is exactly the case the old filename-guessing lookup
            // got wrong, so the index has to learn the new path.
            rememberExport(newFileURL, for: track.id)

            // ID3 is an MP3-container construct — prepending a tag onto an
            // .m4a pushes bytes ahead of the MP4 `ftyp` atom and corrupts it
            // (see export()). Only rewrite tags for real MP3s; other formats
            // just get the rename above.
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
            print("[ExportManager] Failed to update file metadata on disk: \(error)")
        }
    }

    // MARK: - Private helpers

    /// Returns `true` if `url` lies inside the platform Trash / Recently Deleted folder.
    /// Security-scoped bookmarks silently track moves, so a bookmarked folder that is
    /// trashed resolves to its new Trash path — `fileExists` returns true there, so we
    /// must detect it explicitly before treating the folder as a valid export destination.
    private static func isInTrash(_ url: URL) -> Bool {
        #if os(macOS)
        // macOS boot-volume Trash: ~/.Trash  External drives: /Volumes/<n>/.Trashes/<uid>
        let path = url.path
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
        return path.hasPrefix(homeTrash) || path.contains("/.Trashes/")
        #else
        // iOS/iPadOS: Files app "Recently Deleted" items live under a /.Trash component
        // within the originating file provider's storage tree.
        return url.path.contains("/.Trash")
        #endif
    }

    /// Strips characters that are illegal in filenames on HFS+/APFS (iOS & macOS).
    /// Replaces them with hyphens and trims surrounding whitespace/dots.
    public func sanitizeFileName(_ name: String) -> String {
        // Characters disallowed in HFS+/APFS filenames.
        // '/' is the path separator; ':' is the legacy Mac resource-fork separator
        // and causes "invalid name" errors on iOS even though APFS technically allows it.
        let illegal = "/:\\*?\"<>|\u{0000}"
        var result = name
        for ch in illegal {
            result = result.replacingOccurrences(of: String(ch), with: "-")
        }
        // Collapse multiple consecutive hyphens (e.g. "Title---Subtitle" → "Title-Subtitle")
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ".-")))
        // Cap at 80 chars per component so the full filename stays well under 255 bytes.
        result = String(result.prefix(80))
        return result.isEmpty ? "Unknown" : result
    }
}
