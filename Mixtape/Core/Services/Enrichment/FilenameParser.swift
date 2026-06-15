// FilenameParser.swift
// Mixtape — Core/Services/Enrichment
//
// Extracts artist, title, and track number from common audio filename conventions.
//
// Supported patterns (in order of detection):
//   "01 - Artist - Title"      → trackNumber=1, artist, title
//   "01. Title"                → trackNumber=1, title only
//   "Artist - Title"           → artist, title  (most common)
//   "Title (feat. Artist)"     → title with featured artist stripped
//   "Title"                    → title only
//
// stripVersionModifiers(_:) removes common user-added version suffixes such as
// "(slowed)", "(slowed + reverb)", "(sped up)", "(nightcore)", etc. so that
// iTunes lookups target the canonical song name.

import Foundation

// MARK: - Result

public struct ParsedFilename: Sendable {
    public var title:       String?
    public var artistName:  String?
    public var trackNumber: Int?
}

// MARK: - Parser

public struct FilenameParser: Sendable {

    public init() {}

    public func parse(_ url: URL) -> ParsedFilename {
        var stem = url.deletingPathExtension().lastPathComponent

        // 1. Strip leading track number: "01 - ", "1. ", "02 ", etc.
        var trackNumber: Int? = nil
        if let (num, remainder) = stripTrackPrefix(from: stem) {
            trackNumber = num
            stem = remainder
        }

        // 2. Split on " - "
        let parts = stem
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        switch parts.count {
        case 0:
            return ParsedFilename()

        case 1:
            // Single component — treat as title, strip any "(feat. X)" suffix for the title
            let title = stripFeaturing(from: parts[0])
            return ParsedFilename(title: title, artistName: nil, trackNumber: trackNumber)

        case 2:
            // "Artist - Title" is the dominant convention for ripped/downloaded music
            let artist = parts[0]
            let title  = stripFeaturing(from: parts[1])
            return ParsedFilename(title: title, artistName: artist, trackNumber: trackNumber)

        default:
            // 3+ parts: take first as artist, last as title, ignore middle (usually album)
            let artist = parts[0]
            let title  = stripFeaturing(from: parts[parts.count - 1])
            return ParsedFilename(title: title, artistName: artist, trackNumber: trackNumber)
        }
    }

    // MARK: - Private helpers

    /// Strips "01 - ", "1. ", "02 " etc from the front and returns (number, remainder).
    private func stripTrackPrefix(from s: String) -> (Int, String)? {
        // Pattern: optional leading zeros, 1-3 digits, then optional separator
        let pattern = #"^(\d{1,3})[\s\.\-]+"#
        guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
        let numStr = s[range].trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        guard let num = Int(numStr) else { return nil }
        let remainder = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : (num, remainder)
    }

    /// Strips "(feat. X)", "(ft. X)", "(with X)" suffixes from a title.
    private func stripFeaturing(from s: String) -> String {
        let pattern = #"\s*[\(\[]?(feat\.?|ft\.?|with)\s+[^\)\]]+[\)\]]?"#
        let cleaned = s.replacingOccurrences(of: pattern,
                                             with: "",
                                             options: [.regularExpression, .caseInsensitive])
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Version modifier stripping

    /// Removes common user-appended version/edit tags from a title so that the
    /// result can be used as a cleaner iTunes search query.
    ///
    /// Handles three forms:
    ///   A. Parenthetical  — "Song (slowed + reverb)", "Song [nightcore]"
    ///   B. Dash-suffix    — "Song - Sped Up", "Song - slowed"
    ///   C. Bare-suffix    — "Song slowed", "Song slowed reverb"  ← most common in the wild
    ///
    /// Applied repeatedly until stable so stacked tags like "Song (slowed) reverb" collapse fully.
    ///
    /// Examples:
    ///   "Mist slowed"                        → "Mist"
    ///   "Blinding Lights (slowed + reverb)"  → "Blinding Lights"
    ///   "Levitating - Sped Up"               → "Levitating"
    ///   "Someone You Loved (Nightcore Remix)" → "Someone You Loved"
    ///   "drivers license (acoustic version)"  → "drivers license"
    public func stripVersionModifiers(_ title: String) -> String {
        // Keywords that mark a non-canonical version of a song.
        // Order matters: longer/more-specific phrases before their substrings.
        let kw = [
            // Slowed variants (most common bare-suffix case)
            #"slowed\s*\+\s*reverb"#,
            #"slowed\s*reverb"#,
            #"slowed\s*down"#,
            #"slowed\s*version"#,
            #"slowed"#,
            // Sped up variants
            #"sped\s*up\s*version"#,
            #"sped\s*up"#,
            #"speed\s*up"#,
            // Reverb alone
            #"reverb"#,
            // Audio effects
            #"nightcore"#,
            #"lo-fi"#,
            #"lofi"#,
            #"bass\s*boosted"#,
            #"bass\s*boost"#,
            #"8d\s*audio"#,
            #"8d"#,
            #"chopped\s*(?:and|&)\s*screwed"#,
            #"chopped"#,
            // Version labels
            #"official\s*remix"#,
            #"extended\s*remix"#,
            #"extended\s*version"#,
            #"radio\s*edit"#,
            #"remastered"#,
            #"remaster"#,
            #"acoustic\s*version"#,
            #"acoustic"#,
            #"instrumental"#,
            #"live\s*version"#,
            #"live"#,
            #"remix"#,
            #"cover"#,
            #"edit"#,
            #"version"#,
        ].joined(separator: "|")

        // Pattern A: ( keyword … ) or [ keyword … ] — parenthetical, anywhere
        let parenPattern = #"\s*[\(\[]\s*(?:"# + kw + #")[^\)\]]*[\)\]]"#
        // Pattern B: " - keyword" at end of string
        let dashPattern  = #"\s+-\s*(?:"# + kw + #")\s*$"#
        // Pattern C: bare " keyword" at end of string (no surrounding punctuation).
        // We require at least one real word before it so we don't strip single-word titles.
        let barePattern  = #"(?<=\S)\s+(?:"# + kw + #")\s*$"#

        var result = title
        for _ in 0 ..< 6 {
            let prev = result
            result = result
                .replacingOccurrences(of: parenPattern, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: dashPattern,  with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: barePattern,  with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            if result == prev { break }
        }
        // Safety: never return empty string — fall back to original
        return result.isEmpty ? title : result
    }
}
