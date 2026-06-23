#!/bin/zsh
# Notarize and staple a built AR Workspace Manager.app.
# Prereqs:
#   1. Build a Developer-ID-signed release first:
#        CODESIGN_IDENTITY="Developer ID Application: Paul Ketelle (834D8P4J32)" Scripts/build-app.sh release
#   2. Store notary credentials once (app-specific password or App Store Connect API key):
#        xcrun notarytool store-credentials notary-arwm \
#          --apple-id paul@ketelle.co.uk --team-id 834D8P4J32 --password <app-specific-password>
#
# Usage: Scripts/notarize.sh [keychain-profile]   (default: notary-arwm)
set -euo pipefail

PROFILE="${1:-notary-arwm}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AR Workspace Manager.app"
ZIP="$(mktemp -d)/AR-Workspace-Manager.zip"

[[ -d "$APP" ]] || { echo "No app at $APP — build a release first (see header)."; exit 1; }

echo "==> zipping for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple notary (profile: $PROFILE) — waits for result"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling ticket"
xcrun stapler staple "$APP"

echo "==> verifying"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | head -3

echo "==> done: $APP is notarized + stapled"
