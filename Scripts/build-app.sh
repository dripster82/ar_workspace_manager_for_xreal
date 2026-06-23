#!/bin/zsh
# Build "AR Workspace Manager.app" from the SwiftPM product.
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

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/VRDesktop"
HELPER_BIN="$BINDIR/VRDesktopHelper"
APP="$ROOT/build/AR Workspace Manager.app"

rm -rf "$APP" "$ROOT/build/VRDesktop.app"   # also clear the old-named bundle
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
# Bundle executable is the user-facing name (matches CFBundleExecutable in Info.plist); the SwiftPM
# product is still built as "VRDesktop" internally.
cp "$BIN" "$APP/Contents/MacOS/AR Workspace Manager"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/App/AppIcon.icns" ]] && cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Release version is tag-driven (see release.sh): if ARWM_VERSION is set, stamp it into the bundle's
# Info.plist (and use the git short-hash as the build number) so the built app reports the right
# version without committing a version bump. Dev builds just use the repo Info.plist value.
if [[ -n "${ARWM_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ARWM_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HASH" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "==> stamped bundle version $ARWM_VERSION (build $HASH)"
fi

# Privileged helper daemon (installed at runtime via SMAppService): executable into Contents/MacOS,
# its LaunchDaemon plist into Contents/Library/LaunchDaemons (BundleProgram points at the executable).
cp "$HELPER_BIN" "$APP/Contents/MacOS/VRDesktopHelper"
cp "$ROOT/App/LaunchDaemons/uk.co.ketelle.ar.workspace.manager.helper.plist" \
   "$APP/Contents/Library/LaunchDaemons/uk.co.ketelle.ar.workspace.manager.helper.plist"

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
# Sign INSIDE-OUT: nested code (the helper) first, then the outer app bundle — otherwise the app's
# signature doesn't cover a valid helper and SMAppService registration fails. The helper gets its own
# identifier. For a Developer-ID build we add the hardened runtime (--options runtime), required for
# notarization; the self-signed/ad-hoc local path omits it so the current TCC-grant + vendored
# json-c setup keeps working unchanged.
RUNTIME_OPTS=()
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  RUNTIME_OPTS=(--options runtime --timestamp)
fi

# App entitlements (microphone under the hardened runtime). Applied to the APP only — the helper
# stays minimal (no device entitlements). Without this the mic prompt never appears under hardened
# runtime and the app won't show in System Settings > Microphone.
ENTITLEMENTS="$ROOT/App/VRDesktop.entitlements"

if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force "${RUNTIME_OPTS[@]}" --sign "$IDENTITY" \
    --identifier uk.co.ketelle.ar.workspace.manager.helper "$APP/Contents/MacOS/VRDesktopHelper"
  codesign --force "${RUNTIME_OPTS[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" \
    --identifier uk.co.ketelle.ar.workspace.manager "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --identifier uk.co.ketelle.ar.workspace.manager.helper "$APP/Contents/MacOS/VRDesktopHelper"
  codesign --force --entitlements "$ENTITLEMENTS" --sign - --identifier uk.co.ketelle.ar.workspace.manager "$APP"
  echo "Ad-hoc signed — run Scripts/make-signing-cert.sh once so permissions persist across builds"
fi

# Sanity: the app signature must report the nested daemon as valid.
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  codesign: /' || true

echo "Built: $APP"
echo "Run:   open '$APP'"

# --- For NOTARIZED DISTRIBUTION (once you have a Developer ID Application cert) ----------------------
# 1. Set HelperConstants.teamID in Sources/PrivilegedHelperShared/HelperProtocol.swift to your 10-char
#    Team ID (the helper rejects all clients until this is set — fail-closed).
# 2. Build release:  CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh release
# 3. Library validation under the hardened runtime requires every loaded dylib be signed by your team
#    or Apple. If the vendored libjson-c is a .dylib, either statically link it or sign + bundle it,
#    or add the com.apple.security.cs.disable-library-validation entitlement to the app.
# 4. Notarize:  ditto -c -k --keepParent "$APP" VRDesktop.zip
#               xcrun notarytool submit VRDesktop.zip --keychain-profile <profile> --wait
#               xcrun stapler staple "$APP"
