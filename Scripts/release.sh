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
# Usage:  Scripts/release.sh [version]
#         No argument → stable, auto-incremented from the highest stable V* tag.
#         With one    → exact version, e.g. 0.8.0-beta1 or 0.8.0-RC2 (a -suffix publishes as a
#                       GitHub PRE-RELEASE, picked up only by the app's RC/Beta update channels).
# Env:    CODESIGN_IDENTITY (default below) · NOTARY_PROFILE (default notary-arwm)
# Prereqs: Developer ID Application cert, stored notarytool profile, and the `gh` CLI authenticated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Paul Ketelle (834D8P4J32)}"
PROFILE="${NOTARY_PROFILE:-notary-arwm}"
APP="$ROOT/build/AR Workspace Manager.app"
DMG=""   # set once the version is known (named per-version, e.g. AR-Workspace-Manager-0.4.dmg)

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

# --- Decide the version (tag-driven, or explicit for beta/RC) --------------------------------------
if [[ -n "${1:-}" ]]; then
  VERSION="$1"
  [[ "$VERSION" == [0-9]* ]] || { echo "✗ Version must start with a number (e.g. 0.8.0-beta1)."; exit 1; }
  TAG="V$VERSION"
  echo "==> Explicit version: $TAG"
else
  HEAD_TAG="$(git tag --points-at HEAD 'V*' | sort -V | tail -1)"
  if [[ -n "$HEAD_TAG" ]]; then
    TAG="$HEAD_TAG"
    VERSION="${TAG#V}"
    echo "==> HEAD is already tagged $TAG — rebuilding/re-publishing that version."
  else
    # Auto-increment from the highest STABLE tag only, so beta/RC tags don't derail numbering.
    LATEST="$(git tag -l 'V*' | grep -v -- '-' | sort -V | tail -1)"
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
fi

# A -suffix (beta/RC) publishes as a GitHub pre-release: excluded from /releases/latest and from
# the app's Stable update channel; offered on the RC/Beta channels per the suffix.
PRERELEASE_FLAG=()
[[ "$VERSION" == *-* ]] && PRERELEASE_FLAG=(--prerelease)

# Architectures to ship as separate DMGs. arm64 = Apple Silicon, x86_64 = Intel. The vendored
# libjson-c.a is universal so both cross-compile from this machine.
ARCHES=(arm64 x86_64)

# --- Changelog (generated from commits since the previous tag; you review/edit before publishing) ---
NOTES="$ROOT/build/release-notes-$TAG.md"
mkdir -p "$ROOT/build"
PREV_TAG="$(git tag -l 'V*' | sort -V | grep -vx "$TAG" | tail -1 || true)"
{
  echo "## AR Workspace Manager for XREAL $TAG"
  echo
  if [[ -n "$PREV_TAG" ]]; then
    echo "Changes since $PREV_TAG:"
    echo
    git log --no-merges --pretty='- %s' "$PREV_TAG..HEAD"
  else
    echo "Initial release."
  fi
} > "$NOTES"

echo
echo "================ DRAFT RELEASE NOTES ($TAG) ================"
cat "$NOTES"
echo "==========================================================="
echo "File: $NOTES"
printf "Review the changelog — [Enter] accept · [e] edit in \$EDITOR · [q] abort: "
read -r ans
case "$ans" in
  e|E) "${EDITOR:-nano}" "$NOTES"; echo "--- using edited notes ---"; cat "$NOTES"; echo "---" ;;
  q|Q) echo "Aborted before building. No release made."; exit 1 ;;
esac

# --- Build + notarize each architecture into its own DMG -------------------------------------------
DMGS=()
for ARCH in $ARCHES; do
  echo "==> [build] Developer-ID release build ($TAG, $ARCH)"
  ARWM_ARCH="$ARCH" ARWM_VERSION="$VERSION" CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh" release
  "$ROOT/Scripts/notarize.sh" "$PROFILE"

  ADMG="$ROOT/build/AR-Workspace-Manager-$VERSION-$ARCH.dmg"
  echo "==> [dmg] build + notarize $ARCH dmg"
  DMG_VOLNAME="AR Workspace Manager $VERSION ($ARCH)" CODESIGN_IDENTITY="$IDENTITY" \
    "$ROOT/Scripts/make-dmg.sh" "$APP" "$ADMG"
  xcrun notarytool submit "$ADMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$ADMG"
  DMGS+=("$ADMG")
done

# --- Publish to GitHub (creates the tag if new; refreshes the assets if re-running) ----------------
echo "==> publish GitHub release $TAG (${#DMGS[@]} assets)"
command -v gh >/dev/null || { echo "✗ gh CLI not found — tag/release not published. dmgs: ${DMGS[*]}"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${DMGS[@]}" --clobber
  gh release edit "$TAG" --notes-file "$NOTES"
  echo "✅ Updated existing release $TAG (fresh dmgs + changelog)."
else
  gh release create "$TAG" "${DMGS[@]}" \
    --title "$TAG" \
    --target "$(git rev-parse HEAD)" \
    "${PRERELEASE_FLAG[@]}" \
    --notes-file "$NOTES"
  echo "✅ Published release $TAG (tagged HEAD) with ${#DMGS[@]} dmgs + changelog."
fi
printf '   %s\n' "${DMGS[@]}"
