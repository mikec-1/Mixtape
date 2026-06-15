// MetadataParser.swift
// Mixtape — Data/FileSystem
//
// Extracts title, artist, album, artwork, duration, track/disc number, year,
// and genre from an audio file using AVFoundation's async metadata API.
// Supports MP3 (ID3), M4A/AAC (iTunes), FLAC, WAV, AIFF.

import Foundation
import AVFoundation

// MARK: - Result Type

public struct ParsedMetadata: Sendable {
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var artworkData: Data?
    public var composer: String?
}

// MARK: - Parser

public final class MetadataParser: Sendable {

    public init() {}

    /// Parse metadata from a local audio file URL.
    /// The URL must already be accessible (security-scoped resource started by caller).
    public func parse(url: URL) async throws -> ParsedMetadata {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // --- Duration ---
        let cmDuration = try await asset.load(.duration)
        let duration = cmDuration.seconds.isNaN ? 0 : cmDuration.seconds

        // --- Common metadata (works across all formats) ---
        let commonItems = try await asset.load(.commonMetadata)
        var title:       String? = nil
        var artist:      String? = nil
        var album:       String? = nil
        var artworkData: Data?   = nil
        var genre:       String? = nil
        var year:        Int?    = nil
        var composer:    String? = nil

        for item in commonItems {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                title = try? await item.load(.stringValue)
            case .commonKeyArtist:
                artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName:
                album = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                artworkData = try? await item.load(.dataValue)
            case .commonKeyCreationDate:
                if let s = try? await item.load(.stringValue) {
                    year = Int(s.prefix(4))
                }
            case .commonKeyAuthor:
                if composer == nil { composer = try? await item.load(.stringValue) }
            default:
                break
            }
        }

        // --- ID3 (MP3) — track/disc number, genre, additional artist ---
        var trackNumber: Int? = nil
        var discNumber:  Int? = nil

        if let id3Items = try? await asset.loadMetadata(for: .id3Metadata) {
            for item in id3Items {
                switch item.identifier {
                case .id3MetadataTrackNumber:
                    if let s = try? await item.load(.stringValue) {
                        trackNumber = parseSlashSeparated(s)
                    }
                case .id3MetadataPartOfASet:
                    if let s = try? await item.load(.stringValue) {
                        discNumber = parseSlashSeparated(s)
                    }
                case .id3MetadataContentType where genre == nil:
                    genre = try? await item.load(.stringValue)
                case .id3MetadataLeadPerformer where artist == nil:
                    artist = try? await item.load(.stringValue)
                case .id3MetadataComposer where composer == nil:
                    composer = try? await item.load(.stringValue)
                default:
                    break
                }
            }
        }

        // --- iTunes / M4A ---
        if let itunesItems = try? await asset.loadMetadata(for: .iTunesMetadata) {
            for item in itunesItems {
                switch item.identifier {
                case .iTunesMetadataTrackNumber where trackNumber == nil:
                    // iTunes encodes as binary: [0,0, hi,lo track, hi,lo total]
                    if let data = try? await item.load(.dataValue), data.count >= 4 {
                        let n = (Int(data[2]) << 8) | Int(data[3])
                        if n > 0 { trackNumber = n }
                    }
                case .iTunesMetadataDiscNumber where discNumber == nil:
                    if let data = try? await item.load(.dataValue), data.count >= 4 {
                        let n = (Int(data[2]) << 8) | Int(data[3])
                        if n > 0 { discNumber = n }
                    }
                case .iTunesMetadataUserGenre where genre == nil:
                    genre = try? await item.load(.stringValue)
                default:
                    break
                }
            }
        }

        // --- Fallbacks ---
        let filename = url.deletingPathExtension().lastPathComponent

        return ParsedMetadata(
            title:       title      ?? filename,
            artistName:  artist     ?? "Unknown Artist",
            albumTitle:  album      ?? "Unknown Album",
            duration:    max(duration, 0),
            trackNumber: trackNumber,
            discNumber:  discNumber,
            year:        year,
            genre:       genre.flatMap { cleanGenre($0) },
            artworkData: artworkData,
            composer:    composer
        )
    }

    // MARK: - Helpers

    /// Parses "5/12" or "5" → 5
    private func parseSlashSeparated(_ s: String) -> Int? {
        Int(s.split(separator: "/").first.map(String.init) ?? s)
    }

    /// Strip ID3 genre codes like "(17)" from genre strings.
    private func cleanGenre(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("("), let close = s.firstIndex(of: ")") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? nil : s
    }
}
