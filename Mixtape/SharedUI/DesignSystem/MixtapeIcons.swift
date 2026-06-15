// MixtapeIcons.swift
// Mixtape — Design System
//
// Centralised SF Symbol names so we can swap icons in one place.
// All icons use SF Symbols (no third-party icon fonts needed).

import SwiftUI

enum MixtapeIcons {

    // MARK: Tab Bar
    static let library      = "music.note.list"
    static let search       = "magnifyingglass"
    static let nowPlaying   = "waveform"
    static let settings     = "gearshape.fill"

    // MARK: Playback
    static let play         = "play.fill"
    static let pause        = "pause.fill"
    static let skipForward  = "forward.fill"
    static let skipBack     = "backward.fill"
    static let shuffle      = "shuffle"
    static let repeatAll    = "repeat"
    static let repeatOne    = "repeat.1"
    static let queue        = "list.bullet.below.rectangle"
    static let seekBar      = "slider.horizontal.3"
    static let volumeHigh   = "speaker.wave.3.fill"
    static let volumeLow    = "speaker.wave.1.fill"
    static let volumeMute   = "speaker.slash.fill"

    // MARK: Library / Content
    static let track        = "music.note"
    static let album        = "square.stack.fill"
    static let artist       = "person.circle.fill"
    static let playlist     = "music.note.list"
    static let heart        = "heart.fill"
    static let heartOutline = "heart"
    static let clock        = "clock.fill"
    static let download     = "arrow.down.circle.fill"
    static let upload       = "arrow.up.circle"

    // MARK: Actions
    static let add          = "plus"
    static let addCircle    = "plus.circle.fill"
    static let remove       = "minus"
    static let delete       = "trash.fill"
    static let edit         = "pencil"
    static let share        = "square.and.arrow.up"
    static let more         = "ellipsis"
    static let moreCircle   = "ellipsis.circle"
    static let checkmark    = "checkmark"
    static let close        = "xmark"
    static let closeCircle  = "xmark.circle.fill"
    static let back         = "chevron.left"
    static let forward      = "chevron.right"
    static let drag         = "line.3.horizontal"

    // MARK: Follow
    static let following    = "person.badge.minus"
    static let follow       = "person.badge.plus"

    // MARK: Import
    static let importFile   = "square.and.arrow.down"
    static let folder       = "folder.fill"

    // MARK: Sync & Account
    static let sync         = "arrow.triangle.2.circlepath"
    static let syncing      = "arrow.triangle.2.circlepath.circle"
    static let syncError    = "exclamationmark.arrow.triangle.2.circlepath"
    static let account      = "person.crop.circle.fill"
    static let signOut      = "rectangle.portrait.and.arrow.right"
}

// MARK: - Image convenience wrapper

extension Image {
    static func mix(_ icon: String) -> Image {
        Image(systemName: icon)
    }
}
