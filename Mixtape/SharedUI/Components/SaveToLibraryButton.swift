// SaveToLibraryButton.swift
// Mixtape — SharedUI/Components
//
// The one-tap "keep this song" control on Discover rows and in the player.
//
// Pressing it likes the song, which is the same thing as keeping it: a Discover
// row is metadata only, so the like is the whole of what holds it in the library
// (see `LibraryService.saveToLibrary`). Spotify draws that as a heart. This draws
// it as plus / check because it also has to answer the question the heart can't —
// *is this song in my library at all?* — for songs a playlist or an import put
// there without anyone liking them.
//
// Saving is one tap, no sheet. Tapping the check afterwards opens the "saved in"
// sheet — every playlist the song is filed under, Favourites included, each one
// removable there, and "Your Library" at the top of them, which removes the song
// outright. Unsaving is deliberately one step further in than saving: in Mixtape
// it can take a downloaded file with it, so it happens on a row that says so
// rather than on a second tap of the same glyph.

import SwiftUI

struct SaveToLibraryButton: View {

    /// The library ID this Discover song takes once it's saved — `OnlineTrack`
    /// derives it deterministically, so it's known before the save happens.
    let trackID: UUID
    /// What the song is called, used only when `trackID` finds nothing.
    ///
    /// The id is not always the one the song ends up with: `importOnlineTrack`
    /// hashes the resolved file first, and a hash that matches something already
    /// in the library returns *that* track, keeping its older id. The song is
    /// genuinely saved, under an id this button will never find — so the check
    /// used to revert to a plus after the poll, and tapping it did nothing at
    /// all. Falling back to title and artist also means a song already in the
    /// library from a local import shows as saved, which it is.
    ///
    /// The fallback compares recordings, not strings. An exact match on both
    /// fields is not good enough for the case it exists to catch: catalogues
    /// disagree about where the guests go, so Deezer's "Ran To Atlanta" by
    /// "Drake" never met the imported "Ran To Atlanta (feat. Future & Molly
    /// Santana)" by "Drake, Future, Molly Santana". The row showed a plus, and
    /// pressing it saved nothing — the import matches by recording and correctly
    /// returned the copy already there — so the button reported a save that
    /// produced no new row. `LibraryTrackIndex` is the rule the import itself
    /// uses, which is what makes the two agree.
    var identity: (title: String, artist: String, duration: TimeInterval)? = nil
    /// Glyph point size. The player bar runs smaller than a Discover row.
    var size: CGFloat = 17
    /// Fades the plus back when the pointer is elsewhere — a full-strength column
    /// of them down a long result list is too loud. Never applied to the check:
    /// that one is information about the song, not an invitation, and dimming it
    /// made a live control read as a disabled one.
    var dimmed: Bool = false
    let action: () -> Void

    @EnvironmentObject private var deps: AppDependencies
    /// Set on the tap and cleared the moment the library agrees (or the save is
    /// judged to have failed). It is *only* the gap between the press and the
    /// row appearing — the answer itself comes from the library, below.
    @State private var justSaved = false
    @State private var showingSavedIn = false
    /// Bumped on the tap that saves, to fire the bounce. A counter rather than a
    /// flag because two saves in a row have to be two bounces.
    @State private var popCount = 0

    /// Whether this song is in the library.
    ///
    /// Read from the library on every redraw rather than remembered in state.
    /// One song has one answer, and every copy of this button — the Discover
    /// row, the player bar, the full-screen player, the search result — has to
    /// give the same one: saving from the player used to leave the plus sitting
    /// there in Discover, because each button had cached its own answer when it
    /// appeared and nothing told it the world had moved. `AppDependencies`
    /// republishes on every library change, so derived means every one of them
    /// updates on the same frame.
    private var saved: Bool { justSaved || isInLibrary }

