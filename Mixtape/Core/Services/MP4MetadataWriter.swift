// Writes title/artist/album/artwork into an .m4a with a passthrough export,
// so there's no re-encode. ID3TagWriter is MP3 only. Works on iOS too.

import Foundation
import AVFoundation

nonisolated enum MP4MetadataWriter {

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

    /// MP4 family only, since the output is always .m4a bytes.
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "m4b"]

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Writes to a temp file and swaps it in, since the export can't overwrite its input.
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

    /// Common keys so Finder and Music read them.
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
        // The creation date gets overwritten by the export, so the year goes in the
        // iTunes release date.
        add(.iTunesMetadataReleaseDate,   track.year.map { String($0) as NSString })

        return items
    }

    /// trkn is binary: four big-endian UInt16s (reserved, index, total, reserved).
    private static func trackNumberAtom(_ number: Int) -> NSData {
        let n = UInt16(clamping: number)
        return Data([0, 0, UInt8(n >> 8), UInt8(n & 0xFF), 0, 0, 0, 0]) as NSData
    }
}
