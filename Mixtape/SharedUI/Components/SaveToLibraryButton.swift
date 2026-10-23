// One-tap save for Discover rows and the player. Saving likes the song
// (see `LibraryService.saveToLibrary`). Plus/check rather than a heart,
// since it also shows songs added by playlists or imports.
// Tapping the check opens the "saved in" panel, where removal happens. Unsave is
// a step further in because it can delete a downloaded file.

import SwiftUI

struct SaveToLibraryButton: View {

    /// The id `OnlineTrack` derives for this song, known before the save.
    let trackID: UUID
    /// Fallback when `trackID` finds nothing: import can return an existing row
    /// with an older id, and local imports should show as saved too.
    /// Matches by recording via `LibraryTrackIndex`, same as the import, since
    /// catalogues disagree on where features go.
    var identity: (title: String, artist: String, duration: TimeInterval)? = nil
    /// Glyph point size. The player bar runs smaller than a Discover row.
    var size: CGFloat = 17
    /// Dims the plus when not hovered. Never the check.
    var dimmed: Bool = false
    let action: () -> Void

    @Environment(AppDependencies.self) private var deps
    /// Optimistic flag between the tap and the library row appearing.
    @State private var justSaved = false
    @State private var showingSavedIn = false
    /// Bounce trigger. A counter so two saves bounce twice.
    @State private var popCount = 0

    /// Read from the library each redraw, so every copy of the button agrees.
    /// `AppDependencies` republishes on library changes.
    private var saved: Bool { justSaved || isInLibrary }

    var body: some View {
        Button {
            if saved {
                // The check shows optimistically, before the row exists; say so rather
                // than ignore the tap.
                guard libraryTrack != nil else {
                    deps.showToast("Still saving\u{2026}")
                    return
                }
                #if os(macOS)
                // Corner panel, not a sheet. Re-read the track: the saved row has real artwork.
                if let track = libraryTrack {
                    deps.savedInPanel.show(tracks: [track], isSavedIn: true)
                }
                #else
                showingSavedIn = true
                #endif
                return
            }
            // Optimistic check on tap.
            justSaved = true
            popCount += 1
            Haptics.play(.success)
            action()
            // Toast here so every caller gets it.
            deps.showSavedToast(.library)
            // Saves can fail (network, resolver timeout). Poll rather than wait a fixed
            // time; either way the library decides in the end.
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(for: .seconds(1))
                    if isInLibrary { justSaved = false; return }
                }
                justSaved = false
            }
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: size, weight: saved ? .semibold : .regular))
                .foregroundStyle(saved ? Color.mixPrimary : Color.mixTextSecondary)
                // Morph plus into check.
                .mixSymbolReplace()
                .mixAnimation(.mixSnappy, value: saved)
                .frame(width: size + 13, height: size + 13)
                .opacity(saved || !dimmed ? 1 : 0.4)
                .savePop(trigger: popCount)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(savedLabel)
        .accessibilityLabel(savedLabel)
        // A recycled button mustn't keep the old song's press. `popCount` isn't
        // reset: any change fires the bounce.
        .task(id: trackID) { justSaved = false }
        #if !os(macOS)
        .sheet(isPresented: $showingSavedIn) {
            // Re-read the track: the saved row has real artwork.
            if let track = libraryTrack {
                AddToPlaylistSheet(track: track, purpose: .savedIn)
                    .environment(deps)
            }
        }
        #endif
    }

    private var savedLabel: String {
        saved ? "Where this song is saved" : "Add to Liked Songs"
    }

    /// Library row by id, else by recording (see `identity`). One pass, since
    /// this runs per button per redraw.
    private var libraryTrack: Track? {
        guard let t = anyLibraryTrack, !SavedAlbumsService.shared.albumOnlyIDs.contains(t.id) else { return nil }
        return t
    }

    private var anyLibraryTrack: Track? {
        if let exact = deps.libraryService.track(id: trackID) { return exact }
        guard let identity else { return nil }
        return deps.libraryService.track(matching: identity.title,
                                         artistName: identity.artist,
                                         duration: identity.duration)
    }

    private var isInLibrary: Bool { libraryTrack != nil }
}

// MARK: - Now Playing

/// Save control for the player bar and full-screen player. Always plus/check;
/// favouriting lives in the menu.
struct NowPlayingSaveButton: View {

    /// The currently displayed track's ID.
    let trackID: UUID
    var size: CGFloat = 17

    @Environment(AppDependencies.self) private var deps
    @Environment(OnlinePlaybackCoordinator.self) private var coordinator
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        // Unsaved Discover songs save through the coordinator; library songs just need
        // the button. Match by recording like the button does.
        if let online = coordinator.currentOnlineTrack,
           (deps.libraryService.track(id: online.stableTrackID) == nil || SavedAlbumsService.shared.albumOnlyIDs.contains(online.stableTrackID)),
           deps.libraryService.track(matching: online.title,
                                     artistName: online.artistName,
                                     duration: online.duration) == nil {
            SaveToLibraryButton(trackID: online.stableTrackID,
                                identity: (online.title, online.artistName, online.duration),
                                size: size) {
                // No toast; the button shows the card itself.
                Task { await coordinator.addToLibrary(online) }
            }
        } else if let track = engine.queue.currentTrack,
                  track.isOnline,
                  (deps.libraryService.track(id: track.id) == nil || SavedAlbumsService.shared.albumOnlyIDs.contains(track.id)),
                  deps.libraryService.track(matching: track.title,
                                            artistName: track.artistName,
                                            duration: track.duration) == nil {
            // Online, unsaved and no Discover context (e.g. replayed from Home):
            // save the row directly.
            SaveToLibraryButton(trackID: track.id,
                                identity: (track.title, track.artistName, track.duration),
                                size: size) {
                Task { await save(track) }
            }
        } else {
            // The branches above match by recording, so `trackID` may not find the row.
            // Pass the same identity.
            SaveToLibraryButton(trackID: trackID,
                                identity: currentIdentity,
                                size: size,
                                action: {})
        }
    }

    /// Title/artist/duration of what's playing, for the recording match.
    private var currentIdentity: (title: String, artist: String, duration: TimeInterval)? {
        if let online = coordinator.currentOnlineTrack {
            return (online.title, online.artistName, online.duration)
        }
        if let track = engine.queue.currentTrack {
            return (track.title, track.artistName, track.duration)
        }
        return nil
    }

    /// Saves the playing song from its library-shaped row. The source key is in
    /// its provenance; passing its own id keeps the player pointing at it.
    private func save(_ track: Track) async {
        SavedAlbumsService.shared.promote(track.id)
        defer { deps.libraryService.saveToLibrary(trackID: track.id) }
        _ = await deps.importService.saveOnlineTrack(
            sourceRef:   track.file.fileHash,
            id:          track.id,
            title:       track.title,
            artistName:  track.artistName,
            albumTitle:  track.albumTitle,
            duration:    track.duration,
            artworkURL:  nil,
            artworkData: track.displayArtwork,
            isExplicit:  track.isExplicit
        )
    }
}
