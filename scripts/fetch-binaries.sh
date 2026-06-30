#!/usr/bin/env bash
# Fetch the python + yt-dlp + ffmpeg binaries bundled by the Discover feature.
# These are large and NOT committed; run this once after cloning.
#
#   ./scripts/fetch-binaries.sh
#
# Binaries land in Mixtape/Resources/bin/ which the synchronized Xcode group
# copies into the app bundle's Contents/Resources/.
#
# yt-dlp is shipped as its pure-Python ZIPAPP (Resources/bin/yt-dlp.zip) run by
# a bundled relocatable CPython shipped as a single archive (Resources/bin/
# python.tar.gz), which the app unpacks once into Application Support — NOT the
# `yt-dlp_macos` PyInstaller onefile. The onefile unpacks ~1500 files and is
# Gatekeeper-scanned on EVERY launch, costing ~11s of startup per invocation;
# the zipapp + standalone python starts in ~0.2s. See YTDLPService.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Mixtape/Resources/bin"
mkdir -p "$DEST"

ARCH="$(uname -m)"   # arm64 or x86_64

# Clear any stale (possibly read-only) payloads so curl can overwrite.
rm -rf "$DEST/python" "$DEST/python.tar.gz" "$DEST/yt-dlp" "$DEST/yt-dlp.zip" "$DEST/ffmpeg"

# --- Relocatable CPython (python-build-standalone) -------------------------
# We bundle the `install_only` tarball AS A SINGLE FILE (python.tar.gz) and let
# the app unpack it once at first launch into Application Support. Shipping the
# unpacked tree (~1800 files) inside Resources/ collides under Xcode's flattened
# resource copy (many same-named __init__.py / README) and would need every file
# code-signed. One opaque archive sidesteps both. See YTDLPService.bundledPython.
case "$ARCH" in
  arm64)  PY_ARCH="aarch64" ;;
  x86_64) PY_ARCH="x86_64"  ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac
PY_VERSION="3.12.8"
PY_RELEASE="20241219"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/cpython-${PY_VERSION}+${PY_RELEASE}-${PY_ARCH}-apple-darwin-install_only.tar.gz"
echo "→ Downloading standalone CPython ${PY_VERSION} (${PY_ARCH})…"
curl -L --fail -o "$DEST/python.tar.gz" "$PY_URL"   # extracts to python/ at runtime

# Vendor ytmusicapi (+ its pure-Python deps: requests, certifi, …) INTO the
# standalone interpreter so it's importable at runtime with no separate payload.
# YouTube Music's search returns a real per-track `isExplicit` flag + videoId,
# which lets us pick the uncensored upload reliably for explicit tracks instead
# of guessing from YouTube titles. See YTDLPService.ytmusicVideoID().
echo "→ Vendoring ytmusicapi into the bundled CPython…"
PY_TMP="$(mktemp -d)"
tar -xzf "$DEST/python.tar.gz" -C "$PY_TMP"
"$PY_TMP/python/bin/python3" -m pip install --upgrade --quiet \
  --target "$PY_TMP/python/lib/python3.12/site-packages" ytmusicapi
# Re-pack the augmented interpreter (overwrites the plain download).
rm -f "$DEST/python.tar.gz"
tar -czf "$DEST/python.tar.gz" -C "$PY_TMP" python
rm -rf "$PY_TMP"

# --- yt-dlp zipapp ---------------------------------------------------------
echo "→ Downloading yt-dlp zipapp…"
curl -L --fail -o "$DEST/yt-dlp.zip" \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"

# Static ffmpeg — must be statically linked so it runs on machines without
# Homebrew. NEVER copy /opt/homebrew/bin/ffmpeg: it depends on dylibs in
# /opt/homebrew/lib and will crash on any other Mac.
echo "→ Downloading static ffmpeg ($ARCH)…"
FFMPEG_URL="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-${ARCH}"
curl -L --fail -o "$DEST/ffmpeg" "$FFMPEG_URL"
chmod +x "$DEST/ffmpeg"

# Sanity check: confirm ffmpeg is NOT linked against Homebrew dylibs.
if otool -L "$DEST/ffmpeg" 2>/dev/null | grep -q "/opt/homebrew\|/usr/local/lib"; then
  echo "⚠️  WARNING: ffmpeg links non-system dylibs — it will NOT run when distributed."
fi

echo "✓ Binaries in $DEST"
ls -lh "$DEST"
