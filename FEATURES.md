# Mixtape feature tracker (internal)

Everything on `develop`, grouped by the release it goes out in. `README.md` is the public
README and only lists what's out.

Refreshed 2026-10-12. Items up to 09-20 were checked against the code; later ones come from
the commit log and session notes. "Out in 1.1.2" was checked against `main`.

- [x] = built and reachable on `develop`
- ⚠️ = partial, platform-limited, or known-buggy
- Unticked = not built yet

`server/` (resolver) and `supabase/` (schema + migrations) live on disk but are untracked,
see `.gitignore`. How to cut a release is in `RELEASING.md`.

---

## Release plan (draft)

Mac releases go out through Sparkle. iOS isn't distributed yet and gets its own first
release (see iOS below). The website has no version number.

| Release | Theme | Headline |
|---|---|---|
| 1.1.2 | Out now | Import, library, playlists, playback, sync |
| 1.2.0 | The new Mac app | New window, sidebar, song lists, player bar, Settings, sign-in |
| 1.3.0 | Mac integration | Menu bar player, Controls menu, Dock, Siri, Spotlight |
| 1.4.0 | Menus and library tools | One song menu everywhere, Edit Metadata, aliases, watched folders |
| 1.5.0 | Make it yours | Look presets, density, motion, colour backdrop |
| 1.6.0 | Playback | Volume levelling, gapless and crossfade, trim silence |
| 1.7.0 | Lyrics | Synced and word-timed lyrics, karaoke, your own lyrics |
| 1.8.0 | Sound | Equalizer, smart fades, beat-matched transitions |
| 1.9.0 | Stats and history | Stats page, history, play counts, Last.fm |
| 1.10.0 | Smart playlists | Rules on the Mac, monthly tapes, Year in Tapes |
| 1.11.0 | Home | A Home page made from your library |
| 1.12.0 | Tape tools | Sides, auto-reverse, tape decks, liner notes |
| 1.13.0 | Command palette | ⌘K |
| 2.0.0 | Online music | Discover, streaming, offline downloads |
| 2.1.0 | Spotify | Import, export, two-way playlist links |
| 2.2.0 | Mixes and radio | Weekly mixes, song radio, autoplay |
| 2.3.0 | Profiles and sharing | Usernames, profiles, share links and cards |
| 2.4.0 | Dubs and crates | Frozen gift copies, bundles of playlists |
| 2.5.0 | Jam | Listen together, one queue |
| 2.6.0 | Blend | A daily playlist for two |
| 2.7.0 | Continuity | Hand playback between devices |
| 2.8.0 | Messages | Inbox, invites, DMs, notifications |
| 2.9.0 | Recap | Monthly recap and story clips |
| 2.10.0 | Edits | Song editor, waveforms |
| 2.11.0 | Studio | Stems and arranging (Mac only) |
| 2.12.0 | Community | Posts, follows, profile tabs |

How the plan holds together:

- **1.2.0 is big on purpose.** The redesigns replaced the old window, sidebar, song table,
  player bar, Settings and sign-in rather than sitting beside them, so a release switch
  can't bring the old ones back. Everything that only adds (menu bar player, appearance
  settings, lyrics, …) can wait for its own release.
- **1.2.0 also carries the plumbing** (sync, library model, accounts) whatever the switches
  say. It's the release to beta-test hardest.
- **New sidebar rows and Settings rows appear with their release.** Home, Discover, Crates,
  Community and Local Files stay hidden until then, and so do Settings rows like Connections,
  EQ and transitions.
- **Online songs come in at 2.0.** Anything that plays songs you don't own (mixes, shares,
  Spotify imports, Jam, Blend, edits of online songs) can't go out before it.
- **Where an early feature touches a later one,** that part stays hidden until its own
  release. Examples: the menu bar player's lyric line, ⌘K's radio verb, names linking to
  Discover.

---

## Out in 1.1.2

### Mac window
- Sidebar: Songs, Albums, Artists, Playlists, Settings, drag to reorder, pinned playlists
- Toolbar: Sync, Import, Add to Playlist, Delete, search field
- Right panel: Now Playing inspector or Queue
- Player bar with speed (0.5–2×) and sleep timer
- Zoom with ⌘+ / ⌘− / ⌘0
- Song table with zebra rows; artists with an inner list; playlists as a plain list

