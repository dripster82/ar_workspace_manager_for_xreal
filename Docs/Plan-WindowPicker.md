# Plan — Move window to screen (⌃⌥W window picker)

Implementation plan for Roadmap **Phase 5 — Manual window control** (the "send window to screen"
half). Companion to [Roadmap.md](Roadmap.md); reuses the AX move pattern already in
[WindowLayoutStore.swift](../Sources/VRDesktop/WindowLayoutStore.swift).

## Goal & flow

1. Press **⌃⌥W** → a popup appears front-and-centre in the FOV showing **every open window** as a
   thumbnail with its name underneath (truncated to the thumbnail width).
2. Grid is **5 across × 3 down** (15 per page); pages if there are more windows.
3. **Arrow keys** move a highlight around the grid.
4. **Enter** moves the highlighted window to **the screen you're looking at**, then closes the popup.
5. **Esc** or **⌃⌥W** cancels and closes — no change.

Like the other overlays, it renders as an in-AR texture when AR is running and as a macOS panel
fallback when it isn't.

## Visual

```
┌──────────────── Move a window to the screen you're looking at ─────────────────┐
│                                                                                │
│   ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐                   │
│   │ thumb  │  │ thumb  │  │ thumb  │  │ thumb  │  │ thumb  │                   │
│   └────────┘  └────────┘  └────────┘  └────────┘  └────────┘                   │
│    Safari       Code        Slack       Notes      Finder                      │
│                                                                                │
│   ┌────────┐  ┌────────┐  ┏━━━━━━━━┓  ┌────────┐  ┌────────┐   ← highlight     │
│   │ thumb  │  │ thumb  │  ┃ thumb  ┃  │ thumb  │  │ thumb  │     (accent ring) │
│   └────────┘  └────────┘  ┗━━━━━━━━┛  └────────┘  └────────┘                   │
│    Mail        Music       Terminal    Maps        Photos                      │
│                                                                                │
│   ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐                   │
│   │ thumb  │  │ thumb  │  │ thumb  │  │ thumb  │  │ thumb  │                   │
│   └────────┘  └────────┘  └────────┘  └────────┘  └────────┘                   │
│    Xcode       Figma       Zoom        TextEdit    Preview                     │
│                                                                                │
│   → Target: "Code Screen"            Page 1/2   ↵ move   ◀▲▶▼ select   esc ✕   │
└────────────────────────────────────────────────────────────────────────────────┘
```

- **Card**: dark rounded panel (matches help/cursor overlays), ~70% FOV height.
- **Cell**: thumbnail (16:10-ish, letterboxed) in a rounded rect; **highlighted** cell gets an accent
  ring + slight scale. Name below, one line, `.truncationMode(.tail)`, framed to the thumbnail width.
- **Footer**: live **target** = the screen you're currently looking at (updates as you turn your
  head), page indicator, and key hints.
- App icon badge in the cell corner (nice-to-have) to disambiguate same-named windows.

## Components (files)

- **`WindowPickerController`** (new) — like `HelpOverlayController`/`CursorInfoOverlayController`:
  owns visibility, the window list + thumbnails, the selected index, a refresh timer, keyboard
  handling, and drives the renderer overlay or the macOS panel.
- **`WindowPickerContent`** (new, SwiftUI) — the grid view, rendered to a `CGImage` via
  `ImageRenderer` for the AR texture and hosted directly in the panel fallback.
- **`WindowList`/`WindowMover`** (new, or extend `WindowLayoutStore`) — enumerate windows, capture
  thumbnails, and move a chosen window to a target display via AX.
- **Renderer** — a new centred overlay slot (`pickerTexture`/`showPicker`), drawn like the help
  overlay (`drawOverlay`, `heightFraction ≈ 0.8`). Independent of the help slot (never co-shown).
- **Hotkeys** — `⌃⌥W` toggle (new id 17); temporary nav hotkeys while open (below).
- **HelpContent / Features** — add the `⌃⌥W` entry.

## Window enumeration + thumbnails (ScreenCaptureKit)

We already use ScreenCaptureKit and hold Screen-Recording permission.

- **List**: `SCShareableContent.current.windows`, filtered to: `isOnScreen`, window layer 0 (normal
  windows), `frame.width/height > ~40`, has an `owningApplication`, and **exclude our own bundle**.
  Each `SCWindow` gives `windowID`, `title`, `owningApplication` (`applicationName`, `processID`,
  `bundleIdentifier`), and `frame`. Sort by app then title for stable order.
- **Thumbnails**: for each window, `SCScreenshotManager.captureImage(contentFilter:configuration:)`
  with `SCContentFilter(desktopIndependentWindow: window)` and a downscaled
  `SCStreamConfiguration` (e.g. width 320, preserve aspect) → one `CGImage`. Run concurrently with a
  task group. (Falls back to a generic app-icon tile if a capture fails.)
- **Async open**: on ⌃⌥W show the card immediately with placeholder tiles + a spinner, fetch the
  list, then fill thumbnails as they arrive (re-rasterise the card each time a batch completes).
  Captures are one-shot (no live streams), so cost is bounded and ends when the picker closes.

