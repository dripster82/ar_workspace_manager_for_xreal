# VR Desktop — Features

A living inventory of what the app does, grouped by area. Generated from a full pass over the
source; keep it in sync when adding features. See also [Roadmap.md](Roadmap.md) (forward plan),
[PLAN.md](PLAN.md) (original build plan), and [Ideas.md](Ideas.md) (product vision).

## Core AR / head tracking
- **3DoF head tracking** from the XREAL IMU at ~1 kHz (`GlassesDriver/IMUService`)
- **One-Euro adaptive filtering** — tunable "calm at rest" (min-cutoff) vs "responsiveness" (beta)
- **Motion prediction** — extrapolates pose by a configurable lead (default 21 ms) to cut latency
- **Recenter** (⌃⌥Space) — optional roll inclusion (swing-twist keeps the horizon level)
- **Yaw-drift control** — stillness freeze + a 4-second gyro-bias calibration routine
- **Fake head pose** — yaw/pitch sliders to drive the scene with no glasses connected

## Rendering / compositor
- **Metal compositor** on the glasses display via `CAMetalDisplayLink`, optionally on a dedicated
  high-QoS render thread (`Compositor/GlassesRenderer`)
- **Curved screens** — manual curvature (flat → ~150° wrap) or auto "natural sphere" curve
- **Wide-canvas mode** — merges all anchored screens into one continuous curved surface (shared
  distance/scale)
- **Stereo SBS (experimental)** — 3840×1080 split with adjustable IPD
- **Quality controls** — MSAA (2/4/8×), anisotropic sharpening (2–16×), supersampling (up to 2×)
- **Refresh-rate control** — 60/72/90/120 Hz mode switching; frame-pacing / dropped-frame
  diagnostics + FPS counter
- **Glasses brightness** — set/poll levels 0–8 (follows the physical buttons too), with an on-screen HUD

## Virtual displays & workspaces
- **Virtual displays** at arbitrary resolutions incl. ultrawide, HiDPI (auto 1× fallback for very wide)
- **Slot-based stable display identities** — bounded identity pool so macOS's display registry
  doesn't bloat (`DisplayManager/VirtualDisplayService`)
- **Named workspaces** — JSON-persisted, switchable, backward-compatible migration
- **Per-screen placement** — yaw, pitch, distance, scale, curvature; **anchored** (world-fixed) vs
  **floating** (head-locked); reset-placement
- **Per-screen backgrounds** — default / solid colour / image (stretch-to-fill) / transparent
  (black = see-through), applied live as the display's wallpaper
- **Routing & mirroring** — per-screen show-in-AR toggle; mirror virtual→physical and
  virtual→virtual; live toggling
- **Physical monitors** — auto-detected; positioning-only anchors (green) or mirrored into AR (orange)
- **OS display auto-arrangement** — tiles displays edge-to-edge to match the GUI layout; snapshots
  and restores your real arrangement on stop

## View modes & interaction
- **Focus mode** (⌃⌥F) — fits the looked-at screen to the FOV (head-locked), moves the cursor onto
  it and confines it there; toggles back. Render-only (no display reconfig). See [Plan-Focus.md](Plan-Focus.md)
- **Passthrough** (⌃⌥V) — hides only the screens (HUD stays) for a real-world view
- **Gaze tracking** — "looking at" detection; gaze-point ray intersection per screen
- **Cursor tools** — confine cursor off the AR display; **find-my-cursor** compass with homing ping
  and auto-enlarged cursor (⌃⌥C); **move cursor to gaze** (⌃⌥X)
- **Window layout save/restore** — records window→screen positions (Accessibility) and restores
  them on AR start (Off / Always / Ask / Remember)
- **Move window to screen** (⌃⌥W) — a 5×3 FOV grid of window thumbnails; arrow-keys to select,
  Enter moves the chosen window to the screen you're looking at (fills it by default; General-card
  toggle for reposition-only)

## HUD widgets (head-locked, 1 Hz refresh)
- **Clock** (12/24h, seconds), **Power/battery**, **Slack** unreads, **GitHub** PR-triage,
  **Google Calendar** agenda
- **Stacks** — group widgets vertically/horizontally with alignment + per-widget scale; drag-to-reorder
- **Styling** per widget — tint, background (pill/solid/none)
- **Show/hide HUD** (⌃⌥I), independent of passthrough
- **Screen name labels** (⌃⌥L) — per-screen top-left corner label that tracks each screen (anchored, floating, and per-tile in wide-canvas mode); toggle on/off

## Integrations
- **Google Calendar** — iCal feed (Keychain), recurrence expansion, agenda widget, **meeting alarms**
  (dual lead times, audio + centre-FOV card, Esc to dismiss)
- **Slack** — OAuth user token (loopback flow), unread tracking for DMs / group DMs / starred
  channels, user-selectable priority conversations
- **GitHub** — personal access token (Keychain), five PR-triage counts via the Search API, editable
  queries, optional org scope

## Capture & recording
- **Screenshot** the glasses view (⌃⌥P) → Desktop
- **Record** the glasses view (⌃⌥R) → Movies (H.264 + AAC), with **mic mute** (⌃⌥M) and a selectable
  input device; in-AR REC indicator
- **Debug stage dumps** for wide-canvas (raw → merged atlas → curved) with marker crosshairs

## App shell, overlays & diagnostics
- **Menu-bar item** — status, start/stop AR, recenter, stereo, cursor tools, help, launch-at-login, quit
- **Control panel** — 8 cards: Status, AR Output, Layout (drag-to-place map), HUD Widgets, Workspace,
  Tracking & Testing, Permissions, General
- **In-AR overlays** — two-column help (⌃⌥H), cursor-info, brightness, alarms — all with a macOS-panel
  fallback when AR is off
- **Permissions flows** — Screen Recording, Accessibility, Microphone
- **Launch at login**; sleep/wake + unplug recovery; App-Nap prevention while AR runs
- **Debug logging** — general log, raw IMU (~60 Hz), system-load / top-processes (~3 s), reveal/clear

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌃⌥Space | Recenter the view |
| ⌃⌥Esc | Stop AR |
| ⌃⌥S | Start / stop AR |
| ⌃⌥D | Stereo (SBS) on / off |
| ⌃⌥F | Focus the looked-at screen (toggle) |
| ⌃⌥V | Passthrough — hide / show the screens (HUD stays) |
| ⌃⌥I | Show / hide the HUD widgets |
| ⌃⌥L | Show / hide screen name labels |
| ⌃⌥C | Find the cursor (screen + arrow) |
| ⌃⌥X | Move cursor to where you're looking |
| ⌃⌥P | Screenshot the glasses view → Desktop |
| ⌃⌥R | Record the glasses view → Movies |
| ⌃⌥M | Mute / unmute the recording mic |
| ⌃⌥H | Show / hide help |
| ⌃⌥Q | Quit VR Desktop |
| ⌃⌥ + brightness keys | Dim / brighten the glasses |
| Esc | Dismiss an active meeting alarm |
