// Generates dark/violet PLACEHOLDER images + an animated gif for the README, so the asset links
// resolve before real screenshots/recordings exist. Replace the files in assets/ with real captures.
// Run: swift Scripts/make-placeholder-assets.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let bg = NSColor(calibratedRed: 0.10, green: 0.086, blue: 0.149, alpha: 1)      // #1A1626
let panel = NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.24, alpha: 1)
let accent = NSColor(calibratedRed: 0.486, green: 0.361, blue: 1.0, alpha: 1)   // violet
let size = NSSize(width: 1280, height: 720)

func draw(into rep: NSBitmapImageRep, title: String, accentX: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(origin: .zero, size: size)
    bg.setFill(); r.fill()
    // framed panel
    let inset = r.insetBy(dx: 48, dy: 48)
    let path = NSBezierPath(roundedRect: inset, xRadius: 18, yRadius: 18)
    panel.setFill(); path.fill()
    accent.withAlphaComponent(0.5).setStroke(); path.lineWidth = 2; path.stroke()
    // moving accent bar (animated frames vary accentX)
    let bar = NSRect(x: inset.minX + accentX, y: inset.minY + 24, width: 220, height: 8)
    accent.setFill(); NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
    // title
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
        .foregroundColor: NSColor.white, .paragraphStyle: para]
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        .foregroundColor: NSColor(white: 0.7, alpha: 1), .paragraphStyle: para]
    (title as NSString).draw(in: NSRect(x: 0, y: size.height/2 - 10, width: size.width, height: 60),
                             withAttributes: titleAttrs)
    ("AR Workspace Manager for XREAL — placeholder (replace with screenshot)" as NSString)
        .draw(in: NSRect(x: 0, y: size.height/2 - 54, width: size.width, height: 40),
              withAttributes: subAttrs)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
}

func newRep() -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func writePNG(_ title: String, _ name: String) {
    let rep = newRep()
    draw(into: rep, title: title, accentX: 40)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
    print("wrote assets/\(name)")
}

writePNG("Dashboard", "dashboard.png")
writePNG("Workspace layout editor", "workspace-editor.png")
writePNG("HUD widgets", "hud-widgets.png")
writePNG("Hero", "hero.png")

// Animated gif: a few frames with the accent bar sweeping across.
let gifURL = outDir.appendingPathComponent("demo.gif")
let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 6, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
    [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
for i in 0..<6 {
    let rep = newRep()
    draw(into: rep, title: "Quick start demo", accentX: 40 + CGFloat(i) * 150)
    let frameProps = [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFDelayTime as String: 0.5]] as CFDictionary
    CGImageDestinationAddImage(dest, rep.cgImage!, frameProps)
}
CGImageDestinationFinalize(dest)
print("wrote assets/demo.gif")
