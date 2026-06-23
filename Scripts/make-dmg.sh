#!/bin/zsh
# Build a drag-to-install .dmg from the app bundle (app + an /Applications symlink).
# Signs the .dmg if CODESIGN_IDENTITY is set. Called by Scripts/release.sh; can be run standalone.
#
# Usage: Scripts/make-dmg.sh [app-path] [dmg-path]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/AR Workspace Manager.app}"
DMG="${2:-$ROOT/build/AR-Workspace-Manager.dmg}"
VOLNAME="${DMG_VOLNAME:-AR Workspace Manager}"

[[ -d "$APP" ]] || { echo "No app at $APP — build it first (Scripts/build-app.sh)."; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag-to-install target

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Sign the disk image too, so the download itself carries your Developer ID.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"
  echo "==> signed dmg with: $CODESIGN_IDENTITY"
fi

echo "Built: $DMG"