    var body: some View {
        Button {
            if saved {
                // The check goes on optimistically, so it can be showing before
                // the import has produced a library row — and there's nothing to
                // list the song's playlists from until it has. Say so rather
                // than swallowing the tap: a control that does nothing twice in
                // a row reads as broken, not as busy.
                guard libraryTrack != nil else {
                    deps.showToast("Still saving\u{2026}")
                    return
                }
                #if os(macOS)
                // The corner panel, not a sheet: this is a glance at where the
                // song lives, and it shouldn't take the window to answer it.
                // Re-read the track rather than capturing one — a just-saved
                // song exists in the library by now and carries real artwork,
                // where the Discover copy is a provisional stand-in.
                if let track = libraryTrack {
                    deps.savedInPanel.show(tracks: [track], isSavedIn: true)
                }
                #else
                showingSavedIn = true
                #endif
                return
            }
            // Optimistic: the check appears on the tap, not once the resolve,
            // artwork fetch and artist-photo lookup have all finished.
            justSaved = true
            popCount += 1
            Haptics.play(.success)
            action()
            // Said here rather than in each caller's `action`: this control means
            // one thing wherever it is, and the Discover rows that own most of
            // these buttons were confirming the save with nothing but the glyph.
            deps.showSavedToast(.library)
            // Saving can genuinely fail (no network, resolver timeout), so the
            // check has to be able to come back off — but only on real failure.
            // Poll instead of waiting a fixed beat: a save that takes twelve
            // seconds is still a save, and flipping back to a plus on a song
            // that is in the library is the worse lie.
            //
            // Either way this ends by handing the question back to the library:
            // once the row exists the optimism is redundant, and once the
            // attempt is over it was wrong.
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
                // Morph plus into check rather than cutting between them. The
                // two glyphs share a circle, so the swap is nearly free to
                // animate and the cut was the one jarring frame in the save.
                .mixSymbolReplace()
                .mixAnimation(.snappy(duration: 0.22), value: saved)
                .frame(width: size + 13, height: size + 13)
                .opacity(saved || !dimmed ? 1 : 0.4)
                .savePop(trigger: popCount)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(savedLabel)
        .accessibilityLabel(savedLabel)
        // A recycled button — the player bar's, when the song changes — must not
        // carry the previous song's press with it.
        // `popCount` is deliberately not reset here: it is a trigger, and any
        // change to it fires the bounce — zeroing it would make the player bar
        // pop every time the song changed.
        .task(id: trackID) { justSaved = false }
        #if !os(macOS)
        .sheet(isPresented: $showingSavedIn) {
            // Re-read the track rather than capturing one: a just-saved song
            // exists in the library by now and carries real artwork, where the
            // Discover copy is a provisional stand-in.
            if let track = libraryTrack {
                AddToPlaylistSheet(track: track, purpose: .savedIn)
                    .environmentObject(deps)
            }
        }
        #endif
    }

    private var savedLabel: String {
        saved ? "Where this song is saved" : "Add to Library"
    }

    /// This song's library row, by id if it has one and by name if it doesn't.
    /// See `identity` for why the id alone isn't enough.
    ///
    /// One pass rather than an id lookup followed by a name scan: this is read
    /// on every redraw now, once per button on screen, and a Discover page can
    /// be showing fifty of them.
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

/// The save control for the player bar and the full-screen player.
///
/// Always plus / check, whatever is playing — it answers one question ("is this
/// song in my library?") and keeps answering it in the same place with the same
/// two glyphs. An earlier version swapped in a heart once the song was saved,
/// which meant the control changed its meaning underneath the user at the exact
/// moment they'd finished using it. Favouriting is a separate wish and lives in
/// the ••• / right-click menu alongside "Add to Playlist".
struct NowPlayingSaveButton: View {

    /// The currently displayed track's ID.
    let trackID: UUID
    var size: CGFloat = 17

    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var coordinator: OnlinePlaybackCoordinator
    @EnvironmentObject private var engine: PlaybackEngine

    var body: some View {
        // An unsaved Discover song saves through the coordinator, which has the
        // stream and the metadata; anything already in the library just needs the
        // button, which opens the "saved in" sheet on its own.
        // Matched the same way the button itself matches, or the bar shows a
        // plus for a song the library already has under another spelling.
        if let online = coordinator.currentOnlineTrack,
           (deps.libraryService.track(id: online.stableTrackID) == nil || SavedAlbumsService.shared.albumOnlyIDs.contains(online.stableTrackID)),
           deps.libraryService.track(matching: online.title,
                                     artistName: online.artistName,
                                     duration: online.duration) == nil {
            SaveToLibraryButton(trackID: online.stableTrackID,
                                identity: (online.title, online.artistName, online.duration),
                                size: size) {
                // No toast here — the button shows the card itself, for every
                // copy of it, the moment the tap lands.
                Task { await coordinator.addToLibrary(online) }
            }
        } else if let track = engine.queue.currentTrack,
                  track.isOnline,
                  (deps.libraryService.track(id: track.id) == nil || SavedAlbumsService.shared.albumOnlyIDs.contains(track.id)),
                  deps.libraryService.track(matching: track.title,
                                            artistName: track.artistName,
                                            duration: track.duration) == nil {
            // Playing, online, not saved — and no Discover context behind it.
            // That is what a song replayed from Home's shelf looks like once its
            // session is over, and this branch used to hand the button an empty
            // action: the plus turned into a check on the press, saved nothing,
            // and turned back twenty seconds later.
            SaveToLibraryButton(trackID: track.id,
                                identity: (track.title, track.artistName, track.duration),
                                size: size) {
                Task { await save(track) }
            }
        } else {
            // Saved — but the branches above match by *recording*, not by id, so
            // getting here does not mean `trackID` finds the row. Hand the
            // button the same identity they used, or the bar draws a plus for a
            // song the library has under another spelling (the exact case the
            // Discover row two inches above it gets right).
            SaveToLibraryButton(trackID: trackID,
                                identity: currentIdentity,
                                size: size,
                                action: {})
        }
    }

    /// Title / artist / duration of whatever the player is showing, for the
    /// recording match that `trackID` alone can't make.
    private var currentIdentity: (title: String, artist: String, duration: TimeInterval)? {
        if let online = coordinator.currentOnlineTrack {
            return (online.title, online.artistName, online.duration)
        }
        if let track = engine.queue.currentTrack {
            return (track.title, track.artistName, track.duration)
        }
        return nil
    }

    /// Saves the playing song straight from its library-shaped row.
    ///
    /// The source key lives on the row's provenance (that is what makes it
    /// resolvable at all), so no Discover result is needed to save it — and
    /// passing its own id keeps the saved row the one the player is already
    /// pointing at.
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
