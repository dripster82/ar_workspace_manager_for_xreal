# ColorSync runaway — investigation & root cause

**Date:** 2026-06-19 · **macOS:** 26.5.1 (25F80) · **Hardware:** MacBook Pro (built-in XDR) + XREAL Air 2

## Symptom

The machine becomes sluggish — AR frames drop and the mouse periodically freezes.
`colorsync.displayservices` (plus `colorsyncd`) sits pinned at **~74% CPU**, sustained, and
killing it only helps for a moment.

## TL;DR root cause

**A macOS 26.5.1 bug, triggered by the Air 2 as a display — not AR Workspace Manager.**

WindowServer loops in `WS::Displays::CAWSManager::restore_color_preferences()`, making
**synchronous** `ColorSyncXPCAcquireDisplayInfo` calls to `colorsync.displayservices`, which
services each with `ColorSyncProfileCreateDeviceProfile`. It never settles, so ColorSync stays
pinned. The trigger is the **Air 2 glasses being connected as a display**; AR Workspace Manager's virtual
displays are *not* the cause.

Likely reason it never settles: a custom **"Air 2 Calibrated"** colour profile is assigned to the
glasses, while the Air 2's **display UUID changes between sessions** (`8DE95A81…` → `87932B42…`),
so the saved colour preference never matches the live display and WindowServer retries forever.

## Proof it's the Air 2, not the app

| Scenario | `colorsync.displayservices` |
|---|---|
| Air 2 plugged in, **AR Workspace Manager closed**, no virtual displays | **~74% sustained** |
| **Air 2 unplugged** | **0%** (drops within ~2 s) |
| **AR running**, virtual displays present, **output to a monitor (no Air 2)** | **~0%**, only brief transient blips |

The decisive ones: unplugging the Air 2 takes it to 0%, and running the full app with virtual
displays but no glasses stays near 0%. So the virtual displays / AR Workspace Manager are exonerated; the
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
*combination* of display UUIDs and never prunes; AR Workspace Manager's virtual displays previously took a
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
can't be fixed in AR Workspace Manager. The private `CGVirtualDisplay` API exposes no colour fields, and
assigning an sRGB profile via `ColorSyncDeviceSetCustomProfiles` had no effect (that attempt was
reverted).

## ✅ Resolution (confirmed 2026-06-19)

**Resetting the Air 2 to its default colour profile stopped the loop.** With the glasses plugged in
and the default Air 2 profile applied (dropping the custom "Air 2 Calibrated"),
`colorsync.displayservices` settled to **0%** (one brief blip on the profile change, then flat) and
WindowServer dropped to ~5%. The mismatched custom calibration against the Air 2's changing UUID was
the trigger; the default profile restores cleanly in one pass.

### Residual: intermittent bursts during AR (acceptable)

With the Air 2 on the default profile, running AR still produces **intermittent** ColorSync bursts
(~30–53% peaks every ~4–5 s, decaying to 0) — WindowServer periodically re-evaluating the
profile-less *virtual* displays via the same mechanism. Confirmed **not** caused by app timers
(widget refresh 1 s, system-load 3 s, stats 0.5 s — none touch display colour). It's OS-side and
mild: no longer a continuously-pinned core, so it doesn't lock up input the way the Air 2 wedge did.
Assigning the virtual displays a profile via `ColorSyncDeviceSetCustomProfiles` did not take, so
there's no clean in-app fix; left as-is.

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

---

## Recurrence (2026-06-22) — bloated ColorSync *device registry*

The runaway came back at a solid ~73% **even with AR closed**, and killing the daemon didn't help
(it restarts and re-wedges). Unplugging the Air 2 still dropped it to 0%, so it was the Air 2 again
— but the hot path had **moved**.

### What was different this time

WindowServer was **idle (~2%)** while `colorsync.displayservices` (73%) and `colorsyncd` (23%) span
on their own. Sampling both daemons showed the hot path was no longer WindowServer's
`restore_color_preferences`, but the **ColorSync device registry being re-parsed**:

