# Mixtape — `develop` Feature Tracker (internal)

Personal checklist for the full build. **2.0.0 (build 9)**, last verified against the code on 2026-09-20.

- [x] = implemented and reachable in the current build (verified by reading the code, not by testing it).
- ⚠️ = partial, platform-limited, or known-buggy.
- Unticked = genuinely not built yet.

> This is the advanced/full branch. `main` is the trimmed public 1.0.
> `server/` (resolver) and `supabase/` (schema + migrations) live on disk but are deliberately untracked — see `.gitignore`.

---

## Library & import
- [x] Import audio files (`+` button / file picker / drag-drop)
- [x] Automatic metadata enrichment (iTunes lookup) with review sheet before applying
- [x] Filename parsing fallback when tags are missing
- [x] Browse by Songs / Albums / Artists / Playlists
- [x] Sortable native track table (Mac) with columns (title, artist, album, date added…)
- [x] Album & Artist detail views
- [x] Track inspector (artwork, metadata, file format/size)
- [x] Derived library membership — All Songs is computed, never written; "Add to Library" = Like
- [x] Album identity is title + artist (two records sharing a title stay separate)
- [x] Artist name aliases — link "Digga" to "Digga D" without renaming (the id hashes `title|artist`)
- [x] Duplicate detection + merge
- [x] Import ledger with "already imported" badges
- [x] Import is stoppable, and Stop rolls the whole run back
- [x] Explicit / clean tiering with an **E** badge

## Local files & watched folders
- [x] Watched folders — a derived, read-only view over folders you point at
- [x] Local Files page; promoting a local file into the library is just the import path
  - ⚠️ Sidebar row only appears once a watched folder actually contains music.

## Home
- [x] Home carousels: Jump back in, Recently added, Liked Songs, smart playlists
- [x] Listening-stats tile with "See all" → full stats
- [x] Genre shelf
- [x] Deleted songs no longer surface in recently-played

## Discover (online catalogue)
- [x] Sectioned search (Deezer) with Spotify artist images
- [x] Playback via the hosted resolver (yt-dlp behind `server/resolver.py`)
- [x] Artist pages, album pages, top tracks
- [x] Identity gates so the resolver can't substitute a different recording
- [x] "Wrong version" → re-resolve, walking a rejection list
- [x] Resolver pins honoured on **both** macOS and iOS
- [x] Padded-source trimming (trailing-silence uploads trimmed to catalogue length)
- [x] Search history + suggestions

## Mixes & smart playlists
- [x] Rule-based smart playlists, create/edit
- [x] Reachable on **macOS** (sidebar) *and* **iOS** (Library section + Home)
- [x] Built-in rules incl. Forgotten Favourites, Weekly Deal
- [x] 10-song floor — a rule with too few matches isn't shown
- [x] Generated mixes with baked cover art
- [x] Mix randomness centralised so it matches across devices

## Playlists & Liked Songs
- [x] Create / edit / delete playlists
- [x] Pin to sidebar + drag to reorder (Mac & iOS), including across the pinned boundary
- [x] Liked Songs (renamed from Favourites)
- [x] Add-to-playlist sheet
- [x] Sort order follows the account, not the device
- [x] Per-playlist track sort, also account-synced
- [x] Custom playlist covers, two-way synced
  - ⚠️ Cover *consistency* plan (a `coverIsDerived` flag so bakes and custom art stop fighting) is **not started**.

## Sharing & social
- [x] Share links — open the **web player**, not the app
- [x] Public playlist pages + save counts
- [x] Profiles, @usernames, display names, Find People
- [x] Playlist invites + inbox
  - ⚠️ **No real-time collaborative editing.** Sync is last-write-wins on the whole track list, so simultaneous edits can overwrite each other. Still deferred.
  - ⚠️ Join-code flow is effectively retired — link sharing replaced it.
  - ⚠️ Shared-library-by-inference was a dead end and was removed: a share now carries its own title and goes to the resolver rather than refusing to play.

## Playback
- [x] Play / pause / next / previous / seek
- [x] Shuffle, per-list and remembered
- [x] Repeat, incl. repeat-one
- [x] Resume last session on launch at the saved position (no auto-play)
- [x] Recently played history, synced (append-only table)
- [x] Now Playing view / inspector
- [x] Three-column player bar with a centred transport (Mac)
- [x] Audio interruption + route-change handling (iOS) — survives a phone call

## Queue
- [x] Three lanes: manual / context / recommendation, on one flat list
- [x] Add to Queue, Play Next, reorder, clear
- [x] Manual-queue badge
- [x] Tabbed right panel (Queue / Recent) on Mac
- [x] Queue suggestions top the list up
  - ⚠️ `Mac/PlayerBar/MacQueuePopover.swift` is a stale **filename** — it holds `MacQueuePanelView` / `MacRecentPanelView`, both live. Rename when convenient.