## Selection & navigation logic

State: `windows: [WinItem]` (count `N`), `selected: Int` (0…N-1), `cols = 5`, `rows = 3`,
`perPage = 15`.

- **Right** `selected = min(N-1, selected+1)` · **Left** `max(0, selected-1)`
- **Down** `selected = min(N-1, selected+cols)` · **Up** `max(0, selected-cols)`
  (clamped, not wrapping — predictable.)
- **Page** shown = `selected / perPage`; grid displays `windows[page*15 ..< min(N, page*15+15)]`.
- **Highlighted cell** = `selected % perPage` → row `/5`, col `%5`. Moving past a page edge advances
  the page automatically because `selected` crosses the boundary.
- **Enter** → move `windows[selected]`; **Esc/⌃⌥W** → close with no change.
- Empty list (`N == 0`) → show "No movable windows".

## Move logic (Accessibility)

Reuse the pattern in `WindowLayoutStore.restore`:

- **Target** = the screen you're looking at *at the moment Enter is pressed* — `lookedAtConfig()` →
  `displayID(forScreenID:)` → `CGDisplayBounds(displayID)`. If nothing is looked-at: status
  "Look at a screen, then press Enter" and keep the popup open.
- **Find the AX window**: `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute` → pick the AX
  window matching the chosen `SCWindow` by **title**, disambiguated by closest **frame** (SCWindow
  has the frame; AX windows expose position/size) so same-titled windows resolve correctly.
- **Move**: set `kAXPositionAttribute` to the target display origin; when "fill" is on (default),
  also set `kAXSizeAttribute` to the display bounds (maximise on that screen). Set position twice
  (before+after size) since some apps clamp position to the old screen until resized.
- **Fill toggle** (decided): default **fill**, with a **General-card setting** ("Fill screen when
  moving a window") persisted in `UserDefaults`; when off, reposition only (top-left at the screen
  origin, size unchanged).
- **Caveats**: needs Accessibility permission (already used); some apps refuse AX moves/resine —
  handle gracefully (status "Couldn't move <app>") and don't crash.

## Rendering (AR overlay + panel fallback)

- **AR on**: rasterise `WindowPickerContent` → `CGImage` → `renderer.setPickerImage(cg)`; renderer
  draws it centred (new `showPicker`/`pickerTexture` slot, `drawOverlay` at `heightFraction ~0.8`).
  Re-rasterise on every selection change, page change, thumbnail batch, and target change.
- **AR off**: host `WindowPickerContent` in an `NSPanel` centred on the screen under the cursor
  (reuse `WindowPlacement.originUnderCursor`, never the glasses display), like the help/cursor panels.

## Keyboard handling — focus-stealing key panel (decided)

`WindowPickerController` owns an `NSPanel` that becomes **key** while the picker is open and handles
arrows/Return/Esc directly (a local `NSEvent` keyDown monitor scoped to the key window consumes
them and returns nil). This is uniform across AR and non-AR and needs no Carbon hotkeys for nav.

- **AR on**: the visuals are the in-AR texture; the panel is transparent/zero-size (placed off the
  glasses display) and exists only to be the key window for input.
- **AR off**: the panel *is* the visible UI hosting `WindowPickerContent`, centred on the cursor's
  screen.
- **Focus restore**: capture `NSWorkspace.shared.frontmostApplication` on open; on close,
  re-`activate` it so the user's app regains focus. (AX moves don't need the target app focused, so
  the move still works after closing.)
- Only `⌃⌥W` stays a global Carbon hotkey (toggle, new id 17).

## Edge cases

- More than 15 windows → pages, page indicator, arrows page automatically.
- Windows on Spaces other than the current one may not be AX-movable / capturable — filter to
  on-screen; note silently skipped ones.
- Minimised/hidden windows → excluded (not `isOnScreen`).
- The picker closing must unregister the temporary nav hotkeys (and on `stopAR`, and on app quit).
- Don't capture/move our own windows (exclude own bundle id).
- Re-open should refresh the list (windows change).

## Verification

- ⌃⌥W → grid of current windows with names; arrows move the highlight (incl. across pages); footer
  shows the live looked-at target.
- Look at a screen, press Enter → that window jumps to that screen (filling it); popup closes.
- Esc and ⌃⌥W both cancel with no change.
- With AR off, the panel appears on the cursor's screen and behaves the same.
- An app that resists AX move reports a status message rather than failing silently.

## Effort

Medium. New controller + SwiftUI grid + thumbnail capture + AX move (pattern exists) + a renderer
overlay slot + temporary nav hotkeys. ~1 day. Needs Accessibility + Screen-Recording (both already
in use). Low risk to the capture/render hot paths (one-shot screenshots, a separate overlay slot).

## Decisions (locked)

1. **Move = fill the target screen by default**, with a General-card toggle to switch to
   reposition-only (persisted in `UserDefaults`).
2. **Keyboard = focus-stealing key panel** (`NSPanel` becomes key, handles keys directly, restores
   the previously-frontmost app on close).
3. Same-name windows disambiguated by title + nearest-frame match; an app-icon badge per cell is a
   nice-to-have, not required for v1.
