# Spatial Workspace for XREAL Glasses on macOS

## Product Design & Technical Specification

### Version

0.1 Draft

### Author

Paul Ketelle

---

# 1. Overview

Spatial Workspace is a macOS application designed for XREAL Air and compatible AR glasses that transforms virtual displays into a customizable spatial working environment.

Unlike existing solutions that provide a fixed number of virtual monitors, Spatial Workspace allows users to create, arrange, save, and manage virtually unlimited screens within a persistent spatial environment.

The application aims to function as a complete spatial display manager rather than simply a virtual monitor utility.

---

# 2. Design Goals

## Primary Goals

* Unlimited virtual displays
* Fully customizable layouts
* Workspace persistence
* Native macOS integration
* Low latency rendering
* Minimal resource usage
* Comfortable long-term use

## Secondary Goals

* Voice commands
* Automated window placement
* Intelligent workspace management
* Collaborative environments
* Cross-glasses compatibility

---

# 3. Core Architecture

## Virtual Displays

Each virtual screen is backed by a native macOS virtual display.

The operating system sees every virtual screen as a real monitor.

Benefits:

* Native window management
* Native mouse support
* Native application support
* No application modifications required

### Display Properties

Each display contains:

```json
{
  "name": "Documentation",
  "resolution": "2560x1440",
  "scale": 1.0,
  "curve": 15,
  "distance": 2.0,
  "anchored": true,
  "background": "dark-gradient",
  "position": {},
  "rotation": {}
}
```

---

# 4. Screen Types

## Anchored Screens

Anchored screens remain fixed within physical space.

Examples:

* Coding monitors
* Documentation monitors
* Dashboards

Behavior:

* Remain in position while user moves
* Reappear in saved location
* Support persistence

---

## Floating Screens

Floating screens move relative to the user.

Examples:

* Slack
* Teams
* Discord
* Notifications
* Timers

Behavior:

* Maintain fixed location within field of view
* User configurable offset
* User configurable distance

Example:

Slack positioned:

* 15 degrees right
* 10 degrees down
* 1 meter distance

Always remains there regardless of head movement.

---

# 5. Display Customization

Each screen supports independent configuration.

## Resolution

Examples:

* 800x600
* 1920x1080
* 2560x1440
* 3440x1440
* 5120x1440

---

## Scale

Visual size only.

Screen may remain:

2560x1440

while appearing larger or smaller in AR space.

---

## Curvature

Available values:

0-100%

Examples:

* Flat
* Slight curve
* Ultrawide curve
* Deep wrap-around curve

---

## Distance

User adjustable.

Examples:

* 1 meter
* 2 meters
* 5 meters

---

## Opacity

Future feature.

Allows partially transparent screens.

---

# 6. Workspace Profiles

Workspace Profiles are the primary organizational feature.

A profile stores:

* Displays
* Positions
* Rotations
* Curvature
* Scale
* Resolution
* Backgrounds
* Float states
* App mappings

---

## Example Workspaces

### Coding

Center:
VS Code

Left:
Documentation

Right:
Browser

Bottom:
Terminal

Floating:
Slack

---

### Writing

Center:
Word Processor

Left:
Research

Right:
Notes

Floating:
Tasks

---

### Gaming

Center:
Game

Right:
Discord

Left:
Performance Monitor

Floating:
Voice Chat

---

# 7. Workspace Management

## Workspace Switcher

Shortcut:

Ctrl + Option + W

Displays:

```text
Coding
Writing
Gaming
Architecture
Research
```

Supports:

* Search
* Favorites
* Recent workspaces
* Preview images

---

## Favorites

Maximum:

3

Shortcuts:

Ctrl + Option + 1
Ctrl + Option + 2
Ctrl + Option + 3

Loads favorite workspaces instantly.

---

# 8. Window Management

## App Placement Rules

Users may define:

```text
Slack -> Floating Screen
VS Code -> Coding Monitor
Terminal -> Terminal Monitor
```

---

## Window Type Rules

Examples:

Slack Main Window

→ Social Screen

Slack Huddle

→ Floating Center Screen

Incoming Call

→ Floating Center Screen

Zoom Meeting

→ Floating Center Screen

---

## Window Categories

Users may define:

* Work
* Social
* Call
* Monitoring
* Media
* Development

Rules may be assigned per category.

---

# 9. Window Manager Panel

Displays:

All detected windows.

Information:

* Application
* Window title
* Category
* Current screen

Actions:

* Move
* Float
* Anchor
* Tag
* Rename

---

# 10. Focus System

Users may focus on screens.

Shortcut example:

Ctrl + Option + F

Behavior:

* Smooth camera movement
* Brings screen to primary viewing area
* Does not move screen

---

# 11. Navigation Controls

## Recenter

Current implementation.

Shortcut:

Ctrl + Option + R

Centers workspace.

---

## Stop AR

Current implementation.

Shortcut:

Ctrl + Option + S

Disables spatial mode.

---

## Help Overlay

Shortcut:

Ctrl + Option + H

Displays:

* Hotkeys
* Commands
* Workspace controls

Centered in front of user.

---

# 12. Screen Labels

Each screen may display:

```text
VS Code
Slack
Documentation
Terminal
```

Position:

* Top left
* Top right
* Bottom left
* Bottom right

Options:

* Always visible
* Visible on focus
* Hidden

---

# 13. Quick Window Relocation

Future shortcut:

Ctrl + Option + M

Moves selected window to:

* Current screen
* Screen under cursor
* Selected workspace screen

---

# 14. Voice Commands

## Activation

Push-to-talk.

No always-listening mode.

---

## Example Commands

Focus Screen Five

Move Slack Left

Load Coding Workspace

Float Terminal

Reset Workspace

Zoom In

Zoom Out

Recenter

Stop AR

---

# 15. Workspace Recovery

## Restore Workspace

Returns:

* Displays
* Layouts
* App assignments
* Float states

To saved configuration.

Useful after experimentation.

---

# 16. Display Backgrounds

Each screen may have:

* Solid color
* Gradient
* Image
* Transparent

Backgrounds exist only within the spatial environment.

---

# 17. Future Features

## Screen Groups

Multiple screens behave as one unit.

---

## Multi-user Shared Spaces

Multiple users share layout.

---

## Remote Workspace Sync

Cloud synchronization.

---

## AI Workspace Assistant

Commands such as:

"Create a coding workspace."

"Move communication apps to floating displays."

---

# 18. Competitive Advantages

Compared to Nebula:

* Unlimited screens
* Workspace profiles
* Floating displays
* Per-screen curvature
* Per-screen resolution
* App placement automation
* Voice commands

Compared to ultrawide-only solutions:

* Multi-screen environments
* Persistent spatial layouts
* Workflow-focused design

The application should be positioned as:

"Your entire desk, redesigned for spatial computing."

Rather than:

"A virtual monitor application."
