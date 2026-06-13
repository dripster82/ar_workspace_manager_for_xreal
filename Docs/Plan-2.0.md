# Plan 2.0 — Floating Screens & Help Overlay

Detailed implementation plans for the next two features, building on the current code.
Companion to [Roadmap.md](Roadmap.md) (Phase 1 = floating screens, Phase 3 = help overlay)
and [Ideas.md](Ideas.md). Conventions, hardware constraints, and current state are in those docs.

---

## Feature A — Floating (head-locked) screens

### Goal
Each screen is either **anchored** (fixed in world-orientation space — today's behaviour;
stays put as you look around) or **floating** (fixed in the viewer's field of view — travels
with the head, e.g. Slack pinned 15° right / 10° down / 1 m away).

### Concept
A floating screen is rendered **without the head-rotation transform**. Its yaw/pitch/distance
become a *view-space* offset rather than a *world* placement, so it stays glued to where you're
looking. Anchored screens keep the head rotation (so they stay fixed in space). Everything else
(curve, scale, capture, mirroring) is identical.

### Changes

**1. Model — `VirtualScreenConfig` ([DisplayManager/VirtualDisplayService.swift](../Sources/DisplayManager/VirtualDisplayService.swift))**
- Add `enum ScreenPlacement: String, Codable { case anchored, floating }`.
- Add `var placement: ScreenPlacement = .anchored`.
- Decode with `decodeIfPresent(... ) ?? .anchored` (keep the backward-compatible pattern);
  add to `CodingKeys` + `encode`.
- `resetPlacement()` leaves `placement` unchanged (it's a mode, not a transform value).

**2. Scene — `SceneScreen` ([Compositor/Scene.swift](../Sources/Compositor/Scene.swift))**
- Add `var headLocked: Bool`. Geometry (the yaw/pitch/curve quad build) is unchanged —
  placement only affects which view matrix is used at draw time.

**3. Renderer — `GlassesRenderer` ([Compositor/GlassesRenderer.swift](../Sources/Compositor/GlassesRenderer.swift))**
- In `encodeScene`, build **two** view-projections per eye:
  - `anchoredVP = projection · T(eyeOffset) · R(head)⁻¹`
  - `floatingVP = projection · T(eyeOffset)`  *(no head rotation)*
- Split the screen list and draw in two passes within the same encoder:
  `drawScreens(anchored, anchoredVP)` then `drawScreens(floating, floatingVP)`.
  (Depth buffer already handles ordering; floating screens naturally sit "on top" if placed
  closer.) Keep the existing viewport logic for stereo/SSAA.

**4. Coordinator — `sceneScreen(config:capture:)` ([VRDesktop/AppCoordinator.swift](../Sources/VRDesktop/AppCoordinator.swift))**
- Pass `headLocked: config.placement == .floating`.
- `updateLookedAtScreen()`: compute floating screens' direction in **view space** (don't apply
  head orientation), so "Looking at" still works; or simplest v1 — skip floating screens in
  look-at and note it.

**5. UI — `ScreenRow` ([VRDesktop/ControlPanelView.swift](../Sources/VRDesktop/ControlPanelView.swift))**
- Add a segmented `Picker` "Placement: Anchored | Floating" bound to `cfg.placement`.
- When floating, relabel the sliders' helptext as "offset from view" (Yaw/Pitch/Distance still
  apply); no new sliders needed.

### Notes / edge cases
- Recenter (⌃⌥Space) only affects anchored screens (floating ones are already view-relative) —
  that's correct and desirable.
- Mixing: a workspace can have both kinds; e.g. anchored monitors + a floating Slack.
- No persistence migration needed beyond the new field's default.

### Verification
- Mark a screen Floating → it stays fixed in the glasses view as you turn your head; anchored
  screens slide past. Set yaw +15°/pitch −10° → it sits to the lower-right consistently.
