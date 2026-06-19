# ColorSync runaway — investigation & root cause

**Date:** 2026-06-19 · **macOS:** 26.5.1 (25F80) · **Hardware:** MacBook Pro (built-in XDR) + XREAL Air 2

## Symptom

The machine becomes sluggish — AR frames drop and the mouse periodically freezes.
`colorsync.displayservices` (plus `colorsyncd`) sits pinned at **~74% CPU**, sustained, and
killing it only helps for a moment.

## TL;DR root cause

**A macOS 26.5.1 bug, triggered by the Air 2 as a display — not VR Desktop.**

WindowServer loops in `WS::Displays::CAWSManager::restore_color_preferences()`, making
**synchronous** `ColorSyncXPCAcquireDisplayInfo` calls to `colorsync.displayservices`, which
services each with `ColorSyncProfileCreateDeviceProfile`. It never settles, so ColorSync stays
pinned. The trigger is the **Air 2 glasses being connected as a display**; VR Desktop's virtual
displays are *not* the cause.

Likely reason it never settles: a custom **"Air 2 Calibrated"** colour profile is assigned to the
glasses, while the Air 2's **display UUID changes between sessions** (`8DE95A81…` → `87932B42…`),
so the saved colour preference never matches the live display and WindowServer retries forever.

## Proof it's the Air 2, not the app

| Scenario | `colorsync.displayservices` |
|---|---|
| Air 2 plugged in, **VR Desktop closed**, no virtual displays | **~74% sustained** |
| **Air 2 unplugged** | **0%** (drops within ~2 s) |
| **AR running**, virtual displays present, **output to a monitor (no Air 2)** | **~0%**, only brief transient blips |

The decisive ones: unplugging the Air 2 takes it to 0%, and running the full app with virtual
displays but no glasses stays near 0%. So the virtual displays / VR Desktop are exonerated; the
Air 2's presence is necessary and sufficient for the runaway.

## How it was diagnosed (repeatable method)

1. **Top processes** — `ps -Aceo pid,pcpu,comm -r | head` showed `colorsync.displayservices` ~74%
   while `WindowServer` was only intermittently busy.
2. **Sample the daemon** (needs root): `sudo sample $(pgrep -x colorsync.displayservices) 3 -file /tmp/cs.txt`
   → hot in `ColorSyncProfileCreateDeviceProfile → copyDeviceInfo → ColorSyncDeviceRegistryCopyInfo`,
   serviced on `display_services_queue` via XPC (it's the *victim* of a flood).
3. **Sample the sender** — `sudo sample $(pgrep -x WindowServer) 3 -file /tmp/ws.txt` → the caller is
   `CAWSManager::restore_color_preferences() → ColorSyncXPCAcquireDisplayInfo → send_message_with_reply`
   (synchronous). WindowServer is the flood source.
4. **Attribution tests** — sample VRDesktop (clean: only IMU + render) and replayd (idle) to rule
   them out; then physically unplug the Air 2 and watch ColorSync fall to 0%.

## Two separate issues were found (one fixed, one OS-side)

### 1. WindowServer display-registry bloat — FIXED in-app
`~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` had grown to **95k lines /
517 configs / 371 distinct display UUIDs**. WindowServer saves a new arrangement for every distinct
*combination* of display UUIDs and never prunes; VR Desktop's virtual displays previously took a
unique identity per screen (serial = FNV hash of the screen's UUID), so the registry grew without
bound and made every ColorSync request expensive.

**Fix (shipped):** `VirtualDisplayService` now draws serials from a bounded slot pool
(`0x56520000 + lowest free slot`, freed on destroy), so only a handful of identities ever exist and
WindowServer reuses one config. Verified: distinct recorded UUIDs dropped from 371 to ~5.
*One-time cleanup of the historical bloat: remove the displays plist and restart WindowServer
(`sudo killall WindowServer` — a hard logout) so it regenerates clean. cfprefsd caches it, so the
delete only sticks if done immediately before the restart.*

### 2. Air 2 colour-preference loop — OS-side, no app fix
The `restore_color_preferences` loop persists with the app closed and only the Air 2 connected, so it
can't be fixed in VR Desktop. The private `CGVirtualDisplay` API exposes no colour fields, and
assigning an sRGB profile via `ColorSyncDeviceSetCustomProfiles` had no effect (that attempt was
reverted).

## ✅ Resolution (confirmed 2026-06-19)

**Resetting the Air 2 to its default colour profile stopped the loop.** With the glasses plugged in
and the default Air 2 profile applied (dropping the custom "Air 2 Calibrated"),
`colorsync.displayservices` settled to **0%** (one brief blip on the profile change, then flat) and
WindowServer dropped to ~5%. The mismatched custom calibration against the Air 2's changing UUID was
the trigger; the default profile restores cleanly in one pass.

## Fixes / workarounds for the Air 2 loop

1. **Reset the Air 2 colour profile** — System Settings → Displays → Air 2 → Color → select the
   default Air 2 profile (drop the custom **"Air 2 Calibrated"**).
2. **Clear the stale Air 2 profiles** so macOS regenerates one clean default (back up first):
   ```sh
   mkdir -p /tmp/air2-icc-backup
   sudo cp /Library/ColorSync/Profiles/Displays/Air\ 2*.icc \
           "/Library/ColorSync/Profiles/Displays/Air 2 Calibrated.icc" /tmp/air2-icc-backup/
   sudo rm  /Library/ColorSync/Profiles/Displays/Air\ 2*.icc \
            "/Library/ColorSync/Profiles/Displays/Air 2 Calibrated.icc"
   ```
   then unplug/replug the Air 2.
3. **Stopgap while plugged in:** `sudo kill <pid of colorsync.displayservices>`
   (`killall` by name sometimes doesn't match — target the PID). It re-establishes while the Air 2 is
   connected, so this is only temporary.
4. **Report to Apple** (Feedback Assistant): WindowServer `CAWSManager::restore_color_preferences()`
   loops on `ColorSyncXPCAcquireDisplayInfo` when the Air 2 display is connected on macOS 26.5.1.

## Quick re-check commands

```sh
# CPU
ps -o pcpu,comm -p $(pgrep -x colorsync.displayservices)

# WindowServer display-registry size (should stay small now)
P=$(ls ~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist | head -1)
plutil -convert xml1 -o /tmp/ws.xml "$P"
echo "configs: $(grep -cE '<key>ConfigVersion</key>' /tmp/ws.xml) | UUIDs: $(grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' /tmp/ws.xml | sort -u | wc -l)"
```
