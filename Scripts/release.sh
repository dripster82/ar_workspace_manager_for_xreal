#!/bin/zsh
# One command to produce a DISTRIBUTABLE build: Developer-ID-signed release + notarized + stapled.
# Wraps build-app.sh (release) and notarize.sh so you don't have to remember either.
#
# Usage:  Scripts/release.sh
#
# Overridable via env:
#   CODESIGN_IDENTITY   signing identity (default: the Developer ID Application identity below)
#   NOTARY_PROFILE      notarytool keychain profile (default: notary-arwm)
#
# Prereqs (one-time): Developer ID cert in the keychain + stored notary credentials —
# see Scripts/notarize.sh header. For everyday local testing use Scripts/build-app.sh instead
# (debug, self-signed, no notarization) — you do NOT need a notarized build to run it yourself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Paul Ketelle (834D8P4J32)}"
PROFILE="${NOTARY_PROFILE:-notary-arwm}"

echo "==> [1/2] Developer-ID-signed release build"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh" release

echo "==> [2/2] notarize + staple"
"$ROOT/Scripts/notarize.sh" "$PROFILE"

echo
echo "✅ Distributable build ready: $ROOT/build/VRDesktop.app"
echo "   (notarized + stapled — ships to any Mac)"
