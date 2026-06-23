#!/bin/zsh
# Cut a DISTRIBUTABLE, notarized release from main and publish it to GitHub.
#
# Versioning is TAG-DRIVEN:
#   • If the current HEAD already has a V* tag  → rebuild/re-publish that exact version.
#   • Otherwise                                 → auto-increment the last component of the highest
#                                                  existing V* tag (V0.3 → V0.4) and tag HEAD with it.
# The chosen version is stamped into the built app's Info.plist (CFBundleShortVersionString); the
# repo's Info.plist value is only a dev-build fallback.
#
# Steps: guard (main / clean / pushed) → build + notarize app → build + notarize dmg →
#        create/refresh the GitHub release with the dmg attached.
#
# Usage:  Scripts/release.sh
# Env:    CODESIGN_IDENTITY (default below) · NOTARY_PROFILE (default notary-arwm)
# Prereqs: Developer ID Application cert, stored notarytool profile, and the `gh` CLI authenticated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Paul Ketelle (834D8P4J32)}"
PROFILE="${NOTARY_PROFILE:-notary-arwm}"
APP="$ROOT/build/AR Workspace Manager.app"
DMG="$ROOT/build/AR-Workspace-Manager.dmg"

# --- Guards ----------------------------------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || { echo "✗ Releases must be cut from 'main' (currently on '$BRANCH')."; exit 1; }

# Clean tree, ignoring the generated BuildInfo.swift (which every build rewrites).
if [[ -n "$(git status --porcelain -uno -- . ':!Sources/VRDesktop/BuildInfo.swift')" ]]; then
  echo "✗ Working tree has uncommitted changes — commit them before releasing."; exit 1
fi

git fetch -q origin main
git fetch -q --tags --force origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "✗ Local main differs from origin/main — push main first (the release tag points at HEAD)."; exit 1
fi

# --- Decide the version (tag-driven) ---------------------------------------------------------------
HEAD_TAG="$(git tag --points-at HEAD 'V*' | sort -V | tail -1)"
if [[ -n "$HEAD_TAG" ]]; then
  TAG="$HEAD_TAG"
  VERSION="${TAG#V}"
  echo "==> HEAD is already tagged $TAG — rebuilding/re-publishing that version."
else
  LATEST="$(git tag -l 'V*' | sort -V | tail -1)"
  if [[ -z "$LATEST" ]]; then
    VERSION="0.1"
  else
    base="${LATEST#V}"            # e.g. 0.3
    pre="${base%.*}"             # 0
    last="${base##*.}"           # 3
    if [[ "$pre" == "$base" ]]; then VERSION="$((base + 1))"; else VERSION="$pre.$((last + 1))"; fi
  fi
  TAG="V$VERSION"
  echo "==> No tag on HEAD — auto-incrementing ${LATEST:-(none)} → $TAG"
fi

# --- Build + notarize ------------------------------------------------------------------------------
echo "==> [1/3] Developer-ID release build ($TAG)"
ARWM_VERSION="$VERSION" CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh" release
"$ROOT/Scripts/notarize.sh" "$PROFILE"

echo "==> [2/3] build + notarize the .dmg"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/make-dmg.sh" "$APP" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# --- Publish to GitHub (creates the tag if new; refreshes the asset if re-running) -----------------
echo "==> [3/3] publish GitHub release $TAG"
command -v gh >/dev/null || { echo "✗ gh CLI not found — tag/release not published. dmg is at $DMG."; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
  echo "✅ Updated existing release $TAG with a fresh dmg."
else
  gh release create "$TAG" "$DMG" \
    --title "$TAG" \
    --target "$(git rev-parse HEAD)" \
    --notes "AR Workspace Manager for XREAL $TAG"
  echo "✅ Published release $TAG (tagged HEAD) with the dmg."
fi
echo "   $DMG"