## Lyrics
- [x] Embedded tags → `.lrc` sidecar → LRCLIB → NetEase fallback
- [x] Synced (timestamped) lyrics + plain-text fallback
- [x] Word-timed lyrics (Apple TTML) with karaoke view
- [x] Mac lyrics popover + iOS Now Playing lyrics
- [x] User-supplied lyrics, keyed on normalised `title|artist`
- [x] "Your Lyrics" list in Settings → Storage
  - ⚠️ Network failures fail **silently** (no lyrics, no error) — by design, worth confirming it still feels right.

## Equalizer
- [x] 10-band graphic EQ with enable toggle (Settings → Playback)
- [x] Presets + Reset; per-account, persists across launches
  - ⚠️ The **"Custom"** preset is intentionally a no-op (no fixed curve) — by design, not a bug.

## Search
- [x] Library search with fuzzy matching
- [x] Discover/browse results split into sections
- [x] Command palette (⌘K) — **macOS only**

## Spotify
- [x] Connect account (Settings → Connections)
- [x] Import playlists + Liked Songs, with an import ledger
- [x] Export playlists to Spotify; push likes (additive only, never before a baseline pull)
- [x] Follow / two-way playlist links with a real three-way merge
- [x] Rate-limit (429) surfaced as app-wide state, not one screen's error
  - ⚠️ **Development Mode 403s.** Spotify's March 2026 API migration means a dev-mode app reads some endpoints and 403s the rest. Write scopes are a separate opt-in grant. Extended access is the real fix.

## Sync & storage
- [x] Library (tracks/albums/artists/playlists) syncs across devices
- [x] Realtime cross-device sync
- [x] Paginated pulls (PostgREST's silent 1000-row cap used to drop rows)
- [x] Tombstones for deletes, with pruning
- [x] Play history syncs — what makes weekly mixes match across devices
- [x] Per-account store files; nothing holds a `ModelContext` across an account switch
- [x] Remote wipes announce a reset instead of arriving silently
  - ⚠️ Conflict resolution is last-write-wins on `updated_at`. Fine single-user; watch it with multiple devices editing offline.
  - ⚠️ Remote migration history is out of sync with local (37 local migrations). Needs `supabase migration repair` — run from the repo root.

## Offline
- [x] Offline mode — a flag, not an auth state; only explicit sign-out clears the cached user
- [x] Per-song download opt-in, stored as a choice
- [x] Batch enqueue for whole playlists
- [x] Downloads are stoppable, with per-run and overall progress
- [x] Green "complete" disc reads the disk, not the opt-in
  - ⚠️ Offline files are AAC, not Opus — macOS has no real streaming path. See the offline-audio-constraints note.

## Continuity (handoff)
- [x] Hand playback between devices, with cover art
- [x] Picking a song while mirroring sends it to the *current* player
  - ⚠️ Needs migration `20260916000000` applied before it works on a fresh project.

## Listening stats
- [x] Full stats page (top artists, tracks, totals)
- [x] `seconds_played` recorded per play and finalised on leave
- [x] History capped at 200k rows, pruned with slack so it isn't paid per-play
- [ ] Monthly "Wrapped"-style recap — designed, not built

## Account & auth
- [x] Sign up / sign in (email + Google)
- [x] Manage account: display name, @username, email, password
- [x] Sign out — scoped, since Supabase defaults to GLOBAL
- [x] Multi-account local data isolation
- [x] Danger Zone holds every destructive action; delete-account hands off to web
- [x] Guest mode

## Downloads & export
- [x] Download tracks to disk (choose export location, open folder)
- [x] "Download on Wi-Fi only" toggle
- [x] M3U / M3U8 playlist export
  - ⚠️ "Update files on disk when metadata changes" was **removed** — don't re-add without a reason.
  - ⚠️ Export folder scan + deletion ledger were **removed** on purpose. Sync is device-to-device only now.

## App & system
- [x] Appearance: Light / Dark / System
- [x] Haptic feedback (iOS)
- [x] Auto-update via Sparkle, with a beta channel (macOS)
- [x] Settings: category-based + searchable
- [x] Settings → Developer Tools, gated behind the `isDeveloper` role
  - ⚠️ Role flag is UI-only; real protection is RLS.

## Web player (separate `mixtape-web` repo)
- [x] Full port: library, queue, lyrics, Discover, social, import, settings, ⌘K
- [x] Guest mode, legal pages, signup consent
  - ⚠️ Not in this repo. Astro on Cloudflare, second Supabase client.

---

### Cross-cutting, re-check each release
- [ ] Accessibility button audit — EQ and player bar are labelled, the rest is listed and open
- [ ] Playlist cover consistency (`coverIsDerived`) — not started
- [ ] Monthly Wrapped recap — not started
- [ ] Spotify extended-access application (kills the 403s)
- [ ] Rename `MacQueuePopover.swift` and `SmartPlaylistsView.swift` — both filenames lie about their contents
- [ ] Supabase migration repair, then push the 2 genuinely-unapplied migrations
- [ ] Rewrite **main's public README** at 2.0 launch — it still describes the 1.0 Mac-only app (no iOS, Discover, Spotify, lyrics, sharing)
- [ ] First-launch right-click→Open friction (un-notarized build) — revisit if/when notarized
