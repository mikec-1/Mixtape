# Mixtape

A music player for your own offline files. Import your tracks, organise them into a library, and play them — all on your Mac. Sign in and your library, playlists, and files stay in sync across your devices.

## What it does

**Library & import**
- Import audio files straight from your computer with the **+** button
- Automatic metadata lookup (title, artist, album, artwork) with a review step so you can confirm matches before they're applied
- Browse by **Songs**, **Albums**, **Artists**, and **Playlists**, with a sortable track list and album/artist detail views

**Playlists & favourites**
- Create and edit playlists, pin them to the sidebar, and drag to reorder
- Favourite the tracks you love

**Playback**
- Play, queue, play next, and shuffle
- A Now Playing panel with artwork, full metadata, and file info
- Picks up where you left off — your last session is restored on launch
- Recently played history

**Search**
- Fast fuzzy search across songs, albums, and artists at once

**Sync & storage**
- Sign in to sync your library and audio files across your devices, automatically in the background
- Live sync status, plus a Sync Now button
- Download tracks to disk and export them back out, with a Wi-Fi-only option

**App**
- Light, Dark, or System appearance
- Keeps itself up to date automatically

## Requirements

- macOS 14 or later

## Installing

Download the latest `.dmg` from the [Releases](https://github.com/mikec-1/Mixtape/releases) page, open it, and drag Mixtape into your Applications folder.

On the first launch, right-click the app and choose **Open** (a one-time step for this build). After that it opens normally and updates itself.

## Building from source

Open `Mixtape.xcodeproj` in Xcode and build the **Mixtape** scheme. Dependencies are handled through Swift Package Manager.

## Version

Version 1.0 — the public macOS build, kept intentionally simple. An iPhone version is in the works.
