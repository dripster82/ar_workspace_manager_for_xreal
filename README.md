# AR Workspace Manager for XREAL

Turn your XREAL glasses into a head-tracked, multi-monitor spatial workspace on macOS. Create as
many virtual displays as you like, arrange them in the space around you, and drag your Mac windows
onto them — all rendered into the glasses with low-latency head tracking.

> **Requirements:** XREAL Air 2 / Air 2 Pro glasses connected over USB-C DisplayPort, and an
> **Apple Silicon** Mac running **macOS 14 (Sonoma) or later**.

![AR Workspace Manager for XREAL](assets/hero.png)

<sub>⚠️ The images and GIF in this README are placeholders — replace the files in `assets/` with real screenshots/recordings.</sub>

---

## Install

1. Download the latest **AR Workspace Manager for XREAL** release (`.dmg` or `.zip`) from the
   [Releases](https://github.com/dripster82/ar_workspace_manager_for_xreal/releases) page.
2. Drag **AR Workspace Manager** into your **Applications** folder.
3. Launch it. Builds are signed with a Developer ID and notarized by Apple, so it opens normally —
   no right-click-to-open workaround needed.
4. Plug your XREAL glasses into a USB-C port that carries DisplayPort video.

## Permissions

The app asks for these the first time each is needed (you can manage them under
**Settings → Permissions**, which links straight to System Settings):

| Permission | Needed for | Required? |
|---|---|---|
| **Screen Recording** | Capturing your Mac's screens to show them in the glasses | **Yes** — AR can't render without it |
| **Accessibility** | Moving/arranging windows (⌃⌥W, window layout save & restore) | Optional |
| **Microphone** | Recording the glasses view *with audio* | Optional |

> If you remove a virtual display on a **standard (non-admin)** account, macOS may ask once for
> permission so the app can tidy up that display's leftover colour profile. This is handled by a
> small notarized helper; approve it in **System Settings → General → Login Items & Extensions** if
> prompted. Admin accounts never see this.

## Quick start

1. **Connect** the glasses — the **Dashboard** shows *Connected* with live head tracking.
2. Click **Start AR** (top bar, or ⌃⌥S). Your screens appear floating in front of you.
3. Open the **Workspace** page and click **Add Display** to create virtual monitors at the
   resolution you choose (it defaults to your main display's resolution). Each one is a *real* macOS
   display — it shows up in System Settings → Displays and you can drag any window onto it.
4. **Position** screens by dragging them in the **Layout map**. Click a screen to fine-tune its
   distance, size, curvature, and whether it's **anchored** (fixed in the room) or **floating**
   (follows your head). Right-click a screen to delete it.
5. **Recenter** any time with **⌃⌥Space** so the layout sits straight ahead of you.
6. **Stop AR** with **⌃⌥Esc** (or the top bar).

![Quick start](assets/demo.gif)

Your layout is saved automatically. Create multiple **workspaces** for different setups and switch
between them from the top bar.

![Workspace layout editor](assets/workspace-editor.png)

## What it does

**Displays & layout**
- Unlimited virtual displays at almost any resolution, including ultrawide up to 5120-wide, with HiDPI
- Anchored (world-fixed) or floating (head-locked) placement; flat or curved screens; a wide-canvas
  mode that wraps all screens into one continuous curved surface
- Named, saved workspaces; per-screen backgrounds (colour / image / see-through)
- Mirror a virtual screen to a physical monitor (or vice-versa); real monitors auto-appear for
  positioning

**Head tracking & view**
- 3DoF head tracking with motion prediction and adaptive smoothing for low perceived latency
- **Focus mode** (⌃⌥F) to blow the screen you're looking at up to fill your view
- **Passthrough** (⌃⌥V) to hide the screens and see the room (HUD stays)
- Gaze tracking, **find-my-cursor** (⌃⌥C), **move-cursor-to-gaze** (⌃⌥X), and
  **move-window-to-the-screen-you're-looking-at** (⌃⌥W)

**HUD widgets** (head-locked, optional)
- Clock, battery, **Slack** unreads, **GitHub** PR-triage counts, **Google Calendar** agenda with
  **meeting alarms**
- Reusable HUD profiles; group widgets into stacks; per-widget styling

![HUD widgets](assets/hud-widgets.png)

**Glasses & capture**
- Brightness and refresh-rate (60/72/90/120 Hz) control; quality settings (anti-aliasing,
  sharpening, supersampling)
- Stereo side-by-side (experimental) with IPD adjustment
- **Screenshot** (⌃⌥P) and **record** (⌃⌥R) the glasses view, with mic mute (⌃⌥M)

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌃⌥Space | Recenter the view |
| ⌃⌥S | Start / stop AR |
| ⌃⌥Esc | Stop AR |
| ⌃⌥F | Focus the screen you're looking at (toggle) |
| ⌃⌥V | Passthrough — hide / show the screens (HUD stays) |
| ⌃⌥I | Show / hide the HUD widgets |
| ⌃⌥L | Show / hide screen-name labels |
| ⌃⌥W | Move a window to the screen you're looking at |
| ⌃⌥C | Find the cursor (screen + arrow) |
| ⌃⌥X | Move the cursor to where you're looking |
| ⌃⌥D | Stereo (SBS) on / off |
| ⌃⌥P | Screenshot the glasses view → Desktop |
| ⌃⌥R | Record the glasses view → Movies |
| ⌃⌥M | Mute / unmute the recording mic |
| ⌃⌥H | Show / hide help |
| ⌃⌥Q | Quit AR Workspace Manager |
| ⌃⌥ + brightness keys | Dim / brighten the glasses |
| Esc | Dismiss an active meeting alarm |

## Notes & troubleshooting

- **No picture in the glasses?** Make sure they're plugged into a USB-C port that supports
  DisplayPort video, and that macOS sees them as a display (System Settings → Displays). Pick your
  output under **Settings → Glasses → AR Output** if needed.
- **Head tracking not moving?** Check the Dashboard shows *Connected*. Use **⌃⌥Space** to recenter.
- **Microphone prompt never appeared?** Recording only requests the mic the first time you record;
  if it was previously denied, re-enable it in System Settings → Privacy & Security → Microphone.
- **High CPU from `colorsync.displayservices`?** This is a macOS-side issue triggered by the glasses
  as a display, not the app. See
  [Docs/ColorSync-AirII-investigation.md](Docs/ColorSync-AirII-investigation.md) for the cause and
  fixes (keep the glasses on their default colour profile).
- Virtual displays rely on macOS's private display APIs, so exact behaviour can vary between macOS
  releases.

---

## Build from source

For developers. Requires the Xcode command-line tools (or Xcode) and Homebrew `json-c`.

```sh
Scripts/build-app.sh                 # builds + signs "build/AR Workspace Manager.app"
open "build/AR Workspace Manager.app"
```

With only ad-hoc signing, macOS may re-prompt for permissions after each rebuild; an Apple
Development certificate makes grants stick (`Scripts/make-signing-cert.sh` sets up a stable
self-signed identity for local use).

**Release builds:** `Scripts/release.sh` produces a Developer-ID-signed, notarized, stapled build
(needs a *Developer ID Application* certificate and a stored `notarytool` keychain profile — see the
header of `Scripts/notarize.sh`).

### Project layout

- `Sources/GlassesDriver` — XREAL IMU read loop and pose store (recenter, prediction)
- `Sources/CapturePipeline` — ScreenCaptureKit display capture → Metal textures
- `Sources/Compositor` — Metal renderer (flat/curved meshes) driving the glasses display
- `Sources/CPrivateDisplay` / `Sources/DisplayManager` — virtual displays + workspace persistence
- `Sources/VRDesktop` — SwiftUI control panel and app lifecycle
- `Sources/PrivilegedHelperShared` / `Sources/VRDesktopHelper` / `Sources/CXPCAuditToken` —
  the notarized SMAppService helper that prunes orphaned ColorSync display profiles
- `Sources/CXrealDriver` — vendored C: xrealair-sdk-macos (MIT), xioTechnologies Fusion (MIT),
  hidapi mac backend (BSD); `json-c` is statically linked from Homebrew (`vendor/lib/libjson-c.a`)

`vendor/` clones are gitignored; refresh them with the URLs in [PLAN.md](Docs/PLAN.md) if needed.

## License

Source-available under the **[PolyForm Noncommercial License 1.0.0](LICENSE.md)**: free to use,
modify, and share for any **noncommercial** purpose — personal use, hobby projects, study,
non-profits, etc. **Commercial use and selling are not permitted** (don't repackage or sell it).
This is a source-available license, not an OSI "open source" license, because it restricts
commercial use. For commercial licensing, contact the author.

Bundled third-party components keep their own licenses: MIT code from nrealAirLinuxDriver /
xrealair-sdk-macos and xioTechnologies Fusion, and the BSD-licensed hidapi macOS backend
(`Sources/CXrealDriver/LICENSE-*`).

## Credits

Not affiliated with or endorsed by XREAL.
