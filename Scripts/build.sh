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
STAMP="$HASH$DIRTY @ $(date '+%Y-%m-%d %H:%M:%S')"

cat > Sources/VRDesktop/BuildInfo.swift <<EOF
/// Build version, stamped by Scripts/build.sh. Do not edit by hand.
enum BuildInfo {
    static let version = "$STAMP"
}
EOF

echo "==> stamped BuildInfo.version = $STAMP"
CMD="${1:-build}"
shift 2>/dev/null || true
exec swift "$CMD" "$@"
