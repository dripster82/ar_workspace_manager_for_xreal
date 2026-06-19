import AppKit
import CoreGraphics
import DisplayManager
import Foundation

/// Applies a screen's `ScreenBackground` by setting the underlying virtual display's macOS
/// desktop wallpaper. The captured desktop (opaque, and black-is-transparent in the glasses'
/// additive optics) is the only surface we can change, so a solid colour / black wallpaper IS
/// the screen's background as seen in AR.
enum ScreenBackgroundApplier {
    /// Generated solid-colour wallpaper images live here, cached by colour so we don't rewrite
    /// the same file each time AR starts.
    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop/Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Set `background` as the wallpaper of the NSScreen backing `displayID`. No-op when the
    /// screen isn't present yet (it'll be reapplied once displays settle) or for `.default`.
    @MainActor
    static func apply(_ background: ScreenBackground, toDisplayID displayID: CGDirectDisplayID) {
        guard background.kind != .default else { return }
        guard displayID != 0,
              let screen = NSScreen.screens.first(where: { displayNumber($0) == displayID })
        else { return }

        let url: URL?
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch background.kind {
        case .image:
            // A user-chosen image: point macOS straight at the file and scale to fill the display.
            guard let path = background.imagePath, FileManager.default.fileExists(atPath: path) else {
                NSLog("ScreenBackgroundApplier: image missing for display \(displayID): \(background.imagePath ?? "nil")")
                return
            }
            url = URL(fileURLWithPath: path)
            options = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                       .allowClipping: true]
        case .transparent:
            url = imageURL(forHex: "#000000")
        case .color:
            url = imageURL(forHex: background.hex)
        case .default:
            return
        }
        guard let url else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        } catch {
            NSLog("ScreenBackgroundApplier: setDesktopImageURL failed for display \(displayID): \(error)")
        }
    }

    /// Image backgrounds chosen by the user are copied here so the workspace stays self-contained
    /// (moving/deleting the original doesn't break the screen).
    private static let imageDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop/Backgrounds/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Copy a chosen image into the app's support folder and return the copy's path. Returns the
    /// original path on failure so the user still gets a (less robust) result.
    static func importImage(from source: URL) -> String {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let dest = imageDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest.path
        } catch {
            NSLog("ScreenBackgroundApplier: failed to copy \(source.path): \(error)")
            return source.path
        }
    }

    private static func displayNumber(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// A cached 256×256 solid-colour PNG for the given hex (a solid fill scales cleanly to any
    /// display). Returns nil if the colour or write fails.
    private static func imageURL(forHex hex: String) -> URL? {
        guard let color = nsColor(fromHex: hex) else { return nil }
        let name = hex.replacingOccurrences(of: "#", with: "").uppercased()
        let url = cacheDir.appendingPathComponent("solid-\(name).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: url, options: .atomic); return url }
        catch { NSLog("ScreenBackgroundApplier: failed to write \(url.path): \(error)"); return nil }
    }

    /// Parse "#RRGGBB" (or "RRGGBB") into an NSColor.
    static func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Format an NSColor as "#RRGGBB".
    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