```
ColorSyncXPCDeviceRegistryCopyAnyUserInfo
└ ColorSyncDeviceRegistryCopyInfo
  └ CFPropertyListCreateWithData → __CFTryParseBinaryPlist   (deep, repeated, in BOTH daemons)
```

Same *shape* as the original WindowServer-plist bloat, different store. The device registry had
accumulated **20 display profiles** in `/Library/ColorSync/Profiles/Displays/`, many stale —
multiple `Air 2-<UUID>` (the Air 2's display UUID keeps changing between sessions:
`8DE95A81…` → `87932B42…`), old `Screen 1/2/3`, and pre-slot-fix `Code Screen`/`Slack`/`Browser`.
The custom **`Air 2 Calibrated.icc`** is a *preference* the system keeps trying to restore against
the Air 2's shifting identity, which pokes the registry; re-parsing the fat plist on each poke pins
both daemons. (The slot-based virtual-display fix means *our* virtual displays no longer add to this
churn — the stale virtual entries are historical.)

### Fix that worked (durable)

Clear the stale display profiles (incl. the custom calibration being chased) and restart the
daemons so they rebuild a clean registry — macOS regenerates the profiles it actually needs:

```sh
sudo cp -R /Library/ColorSync/Profiles/Displays /tmp/colorsync-displays-backup
sudo rm -f /Library/ColorSync/Profiles/Displays/*.icc
sudo killall colorsyncd colorsync.displayservices
# verify
sleep 3; ps -o pcpu,comm -p $(pgrep -x colorsync.displayservices)   # → ~0%
```

A reboot guarantees the daemons start from the clean folder if the kill alone doesn't settle it.

### Keep it from recurring

- **Don't re-calibrate the Air 2** (System Settings → Displays → Color). A custom profile against its
  unstable UUID is what re-arms the loop; leave it on the default profile.
- If it creeps back, the three commands above clear it. It won't re-bloat from AR Workspace Manager's virtual
  displays (stable slot UUIDs now) — the source is the Air 2's churning identity + accumulated
  profiles.

---

## Recurrence (2026-06-23) — confirmed clean-registry self-loop + in-app profile pruning

Came back at ~74% with the registry **already clean** (5 profiles, single Air 2 entry, no custom
calibration). Sampling `colorsync.displayservices` showed the same hot path as 06-22 —
`ColorSyncProfileCreateDeviceProfile → ColorSyncDeviceRegistryCopyInfo → __CFTryParseBinaryPlist` —
but WindowServer was idle (~6%), so the two ColorSync daemons were **looping between themselves**,
re-parsing the device registry on a tight retry triggered by the Air 2 as a display. Cost was
*frequency*, not plist size. Grep confirmed the app makes no ColorSync device-profile calls (only
`CGColorSpaceCreateDeviceRGB`/`metalLayer.colorspace`), so the app is exonerated at the code level
too. Decisive test unchanged: unplug the Air 2 → 0%.

### Preventative fix shipped: prune orphaned profiles on display removal

When a virtual display is **removed from a workspace** (`AppCoordinator.removeScreen`), the app now
deletes its now-orphaned `*-<uuid>.icc` from `/Library/ColorSync/Profiles/Displays`
(`SystemHealth.removeDisplayProfiles`, keyed by the CGDisplay UUID — physical displays have no virtual
displayID so they're never touched). The folder is group-`wheel`-writable, so admin accounts delete
directly with no prompt. For standard accounts a **signed privileged helper** does it as root.

### The privileged helper (for distribution)

A root LaunchDaemon (`Sources/VRDesktopHelper/`, target `VRDesktopHelper`) installed via
`SMAppService.daemon` and reached over XPC (`PrivilegedHelperClient`). `ClientValidator` verifies the
caller's **audit token** (via the `CXPCAuditToken` shim) against a code requirement (Apple anchor +
Developer ID marker + Team ID `834D8P4J32` + bundle id) — fail-closed in release, debug-bypassed for
local dev. The helper only ever deletes `*-<uuid>.icc` for valid UUIDs, never arbitrary paths.

