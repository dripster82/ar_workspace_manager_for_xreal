#!/bin/zsh
# Fetch the VLCKit binary framework (LGPL 2.1 build from VideoLAN) into vendor/VLCKit/.
# Used by the media player's VLC backend (MKV/AVI/etc. + uniform VLC-rendered subtitles).
#
# The xcframework is universal (arm64 + x86_64), ~80 MB — kept OUT of git like the other
# vendor/ deps; run this once per checkout. Pinned by version + sha256.
#
# Usage: Scripts/fetch-vlckit.sh
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VERSION.tar.xz"
SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/VLCKit"

if [[ -d "$DEST/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" ]]; then
  echo "VLCKit already present at $DEST — delete it to re-fetch."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading VLCKit $VERSION (~85 MB)"
curl -fL -o "$WORK/vlckit.tar.xz" "$URL"
echo "$SHA256  $WORK/vlckit.tar.xz" | shasum -a 256 -c - >/dev/null || {
  echo "✗ checksum mismatch — refusing to install"; exit 1; }

echo "==> extracting"
tar xf "$WORK/vlckit.tar.xz" -C "$WORK"
SRC="$WORK/VLCKit - binary package"

mkdir -p "$DEST"
cp -R "$SRC/VLCKit.xcframework" "$DEST/"
cp "$SRC/COPYING.txt" "$DEST/"                 # LGPL 2.1 text (shipped with the app)
rm -rf "$DEST/VLCKit.xcframework/macos-arm64_x86_64/dSYMs"   # 300+ MB of debug symbols

echo "==> installed $DEST/VLCKit.xcframework"
echo "    archs: $(lipo -archs "$DEST/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/VLCKit")"
