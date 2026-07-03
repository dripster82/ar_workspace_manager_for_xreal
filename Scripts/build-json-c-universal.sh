#!/bin/zsh
# Rebuild vendor/lib/libjson-c.a as a UNIVERSAL (arm64 + x86_64) static library from json-c source,
# so the app can be built for both Apple Silicon and Intel from an Apple Silicon machine.
#
# The headers used at compile time come from Homebrew (Package.swift: -I /opt/homebrew/opt/json-c/…),
# which are architecture-independent — only the linked .a needs both slices. Keep this json-c version
# in sync with the Homebrew one (`brew info json-c`) so headers and lib match.
#
# Usage:  Scripts/build-json-c-universal.sh          (uses JSONC_VERSION below)
# Prereqs: cmake (brew install cmake), curl, lipo.
set -euo pipefail

JSONC_VERSION="${JSONC_VERSION:-0.18-20240915}"   # matches Homebrew json-c 0.18
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching json-c $JSONC_VERSION source"
curl -fsSL -o "$WORK/json-c.tar.gz" \
  "https://github.com/json-c/json-c/archive/refs/tags/json-c-$JSONC_VERSION.tar.gz"
tar xzf "$WORK/json-c.tar.gz" -C "$WORK"
SRC="$(echo "$WORK"/json-c-*/)"

echo "==> configuring universal static build"
cmake -B "$WORK/build" -S "$SRC" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DDISABLE_EXTRA_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release >/dev/null

echo "==> building"
cmake --build "$WORK/build" --target json-c -j >/dev/null

DEST="$ROOT/vendor/lib/libjson-c.a"
chmod u+w "$DEST" 2>/dev/null || true
cp "$WORK/build/libjson-c.a" "$DEST"
echo "==> installed $DEST"
echo "    archs: $(lipo -archs "$DEST")"
