import AVFoundation
import CapturePipeline
import Compositor
import Metal
import SwiftUI

/// A head-locked video player pinned to one of five FOV positions: the four corners (like the window
/// hotspots) or full-FOV. Decodes with `AVPlayer` and renders as a head-locked `SceneScreen`, so it
/// coexists with the AR screens and moves with your view. Spatial (world-locked) placement is a later
/// phase. Sources are file URLs — local disk or a mounted network drive.
@MainActor
final class MediaPlayerManager: ObservableObject {
    enum Position: Int, CaseIterable, Identifiable {
        case off = 0, topLeft = 1, topRight = 2, bottomLeft = 3, bottomRight = 4, fullFOV = 5
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .topLeft: return "Top-left"
            case .topRight: return "Top-right"
            case .bottomLeft: return "Bottom-left"
            case .bottomRight: return "Bottom-right"
            case .fullFOV: return "Full view"
            }
        }
    }

    /// Placement of a pinned screen: centre (yaw/pitch, radians; +yaw = left, +pitch = up), distance,
    /// and the max box (metres) the video is fit inside (aspect-preserved).
    private struct Slot { let yaw: Float; let pitch: Float; let distance: Float; let maxW: Float; let maxH: Float }

    @Published private(set) var position: Position = .off
    @Published private(set) var fileName: String?
    @Published private(set) var playing = false

    private let source: MediaPlayerSource
    /// Stable id so the renderer caches this screen's mesh across frames.
    private let sceneID = UUID(uuidString: "0000B0B0-0000-0000-0000-0000000000A1")!
    /// Called when the pinned screen needs rebuilding (position/media change), so the owner re-renders.
    var onChange: (() -> Void)?

    init(device: MTLDevice) { source = MediaPlayerSource(device: device) }

    var hasMedia: Bool { source.hasMedia }

    func open(url: URL) {
        source.load(url: url)
        fileName = url.lastPathComponent
        playing = true
        if position == .off { position = .fullFOV }   // show it somewhere on first open
        onChange?()
    }

    func setPosition(_ p: Position) {
        position = p
        if p == .off { source.pause(); playing = false }
        onChange?()
    }

    func togglePlay() {
        source.togglePlay()
        playing = source.isPlaying
    }

    func stop() {
        source.stop()
        fileName = nil
        position = .off
        playing = false
        onChange?()
    }

    /// The head-locked `SceneScreen` for the current position, or nil when off / no media loaded.
    func sceneScreen() -> SceneScreen? {
        guard position != .off, source.hasMedia else { return nil }
        let slot = Self.slot(for: position)
        let aspect = max(0.1, source.aspect)
        // Fit the video inside the slot box, preserving aspect.
        let width = (aspect >= slot.maxW / slot.maxH) ? slot.maxW : slot.maxH * aspect
        return SceneScreen(
            id: sceneID,
            yaw: slot.yaw, pitch: slot.pitch, distance: slot.distance,
            widthMeters: width, aspect: aspect,
            curveH: 0, autoCurveH: false,
            headLocked: true,
            textureProvider: { [weak source] in source?.latestTexture })
    }

    /// FOV geometry. Corner boxes match the window-hotspot slots (vertical FOV ≈ 23°, horizontal ≈
    /// 40° at per-eye 1920×1080); full-FOV fills that box centred.
    private static func slot(for p: Position) -> Slot {
        switch p {
        case .topLeft:     return Slot(yaw:  0.2496, pitch:  0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .topRight:    return Slot(yaw: -0.2496, pitch:  0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .bottomLeft:  return Slot(yaw:  0.2496, pitch: -0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .bottomRight: return Slot(yaw: -0.2496, pitch: -0.1292, distance: 1.4, maxW: 0.26, maxH: 0.17)
        case .fullFOV, .off:
            return Slot(yaw: 0, pitch: 0, distance: 1.4, maxW: 1.02, maxH: 0.57)
        }
    }
}