This pairs with the Mac-App-Store-incompatible reality: a sandboxed app can't write to
`/Library/ColorSync` at all, so the app ships **direct-download (Developer ID + notarization)**, not
App Store. App rebranded to **AR Workspace Manager for XRE** (`uk.co.ketelle.ar.workspace.manager`).
First notarized + stapled build confirmed Gatekeeper-accepted 2026-06-23. Build/sign/notarize:
`Scripts/release.sh` (local dev testing uses `Scripts/build-app.sh debug` — no notarization needed).

---

## Recurrence (2026-06-25) — accumulation gap + always-on watchdog

Came back at ~74% after a few hours of use. The folder had **10 profiles**, 8 of them stale virtual
displays (`Browser`, `Code Screen`, `Screen 4/5/6/7`, `Slack`, `XrealVirtualR-1`) dated across the
prior three days. Root cause of the *accumulation*: the 06-23 pruning only fired on
`AppCoordinator.removeScreen` (manual single-screen removal). The **whole-session teardown paths —
`stopAR` (which calls `virtualDisplays.destroyAll()`), app quit, and crashes — left every virtual
display's profile behind**, so they piled up every session and re-bloated the registry. Manual
`rm *.icc` + `killall` didn't settle it this time (macOS regenerates and re-wedges while the Air 2 is
connected), confirming a one-shot clear isn't enough — it needs continuous remediation.

### Fixes shipped (in-app)

1. **Plug the leak** — `stopAR` now captures the virtual displays' UUIDs *before* `destroyAll()` and
   deletes their orphaned profiles (mirrors what `removeScreen` already did for single removals).
