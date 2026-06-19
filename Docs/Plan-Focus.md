# Plan — Focus mode (⌃⌥F)

Detailed implementation plan for Roadmap **Phase 4 — Focus mode**, building on the current code.
Companion to [Roadmap.md](Roadmap.md), [Plan-2.0.md](Plan-2.0.md) and [Ideas.md](Ideas.md) §10.
Conventions, hardware constraints, and current state are in those docs.

---

## Goal

Press **⌃⌥F** and the screen you're currently looking at becomes a **focused** screen: it snaps
to the centre of your view, head-locked, sized to fill the FOV exactly, with every other screen
hidden. The mouse cursor is moved onto it and confined to its bounds so you can't accidentally
lose the cursor onto another (now-hidden) display. Press **⌃⌥F** again to drop focus — the normal
layout returns, the cursor is freed, and (optionally) restored to where it was.

This differs slightly from the Roadmap's "ease the view to the screen" wording: the user wants the
screen brought to a perfect FOV fit (a head-locked overlay), not just an animated view nudge. The
plan below implements the FOV-fit overlay; an eased transition is an optional polish (see Notes).

---

## Concept

Focus is a **transient overlay state**, never persisted. The chosen screen's saved
placement/scale/curve are untouched; focus only overrides how the scene is *assembled* while it's
active. Mechanically a focused screen is just a **floating (head-locked) screen** placed at
yaw 0 / pitch 0, flat, at a fixed distance, with its width chosen so its edges land exactly on the
FOV edges. Because it's head-locked it stays glued to your view as you turn — i.e. it "fits into
the FOV perfectly" and stays there. Dropping focus rebuilds the normal scene.

While focused, only the focused screen is rendered (others hidden), and the existing
"confine cursor off the AR display" rule is swapped for "confine cursor *inside* the focused
display."

---

## FOV-fit geometry

The renderer's projection ([GlassesRenderer.projectionMatrix](../Sources/Compositor/GlassesRenderer.swift))
uses `fovY = 23°` and `aspect = eyeWidth / height`. For a full-width mono 16:9 eye that gives
`fovX ≈ 39.8°`. In stereo each eye is also 16:9 (e.g. 1920×1080 of a 3840×1080 frame), so the FOV
is the same per eye — the fit works for mono and SBS with no special-casing.

A flat quad placed head-locked at distance `d`, centred, fills the FOV exactly when its half-extents
are the FOV half-angles' tangents times `d`:

```
halfX = fovX/2,  halfY = fovY/2           // fovX derived from fovY and the output aspect
maxHalfW = d * tan(halfX)                  // metres
maxHalfH = d * tan(halfY)
let As   = contentWidth / contentHeight    // the screen's content aspect
if As >= maxHalfW / maxHalfH {             // content wider than the FOV box → width-limited
    halfW = maxHalfW * fill;  halfH = halfW / As
} else {                                   // height-limited
    halfH = maxHalfH * fill;  halfW = halfH * As
}
widthMeters = 2 * halfW                     // SceneScreen derives height from aspect
```

`fill ≈ 0.98` leaves a hair of margin so rounding never clips an edge. `d` is free (angular size
depends only on `width/d`); pick `focusDistanceMeters = 1.0` for a comfortable, dominant screen.
`fovX` must be derived from the **same** aspect the renderer uses for the current output, so add a
single shared helper rather than hard-coding 39.8°.

Keep the focused screen **flat** (`curveH = 0`, `autoCurveH = false`): a flat quad's edges map
exactly to the FOV edges, giving a true rectangular fit. (Curved fills the FOV too but the corners
no longer touch — flat is the "perfect fit.")

---

## Changes

**1. Coordinator state — [AppCoordinator.swift](../Sources/VRDesktop/AppCoordinator.swift)**
- `@Published var focusedScreenID: UUID?` (published so the panel can show a "Focused: X" pill and
  the menu bar can show a toggle). Not in the workspace JSON.
- `private var preFocusCursor: CGPoint?` — global cursor position captured on entering focus, to
  restore on exit (optional nicety).

**2. Toggle entry point — `toggleFocus()` (new)**
- `guard arActive else { statusMessage = "Start AR to use focus"; return }`.
- If `focusedScreenID != nil` → `dropFocus()` and return (F toggles off regardless of gaze).
- Else pick the target: `guard let cfg = lookedAtConfig() else { statusMessage = "Look at a screen to focus it"; return }`.
  (`lookedAtConfig()` already returns the gaze-nearest `showInAR` screen within ~30°, virtual or
  physical, so it always has a live capture.)
- `preFocusCursor = currentGlobalCursor()`; `focusedScreenID = cfg.id`.
- `liveUpdateScreens()` to rebuild the scene with just the focused screen (see change 4).
- `moveCursorToGaze()` to drop the cursor onto the focused screen where you were looking (falls back
  to the display centre if the gaze ray misses).
- `updateCursorConfinement()` (see change 5) — now confines into the focused display.
- `statusMessage = "Focused on \(cfg.name) — ⌃⌥F to exit"`.

**3. `dropFocus()` (new)**
- `focusedScreenID = nil`; `liveUpdateScreens()` (restores the full layout).
- `updateCursorConfinement()` (back to the off-AR-display rule).
- If `preFocusCursor` set, warp the cursor back (`CGWarpMouseCursorPosition` + re-associate); clear it.
- Also call `dropFocus()` (or just clear `focusedScreenID`) from `stopAR()`/teardown so focus never
  outlives a session.

