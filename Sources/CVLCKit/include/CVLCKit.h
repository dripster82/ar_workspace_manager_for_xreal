// Exposes VLCKit's bundled libvlc C API to Swift. The VLCKit framework ships the full libvlc
// headers (Headers/vlc/…) but excludes them from its module map, so `import VLCKit` only surfaces
// the ObjC wrapper — which has no route to raw decoded frames. The media player's VLC backend needs
// the C "vmem" video callbacks (libvlc_video_set_callbacks / set_format_callbacks) to pull each
// frame into a Metal texture, so this header-only target re-exports the C API. The symbols live in
// the VLCKit binary itself; no extra library is linked.
#ifndef CVLCKIT_H
#define CVLCKIT_H

#include <vlc/vlc.h>

#endif