### Library and playback
- Import with metadata lookup (iTunes) and a review step, filename fallback, exact duplicates skipped
- Album and artist pages, track inspector
- Playlists: create, edit, pin, drag to reorder
- Favourites
- Play, queue, play next, shuffle, repeat, resume on launch, recently played
- Fuzzy library search
- Play / pause from the keyboard media keys and Control Center

### Account and sync
- Sign in; library and files sync across devices; Sync Now
- Download / export to disk, Wi-Fi only, M3U export

### Settings
- Account (username, email, password, sign out), Appearance (Light / Dark / System), Sync,
  Downloads, Developer Tools, About (Check for Updates)
- Also opened as a separate Preferences window
- Sparkle auto-update

### In the code but not reachable in 1.1.2
- Equalizer engine, gapless and crossfade modes (no switch in the app)
- Last.fm scrobbler, listening stats view, playlist sharing service (no UI)
- iOS: tabs Library, Search, Queue, Settings; mini player; Now Playing; smart playlists;
  haptics switch. Never distributed.

---

## 1.2.0 · The new Mac app

### Window
- [x] Hidden title bar with a custom top bar, replacing the toolbar. Traffic lights keep their clearance at every zoom level.
- [x] Search moves to a centred capsule field (⌘F) with type-ahead suggestions. Search runs on Return, so typing never takes you off the page.
- [x] Back / forward through pages, library tabs, artists and Settings panes
- [x] Toolbar cut to a + menu and Sync. ⌘⌫ still deletes.
- [x] One artwork wash across top bar, sidebar, page and right panel (replaces the sidebar material)
- [x] Splash screen at launch

### Sidebar
- [x] Rebuilt: Library at the top, then playlists with their real covers, Settings at the bottom
- [x] Playlist list: sort, Arrange / Done, filter, drop songs onto a playlist
- [x] Pinned playlists stay on top; drag works across the pinned boundary
- [x] Footer shows library activity, downloads and offline state
- [x] Collapses to an icon rail
  - ⚠️ Until their releases, Home, Discover, Crates, Community and Local Files are hidden, so the top section is just Library.

### Library pages
- [x] Playlists, Songs, Albums and Artists become tabs of one Library page, remembered across launches
- [x] Song table: flat rows with hover, a play badge on hover, single-click artwork plays, a heart column (replaces zebra rows)
- [x] Playlists tab: 48pt covers, single click opens, hover play, offline badge
- [x] Artists tab: a grid of round photos opening a detail page (replaces the inner list)
- [x] Playlist, album and artist pages share one header: big cover, artwork wash, action row
- [x] Playlist page: the cover is the edit button; rows with a number column, hover play, inset highlight
- [x] Search inside a playlist; sort by column header or menu, and the two agree
- [x] Shuffle is a stored setting per list

### Player bar and right panel
- [x] Three-column player bar: transport always centred, a save check after the title
- [x] Song title and artist are links
  - ⚠️ Names open Discover once 2.0 is out; until then they must open the library artist page. Needs its switch.
- [x] Right panel with Now Playing / Queue / Recent tabs and a close button (replaces the inspector / queue toggle)
- [x] Queue: manual-queue badge, reorder, clear
  - ⚠️ `MacQueuePopover.swift` is a stale filename; it holds the two panel views.

### Settings
- [x] Rebuilt as two columns with a category list: Account, General, Playback, Downloads, Storage, Sync, Connections, About, Developer, Danger Zone
- [x] Search across every setting
- [x] Storage page: what's using space, cache limits
- [x] The separate Preferences window is gone; Settings lives in the main window

### Feedback
- [x] Toasts: one style everywhere, with View / Undo
- [x] "Added to X" pill and a save bounce
- [x] One sheet style for every modal: close X, click outside to close, Esc cancels, Return commits

### Account
- [x] New sign-in card (the same card on web, iOS and Mac), email + Google
- [x] Manage account: display name, email, password
- [x] Sign out is scoped (Supabase defaults to GLOBAL); Danger Zone holds every destructive action
- [x] Offline mode: a flag, not an auth state
- [x] Guest mode
- [x] Developer Tools behind the `isDeveloper` role
  - ⚠️ The role is UI-only; real protection is RLS.

### Library model (plumbing)
- [x] Derived membership: All Songs is computed, never written. "Add to Library" = Like. Favourites becomes Liked Songs.
- [x] Album identity is title + artist
- [x] Multi-artist songs split into their credited artists
- [x] Explicit / clean versions tiered, with an **E** badge
- [x] Sort order and per-playlist sort follow the account

