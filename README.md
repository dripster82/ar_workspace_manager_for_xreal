# AR Workspace Manager for XREAL

macOS app that renders head-tracked virtual desktops into XREAL Air 2 glasses.
Feature list: see [Docs/Features.md](Docs/Features.md). Plan and milestones: see [PLAN.md](PLAN.md).

## Build & run

```sh
Scripts/build-app.sh          # builds + signs "build/AR Workspace Manager.app"
open "build/AR Workspace Manager.app"
```

Requires macOS 14+, Apple Silicon. First AR start will prompt for **Screen Recording**
permission (System Settings → Privacy & Security); recording the glasses view also prompts
for **Microphone**. With only Command Line Tools and ad-hoc signing, macOS may re-prompt
after rebuilds; an Apple Development certificate makes the grant stick.

## Distribution

`Scripts/release.sh` produces a Developer-ID-signed, notarized, stapled build (needs a
Developer ID Application cert + a stored `notarytool` profile — see `Scripts/notarize.sh`).

## Staged testing

1. **IMU**: launch the app, plug in the glasses → status shows *Connected*, live
   yaw/pitch/roll at ~500–1000 Hz. Unplug → *not connected*, no crash.
2. **Render output**: pick any external monitor (a stand-in works) under *AR Output*,
   Start AR → screens render fullscreen there (placeholder grid until capture permission
   is granted). ⌃⌥Esc stops AR; ⌃⌥Space recenters (both global).
3. **Head tracking without glasses**: enable *Fake head pose* and drag the yaw/pitch
   sliders — the scene should pan on the output display.
4. **Virtual desktops**: add screens to the workspace; each becomes a real macOS display
   (System Settings → Displays) you can drag windows onto, and appears in AR.

## Layout

- `Sources/CXrealDriver` — vendored C: xrealair-sdk-macos (MIT), xioTechnologies Fusion
  (MIT, pinned to the SDK's submodule commit 490ebf1), hidapi mac backend (BSD).
  json-c is statically linked from Homebrew at build time (`vendor/lib/libjson-c.a`).
- `Sources/GlassesDriver` — IMU read-loop thread, `PoseStore` (latest pose + prediction,
  yaw recenter).
- `Sources/CapturePipeline` — ScreenCaptureKit display capture → Metal textures.
- `Sources/Compositor` — CAMetalLayer fullscreen output + CAMetalDisplayLink renderer,
  flat/curved screen meshes.
- `Sources/CPrivateDisplay` / `Sources/DisplayManager` — CGVirtualDisplay private API,
  workspaces, persistence (`~/Library/Application Support/AR Workspace Manager/workspaces.json`).
- `Sources/VRDesktop` — SwiftUI control panel + app lifecycle.
- `Sources/PrivilegedHelperShared` / `Sources/VRDesktopHelper` / `Sources/CXPCAuditToken` —
  signed SMAppService privileged helper that prunes orphaned ColorSync display profiles.

`vendor/` clones are gitignored; refresh them with the URLs in PLAN.md if needed.
