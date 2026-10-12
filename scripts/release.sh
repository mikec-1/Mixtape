#!/usr/bin/env bash
#
# release.sh — Number, build, package, and sign a Mixtape macOS release.
# RELEASING.md says when to run what.
#
# Usage:  ./scripts/release.sh [--beta] [--dry-run] [patch|minor|major] ["<release notes HTML>"]
#   --beta     A beta of the current version, cut from develop. Goes out on the
#              Sparkle "beta" channel, tagged vX.Y.Z-beta.N.
#   --dry-run  Print the version, build, and names this run would use. Changes nothing.
#   patch|minor|major
#              Bump MARKETING_VERSION first: patch for a hotfix on main, minor or
#              major for the first beta of the next version on develop.
#   The optional release-notes argument is the body shown in the Sparkle update
#   window (simple HTML — <ul><li>… or <p>…). Defaults to a generic note.
#
# The build number is always one past the highest build in the live feed, so a
# beta on develop and a hotfix on main can never get the same number.
#
# Produces build/Mixtape-<version>[-beta.N].dmg, docs/appcast.xml, and (stable
# only) docs/index.html. It never commits, tags, or uploads; it prints those steps.
#
# Distribution is un-notarized: the app is ad-hoc signed and update integrity
# is guaranteed by Sparkle's EdDSA signature (private key in the login Keychain).
# First manual install needs a one-time Open Anyway (System Settings → Privacy
# & Security) on macOS 15+; Sparkle updates are seamless thereafter.
#
# Run from the repo root (the dir containing Mixtape.xcodeproj).

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
BETA=false
DRY_RUN=false
BUMP=""
NOTES_BODY="<p>Bug fixes and improvements.</p>"
for arg in "$@"; do
    case "$arg" in
        --beta)            BETA=true ;;
        --dry-run)         DRY_RUN=true ;;
        patch|minor|major) BUMP="$arg" ;;
        *)                 NOTES_BODY="$arg" ;;
    esac
done

# ── Config ───────────────────────────────────────────────────────────────────
PROJECT="Mixtape.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="Mixtape"
APP_NAME="Mixtape"
REPO="mikec-1/Mixtape"
FEED_URL="https://mikec-1.github.io/Mixtape/appcast.xml"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
[ -f "$PBXPROJ" ] || { echo "✗ Run from the repo root (can't find $PBXPROJ)"; exit 1; }

# ── Betas come from develop, everything else from main ───────────────────────
BRANCH=$(git branch --show-current)
if [ "$BETA" = true ]; then WANT=develop; else WANT=main; fi
if [ "$BRANCH" != "$WANT" ]; then
    echo "✗ This release is cut from $WANT, you're on $BRANCH. See RELEASING.md."
    [ "$DRY_RUN" = true ] || exit 1
fi

# ── Version ──────────────────────────────────────────────────────────────────
CUR_VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/')
CUR_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/')
IFS='.' read -r MAJ MIN PAT <<<"$CUR_VERSION"
MAJ=${MAJ:-0}; MIN=${MIN:-0}; PAT=${PAT:-0}
case "$BUMP" in
    patch) PAT=$((PAT + 1)) ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
esac
VERSION="$MAJ.$MIN.$PAT"

# Tags already on GitHub for this version: v2.0.0, v2.0.0-beta.1, …
TAGS=$(git ls-remote --tags origin "v$VERSION*" | sed -E 's|.*refs/tags/||; s|\^\{\}$||' | sort -u)
if grep -qx "v$VERSION" <<<"$TAGS"; then
    echo "✗ $VERSION is already out. Add patch (hotfix on main) or minor (next beta on develop)."
    exit 1
fi

# ── Build number: one past anything users can already have ───────────────────
FEED=$(curl -fsS "$FEED_URL") || { echo "✗ Couldn't read $FEED_URL"; exit 1; }
FEED_BUILD=$(echo "$FEED" | sed -nE 's/.*<sparkle:version>([0-9]+)<.*/\1/p' | sort -n | tail -1)
FEED_BUILD=${FEED_BUILD:-0}
BUILD_NUM=$(( (FEED_BUILD > CUR_BUILD ? FEED_BUILD : CUR_BUILD) + 1 ))

