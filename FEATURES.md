# Mixtape — `develop` Feature Tracker (internal)

Personal checklist for the full build.
⚠️ notes flag things that are partial, platform-limited, or known-buggy — based on the current code.

> This is the advanced/full branch. `main` is the trimmed public 1.0.

---

## Library & import
- [ ] Import audio files (`+` button / file picker)
- [ ] Automatic metadata enrichment (iTunes lookup) with review sheet before applying
- [ ] Browse by Songs / Albums / Artists / Playlists
- [ ] Sortable native track table (Mac) with columns (title, artist, album, date added…)
- [ ] Album & Artist detail views
- [ ] Track inspector (artwork, metadata, file format/size)

## Home
- [ ] Home screen with carousels: "Jump back in" (recently played), "Recently added", "Your favourites"
- [ ] Listening-stats tile with "See all" → full stats

## Playlists & favourites
- [ ] Create / edit playlists
- [ ] Pin playlists to sidebar + drag to reorder (Mac)
- [ ] Favourite tracks (Favourites system playlist)
- [ ] Add-to-playlist sheet

## Smart Playlists
- [ ] Create rule-based smart playlists (`SmartPlaylistsView` / editor)
  - ⚠️ **iOS only** — surfaced in the iOS Library view; **not reachable on macOS** (no sidebar/nav entry). Needs wiring into the Mac UI.

## Collaborative / shared playlists
- [ ] Share a playlist via join code ("Share Collaboratively")
- [ ] Join a shared playlist by code (creates a local snapshot)
- [ ] Plain share via `.m3u8` export (ShareLink)
  - ⚠️ **No real-time editing.** Sync is last-write-wins on the *whole* track list, so simultaneous edits by two people can overwrite each other. Live collaborative editing is explicitly deferred.
  - ⚠️ Songs a joiner doesn't own locally show as **"unavailable" placeholder tracks** (metadata-only) so the list isn't empty.
  - ✅ Backend migration + RLS are applied and verified (tables locked to `auth.uid()`).

## Playback
- [ ] Play / pause / next / previous
- [ ] Queue (add, play next, reorder) + queue popover/panel
- [ ] Shuffle
- [ ] Resume last session on launch (paused at saved position, no auto-play)
- [ ] Recently played history
- [ ] Now Playing view / inspector

## Equalizer
- [ ] 10-band graphic EQ with enable toggle (Settings → Playback)
- [ ] Presets + Reset; adjustments persist across launches
  - ⚠️ Selecting the **"Custom"** preset is intentionally a no-op (it has no fixed curve) — by design, not a bug.

## Lyrics
- [ ] Lyrics display: embedded tags → `.lrc` sidecar → LRCLIB API fallback
- [ ] Synced (timestamped) lyrics + plain-text fallback
- [ ] Now Playing lyrics (iOS) + Mac lyrics popover
  - ⚠️ Network failures fail **silently** (no lyrics shown, no error) — expected behaviour, worth confirming it feels right.

## Last.fm
- [ ] Connect Last.fm account (Settings → Last.fm)
- [ ] Scrobble on play + "now playing" updates
  - ⚠️ Scrobbling no-ops until an account is connected (guarded) — verify the connect flow actually authenticates.

## Account & auth
- [ ] Sign up / sign in
- [ ] Manage account: change username / email / password (`AccountSettingsView`)
- [ ] Sign out + multi-user local data isolation (wipe on account switch)

## Sync & storage
- [ ] Library (tracks/albums/artists/playlists) syncs across devices
- [ ] Audio files upload/download via Supabase storage
- [ ] Background auto-sync (~60s) + Sync Now + live sync-status badge
  - ⚠️ Conflict resolution is last-write-wins on `updated_at` — fine for single-user, worth watching with multiple devices editing offline.

## Downloads & export
- [ ] Download tracks to disk (choose export location, open folder)
- [ ] "Download on Wi-Fi only" toggle
- [ ] "Update files on disk when metadata changes" toggle
- [ ] M3U / M3U8 playlist export

## App & system
- [ ] Appearance: Light / Dark / System
- [ ] Haptic feedback (iOS)
- [ ] Auto-update via Sparkle (macOS)
- [ ] Settings → Developer Tools (delete all music / playlists / clear DB)
  - ⚠️ Gated behind the `isDeveloper` role flag (UI only; real protection is RLS).

---

### Cross-cutting things to re-check each release
- [ ] Smart Playlists wired into macOS (currently iOS-only)
- [ ] Real-time collaborative editing (currently deferred)
- [ ] First-launch right-click→Open friction (un-notarized build) — revisit if/when notarized
