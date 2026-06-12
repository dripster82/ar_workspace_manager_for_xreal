#!/bin/zsh
# Build VRDesktop.app from the SwiftPM product.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/VRDesktop"
APP="$ROOT/build/VRDesktop.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VRDesktop"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# Sign with an Apple Development identity if available (keeps TCC grants stable),
# otherwise fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --sign "$IDENTITY" --identifier co.ketelle.vrdesktop "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --identifier co.ketelle.vrdesktop "$APP"
  echo "Ad-hoc signed (install Xcode + a free Apple Development cert for stable TCC grants)"
fi

echo "Built: $APP"
echo "Run:   open '$APP'"
