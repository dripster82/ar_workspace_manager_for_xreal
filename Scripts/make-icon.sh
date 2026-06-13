#!/bin/zsh
# Generate App/AppIcon.icns from the "eyeglasses" SF Symbol (to match the menu-bar icon).
# Run once (or after changing the design); build-app.sh copies the .icns into the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PNG="$TMP/icon_1024.png"

# Render a 1024×1024 PNG: dark squircle background + white eyeglasses glyph.
swift - "$PNG" <<'SWIFT'
import AppKit
_ = NSApplication.shared
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let base = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)!
var cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular)
cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let glasses = base.withSymbolConfiguration(cfg) ?? base

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset = size * 0.085
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
])!
grad.draw(in: path, angle: -90)

let g = glasses.size
let scale = (size * 0.56) / max(g.width, g.height)
let dw = g.width * scale, dh = g.height * scale
glasses.draw(in: NSRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh),
             from: .zero, operation: .sourceOver, fraction: 1.0)
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
SWIFT

# Build the .iconset and convert to .icns.
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/App/AppIcon.icns"
echo "Wrote $ROOT/App/AppIcon.icns"
