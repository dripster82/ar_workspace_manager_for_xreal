# VR Desktop — Head-Tracked AR Desktops for XREAL Air 2 on macOS

## Context

Greenfield personal-use macOS app in `/Users/paulketelle/Code/VR Desktop` (currently empty). Goal: render head-tracked virtual desktops into XREAL Air 2 glasses (a 1920×1080 USB-C DP display), with a UI to choose which desktops appear in AR vs on physical monitors. User decisions: head-tracked 3DoF AR screens (Nebula/breezy-desktop style), content via ScreenCaptureKit compositing in Metal, personal use only (private APIs fine).

Confirmed requirements:
- **Named workspaces**: saved layouts (e.g. "Coding", "Writing"); switching tears down/creates virtual displays and re-lays-out the AR scene.
- **Screens of arbitrary resolution**, including ultrawide (e.g. 5120×1080) virtual screens you pan across by turning your head; curvature strongly recommended for ultrawides.
- **Per-screen routing**: every display (physical or virtual) has an independent "show in glasses" toggle; additionally a physical monitor can mirror a virtual screen (`CGConfigureDisplayMirrorOfDisplay`), so content can be AR-only, physical-only, or both.
- **Per-screen settings**: yaw/pitch position, distance, scale, curvature radius (flat ↔ cylindrical), persisted per workspace.

Research established:
- **IMU/HID**: XREAL VID `0x3318` (Air 2 Pro PID `0x0432`; enumerate by VID). Best reusable code: [adidoes/xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos) (MIT C port, Air 2 Pro tested, deps hidapi + [xioTechnologies/Fusion](https://github.com/xioTechnologies/Fusion) Madgwick AHRS, ~1kHz IMU). Protocol reference: [badicsalex/ar-drivers-rs](https://github.com/badicsalex/ar-drivers-rs) + voidcomputing.hu blog posts.
- **Rendering**: SCStream (BGRA, queueDepth 3, 1/60 frame interval) → IOSurface-backed CVPixelBuffer → zero-copy MTLTexture; fullscreen CAMetalLayer on the glasses' NSScreen with CAMetalDisplayLink (macOS 14+), maximumDrawableCount 2; billboard quads with latest-pose-at-render + ~16–20ms prediction. Birdbath optics → no lens distortion correction. Target <20ms motion-to-photon.
- **Virtual displays**: CGVirtualDisplay private API (60Hz cap, fine) — Swift usage pattern in [Stengo/DeskPad](https://github.com/Stengo/DeskPad).

## Architecture

Xcode app shell + local SPM packages (stable signing → TCC Screen Recording grant sticks):

```
VRDesktop.xcodeproj            # app shell, signing (bundle id uk.co.ketelle.ar.workspace.manager), Info.plist (NSScreenCaptureUsageDescription)
VRDesktop/                     # SwiftUI app target: AppCoordinator, control-panel UI, .metal shaders
Packages/
  GlassesDriver/
    Sources/CXrealDriver/      # vendored C: xrealair-sdk-macos files + Fusion + hidapi mac/hid.c (copy in with NOTICE, not brew)
    Sources/GlassesDriver/     # IMUService (1kHz read thread), PoseStore (seqlock latest pose + predict(at:)), recenter (yaw-only), hotplug
  CapturePipeline/             # SCStream per display → CVMetalTextureCache → atomic latest MTLTexture; ShareableContentService
  Compositor/                  # GlassesOutputWindow (borderless fullscreen CAMetalLayer on glasses NSScreen), CAMetalDisplayLink render loop, Scene of VirtualScreens (yaw/pitch/distance/size)
  DisplayManager/              # VirtualDisplayService (CGVirtualDisplay wrapper, arbitrary modes incl. ultrawide), MirrorService (CGConfigureDisplayMirrorOfDisplay), RoutingModel (per-display showInAR flag; glasses display NEVER captured), WorkspaceStore (named layouts, Codable JSON)
```

**Threading**: IMU C read loop thread → PoseStore (atomic/seqlock) ← render thread (display-link callback). SCK frames on SCK queue → atomic texture swap ← render thread. UI on main actor. No queues/actors in the hot path.

**Locked decisions**: mono 1920×1080 (no SBS initially — architecture allows adding stereo later); display-level capture is the routing unit ("virtual desktop" = a display, possibly virtual); single C target with umbrella header, Swift never touches HID directly.

## Milestones (each independently verifiable)

- **M0 Skeleton** (½ day): project + packages compile, signed, empty window, `git init`.
- **M1 Glasses + IMU** (1–2 days): vendor C driver/Fusion/hid.c; IMUService + PoseStore; hotplug. *Verify*: plug in glasses → "Connected" + live yaw/pitch/roll tracking head movement at ~500–1000Hz; clean unplug; log all PIDs under VID 0x3318 (Air 2 non-Pro PID unknown); observe yaw drift over 5 min.
- **M2 Metal output** (1 day): fullscreen render (spinning gradient) on glasses display via CAMetalDisplayLink; Esc exits. *Verify*: works on any external monitor as stand-in; FPS matches refresh; clean teardown on unplug.
- **M3 One head-tracked billboard** (2–3 days): capture main display, world-anchored quad, predicted pose per frame, recenter button; exclude glasses display from capture. *Verify*: screen stays anchored as head turns, no bad swim on head shake; fake-pose slider in UI for glasses-free testing.
- **M4 Multi-screen + virtual displays + routing UI** (3–4 days): VirtualDisplayService (incl. custom ultrawide modes like 5120×1080), multiple SCStreams, RoutingModel with per-display showInAR toggle, arrangement UI (yaw/pitch, distance, scale), layout persistence. *Verify*: added virtual display appears in System Settings > Displays; drag a window onto it → appears on its AR screen; ultrawide screen pans naturally as head turns; toggling showInAR adds/removes a screen live; 2–3 billboards spaced around you; layout restored on relaunch.
- **M5 Workspaces + curvature + mirroring** (3–4 days): WorkspaceStore (named layouts, switcher UI), curved-screen cylinder mesh with per-screen curvature radius ("curve around me" default), MirrorService so a physical monitor can mirror a virtual screen. *Verify*: switch between two saved workspaces and screens/layout swap correctly; ultrawide curves around you; mirror a virtual screen to a physical monitor while toggling its AR visibility through all three states (AR-only / physical-only / both).
- **M6 Polish** (ongoing): tuned prediction, recenter hotkey (⌃⌥Space), brightness control via MCU HID commands, sleep/wake + launch-at-login. *Verify*: comfortable 30-min work session.

## Risks to probe early

- Air 2 non-Pro PID may differ — log enumeration in M1.
- Sequoia+ may require Input Monitoring TCC for raw HID reads — fall back to IOHIDDevice matching if blocked.
- CGVirtualDisplay symbols on current macOS — smoke-test in isolation at start of M4 (DeskPad repo tracks breakage).
- macOS 15+ monthly screen-recording re-prompts — accepted; consistent signing minimizes friction.

## Verification (end-to-end)

Build and launch the .app (always the same signed bundle so TCC grants persist). With glasses: M1 IMU readout → M3 anchored screen latency feel → M4 multi-desktop routing. Without glasses: any external monitor + fake-pose slider exercises M2–M4 rendering and routing paths.
