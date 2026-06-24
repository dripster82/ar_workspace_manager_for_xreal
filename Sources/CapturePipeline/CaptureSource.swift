import AppKit
import Foundation
import ScreenCaptureKit
import Metal
import CoreVideo
import QuartzCore

/// Captures one display via ScreenCaptureKit and exposes the latest frame as a Metal texture.
public final class CaptureSource: NSObject, @unchecked Sendable {
    public let displayID: CGDirectDisplayID

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache!
    private var stream: SCStream?
    // Below the render/display-link priority band so capture yields to rendering rather
    // than competing for cores (which was delaying frame delivery → head-tracking stalls).
    private let outputQueue = DispatchQueue(label: "capture.output", qos: .userInitiated)

    private let lock = NSLock()
    // Keep the CVMetalTexture alive while its MTLTexture may be in flight.
    private var latest: (texture: MTLTexture, backing: CVMetalTexture)?
    // Recovery state: whether we intend to be capturing, last delivered-sample time (the stream
    // delivers idle frames too, so this tracks "stream alive"), and a restart guard.
    private var wantCapture = false
    private var lastSampleAt: CFTimeInterval = CACurrentMediaTime()
    private var restarting = false

    public init(displayID: CGDirectDisplayID, device: MTLDevice) {
        self.displayID = displayID
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    public var latestTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latest?.texture
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "CaptureSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Display \(displayID) not found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Capture at the display's true native pixel resolution so HiDPI (Retina)
        // displays stay crisp and 1× displays aren't upscaled into softness.
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            config.width = mode.pixelWidth
            config.height = mode.pixelHeight
        } else {
            config.width = display.width
            config.height = display.height
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // 60fps capture: smoother scrolling/video and a far less laggy captured cursor (it's baked
        // into the frame at this rate). Head-tracked reprojection runs at full display rate
        // independently, so this is purely content smoothness. With many screens at once (e.g. an
        // 8-screen ring) this raises capture load — reduce the screen count if the framerate dips.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        lock.lock(); wantCapture = true; lastSampleAt = CACurrentMediaTime(); restarting = false; lock.unlock()
    }

    public func stop() async {
        lock.lock(); wantCapture = false; lock.unlock()
        try? await stream?.stopCapture()
        stream = nil
        clearLatest()
    }

    /// Seconds since the stream last delivered a sample. While alive the stream delivers frames
    /// (incl. idle ones), so a large value means it has frozen — e.g. after sleep / display reconfig.
    public var secondsSinceLastSample: Double {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastSampleAt
    }

    /// Tear down and re-create the stream (recovery). No-op if we don't want capture or a restart
    /// is already in flight. Safe to call repeatedly from the stall watchdog.
    public func restartCapture() {
        lock.lock()
        let skip = restarting || !wantCapture
        if !skip { restarting = true; lastSampleAt = CACurrentMediaTime() } // reset so the watchdog waits
        lock.unlock()
        guard !skip else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.stream?.stopCapture()
            self.stream = nil
            do { try await self.start() }
            catch {
                NSLog("CaptureSource(\(self.displayID)) restart failed: \(error.localizedDescription)")
                self.lock.lock(); self.restarting = false; self.lock.unlock()
            }
        }
    }

    private func clearLatest() {
        lock.lock(); latest = nil; lock.unlock()
    }
}

extension CaptureSource: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Mark the stream alive on every callback (including idle frames) for the stall watchdog.
        lock.lock(); lastSampleAt = CACurrentMediaTime(); lock.unlock()
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        lock.lock()
        latest = (texture, cvTexture)
        lock.unlock()
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("CaptureSource(\(displayID)) stopped: \(error.localizedDescription)")
        restartCapture() // auto-recover if we still want to be capturing (sleep / display reconfig)
    }
}

/// Enumerates capturable displays for the UI.
public enum ShareableContentService {
    public struct DisplayInfo: Identifiable, Hashable, Sendable {
        public let id: CGDirectDisplayID
        public let width: Int
        public let height: Int
        public let name: String
    }

    public static func displays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map {
            DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height,
                        name: displayName(for: $0.displayID))
        }
    }

    public static func displayName(for id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) {
            return screen.localizedName
        }
        return "Display \(id)"
    }
}
