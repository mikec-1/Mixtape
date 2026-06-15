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
# First manual install needs a one-time right-click → Open; Sparkle updates are
# seamless thereafter.
#
# Usage:  ./scripts/release.sh
# Run from the repo root (the dir containing Mixtape.xcodeproj).

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
PROJECT="Mixtape.xcodeproj"
SCHEME="Mixtape"
APP_NAME="Mixtape"
REPO="mikec-1/Mixtape"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

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

# ── Write appcast.xml (latest item only) ─────────────────────────────────────
echo "▸ Writing docs/appcast.xml…"
mkdir -p docs
touch docs/.nojekyll
cat > docs/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mixtape</title>
    <link>https://mikec-1.github.io/Mixtape/appcast.xml</link>
    <description>Mixtape updates</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $SIG_LINE />
    </item>
  </channel>
</rss>
XML

# ── Summary ──────────────────────────────────────────────────────────────────
cat <<DONE

✅ Release artifacts ready for v$VERSION:
   • DMG:      $DMG
   • Appcast:  docs/appcast.xml

Next steps:
   1. Create the GitHub Release and upload the DMG:
        gh release create v$VERSION "$DMG" \\
          --repo $REPO --title "Mixtape $VERSION" \\
          --notes "First launch: right-click the app → Open (one-time, un-notarized build)."
   2. Commit & push the feed so Sparkle sees it:
        git add docs/appcast.xml && git commit -m "Appcast: v$VERSION" && git push
   3. Ensure GitHub Pages serves /docs on the main branch (one-time setup).
DONE
