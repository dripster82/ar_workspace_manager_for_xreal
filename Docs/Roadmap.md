# Spatial Workspace — Roadmap

Forward-looking plan derived from [Ideas.md](Ideas.md), with feasibility decisions applied.
[Plan.md](Plan.md) is the original build plan (now largely delivered); Ideas.md is the
product vision; this doc is the actionable next-stage plan and the technical detail.

## Positioning

"Your entire desk, redesigned for spatial computing" — a spatial **display manager**, not a
virtual-monitor utility. Differentiators over Nebula / ultrawide-only tools: named
workspaces, head-locked floating screens, per-screen curvature, and (later) window
automation.

---

## Decisions applied (this revision)

1. **"Floating" = head-locked.** A floating screen keeps a fixed offset in the viewer's
   field of view (e.g. Slack 15° right, 10° down, 1 m away) and travels with the head.
   "Anchored" screens stay fixed in *orientation* space (today's behaviour).
2. **Screen count is "as many as you want, arranged so you turn to the one you need"** —
   not marketed as unlimited. The optics make distant/small screens unreadable and
   CGVirtualDisplay is stable only to a handful of displays; workspaces + focus mode are how
   you manage many screens.
3. **Automatic window management is a future nice-to-have, not a requirement.** Manual
   "send window to screen" is in scope; rule-based auto-placement is deferred.

---

## Hardware constraints (design within these)

- **3DoF only.** Air 2 reports orientation, not position — no parallax when you lean or
  walk. "Anchored" = orientation-locked, good for seated use. True 6DoF world-anchoring
  needs cameras (Air 2 Ultra), out of scope for Air 2.
- **1080p per eye, ~46° FOV.** You can read 1–2 screens at a time; design for "turn to
  focus," not a wall of tiny readable screens.
- **Fixed focal plane (~4 m).** Per-screen distance changes apparent size and stereo
  convergence (in SBS), not optical focus. Distance doesn't fix eye strain.
- **Additive optics: black = transparent.** Transparent screens are free; opacity is a
  shader alpha; opaque backgrounds occlude the real world.

---

## Current state (already built)

- **GlassesDriver** — 3DoF IMU tracking (smoothing + prediction, tunable), recenter (with
  optional roll), brightness, MCU display-mode switching (SBS).
- **CapturePipeline** — ScreenCaptureKit per-display capture at native pixel size →
  zero-copy Metal textures.
- **Compositor** — fullscreen CAMetalLayer on the glasses display, CAMetalDisplayLink, depth
  buffer, horizontal curvature (manual + auto "natural sphere"), SBS stereo.
- **DisplayManager** — CGVirtualDisplay (HiDPI), 3840×1080 SBS mode switching, mirroring
  control, named workspaces with JSON persistence.
- **App** — control panel, workspace CRUD, live add/remove screens, physical monitors into
  AR, output auto-select, global hotkeys (⌃⌥Space recenter, ⌃⌥Esc stop), Screen-Recording
  permission flow, sleep/wake + unplug resilience.

This already covers most of Ideas.md §3–6 and §11.

---

## Core concepts

**Screen placement modes** (per screen):
- **Anchored** — fixed yaw/pitch in world-orientation space; stays put as you look around
  (current default).
- **Floating (head-locked)** — fixed offset in view space; follows the head. Configurable
  yaw/pitch offset + distance.

**Workspace** — a named set of screens with full placement, plus (later) app→screen
mappings. Switchable, with favourites for instant load.

**Screen** — a (possibly virtual) display captured and placed in the scene, with resolution,
scale, curvature, distance, placement mode, label, and background.

---

## Roadmap

### Phase 1 — Floating screens + placement modes  *(highest value, small change)*
- Add a `placement` mode (anchored | floating) to the screen config.
- Renderer: for floating screens, skip the head-rotation transform and place at a fixed
  view-space yaw/pitch/distance (per-screen branch in the existing scene transform).
- UI: per-screen mode toggle + offset/distance controls (reuse existing sliders).
- *Verify:* a floating screen stays glued to your view as you turn; anchored screens stay
  fixed in space.

### Phase 2 — Workspace UX
- Workspace switcher overlay (⌃⌥W): list, search, recent, preview thumbnails.
- Favourites with ⌃⌥1/2/3 instant load.
- *Verify:* switch workspaces by hotkey; favourites load the right layout.

### Phase 3 — In-AR readability & chrome
- Screen labels (corner-positioned; always / on-focus / hidden).
- Per-screen backgrounds (solid / gradient / image / transparent).
- Help overlay (⌃⌥H) listing hotkeys, rendered front-and-centre.
- *Verify:* labels and backgrounds render per screen; help overlay shows on hotkey.

### Phase 4 — Focus mode
- ⌃⌥F eases a chosen screen to the primary viewing area via an animated orientation offset
  (the screen doesn't move; the view eases to it).
- Screen selection (cycle / pick) for focus.
- *Verify:* focus eases the chosen screen to centre and back.

### Phase 5 — Manual window control  *(the useful 20% of window management)*
- Window-manager panel: list windows (Accessibility API) with app, title, current screen.
- "Send window to screen X" via hotkey (⌃⌥M) and panel action — compute the target virtual
  display's global frame and set the window's AXPosition/AXFrame.
- *Verify:* a chosen window jumps onto the chosen AR screen.
- *Note:* needs Accessibility permission; some apps resist being moved — handle gracefully.

### Phase 6 — Polish
- Launch at login + menu-bar presence.
- Yaw-drift auto-correction (reduce reliance on manual recenter).
- *Verify:* starts with the Mac; drift stays bounded over a long session.

---

## Future (nice-to-have, not required)

- **Automatic window placement rules** — app / window-type → screen mappings, categories
  (Work / Social / Call / …). Brittle (AX heuristics, app-specific quirks); revisit after
  Phase 5 proves the manual moves are solid.
- **Voice commands** — push-to-talk, on-device `SFSpeechRecognizer`, small fixed grammar
  (focus / move / load workspace / recenter / stop). Self-contained; schedule after the
  visual work.
- **Screen groups**, **multi-user shared spaces**, **remote / cloud sync**, **AI workspace
  assistant** — long-horizon; no action yet.
- **6DoF world-anchoring** — gated on camera hardware (Air 2 Ultra); revisit if the target
  device changes.

---

## Data model additions (incremental)

Extend `VirtualScreenConfig` (persisted; keep the backward-compatible decode-with-defaults
pattern already in use):
- `placement`: `anchored | floating`
- `floatingOffset`: yaw / pitch degrees + distance (used when floating)
- `label`: text + corner + visibility
- `background`: none | color | gradient | image
- (later) workspace-level `appMappings` for window automation
