// LyricSync.swift
// Mixtape — Core/Services
//
// Shared tuning for synced-lyric highlighting. LRC timestamps mark the moment a
// line *starts* being sung, and the published playback clock updates on a timer,
// so without compensation the highlighted line trails the audio by ~1–2s.
// `leadOffset` advances the match so lines light up as they're heard.

import Foundation

public enum LyricSync {
    /// Seconds to look ahead when picking the active lyric line.
    public static let leadOffset: TimeInterval = 0.9
}