### Sync (plumbing)
- [x] Paginated pulls (PostgREST's silent 1000-row cap)
- [x] Tombstones for deletes, with pruning
- [x] Realtime cross-device sync
- [x] Per-account store files; multi-account isolation
- [x] Remote wipes announce a reset
- [x] Migration history in sync
  - ⚠️ Conflicts are last-write-wins on `updated_at`.

### Under the hood
- [x] New app icon (Icon Composer, dark + tinted)
- [x] Crash reports and analytics, with a privacy manifest
- [x] Accessibility 8.1–8.6: VoiceOver values, keyboard-focusable cards, states not by colour alone
  - ⚠️ Dynamic Type still has unscaled text sizes. Audit unfinished.

---

## 1.3.0 · Mac integration
- [x] Controls menu, with shortcuts out of the key monitor (⌘L like, ⌘I info, ⌘↑↓ volume, ⌥⌘→← seek, ⌘⇧S shuffle)
- [x] Menu bar player: scrubber, volume, shuffle/repeat, like, up next, sleep/speed, title in the menu bar. Settings switch.
  - ⚠️ Its lyric line waits for 1.7.
- [x] Dock menu: Play/Pause, Next, Previous
- [x] Siri and Shortcuts: play a playlist, like the current song
  - ⚠️ On macOS Siri's music domain eats "Play X". A personal Shortcut is the reliable route.
- [x] Spotlight indexes library songs with covers and artists; a hit plays it
- [x] Shuffle, repeat and like from AirPods, Control Center and Watch
- [x] Reveal in Finder
- [x] Open at Login
- [x] Drop files anywhere on the window to import

---

## 1.4.0 · Menus and library tools

### Menus
- [x] One shared song menu everywhere (replaced nine hand-written copies)
- [x] Full menus on albums, artists and playlists
- [x] Like from queue rows
- [x] "Saved in" panel: where a song is saved, next to the + that opens it
- [x] Edit Metadata
- [x] Make a Copy of a playlist

### Library tools
- [x] Duplicate detection + merge
- [x] Artist name aliases: link "Digga" to "Digga D" without renaming
- [x] Move to Artist Folder
- [x] Artist bios and profile photos
- [x] Restore Missing Songs, Find Missing Covers, Refetch All Covers
- [x] Import ledger with "already imported" badges; Stop rolls the whole run back
- [x] Show All Songs, per account
- [x] Custom playlist covers, two-way synced
  - ⚠️ Cover consistency plan (`coverIsDerived`) not started.
- [x] Watched folders + Local Files page (new sidebar row)
  - ⚠️ The row only appears once a watched folder contains music.

---

## 1.5.0 · Make it yours
- [x] Look presets: Normal, Minimal, Efficient, Custom
- [x] Density, Motion and Chrome as separate settings under the presets
- [x] Colour backdrop: a colour you pick, mixed into the whole window, with optional drift
- [x] Hardware Acceleration switch (Metal backdrop, read once per launch)
  - ⚠️ Every build needs the Metal Toolchain.

---

## 1.6.0 · Playback
- [x] Volume normalization (BS.1770, measured at first play, cached on the file)
- [x] Gapless and crossfade get a setting (the engine has had them since 1.1.2)
- [x] Crossfade on skip (opt-in, uses the user's length)
- [x] Trim Trailing Silence switch
- [x] Short fade on play / pause

---

## 1.7.0 · Lyrics
- [x] Embedded tags → `.lrc` sidecar → LRCLIB → NetEase
- [x] Synced lyrics with tap-to-seek; plain-text fallback
- [x] Word-timed lyrics (Apple TTML) with a karaoke view and its own moving backdrop
- [x] Lyrics popover in the player bar, or fullscreen in the window
- [x] Lyric line in the menu bar player
- [x] Your own lyrics: an editor, keyed on normalised `title|artist`, and a "Your Lyrics" list in Settings
  - ⚠️ Network failures are silent (no lyrics, no error), by design.

---

## 1.8.0 · Sound
- [x] 10-band EQ with presets (23), per account. First time the EQ is reachable.
  - ⚠️ "Custom" is a no-op on purpose.
- [x] Smart fade: skips silence, starts at the outro
- [x] Beat-matched crossfades
- [x] Per-playlist transitions (in `user_metadata`)

---

## 1.9.0 · Stats and history
- [x] Stats page: top artists / tracks / albums, totals, listening over time, streaks, heatmap, genres, devices, rank movement
- [x] History page: browse and clear
- [x] Play counts, first played and artist standing in Get Info and on artist pages
- [x] Plays remember the playlist, album or mix they came from
- [x] Play history syncs, `seconds_played` recorded, capped at 200k rows
- [x] Private session (6-hour expiry)
- [x] Last.fm scrobbling (Settings → Connections)

---

## 1.10.0 · Smart playlists
- [x] Rule-based smart playlists on the Mac (until now iOS-only, and iOS never shipped): create / edit, a Smart tab in Library
- [x] Built-in rules incl. Forgotten Favourites, Weekly Deal
- [x] 10-song floor: a rule with too few matches isn't shown
- [x] Smart shuffle (mixes library songs into a shuffled list)
  - ⚠️ `SmartPlaylistsView.swift` is a stale filename.
- [x] Monthly tapes: your top 25 of each month, filling as you listen, frozen on the 1st
- [x] Year in Tapes

---

## 1.11.0 · Home
- [x] Home page (new sidebar row): greeting, Jump back in, recent artists, Recently added, Liked Songs, smart playlists, genre shelf
- [x] "This week, one year ago"
- [x] Monthly tapes shelf
- [x] Listening-stats tile

---

## 1.12.0 · Tape tools
- [x] Sides: split a playlist into A and B, synced
- [x] Auto-reverse: repeat flips side to side; Tape eyebrow on the playlist page
- [x] Tape decks: three named queues that keep their place
- [x] Liner notes on playlists and songs, synced

---

## 1.13.0 · Command palette
- [x] ⌘K: search anything, jump anywhere
- [x] Verbs: queue, download, goto
  - ⚠️ The radio verb waits for 2.2, dub for 2.4.

---

## 2.0.0 · Online music

### Discover
- [x] Discover page (new sidebar row); the top-bar search gains online results
- [x] Sectioned search (Deezer) with Spotify artist images, search history + suggestions
- [x] Artist pages, album pages, top tracks
- [x] Song and artist names open Discover from everywhere

### Streaming
- [x] Hosted resolver (yt-dlp behind `server/resolver.py`), `/live` HLS so a cold tap starts fast
- [x] Identity gates so the resolver can't swap in a different recording
- [x] "Wrong version" → re-resolve, walking a rejection list; a card to go back, try another or keep it; pins honoured everywhere
- [x] Padded-source trimming
- [x] Preparing bar while a song resolves; red mark on queue rows nothing online has; a strip naming songs the queue skipped
- [x] Link imports with a review sheet; a link upgrades a saved online song in place
  - ⚠️ The resolver is one Oracle Always-Free box. Check it holds before this goes out.

### Offline
- [x] Per-song download opt-in, batch per playlist, stoppable, with progress
- [x] Green "complete" disc reads the disk, not the opt-in
- [x] Download quality setting
  - ⚠️ Offline files are AAC, not Opus.

---

## 2.1.0 · Spotify
- [x] Connect account (Settings → Connections, new row)
- [x] Import playlists + Liked Songs, with an import ledger
- [x] Export playlists; push likes (additive, never before a baseline pull)
- [x] Two-way playlist links with a three-way merge
- [x] 429s surfaced app-wide
  - ⚠️ Imported songs play as online songs, so this can't go before 2.0.

---

## 2.2.0 · Mixes and radio
- [x] Weekly shelves on Discover: mixes, radar, radios, genres. One row per account, feedback syncs.
- [x] Generated mixes with baked covers; Generate a Mix
- [x] Song Radio from any song
- [x] Autoplay after a single pick; the queue gets a third lane for recommendations
- [x] Don't suggest this song / this artist
- [x] Fetch While Browsing; Download Ahead in the queue
- [x] ⌘K radio verb

---

## 2.3.0 · Profiles and sharing
- [x] @usernames, profile pages, Find People
- [x] Blob avatars, seeded by username (Swift and web in lockstep)
- [x] Avatar menu in the corner: profile, account, find people, sign out
- [x] Share links open mixtaped.tech; in-app links stay in the app
- [x] Public playlist pages + save counts
- [x] Share sheet with cards; lyric cards
  - ⚠️ No real-time collaborative editing. Last-write-wins on the whole track list.

---

## 2.4.0 · Dubs and crates
- [x] Dubs: a frozen shared copy with a cover, recipient and note
- [x] Crates: playlists, albums and artists shared as one link (new sidebar section)
- [x] ⌘K dub verb

---

## 2.5.0 · Jam
- [x] Start one or join with a code or QR; the host plays, everyone adds to one queue
- [x] Guest control; the Jam ends when the host leaves
- [x] Jams near you (local network)

## 2.6.0 · Blend
- [x] A two-person daily playlist

## 2.7.0 · Continuity
- [x] Hand playback between devices, with cover art (devices button in the player bar)
  - ⚠️ Needs migration `20260916000000` (applied to production).

## 2.8.0 · Messages
- [x] Inbox, playlist invites + collaborators
- [x] DMs: exact previews, edit for 15 min, unsend, reactions, replies, Sent / Read, typing, attachments
- [x] Local notifications: invites, Jams nearby, new releases, tap routing
  - ⚠️ No APNs. Mac and iOS poll; Web Push is web only.

## 2.9.0 · Recap
- [x] Monthly recap: story, share card, profile shelf, private by default
- [x] Story clips with a Wrapped look: pre-cut clips, clock-driven slides, gentle-motion switch
  - ⚠️ Needs history from the month's first week.
- [x] Spotify listening merges in when an account is connected

## 2.10.0 · Edits
- [x] Song editor: speed, pitch apart from speed, bass boost, trim with fades. Saved as new songs.
- [x] The recipe syncs and each device rebuilds the file
- [x] Waveforms (500 RMS slices, time tags)
- [x] Edits take their original's cover

## 2.11.0 · Studio (Mac only)
- [x] Stems (DemucsMLX, Mac arm64 only)
- [x] Arranging: full-window studio, zoom, drag parts, undo, loop a part, beat snap, edge scroll, shortcuts
- [x] Studio edits upload their file

## 2.12.0 · Community
- [x] Community page (new sidebar row): posts with audio, follows, profile tabs
- [x] Comment dots, notifications, moderation

---

## iOS (first iOS release)
Carries everything out on the Mac by then, with the same switches. iOS-only on top:

### Redesigns (replace the never-shipped 1.1.2 screens)
- [x] Tabs become Home, Search, Community, Library (were Library, Search, Queue, Settings)
  - ⚠️ Home and Community tabs follow their releases; the shell needs a layout for when they're hidden.
- [x] Now Playing redesigned Spotify-style: one ••• menu instead of rows of buttons
- [x] Mini player that pages scroll clear of; long titles scroll
- [x] Library header: avatar on the title line, filter pills, a + menu with every way to add a playlist
- [x] Pull to refresh runs a full sync
- [x] Toasts float above sheets; confirmations use one dialog style

### iOS-only features
- [x] Home with no connection, made from downloads (with 2.0)
- [x] Search keeps focus after a tab switch
- [x] Widgets: Now Playing + Cover Art, Up Next, Cassette, Vinyl, Big Type, Click Wheel, Receipt
- [x] Live Activity / Dynamic Island (opt-in, Settings ▸ General ▸ Lock Screen)
- [x] Audio interruptions + route changes (survives a phone call)
- [x] CarPlay
  - ⚠️ Simulator only. A device needs Apple's carplay-audio entitlement.

## Web player (separate `mixtape-web` repo)
- [x] Full port, already live: library, queue, lyrics, Discover, social, Jam, messages, recap, edits, import, settings, ⌘K
- [x] Saved library in IndexedDB for first paint
  - ⚠️ Not in this repo. Astro on Cloudflare. It's ahead of the Mac releases.

---

### Cross-cutting, re-check each release
- [ ] Release switches: one table where each feature names the version it ships in. Not built yet.
- [ ] Switches hide additions only. Anything that replaced old UI ships in 1.2.0.
- [ ] Update `README.md` with what's out, every release
- [ ] The server and database keep working for the oldest app out (1.1.2 today)
- [ ] Accessibility: Dynamic Type audit
- [ ] Playlist cover consistency (`coverIsDerived`), not started
- [ ] Resolver capacity before 2.0
- [ ] Rename `MacQueuePopover.swift` and `SmartPlaylistsView.swift`
- [ ] Every build needs the Metal Toolchain (stems, shader backdrop)
- [ ] First-launch Open Anyway friction (un-notarized build)
