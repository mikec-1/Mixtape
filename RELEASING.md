# Releasing Mixtape

How versions, build numbers and betas work, and what to run for each kind of release.
`scripts/release.sh` does all of the numbering. Nothing here needs editing by hand.

## The two numbers

| | Xcode setting | Example | Who reads it |
|---|---|---|---|
| **Version** | `MARKETING_VERSION` | 2.0.0 | People: About screen, website, GitHub |
| **Build** | `CURRENT_PROJECT_VERSION` | 10 | Sparkle, to decide whether an update is newer |

The build number is one counter for every build that leaves your Mac, beta or stable.
It only goes up, is never reused, and never resets when the version changes. Gaps are
fine; Sparkle only cares that the new one is higher.

The Mac app, the iOS app and the widget share both numbers.

## When the version changes

Pick by the biggest change in the release:

- **Patch** (2.0.0 → 2.0.1): fixes only. Always cut from `main`.
- **Minor** (2.0.x → 2.1.0): anything new that a user can see.
- **Major** (2.x → 3.0.0): rare. Something old stops working: a sync or database change
  older apps can't read, or dropping a macOS version. 2.0 is one.

## Betas

A beta is a build of the next version before it's finished. It has the same version
as the final release and a lower build number, so 2.0.0 beta 1, beta 2 and 2.0.0 are
builds 10, 11 and 12.

"beta N" appears in the tag (`v2.0.0-beta.1`), the DMG name, the feed, the GitHub
release title and the app's About screen. It never goes into `MARKETING_VERSION`,
because TestFlight and the App Store only accept plain numbers there. `release.sh`
marks the build itself as a beta through the `MixtapeBeta` Info.plist key.

## Branches

- `main` is what's out. GitHub Pages serves the update feed from `main/docs`, so
  nothing reaches anyone until it's on `main`.
- `develop` is what's next. Betas are cut from here.

## What to run

Always run with `--dry-run` first. It prints the version, build and names without
changing anything.

| You want | Branch | Command |
|---|---|---|
| First beta of the next version | `develop` | `./scripts/release.sh --beta minor` (or `major`) |
| Another beta | `develop` | `./scripts/release.sh --beta` |
| Ship the version the betas were for | `main`, after `git merge --ff-only develop` | `./scripts/release.sh` |
| Hotfix | `main` | `./scripts/release.sh patch` |

Add release notes as the last argument: `./scripts/release.sh --beta "<ul><li>…</li></ul>"`.

The script builds, signs and writes the feed, then prints the remaining steps. It never
uploads, commits or pushes. Follow its steps in order:

1. Upload the DMG to GitHub (`gh release create …`). A beta is marked as a pre-release.
2. Commit everything as one release commit: `Mixtape 2.0.0 beta 1 - Release DD.MM.YYYY - summary`.
3. Get the feed onto `main` and merge `main` back into `develop`. For a beta that's a
   small "Appcast" commit on `main`, since the code stays on `develop`.

## The road from here

| Release | Version | Build | Branch | Command |
|---|---|---|---|---|
| 1.1.2 (out now) | 1.1.2 | 4 | `main` | |
| 2.0.0 beta 1 | 2.0.0 | 10 | `develop` | `--beta` |
| 2.0.0 beta 2 | 2.0.0 | 11 | `develop` | `--beta` |
| 2.0.0 | 2.0.0 | 12 | `main` | (fast-forward to `develop`, then no flags) |
| 2.0.1 | 2.0.1 | 13 | `main` | `patch` |
| 2.1.0 beta 1 | 2.1.0 | 14 | `develop` | `--beta minor` |

Builds 5 to 8 are skipped because `develop` was already at 9 when this was written.

## Who gets what

- **1.1.2 users** have no toggle and never see betas. A tester downloads 2.0.0 beta 1
  once from the GitHub pre-release. On first launch macOS will ask for Open Anyway in
  System Settings, Privacy & Security. From then on Sparkle delivers each beta, then 2.0.0.
- **Beta builds** start with Settings › About › Receive Development Builds turned on.
  Turning it off stops new betas; the tester stays on the beta they have until a stable
  release with a higher build comes out.
- **Stable users** get nothing until 2.0.0.

## Rules that keep it working

1. **Upload before committing.** The feed must never point at a DMG that isn't there yet.
2. **Never pick a build number yourself.** `release.sh` reads the live feed and goes one
   higher, so a beta on `develop` and a hotfix on `main` can't collide.
3. **A hotfix during a beta moves testers back.** 2.0.2 gets a higher build than
   2.1.0 beta 1, so Sparkle offers it to testers too. Merge `main` into `develop` and cut
   the next beta straight after the hotfix.
4. **After anything lands on `main`, merge `main` into `develop`.** If the version lines
   in `project.pbxproj` conflict, keep `develop`'s side. The build number comes from the
   feed anyway.
5. **The server and database must keep working for the oldest app still out there**
   (1.1.2 today). The website has no version and ships whenever it's ready.

## Before 2.0.0 (one time)

- `README.md` is two documents: the public README on `main` and the internal feature
  tracker on `develop`. Fast-forwarding `main` would publish the tracker. Before the
  release, move the tracker to its own file on `develop` and put a public 2.0 README
  in its place.
- Once beta 1 is in the feed, mixtaped.tech/about can mention development builds again.
