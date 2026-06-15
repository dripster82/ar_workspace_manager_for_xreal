#!/usr/bin/env bash
#
# sophos-test.sh — diagnostic helper for the "AR jitter" investigation.
#
# Sophos's real-time scanner and scheduled scans can steal CPU from WindowServer
# (the compositor that draws the glasses' image), which shows up as stutter/jitter.
# This script lets you (a) SEE what Sophos is using, and (b) momentarily KILL the
# Sophos processes so you can re-test the glasses and see if the jitter clears.
#
# IMPORTANT
#   * Sophos is managed corporate security and almost certainly has TAMPER
#     PROTECTION — killed processes will usually relaunch within seconds. That's
#     expected. This is a *test*, not a permanent disable. If killing them clears
#     the jitter even for a few seconds, you've found your culprit and the real
#     fix is to (i) stop the active scan in the Sophos UI, or (ii) ask IT to add
#     an exclusion / pause protection for AR work.
#   * Killing requires sudo. You'll be prompted.
#   * This does NOT uninstall anything or change any Sophos config.
#
# Usage
#   ./sophos-test.sh                 # show Sophos processes + CPU (no killing)
#   ./sophos-test.sh --kill          # show, then SIGTERM all Sophos processes
#   ./sophos-test.sh --kill --force  # use SIGKILL (-9) instead of SIGTERM
#   ./sophos-test.sh --watch         # re-print the process table every 2s (Ctrl-C to stop)

set -euo pipefail

PATTERN='[Ss]ophos'
SIGNAL="TERM"
DO_KILL=0
WATCH=0

for arg in "$@"; do
  case "$arg" in
    --kill)  DO_KILL=1 ;;
    --force) SIGNAL="KILL" ;;
    --watch) WATCH=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Print every running Sophos process with its CPU%, sorted by CPU (heaviest first).
show() {
  echo "=== Sophos processes ($(date '+%H:%M:%S')) ==="
  # ps columns: pid, %cpu, %mem, command. Filter to Sophos, drop the grep itself.
  local rows
  rows=$(ps -axo pid,%cpu,%mem,comm | grep "$PATTERN" | grep -v "$0" || true)
  if [[ -z "$rows" ]]; then
    echo "  (none running)"
    return
  fi
  printf "  %-7s %-6s %-6s %s\n" "PID" "%CPU" "%MEM" "COMMAND"
  echo "$rows" \
    | sort -k2 -nr \
    | while read -r pid cpu mem comm; do
        printf "  %-7s %-6s %-6s %s\n" "$pid" "$cpu" "$mem" "$comm"
      done
  local total
  total=$(echo "$rows" | awk '{s+=$2} END {printf "%.1f", s}')
  echo "  -------"
  echo "  Total Sophos CPU: ${total}%"
}

if [[ "$WATCH" == "1" ]]; then
  trap 'exit 0' INT
  while true; do
    clear
    show
    sleep 2
  done
fi

show

if [[ "$DO_KILL" != "1" ]]; then
  echo
  echo "No processes killed. Re-run with --kill to stop them and re-test the glasses."
  exit 0
fi

# Collect PIDs and send the signal under sudo (Sophos runs as root).
pids=$(ps -axo pid,comm | grep "$PATTERN" | grep -v "$0" | awk '{print $1}' || true)
if [[ -z "$pids" ]]; then
  echo
  echo "Nothing to kill."
  exit 0
fi

echo
echo ">>> Sending SIG${SIGNAL} to: $(echo "$pids" | tr '\n' ' ')"
echo ">>> (sudo required; Sophos tamper protection may relaunch them immediately)"
# shellcheck disable=SC2086
sudo kill -"$SIGNAL" $pids 2>/dev/null || true

sleep 2
echo
echo "=== After kill ==="
show
echo
echo "Now look through the glasses. If the jitter is gone (even briefly before"
echo "Sophos relaunches), Sophos is the cause — stop the active scan in the Sophos"
echo "Endpoint app, or ask IT to pause protection / add an exclusion."
