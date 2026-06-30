#!/usr/bin/env bash
#
# bump.sh — Bump Mixtape's version numbers in one step.
#
# Updates BOTH version fields in Mixtape.xcodeproj/project.pbxproj:
#   • MARKETING_VERSION       (CFBundleShortVersionString) — human-facing, SemVer
#   • CURRENT_PROJECT_VERSION (CFBundleVersion)            — build counter, +1
#
# The build number ALWAYS increments by 1 (Sparkle compares it to decide if an
# update exists, so it must strictly increase on every shipped build).
#
# Usage:
#   ./scripts/bump.sh patch      1.2.3 -> 1.2.4   (bug fixes only)
#   ./scripts/bump.sh minor      1.2.3 -> 1.3.0   (new features, nothing breaks)
#   ./scripts/bump.sh major      1.2.3 -> 2.0.0   (big/breaking changes)
#   ./scripts/bump.sh 2.5.0      set marketing version explicitly
#
# Run from the repo root (the dir containing Mixtape.xcodeproj).
# After bumping, run ./scripts/release.sh to build & package.

set -euo pipefail

PBXPROJ="Mixtape.xcodeproj/project.pbxproj"
[ -f "$PBXPROJ" ] || { echo "✗ Run from the repo root (can't find $PBXPROJ)"; exit 1; }
[ $# -eq 1 ] || { echo "Usage: ./scripts/bump.sh {patch|minor|major|X.Y.Z}"; exit 1; }

# ── Read current values (first occurrence; all configs share them) ────────────
CUR_VERSION=$(grep -m1 -E 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/')
CUR_BUILD=$(grep -m1 -E 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/')
[ -n "$CUR_VERSION" ] || { echo "✗ Could not read MARKETING_VERSION"; exit 1; }
[ -n "$CUR_BUILD" ]   || { echo "✗ Could not read CURRENT_PROJECT_VERSION"; exit 1; }

# Normalize current marketing version to MAJOR.MINOR.PATCH
IFS='.' read -r MAJ MIN PAT <<<"$CUR_VERSION"
MAJ=${MAJ:-0}; MIN=${MIN:-0}; PAT=${PAT:-0}

# ── Compute new marketing version ─────────────────────────────────────────────
case "$1" in
  patch) PAT=$((PAT + 1)) ;;
  minor) MIN=$((MIN + 1)); PAT=0 ;;
  major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
  [0-9]*.[0-9]*.[0-9]*) IFS='.' read -r MAJ MIN PAT <<<"$1" ;;
  *) echo "✗ Unknown bump '$1' — use patch|minor|major|X.Y.Z"; exit 1 ;;
esac
NEW_VERSION="$MAJ.$MIN.$PAT"
NEW_BUILD=$((CUR_BUILD + 1))

# ── Apply to every config block in the pbxproj ────────────────────────────────
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $NEW_VERSION;/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"

cat <<DONE
✅ Bumped:
   Marketing version:  $CUR_VERSION  ->  $NEW_VERSION
   Build number:       $CUR_BUILD  ->  $NEW_BUILD

Next:
   1. ./scripts/release.sh                      # build, sign, package, write appcast
   2. gh release create v$NEW_VERSION build/Mixtape-$NEW_VERSION.dmg \\
        --repo mikec-1/Mixtape --title "Mixtape $NEW_VERSION" --notes "…"
   3. git tag v$NEW_VERSION && git push --tags  # tag the exact code for this release
   4. git add docs/appcast.xml && git commit -m "Appcast: v$NEW_VERSION" && git push
DONE
