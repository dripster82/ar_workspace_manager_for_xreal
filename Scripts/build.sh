#!/bin/sh
# Stamp the current git commit (hash + dirty flag + build time) into BuildInfo.swift, then build.
# Use this instead of a bare `swift build`/`swift run` so the running binary reports its version.
# Pass through any args, e.g.:  Scripts/build.sh run     |    Scripts/build.sh -c release
set -e
cd "$(dirname "$0")/.."

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
CMD="${1:-build}"
shift 2>/dev/null || true
exec swift "$CMD" "$@"
