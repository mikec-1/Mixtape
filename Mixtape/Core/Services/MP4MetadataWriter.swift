// MP4MetadataWriter.swift
// Mixtape — Core/Services
//
// Writes title/artist/album/artwork into an .m4a.
//
// The counterpart to ID3TagWriter, which only works on MP3: ID3 is an MP3
// container construct, and prepending one to an .m4a pushes bytes in front of
// the MP4 `ftyp` atom and corrupts the file. So every non-MP3 export used to
// have to become an MP3 first — a lossy re-encode of an already-lossy source,
// paid on every Discover song, purely to get a filename and a cover in Finder.
//
// This does it the other way round: a passthrough export, which rewrites the
// container's metadata atoms and copies the audio stream through untouched. No
// re-encode, so "High" can mean what it says. It also works on iOS, where
// there is no ffmpeg and exported files carried no metadata at all.

import Foundation
import AVFoundation

enum MP4MetadataWriter {

    enum WriteError: LocalizedError {
        case cannotConfigure
        case unsupportedContainer(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cannotConfigure: return "Couldn't set up the metadata writer."
            case .unsupportedContainer(let ext):
                return ".\(ext) isn't an MP4 container, so its metadata can't be written this way."
            case .failed(let why): return why
            }
        }
    }

    /// Containers this can safely rewrite. The output is always an `.m4a`
    /// swapped over the original path, so anything outside the MP4 family
    /// would end up as MP4 bytes wearing the wrong extension — a `.flac` that
    /// isn't FLAC any more. AVFoundation reads several of those formats, so
    /// "the export would just fail" isn't something to rely on.
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "m4b"]

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Rewrites `url` in place with `track`'s metadata attached.
    ///
    /// Writes to a sibling temporary file and swaps it in, because an export
    /// session cannot use its own input as its output.
    static func write(_ track: Track, to url: URL) async throws {
        guard supports(url) else {
            throw WriteError.unsupportedContainer(url.pathExtension.lowercased())
        }

        let asset = AVURLAsset(url: url)

        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough)
        else { throw WriteError.cannotConfigure }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".mixtape-tag-\(UUID().uuidString).m4a")

        session.metadata = metadataItems(for: track)

        if #available(macOS 15.0, iOS 18.0, *) {
            try await session.export(to: temp, as: .m4a)
        } else {
            session.outputURL      = temp
            session.outputFileType = .m4a
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: temp)
                throw WriteError.failed(session.error?.localizedDescription
                                        ?? "The metadata write didn't finish.")
            }
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// The common-key items every MP4 reader understands (Finder, Music, the
    /// iOS Files preview). Deliberately common-key rather than iTunes-specific:
    /// the point is that the file reads correctly outside Mixtape.
    private static func metadataItems(for track: Track) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier   = identifier
            item.value        = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        add(.commonIdentifierTitle,       track.title.isEmpty ? nil : track.title as NSString)
        add(.commonIdentifierArtist,      track.artistName.isEmpty ? nil : track.artistName as NSString)
        add(.commonIdentifierAlbumName,   track.albumTitle.isEmpty ? nil : track.albumTitle as NSString)
        add(.commonIdentifierArtwork,     track.artworkData as NSData?)
        add(.iTunesMetadataTrackNumber,   track.trackNumber.map(trackNumberAtom))
        add(.iTunesMetadataUserGenre,     track.genre.flatMap { $0.isEmpty ? nil : $0 as NSString })
        // `.commonIdentifierCreationDate` maps to a container field that the
        // export overwrites with the write time — the year has to go in the
        // iTunes release-date atom to survive (verified with ffprobe).
        add(.iTunesMetadataReleaseDate,   track.year.map { String($0) as NSString })

        return items
    }

    /// `trkn` is a binary atom, not a number — an `NSNumber` here silently
    /// writes 0. Layout is four big-endian 16-bit fields: reserved, index,
    /// total, reserved. Total stays 0, which readers treat as "unknown".
    private static func trackNumberAtom(_ number: Int) -> NSData {
        let n = UInt16(clamping: number)
        return Data([0, 0, UInt8(n >> 8), UInt8(n & 0xFF), 0, 0, 0, 0]) as NSData
    }
}