**4. Scene assembly — `assembleScene(_:)` + a focused builder**
- At the top of `assembleScene`: if `let id = focusedScreenID`, find that pair and return
  `[focusedSceneScreen(config:capture:)]` (ignore wide-canvas merging and all other screens while
  focused). If the id isn't in `pairs` (e.g. it was toggled off-AR), fall through to normal assembly
  and clear focus.
- `focusedSceneScreen(config:capture:)` (new): like `sceneScreen` but
  `yaw = 0, pitch = 0, headLocked = true, curveH = 0, autoCurveH = false, distance = focusDistanceMeters`,
  and `widthMeters` from the FOV-fit helper using `config.width/height` as the content aspect and the
  current output aspect for `fovX`.
- Add `focusFOVFit(contentAspect:) -> (widthMeters: Float, distance: Float)` using the geometry above;
  the output aspect comes from the renderer/output screen (expose `displayRefreshHz`-style, or pass
  the eye aspect the renderer already knows — simplest: compute `fovX` from `fovY` and 16:9, which is
  correct for every supported glasses mode, and note the assumption).

**5. Cursor confinement — [CursorConfiner.swift](../Sources/VRDesktop/CursorConfiner.swift)**
- Generalise to two modes:
  ```swift
  enum Mode { case offDisplay(CGDirectDisplayID)   // current: keep cursor OFF the AR output
              case confineTo(CGDirectDisplayID) }   // new: keep cursor INSIDE one display
  ```
- `confineTo`: in `enforce()`, if the cursor leaves the target display's frame, **clamp** it to the
  nearest point inside that frame (warp to the clamped point) rather than snapping to `lastAllowed` —
  so dragging to an edge feels natural (the cursor sticks to the edge). Reuse the existing
  `toCG`/global-frame lookup.
- `updateCursorConfinement()` in the coordinator chooses the mode: focused → `confineTo(focused
  display id)`; otherwise → `offDisplay(glassesDisplayID)` (today's behaviour). The focused display id
  is `displayID(forConfig:)` for the focused config (already exists).

**6. Hotkey — [main.swift](../Sources/VRDesktop/main.swift)**
- Add `toggleFocusHotKeyID: UInt32 = 14` + a `toggleFocusHotKeyRef`; in the dispatch switch
  `case toggleFocusHotKeyID: delegate.coordinator.toggleFocus()`; register `kVK_ANSI_F` with
  control+option alongside the others.

**7. Help + menu — [HelpContent.swift](../Sources/VRDesktop/HelpContent.swift), menu bar**
- Add `Shortcut(keys: "⌃⌥F", action: "Focus the screen you're looking at (toggle)")`.
- Optional: a "Focus screen I'm looking at (⌃⌥F)" menu item (enabled while `arActive`), mirroring the
  cursor/SBS items in `menuNeedsUpdate`.

**8. UI (optional, low priority)** — a small "Focused: <name>" indicator with an Exit button in the
Workspace card while `focusedScreenID != nil`.

---

## Notes / edge cases

- **Toggle semantics:** v1 = F toggles focus on/off. Pressing F while focused exits even if you're
  now looking elsewhere. (Switch-focus-to-the-new-gaze is a possible later refinement.)
- **Head-locked = stays in view:** no recenter interaction needed; recenter only affects anchored
  screens, and the focused screen is floating.
- **Captures:** the focused screen is always a `showInAR` screen, so its capture is already live; no
  new capture is started. Mirror-of-virtual targets resolve through `captureForConfig`.
- **Other displays still exist** as OS monitors while focused (we only change rendering); confining
  the cursor to the focused display keeps interaction sane. Their windows are simply off-view.
- **HUD widgets:** keep showing by default (they're head-locked HUD, complementary to focus). If a
  cleaner view is wanted, gate `drawWidgets` on `!focused` later — not v1.
- **Teardown/unplug/sleep:** clear focus in `stopAR()` so a session never restarts focused; the
  confiner is already stopped there.
- **Eased transition (polish, optional):** instead of an instant snap, animate `widthMeters`/distance
  (and a brief yaw/pitch lerp from the screen's placed direction to centre) over ~0.25 s by pushing a
  few interpolated `setScreens` frames. Adds the Roadmap's "ease to it" feel; not required for a
  working v1.

---

## Verification

- **With glasses:** look at a screen → ⌃⌥F → it snaps to fill your view and stays centred as you turn
  your head; the cursor jumps onto it and can't be dragged off (sticks at the edges). ⌃⌥F again →
  the full layout returns and the cursor is freed (restored to its prior spot).
- **Without glasses:** enable fake pose, point it at a screen, repeat on an external monitor stand-in.
- **Stereo (SBS) on:** the focused screen fills both eyes with no clipping.
- **No gaze target:** ⌃⌥F while looking between screens → status message, no change.
- **Confinement stress:** drag the mouse hard to all four edges → it stays within the focused display.

---

## Effort

Medium. New scene-assembly branch + a small FOV-fit helper + a second cursor-confinement mode + one
hotkey + help entry. ~half to one day, low risk (doesn't touch the capture/SBS/quality paths).
