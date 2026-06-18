#!/bin/zsh
# Build VRDesktop.app from the SwiftPM product.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
# "dirty" = uncommitted changes, ignoring the generated BuildInfo.swift itself.
if [ -n "$(git status --porcelain -uno -- . ':!Sources/VRDesktop/BuildInfo.swift' 2>/dev/null)" ]; then
    DIRTY="+dirty"
else
    DIRTY=""
fi
COMMIT="$HASH$DIRTY"
DATE="$(date '+%Y-%m-%d %H:%M')"
STAMP="$COMMIT · $DATE"

cat > Sources/VRDesktop/BuildInfo.swift <<EOF
/// Build identity, stamped by Scripts/build.sh. Do not edit by hand.
enum BuildInfo {
    static let commit = "$COMMIT"
    static let date = "$DATE"
    static let version = "$STAMP"
}
EOF

echo "==> stamped BuildInfo = $STAMP"


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
[[ -f "$ROOT/App/AppIcon.icns" ]] && cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable identity (so TCC permissions persist across rebuilds), most-trusted first.
# Override with CODESIGN_IDENTITY=... if you have a specific cert.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # No -v: a self-signed cert is usable by codesign but shows as "not trusted" under -v.
  for pat in "Developer ID Application" "Apple Development" "VRDesktop Self-Signed"; do
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
      | awk -F'"' -v p="$pat" '$0 ~ p {print $2; exit}')"
    [[ -n "$IDENTITY" ]] && break
  done
fi
if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --sign "$IDENTITY" --identifier co.ketelle.vrdesktop "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --identifier co.ketelle.vrdesktop "$APP"
  echo "Ad-hoc signed — run Scripts/make-signing-cert.sh once so permissions persist across builds"
fi

echo "Built: $APP"
echo "Run:   open '$APP'"