- Toggle back to Anchored live → it re-anchors in world space.
- Confirm stereo (SBS) and SSAA still render floating screens correctly (two view matrices per eye).

### Effort
Small. One field, one renderer branch, one picker. ~half a day.

---

## Feature B — Help overlay (⌃⌥H)

### Goal
Press **⌃⌥H** anywhere to toggle a popup listing all hotkeys and commands; press again (or Esc)
to dismiss.

### Decision
v1 = a macOS **HUD panel** (`NSPanel`, `.hudWindow`), centered on the screen under the cursor
(never the AR output). Simple, reliable, readable, and works whether or not AR is running.
(A later option: render the same content as an in-AR floating screen — natural once Feature A
lands — tracked as a follow-up, not v1.)

### Changes

**1. Global hotkey — `AppDelegate` ([VRDesktop/main.swift](../Sources/VRDesktop/main.swift))**
- Add a third hotkey id (`helpHotKeyID = 3`) alongside the existing recenter/stop registrations
  in `registerGlobalRecenterHotKey()`; register `kVK_ANSI_H` + control+option.
- In the hotkey handler switch, add `case helpHotKeyID: helpOverlay.toggle()`.

**2. `HelpOverlayController` (new — `Sources/VRDesktop/HelpOverlayController.swift`)**
- Owns a lazily-created `NSPanel`: `styleMask = [.hudWindow, .titled, .closable, .nonactivatingPanel]`,
  `level = .floating`, `isFloatingPanel = true`, `hidesOnDeactivate = false`.
- `contentView = NSHostingView(rootView: HelpView())`.
- `toggle()` — if visible, `orderOut`; else place + `orderFront` (don't steal focus — nonactivating).
- Placement: center on the screen under the cursor, excluding the AR output display. **Factor**
  the existing cursor/AR-exclusion logic out of `AppDelegate.placeWindowUnderCursor()` into a
  shared helper (e.g. `ScreenPlacement.windowOriginUnderCursor(size:excluding:)`) and reuse it
  here so both the main window and the help panel share one implementation.
- Dismiss on Esc: a local key monitor while visible, or a Cancel button in the view.

**3. `HelpView` (SwiftUI, in the same file)**
- Data-driven list of `(keys, description)` grouped by section:
  - **Global**: ⌃⌥Space Recenter · ⌃⌥Esc Stop AR · ⌃⌥H Help · ⌃⌥ + Brightness keys (dim glasses)
  - **In window**: Start/Stop AR, workspace switch, add/remove screens (reference the controls)
  - Pull the hotkey list from a single source of truth so it can't drift from the real bindings
    (define a `HotKeys` table the registrations and the help view both read).
- Styled as a compact two-column grid (keycap chips on the left, description on the right),
  matching the control panel's card aesthetic.

**4. Menu bar — `AppDelegate.menuNeedsUpdate`**
- Add a "Keyboard Shortcuts" item that calls `helpOverlay.toggle()` (discoverability for the
  hotkey itself).

### Notes / edge cases
- Use `.nonactivatingPanel` so invoking help while working in another app doesn't yank focus.
- The panel is a normal macOS window → it must not land on the glasses display while AR runs
  (reuse the AR-output exclusion).
- Single source of truth for the shortcut list avoids the help drifting out of sync when
  bindings change.

### Verification
- ⌃⌥H from within any app toggles the panel; it appears centered on the cursor's screen, never
  on the glasses; ⌃⌥H again or Esc hides it.
- With AR running, the panel shows on a physical monitor, not in the AR output.
- Every listed shortcut matches the actual behaviour (recenter, stop, brightness).

### Effort
Small–medium. New controller + view + one hotkey + a shared placement helper. ~half a day.

---

## Suggested order
1. **Feature A (floating screens)** — higher value, unblocks the in-AR help variant later.
2. **Feature B (help overlay)** — quick, improves discoverability of the growing hotkey set.

Both are self-contained and low-risk; neither touches the capture/SBS/quality paths.
