import AppKit
import Foundation
import ScreenCaptureKit
import Metal
import CoreVideo

/// Captures one display via ScreenCaptureKit and exposes the latest frame as a Metal texture.
public final class CaptureSource: NSObject, @unchecked Sendable {
    public let displayID: CGDirectDisplayID

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache!
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "capture.output", qos: .userInteractive)

    private let lock = NSLock()
    // Keep the CVMetalTexture alive while its MTLTexture may be in flight.
    private var latest: (texture: MTLTexture, backing: CVMetalTexture)?

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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        clearLatest()
    }

    private func clearLatest() {
        lock.lock(); latest = nil; lock.unlock()
    }
}

extension CaptureSource: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