2. **Sweep on launch** — `AppCoordinator.init` runs `SystemHealth.sweepOrphanProfiles()`, clearing
   anything a previous quit/crash left behind. The sweep deletes every `*-<uuid>.icc` whose UUID is
   **not currently online** (via `CGGetOnlineDisplayList`) — so built-in/externals/live glasses and
   in-use virtuals are kept, orphans (dead virtuals, the Air 2's churned old UUIDs) go.
3. **Always-on watchdog** (`ColorSyncWatchdog.swift`, default on, toggle on Diagnostics) — samples
   `colorsync.displayservices` CPU every 30 s; if it stays ≥65% for 3 samples (~90 s sustained, above
   the benign 30–53% AR bursts) it remediates: `sweepOrphanProfiles()` + bounce the daemons. The
   bounce needs root (both daemons run as root), so it goes through the privileged helper's new
   `bounceColorSyncDaemons` XPC op (`killall colorsyncd colorsync.displayservices` — process names are
   fixed constants, never caller input). Rate-limited to once / 5 min; after 3 attempts that don't
   settle it (the pure Air-2 self-loop, which only a replug/reboot cures) it stops bouncing and
   surfaces a one-off warning on the Diagnostics page instead of looping.
4. **Manual Diagnostics buttons** — "Clean ColorSync now" (sweep + bounce on demand) and
   "Clear saved configs…" (`SystemHealth.clearSavedDisplayConfigs()` backs up + removes the bloated
   `com.apple.windowserver.displays.*.plist`; takes effect after logout, so it's confirmation-gated).

Helper protocol version bumped to **2**. Build confirmed clean (`Scripts/build-app.sh debug`).

## Nebula comparison prep (2026-07-02) — static analysis + registry mechanics

Goal: test whether XREAL's own **Nebula for Mac** provokes the same
`colorsync.displayservices` runaway. If it does, the trigger is the Air 2 + macOS combination
(worth reporting upstream); if it stays clean, Nebula's display strategy differs in a way we can
copy. Everything below was gathered **read-only** (no Nebula launch, no display changes).

### What Nebula's display engine looks like (static inspection of the app bundle)

- Nebula is a **Unity app** (`UnityPlayer.dylib` / `GameAssembly.dylib`); its display machinery
  lives in **`Contents/PlugIns/libMonitorUtil.dylib`**.
- It uses the **same private `CGVirtualDisplay` API we do**: `CGVirtualDisplayDescriptor` /
  `CGVirtualDisplaySettings` / `CGVirtualDisplayMode`, `setVendorID:` / `setProductID:` /
  `setSerialNum:`, with `CreateVirtualDisplay` / `CloseVirtualDisplay` wrappers. So Nebula has the
  same *class* of ColorSync exposure — the question is only how much reconfiguration it generates
  and how stable its display identities are.
- Capture is the **legacy `CGDisplayStream`** API (not ScreenCaptureKit), via an
  `ai.xreal.StreamHelper` service; `newTextureWithDescriptor:iosurface:plane:` suggests an
  IOSurface→Metal path much like ours.
- It also finds the glasses' display (`FindNrealDisplayID:`) and rearranges the OS layout
  (`CGConfigureDisplayOrigin xreal:`) — same moves as ours.
- The actual vendor/product/serial **values** are set at runtime (not visible in strings); the live
  test below will reveal them via the registry diff.

### Registry mechanics measured the same day (why the config count grows)

- WindowServer saves **one config per distinct display-SET** (combination + arrangement of display
  UUIDs), and never prunes. After a **fresh boot (15:43) with the registry fully cleared in both
  locations**, the user-level plist was back to **57 configs within ~2–3 h** of heavy dev use —
  sets of 1–9 displays drawn from just **13 distinct UUIDs** (built-in in 54/57 configs, the
  physical monitor in 44). Every AR start/stop, workspace switch, or plug/unplug that produces a
  *novel* combination mints a new config: growth is **combinatorial from set churn**, not leftover
  bloat. Clearing the registry is cosmetic — it re-bloats in hours.
- The runaway itself **re-armed ~75 min after the fresh boot + clean registry**, confirming
  registry size is a *byproduct*, not the cause.
- Unplugging the Air 2 clears the pin in **~25 s** (bursty decay: 70%→46% spikes shrinking for
  ~20 s, then flat 0%). Timed live with a 2 s poller.

### Test protocol (to run)

1. Quit AR Workspace Manager entirely; confirm `colorsync.displayservices` at 0%.
2. Run `notes/monitor-nebula-colorsync.sh` (logs Nebula/ColorSync/WindowServer CPU + ICC-profile
   count + registry size every 5 s to a Desktop log; flags `*** PINNED` samples; Ctrl-C = summary).
3. Plug in the Air 2, use **Nebula only** for 1.5–2 h (our re-arm baseline is ~75 min).
4. Afterwards: diff the display registry (config count, new UUIDs) to extract Nebula's virtual
   display identities — how many displays it creates, and whether their UUIDs are stable across
   sessions (our slot-serial scheme vs whatever Nebula does).

**Interpretation:** Nebula pins too → macOS/Air-2 trigger, largely out of our hands (report to
XREAL/Apple). Nebula stays clean → compare its set-churn (it may create its displays once and never
reconfigure) and identity scheme, and copy the difference.

## Nebula comparison RESULT (2026-07-02) — Nebula reproduces the runaway. It's not us.

Ran the protocol above: ARWM fully quit, Air 2 plugged in, **Nebula only**, monitored every 10 s.

**Nebula provoked the identical runaway, faster than ARWM ever has:**

- First `*** PINNED` sample (`displayservices` 73.5%) **~2 minutes** after Nebula started
  (17:24 start → 17:25:40 pinned). ARWM's re-arm baseline the same day was ~75 minutes.
- Identical signature: `colorsync.displayservices` ~70–74% with `colorsyncd` ~23–25% — the exact
  pair/ratio seen in every ARWM incident (and in the two WindowServer-crash stackshots).
- Pattern under Nebula: **cycling episodes** — pinned for ~2–3 min, decays to ~0–2%, re-climbs,
  roughly every 6–7 min (ARWM's episodes tend to pin and stay pinned).

**Nebula's display setup (read-only inspection while it ran):** exactly two virtual displays,
`XrealVirtualR-1` and `XrealVirtualL-2` (1920×1080 each), plus the Air 2. Their CGDisplay UUIDs
matched profiles/configs already in the registry from earlier Nebula sessions — i.e. **Nebula's
virtual-display identities are stable across sessions**, and its registry churn during the test was
negligible (displays plist grew 377 bytes; ICC profiles 6→8, just its two displays).

### Conclusion — shared trigger, DIFFERENT severity

Stable identities + only 2 displays + ~zero churn **still spins the daemon within minutes**, so the
loop's *trigger* is a **macOS + Air 2 (+ virtual display?) interaction, not ARWM's churn or
identity scheme**. BUT the patterns differ in a way that matters:

- **Nebula: cyclic and self-recovering** — bursts to 65–74% for ~2–3 min, then fully releases to
  ~0–2%, repeating every ~6–7 min. The loop appears to complete its work each cycle. A Nebula
  session probably never accumulates the backlog that kills WindowServer.
- **ARWM: sustained wedge** — once pinned it holds 72–75% indefinitely (47+ min observed the same
  day, never dipping) until the glasses are unplugged or WindowServer is watchdog-killed. This is
  the fatal variant. Cause of the difference UNKNOWN. One confounding data point: the sustained
  pin continued after Stop AR (virtual displays destroyed), so it isn't obviously live app
  activity — the loop may wedge into a state it can't finish. Candidate aggravators to test:
  display-set size (we run more displays), per-display wallpaper/profile writes, session history.

Consequences for us:

- Churn-reduction work remains good hygiene but is NOT the lever for the *trigger* — however the
  sustained-vs-cyclic difference is worth one more experiment: run the same monitor over an ARWM
  session and compare patterns (e.g. 2-screen workspace vs many, wallpaper features off).
- The realistic mitigation stands: detect the pin → tell the user to replug (clears in ~25 s).
- Upstream report material is strong either way: XREAL's own app exhibits the loop on macOS 26.5.1
  (attach monitor logs + the two WindowServer watchdog stackshots).

### Nebula long-run baseline (overnight 2026-07-02→03, ~16 h) — cyclic forever, never wedges

Monitor ran 17:23→09:13 (5,574 samples @10 s): **150 pinned episodes**, metronomic ~7-min period,
each ~2–2.4 min then a full release to ~0–2%. **Longest episode: 3.1 min**; longest stretch even
above 20% was 4.3 min. It never once wedged. (Averaged over the night the cycle still burns ~47% of
a core on `colorsync.displayservices` — the bug costs Nebula sessions too, just never fatally.)

Baseline established: **Nebula = cyclic, self-recovering, indefinitely. ARWM = the sustained wedge
(47+ min, no dips, twice fatal) is session-specific to us.** Next: the identical monitored run with
ARWM only (Step 2), then knob isolation (Step 3: 2-screen workspace, backgrounds off, no switching)
if the difference holds.

### Wedge-onset observation (2026-07-03 15:14) — reconfiguring on a HOT daemon tips it

Cleanest onset capture yet: after an app crash (15:01) the daemon sat *elevated* (20–45%,
oscillating) for ~12 min digesting the teardown; the app relaunched at 15:14:03 and created its
virtual displays; **ten seconds later (15:14:20) the daemon hard-pinned at ~72% and stayed wedged
13+ min** (the 6-min alert fired correctly — first true positive).

Working hypothesis for burst-vs-wedge: a display reconfiguration landing on an **already-hot**
daemon wedges it; the same reconfiguration on a cold daemon just bursts. Fits Nebula (creates its
2 displays once, from cold, never reconfigures → only ever bursts) and both crash days (crash →
teardown churn → elevated daemon → next reconfiguration → wedge).

Candidate mitigation to test: before creating/destroying virtual displays (AR start/stop,
workspace switch, app relaunch), sample `colorsync.displayservices`; if it's hot (say >20%), wait
for it to settle (a few seconds, bounded) before reconfiguring — deny the wedge its trigger window.
