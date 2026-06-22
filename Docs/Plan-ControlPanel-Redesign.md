# Control Panel redesign — design spec & UX review

A **planning document** for moving the control panel from one long scrolling stack of cards to the
concept's **sidebar-driven multi-page app** (Dashboard, Workspaces, Displays, HUD Widgets,
Automation, Settings). This describes what each page looks like and what information it shows, then
reviews whether the proposed grouping is good UX. **No implementation here.**

Source mockups: `~/Downloads/ChatGPT Image Jun 22, 2026, 02_50_39 PM.png` (6 panels).

Locked decisions: Window Rules = **scaffold UI only** (engine later); Voice Commands / Updates /
About = **"coming soon" stubs**; **no greeting** line.

**UX recommendations in §4 are ADOPTED** (they override §2/§3 where they differ):
- A persistent **active-workspace + Start/Stop AR top bar** on every page.
- **Performance** and **Glasses** are **Settings sub-tabs only** (not top-level).
- **Automation = Window Rules + Voice Commands**; **Calendar Alerts** moves under the Calendar HUD
  widget; **Shortcuts** moves into **Settings**.
- **Permissions banner** on Dashboard when a required grant is missing.
- **Advanced disclosures** preserve existing power (HUD stacks + precise placement; Displays
  mirroring / show-in-AR / auto-curve / HiDPI).
- Dashboard stats: Screens / HUD Widgets / FPS / connection — **drop the Window Rules count**.

---

## 0. Revision — merged Workspace page + settings moves (supersedes §2–§6 where they differ)

Design direction after Phase 0:

- **Merge Workspaces + Displays into one "Workspace" page.** They're the same thing with extra
  steps — a workspace *is* its set of displays. The page is **layout-centric**:
  - **Workspace selector** + **HUD Profile selector** at the top (HUD "layouts" are renamed **HUD
    Profiles** — named, selectable like workspaces).
  - The **Layout map is the main element**; an **Add Display** button drops a new display into it.
  - **Clicking a screen in the layout selects it** and shows its **detail below**: background,
    placement sliders (yaw/pitch/distance/scale/curve) with **editable numeric values**, mirror
    options, label, reset/delete.
- **Move "AR Output" to Settings › Glasses** (output picker, display mode, refresh, stereo/IPD,
  wide-canvas) and **duplicate the brightness slider** there.
- **Move HUD widget connections/settings to Settings › HUD** (Slack / GitHub / Calendar auth +
  refresh intervals). The **HUD Widgets page** keeps only widget management + placement.
- **Move the calendar meeting-alarm options onto the Calendar widget itself** (its per-widget
  config), not a separate Automation page.

Resulting navigation: **Main** — Dashboard, Workspace, HUD Widgets · **Automation** — Window Rules,
Voice Commands · **Settings** (sub-tabs) — General, Glasses, HUD, Performance, Permissions,
Shortcuts, About.

Phase 0 applies the easy structural moves (merge the two routes; AR Output + brightness under
Glasses); the layout-centric click-to-select editor, the connections split, HUD Profiles as a
selectable model, and calendar-alarms-on-widget are the next build phases.

## 1. Visual language

