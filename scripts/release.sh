#!/usr/bin/env bash
#
# release.sh — Build, package, sign, and prepare a Mixtape macOS release.
#
# Produces:
#   build/Mixtape-<version>.dmg      → upload as a GitHub Release asset
#   docs/appcast.xml                 → Sparkle feed (served via GitHub Pages)
#
# Distribution is un-notarized: the app is ad-hoc signed and update integrity
# is guaranteed by Sparkle's EdDSA signature (private key in the login Keychain).
# First manual install needs a one-time Open Anyway (System Settings → Privacy
# & Security) on macOS 15+; Sparkle updates are
# seamless thereafter.
#
# Usage:  ./scripts/release.sh [--beta] ["<release notes HTML>"]
#   --beta  Cut an opt-in development build on the Sparkle "beta" channel:
#             • bumps CURRENT_PROJECT_VERSION so Sparkle sees a newer build
#             • tags the appcast item with <sparkle:channel>beta</sparkle:channel>
#               (only users who enabled "Receive development builds" get it; the
#               existing stable item is preserved in the feed)
#             • marks the GitHub Release as a pre-release (--prerelease)
#   The optional release-notes argument is the body shown in the Sparkle update
#   window (simple HTML — <ul><li>… or <p>…). Defaults to a generic note.
# Run from the repo root (the dir containing Mixtape.xcodeproj).

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
BETA=false
NOTES_BODY="<p>Bug fixes and improvements.</p>"
for arg in "$@"; do
    case "$arg" in
        --beta) BETA=true ;;
        *)      NOTES_BODY="$arg" ;;
    esac
done

# ── Config ───────────────────────────────────────────────────────────────────
PROJECT="Mixtape.xcodeproj"
SCHEME="Mixtape"
APP_NAME="Mixtape"
REPO="mikec-1/Mixtape"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

# ── Beta: bump the build number so Sparkle sees a newer build ────────────────
if [ "$BETA" = true ]; then
    echo "▸ Beta build — bumping CURRENT_PROJECT_VERSION…"
    PBXPROJ="$PROJECT/project.pbxproj"
    CUR_BUILD=$(awk -F'= ' '/CURRENT_PROJECT_VERSION = /{gsub(/[ ;]/,"",$2); print $2; exit}' "$PBXPROJ")
    [ -n "$CUR_BUILD" ] || { echo "✗ Could not read CURRENT_PROJECT_VERSION"; exit 1; }
    NEXT_BUILD=$((CUR_BUILD + 1))
    sed -i '' "s/CURRENT_PROJECT_VERSION = $CUR_BUILD;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PBXPROJ"
    echo "  build $CUR_BUILD → $NEXT_BUILD"
fi

# ── Resolve version from build settings ──────────────────────────────────────
echo "▸ Reading version…"
SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' -showBuildSettings 2>/dev/null)
VERSION=$(echo "$SETTINGS" | awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}')
BUILD_NUM=$(echo "$SETTINGS" | awk -F' = ' '/ CURRENT_PROJECT_VERSION =/{print $2; exit}')
[ -n "$VERSION" ]   || { echo "✗ Could not read MARKETING_VERSION"; exit 1; }
[ -n "$BUILD_NUM" ] || { echo "✗ Could not read CURRENT_PROJECT_VERSION"; exit 1; }
echo "  version $VERSION (build $BUILD_NUM)"

DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"

# ── Release notes (shown in the Sparkle update window) ───────────────────────
# NOTES_BODY is resolved during argument parsing above.

# ── Locate Sparkle's sign_update tool ────────────────────────────────────────
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/Mixtape-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -name sign_update 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "✗ sign_update not found — build the app once in Xcode first"; exit 1; }

# ── Archive (Release, unsigned) ──────────────────────────────────────────────
echo "▸ Archiving…"
mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    archive > "$BUILD_DIR/archive.log" 2>&1 \
    || { echo "✗ Archive failed — see $BUILD_DIR/archive.log"; tail -20 "$BUILD_DIR/archive.log"; exit 1; }

APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

# ── Ad-hoc sign (deep) so the app + Sparkle framework load consistently ──────
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

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
    ITEM_TITLE="Version $VERSION (beta)"
else
    CHANNEL_TAG=""
    ITEM_TITLE="Version $VERSION"
fi

ITEM_FILE="$BUILD_DIR/appcast-item.xml"
cat > "$ITEM_FILE" <<XML
    <item>
      <title>$ITEM_TITLE</title>
      <description><![CDATA[
        <html><head><meta charset="utf-8"><style>
          body { font: -apple-system-body, -apple-system; margin: 0; color: #1d1d1f;
                 font-family: -apple-system, system-ui, sans-serif; line-height: 1.5; }
          h1 { font-size: 17px; margin: 0 0 10px; }
          ul { margin: 0; padding-left: 20px; } li { margin: 4px 0; }
          p { margin: 0 0 8px; }
          @media (prefers-color-scheme: dark) { body { color: #f5f5f7; } }
        </style></head><body>
          <h1>Mixtape $VERSION</h1>
          $NOTES_BODY
        </body></html>
      ]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$CHANNEL_TAG
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $SIG_LINE />
    </item>
XML

if [ "$BETA" = true ] && [ -f docs/appcast.xml ]; then
    # Preserve the existing stable item; insert the new beta item just after the
    # <language> line so stable users keep their feed entry.
    awk -v itemfile="$ITEM_FILE" '
        /<language>/ { print; while ((getline line < itemfile) > 0) print line; next }
        { print }
    ' docs/appcast.xml > docs/appcast.xml.tmp && mv docs/appcast.xml.tmp docs/appcast.xml
else
    # Stable release (or no existing feed): full rewrite with this single item.
    {
        cat <<HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mixtape</title>
    <link>https://mikec-1.github.io/Mixtape/appcast.xml</link>
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

# ── Summary ──────────────────────────────────────────────────────────────────
if [ "$BETA" = true ]; then
    PRERELEASE_FLAG=" --prerelease"
    REL_TITLE="Mixtape $VERSION (beta)"
    CHANNEL_NOTE="
   • Channel:  beta (only users with \"Receive development builds\" enabled)"
else
    PRERELEASE_FLAG=""
    REL_TITLE="Mixtape $VERSION"
    CHANNEL_NOTE=""
fi

cat <<DONE

✅ Release artifacts ready for v$VERSION (build $BUILD_NUM):
   • DMG:      $DMG
   • Appcast:  docs/appcast.xml$CHANNEL_NOTE
   • Website:  docs/index.html (download link + version badge updated)

Next steps (single release commit — do NOT commit before this point):
   1. Create the GitHub Release and upload the DMG (the download URL must
      exist before the appcast/site that point at it are committed):
        gh release create v$VERSION "$DMG"$PRERELEASE_FLAG \\
          --repo $REPO --title "$REL_TITLE" \\
          --notes "First launch: if macOS blocks it, open System Settings → Privacy & Security and click Open Anyway (one-time, un-notarized build)."
   2. Commit code + version bump + feed + site in ONE commit, then push:
        git add -A && git commit -m "Mixtape $VERSION - Release <DD.MM.YYYY> - <summary>" && git push
DONE
