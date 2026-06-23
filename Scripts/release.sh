#!/bin/zsh
# One command to produce a DISTRIBUTABLE, notarized .dmg:
#   1. Developer-ID-signed release build of the app
#   2. notarize + staple the app (so it launches offline once installed)
#   3. build a drag-to-install .dmg
#   4. notarize + staple the .dmg (so the download itself passes Gatekeeper)
#
# Usage:  Scripts/release.sh
#
# Overridable via env:
#   CODESIGN_IDENTITY   signing identity (default: the Developer ID Application identity below)
#   NOTARY_PROFILE      notarytool keychain profile (default: notary-arwm)
#
# Prereqs (one-time): Developer ID Application cert in the keychain + stored notary credentials —
# see Scripts/notarize.sh header. For everyday local testing use Scripts/build-app.sh instead
# (no notarization needed to run it yourself).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Paul Ketelle (834D8P4J32)}"
PROFILE="${NOTARY_PROFILE:-notary-arwm}"
APP="$ROOT/build/AR Workspace Manager.app"
DMG="$ROOT/build/AR-Workspace-Manager.dmg"

echo "==> [1/4] Developer-ID-signed release build"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh" release

echo "==> [2/4] notarize + staple the app"
"$ROOT/Scripts/notarize.sh" "$PROFILE"

echo "==> [3/4] build the .dmg"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/make-dmg.sh" "$APP" "$DMG"

echo "==> [4/4] notarize + staple the .dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | head -3 || true

echo
echo "✅ Distributable disk image ready: $DMG"
echo "   (app + dmg both notarized & stapled — upload this to your Releases page)"