# ── Names ────────────────────────────────────────────────────────────────────
if [ "$BETA" = true ]; then
    LAST_BETA=$(echo "$TAGS" | sed -nE "s/^v$VERSION-beta\.([0-9]+)$/\1/p" | sort -n | tail -1)
    BETA_NUM=$(( ${LAST_BETA:-0} + 1 ))
    LABEL="$VERSION beta $BETA_NUM"
    TAG="v$VERSION-beta.$BETA_NUM"
else
    BETA_NUM=""
    LABEL="$VERSION"
    TAG="v$VERSION"
fi
DMG_NAME="$APP_NAME-${TAG#v}.dmg"
DMG="$BUILD_DIR/$DMG_NAME"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"

echo "▸ $APP_NAME $LABEL (build $BUILD_NUM), tag $TAG"
echo "  version $CUR_VERSION → $VERSION"
echo "  build $CUR_BUILD → $BUILD_NUM (highest in the live feed: $FEED_BUILD)"
echo "  $DMG"
if [ "$DRY_RUN" = true ]; then
    echo "Dry run, nothing changed."
    exit 0
fi

sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD_NUM;/g" "$PBXPROJ"

# ── Locate Sparkle's sign_update tool ────────────────────────────────────────
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/Mixtape-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -name sign_update 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "✗ sign_update not found — build the app once in Xcode first"; exit 1; }

# ── Archive (Release, unsigned) ──────────────────────────────────────────────
# MIXTAPE_BETA lands in Info.plist, which is how the app knows it's a beta.
echo "▸ Archiving…"
mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    MIXTAPE_BETA="$BETA_NUM" \
    archive > "$BUILD_DIR/archive.log" 2>&1 \
    || { echo "✗ Archive failed — see $BUILD_DIR/archive.log"; tail -20 "$BUILD_DIR/archive.log"; exit 1; }

APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

# ── Ad-hoc sign (deep) so the app + Sparkle framework load consistently ──────
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

# --deep re-signs the bundled deno too, dropping the entitlements Deno ships it
# with. That is survivable only while the replacement signature has no hardened
# runtime: add `-o runtime` (or move to Developer ID + notarization) without also
# passing an allow-jit entitlement and deno dies on V8 startup — which shows up
# not as a crash but as every download failing "Requested format is not
# available", because yt-dlp then can't solve YouTube's n challenge. Cheaper to
# catch here than in an appcast.
echo "▸ Verifying bundled deno still runs…"
"$APP/Contents/Resources/deno" eval 'Deno.exit(0)' 2>/dev/null \
    || { echo "✗ Bundled deno won't run after signing — YouTube downloads would all fail."; exit 1; }

# ── Build DMG ────────────────────────────────────────────────────────────────
echo "▸ Building DMG…"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ── Sign the DMG with Sparkle's EdDSA key ────────────────────────────────────
echo "▸ Signing update (EdDSA)…"
# sign_update emits both attributes already, e.g.  sparkle:edSignature="…" length="…"
SIG_LINE=$("$SIGN_UPDATE" "$DMG")
echo "  $SIG_LINE"
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# ── Build the appcast item for this release ──────────────────────────────────
echo "▸ Writing docs/appcast.xml…"
mkdir -p docs
touch docs/.nojekyll

# Stable items have no channel tag (visible to everyone); beta items carry
# <sparkle:channel>beta</sparkle:channel> so only opted-in users receive them.
if [ "$BETA" = true ]; then
    CHANNEL_TAG=$'\n      <sparkle:channel>beta</sparkle:channel>'
else
    CHANNEL_TAG=""
fi