- **Theme:** near-black window (~#0E0E12), lighter cards (~#16161C), hairline borders (white ~8%),
  rounded **14px** cards / **10px** controls, generous padding.
- **Accent:** violet (~#7C5CFC) — selected nav, primary buttons, toggles-on, slider tracks, focus
  rings. Semantic colours kept: green (connected / positioning-only), orange (in-AR / warning),
  red (destructive / failing).
- **Type:** each page = **title + subtitle** header; section labels caption-uppercase-secondary;
  big numbers on stat cards.
- **Controls:** iOS-style toggles, violet sliders with a value read-out, segmented pickers, list
  rows with a leading coloured icon/dot, preview thumbnails (a mini Layout map).
- **Window:** grows from 520×680 → ~**1040×720**, resizable (min ~920×620). Sidebar ~210px.

## 2. Global chrome

**Left sidebar (every page):**
- **Top:** app identity ("Spatial Workspace v2.0" + icon).
- **Nav groups** (see §4 for the UX critique of these): *Main* — Dashboard, Workspaces, Displays,
  HUD Widgets · *Automation* — Window Rules, Voice Commands, Calendar Alerts, Shortcuts ·
  *System* — Settings, Performance, Glasses.
- **Bottom status chip:** active workspace name + AR state ("Running" / "Stopped") — **see UX review:
  this should also be the always-visible Start/Stop AR control.**

Every page = `PageHeader(title, subtitle)` then content in cards.

---

## 3. Page-by-page spec (what's shown)

### 3.1 Dashboard — "Overview and quick actions"
At-a-glance status + the few things you do often.
- **Top bar:** active-workspace dropdown · **Start/Stop AR** (primary) · Recenter.
- **Stat cards** (row): **Screens** (count), **HUD Widgets** (count), **Window Rules** (count),
  **Performance** (FPS · CPU · Mem). Glanceable, read-only.
- **Current Workspace** card: name, last-edited, *Load Another Workspace*, *Reset Workspace*.
- **Workspace Preview** card: a mini Layout map of the current screens + *Edit Layout* (opens the
  Displays layout editor).
- **Quick Actions** row (icon buttons, each = an existing hotkey): Recenter (⌃⌥Space), Focus (⌃⌥F),
  Passthrough (⌃⌥V), Labels (⌃⌥L), Screenshot (⌃⌥P), Record (⌃⌥R), Move Window (⌃⌥W).
- **States:** glasses not connected → status pill + "connect glasses"; permission missing → a banner
  (see UX review).

### 3.2 Workspaces — "Manage your workspace profiles"
- **Left list:** workspace cards — icon/accent, name, ★ favourite, screen count, last-used.
  *New Workspace* (primary).
- **Right detail (selected workspace):** Name, Description, Favourite Slot (None/1/2/3), summary
  stats (Screens, HUD layout, Window Rules), Last Modified; actions *Duplicate*, *Export*, *Delete*;
  layout preview + *Edit Workspace Layout*; *Set Active*.
- **Bottom:** *Manage Favourites*.
- New per-workspace metadata: `description`, `icon`/`accent`, `favouriteSlot`.

### 3.3 Displays — "Configure your virtual displays"
Edits the **active workspace's** screens (master/detail).
- **Left list:** each virtual screen — name, resolution, Anchored/Floating, coloured dot;
  *+ Add Display*. Physical monitors shown as positioning-only (green) entries.
- **Right detail (selected screen):**
  - Display Name; **Mode** segmented Anchored | Floating; preview thumbnail.
  - Sliders: **Scale**, **Curve** (+ auto-curve), **Distance**, **Rotation** presets.
  - **Resolution** menu; **Background** (Default / Colour / Image+Browse / Transparent); **Label**
    toggle.
  - **Routing/advanced** (disclosure): Show in glasses, Mirror → physical, Mirror → another virtual,
    HiDPI. *(These exist today and must not be lost — see UX review.)*
  - *Reset to Defaults*, *Delete Display*.
- **Layout editor:** the drag-to-place PlacementMap, reached via *Edit Layout* (Dashboard/Displays).
- **Workspace view options** (wide-canvas on/off + distance/scale) live here too (per-workspace).

### 3.4 HUD Widgets — "Customize your HUD (always in view)"
Three columns:
- **Available:** Clock, Battery, Calendar, Slack, GitHub, System Monitor, Messages, Weather,
  Pomodoro, Custom Text — each with **+**.
- **Active:** drag-to-reorder list with eye (show/hide) toggles.
- **Detail (selected widget):** Size, **Position** (3×3 quick picker), Opacity, Refresh interval,
  Show icon, Workspace visibility; plus the integration auth (Slack/GitHub/Calendar) under the
  relevant widget. **Advanced** disclosure for precise yaw/pitch/distance + **stack** membership
  *(today's power — keep it).*
- *Restore Default HUD*.

### 3.5 Automation — "Rules, voice commands, alerts and shortcuts"
Tabbed (Window Rules · Voice Commands · Calendar Alerts · Shortcuts).
- **Window Rules** *(UI scaffold; engine later)*: table — Name · When (app/title match) · Target
  (a display / floating position / minimise) · enabled toggle; *Add Rule*, *Import*, *Export*. Shows
  a "rules don't run yet — engine coming" note until the engine ships.
- **Voice Commands:** "coming soon" stub.
- **Calendar Alerts:** the existing calendar feed + meeting-alarm settings (lead times, sound).
- **Shortcuts:** the canonical ⌃⌥ table (same source as the ⌃⌥H overlay), read-only reference.

### 3.6 Settings — "App preferences and advanced settings"
Secondary sub-nav:
- **General:** Start at Login, Launch in Menu Bar, App Theme, behaviour toggles (confirm-before-
  delete, notifications, sounds), cursor-confinement, recording mic, window-restore mode.
- **Permissions:** Screen Recording, Accessibility, Microphone (status + grant).
- **Performance:** MSAA, sharpening, supersample, render thread; IMU tuning (calm/response/
  prediction), drift correction + calibrate; fake-pose (dev); debug logging (general / raw IMU /
  system load) + reveal/clear.
- **Glasses:** Brightness, Display Mode, Refresh rate, Stereo (SBS) + IPD, *Apply to Glasses*.
- **Updates:** "coming soon" stub (no auto-updater exists).
- **About:** version, build hash/date, links.

---

## 4. UX review — does the grouping work?

The sidebar model is a clear win over one long scroll for an app this feature-rich. But a few
groupings need rethinking before building:

**A. "Active workspace" must be globally persistent — biggest issue.** Displays, HUD Widgets, and
(future) Window Rules all edit *the active workspace*, but the mockups only surface it on Dashboard.
A user on the Displays page won't know which workspace they're changing. **Recommendation:** show the
active workspace in the **sidebar header or a slim top bar on every page**, with a quick switcher, so
"what am I editing?" is always answered. Editing Displays/HUD always targets the active workspace;
switching is explicit.

**B. Resolve the Performance/Glasses duplication.** The mockups show *Performance* and *Glasses* both
as **top-level sidebar items** (panel 1) **and** as **Settings sub-tabs** (panel 6). Pick one.
**Recommendation:** keep them as **Settings sub-tabs** (they're configuration), and *don't* duplicate
at top level — except surface the few high-frequency Glasses controls (Brightness, Recenter) as
Dashboard Quick Actions, where they belong.

**C. "Automation" is a grab-bag.** Window Rules and Voice Commands are genuine automation; **Calendar
Alerts** and **Shortcuts** are not. **Recommendation:** move **Calendar Alerts** to live with the
**Calendar HUD widget** (it's calendar-specific) or a "Notifications" area; move **Shortcuts** into
**Settings** (it's a reference). Rename the remaining group **Automation** (Window Rules + Voice
Commands). If keeping the mockup's grouping for fidelity, at least rename it something honest like
"Behaviour" — but splitting is cleaner.

**D. Always-visible Start/Stop AR.** Starting AR is the app's primary action and is needed from any
page. The bottom status chip already shows Running/Stopped — **make it the Start/Stop AR control**
(or pair a button with it) so it's reachable everywhere, not only Dashboard.

**E. Surface missing permissions prominently.** AR silently fails without Screen Recording /
Accessibility. **Recommendation:** a dismissible **banner on Dashboard** when a required permission
is missing, linking to Settings › Permissions — don't bury it.

**F. Don't lose power in HUD placement.** The mockup simplifies widget placement to a 3×3 grid +
size, but today's app has **stacks** and precise yaw/pitch/distance. **Recommendation:** keep the
3×3 + size as the friendly default, with an **Advanced disclosure** for precise placement + stack
membership — so the simplification doesn't remove capability.

**G. Don't lose Displays power.** The mockup's display detail omits **mirroring** (virtual→physical,
virtual→virtual), **show-in-AR routing**, **auto-curve**, and **HiDPI** — all of which exist today.
**Recommendation:** keep them in a "Routing / advanced" disclosure on the display detail.

**H. Dashboard stats: keep useful, drop vanity.** Screens / HUD Widgets / Performance are useful at a
glance; a **Window Rules count** is low-value (and the engine isn't built). **Recommendation:** show
Screens, HUD Widgets, FPS, and connection/latency; drop or de-emphasise the rules count for now.

**I. Where do view toggles live?** Focus (⌃⌥F), Passthrough (⌃⌥V), Labels (⌃⌥L), wide-canvas are
per-session/per-workspace view states. **Recommendation:** expose them as **Dashboard Quick Actions**
(transient) and, where they're persistent (wide-canvas, labels-default), in the relevant page
(Displays). Avoid scattering them.

**J. Nav length.** Even after regrouping, the sidebar has ~10 destinations. That's fine with clear
group headers, but keep the groups to 3 (Main / Automation / Settings) and let Settings hold its own
sub-nav rather than promoting Performance/Glasses to the top level (ties to B).

### Net assessment
The page split (Dashboard / Workspaces / Displays / HUD / Automation / Settings) is sound and maps
cleanly onto the existing features. The main risks are **(A) losing the "active workspace" context**,
**(B/C) the duplicated/grab-bag groups**, and **(F/G) over-simplifying Displays/HUD and dropping
existing power**. Addressing A–C and F–G makes this a strong, discoverable UI; the rest are polish.

---

## 5. Feature coverage check (nothing dropped)

Existing features and their new home — verify each lands somewhere:

- Start/Stop AR, output picker, recenter, status, FPS/IMU → **Dashboard** (+ always-on AR toggle).
- Workspace CRUD, favourites → **Workspaces**.
- Virtual screens (res, placement, scale, curve+auto, distance, background, label, HiDPI),
  show-in-AR, mirroring, wide-canvas, Layout map → **Displays**.
- HUD widgets, stacks, Slack/GitHub/Calendar integrations → **HUD Widgets**.
- Calendar feed + meeting alarms → **Calendar Alerts** (under Calendar widget per UX-C).
- Shortcuts reference → **Settings › Shortcuts** (per UX-C).
- Brightness, display mode, refresh, stereo/IPD → **Settings › Glasses**.
- MSAA / sharpen / supersample / render thread, IMU tuning, drift cal, fake pose, debug logging →
  **Settings › Performance**.
- Permissions → **Settings › Permissions**.
- Launch-at-login, menu bar, cursor confinement, mic, window-restore → **Settings › General**.
- Focus / Passthrough / Labels / Move-window / Screenshot / Record → **Dashboard Quick Actions**.
- New (scaffold/stub): **Window Rules**, **Voice Commands**, **Updates**, **About**.

## 6. Build approach (when planning is approved — not now)

Phase the work so each step ships working: **0** shell + design-system + routing (wire existing views
in) → **1** Dashboard → **2** Displays → **3** Workspaces → **4** HUD Widgets → **5** Settings → **6**
Automation. Preserve the existing **"no @Published writes while AR runs"** rule (Dashboard stats must
gate on `!arActive`, or the head-tracking judder returns). Split `ControlPanelView.swift` (~1400
lines) into `Panel/<page>.swift` + `Panel/Components/`.
