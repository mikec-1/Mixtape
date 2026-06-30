// LyricSync.swift
// Mixtape — Core/Services
//
// Shared tuning for synced-lyric highlighting. LRC timestamps mark the moment a
// line *starts* being sung, and the published playback clock updates on a timer,
// so without compensation the highlighted line trails the audio by ~1–2s.
// `leadOffset` advances the match so lines light up as they're heard.

import Foundation

public enum LyricSync {
    /// Seconds to look ahead when picking the active lyric line. Tuned per
    /// platform: macOS's published clock lags more, so it needs a larger lead;
    /// iOS reports playback time tighter, so the same 0.9s ran ~1–2s early.
    #if os(iOS)
    public static let leadOffset: TimeInterval = -0.4
    #else
    public static let leadOffset: TimeInterval = 0.9
    #endif
}