ITEM_FILE="$BUILD_DIR/appcast-item.xml"
cat > "$ITEM_FILE" <<XML
    <item>
      <title>Version $LABEL</title>
      <description><![CDATA[
        <html><head><meta charset="utf-8"><style>
          body { font: -apple-system-body, -apple-system; margin: 0; color: #1d1d1f;
                 font-family: -apple-system, system-ui, sans-serif; line-height: 1.5; }
          h1 { font-size: 17px; margin: 0 0 10px; }
          ul { margin: 0; padding-left: 20px; } li { margin: 4px 0; }
          p { margin: 0 0 8px; }
          @media (prefers-color-scheme: dark) { body { color: #f5f5f7; } }
        </style></head><body>
          <h1>Mixtape $LABEL</h1>
          $NOTES_BODY
        </body></html>
      ]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$LABEL</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$CHANNEL_TAG
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $SIG_LINE />
    </item>
XML

if [ "$BETA" = true ]; then
    # Added to the live feed, not the local copy, so the stable item stays even
    # if this branch hasn't caught up with main.
    echo "$FEED" | awk -v itemfile="$ITEM_FILE" '
        /<language>/ { print; while ((getline line < itemfile) > 0) print line; next }
        { print }
    ' > docs/appcast.xml
else
    # Stable release: full rewrite with this single item.
    {
        cat <<HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mixtape</title>
    <link>$FEED_URL</link>
    <description>Mixtape updates</description>
    <language>en</language>
HEADER
        cat "$ITEM_FILE"
        cat <<FOOTER
  </channel>
</rss>
FOOTER
    } > docs/appcast.xml
fi

# ── Update the landing page (docs/index.html) to point at this version ───────
# Rewrites the "Download for Mac" link to this release's DMG and the version
# badge so the site always matches the latest build.
SITE="docs/index.html"
if [ "$BETA" = true ]; then
    echo "Beta release — leaving $SITE pointing at the latest stable build."
elif [ -f "$SITE" ]; then
    echo "Updating $SITE..."
    # Direct-download link → current versioned DMG asset.
    sed -i '' -E "s|https://github.com/$REPO/releases/download/v[0-9][^\"]*\.dmg|$DOWNLOAD_URL|g" "$SITE"
    # "version X.Y(.Z)" badge text (leaves the surrounding "macOS · " intact).
    sed -i '' -E "s|version [0-9][0-9A-Za-z.-]*|version $VERSION|g" "$SITE"
else
    echo "⚠️  $SITE not found — skipping site update."
fi

# ── Next steps ───────────────────────────────────────────────────────────────
TODAY=$(date +%d.%m.%Y)
FIRST_LAUNCH="First launch: if macOS blocks it, open System Settings → Privacy & Security and click Open Anyway (one-time, un-notarized build)."

cat <<DONE

✅ $APP_NAME $LABEL (build $BUILD_NUM) is built. Nothing is public yet.
   • DMG:      $DMG
   • Appcast:  docs/appcast.xml
DONE

if [ "$BETA" = true ]; then
    cat <<DONE

Next, in order. Testers get it at step 3, when the feed reaches main.
   1. Upload the DMG as a pre-release (the feed must never point at a missing file):
        gh release create $TAG "$DMG" --prerelease \\
          --repo $REPO --title "$APP_NAME $LABEL" --notes "$FIRST_LAUNCH"
   2. One release commit on develop:
        git add -A && git commit -m "$APP_NAME $LABEL - Release $TODAY - <summary>" && git push
   3. Publish the feed from main, then bring main back into develop:
        git checkout main && git checkout develop -- docs/appcast.xml
        git commit -m "Appcast: $LABEL" && git push
        git checkout develop && git merge main && git push
DONE
else
    cat <<DONE
   • Website:  docs/index.html (download link + version badge)

Next, in order. Everyone gets it at step 2.
   1. Upload the DMG (the feed must never point at a missing file):
        gh release create $TAG "$DMG" \\
          --repo $REPO --title "$APP_NAME $LABEL" --notes "$FIRST_LAUNCH"
   2. One release commit on main:
        git add -A && git commit -m "$APP_NAME $LABEL - Release $TODAY - <summary>" && git push
   3. Bring it into develop:
        git checkout develop && git merge main && git push
DONE
fi
