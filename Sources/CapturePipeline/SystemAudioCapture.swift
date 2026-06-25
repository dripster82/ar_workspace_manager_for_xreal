import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures the Mac's **system output audio** (meeting voices, music, app SFX) via ScreenCaptureKit
/// and hands each PCM sample buffer to `onAudio`. Audio-only: it runs a stream with a tiny throwaway
/// video config (SCK needs a display filter) and consumes only the `.audio` output. Rides on the
/// Screen Recording permission the app already holds — no extra entitlement or prompt.
///
/// Configured to **48 kHz mono Float32** so the recorder can fold it straight into its 48 kHz mono
/// mic track with no resampling. `excludesCurrentProcessAudio` keeps the app's own tones/alarms out.
public final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    public static let sampleRate = 48_000
    public static let channelCount = 1

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "system.audio.capture")
    private var onAudio: ((CMSampleBuffer) -> Void)?

    public override init() { super.init() }

    /// Begin capturing system audio. `handler` is called on a background queue for each buffer.
    public func start(_ handler: @escaping (CMSampleBuffer) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display to attach the audio stream to"])
        }
        onAudio = handler

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = Self.channelCount
        config.excludesCurrentProcessAudio = true   // don't record our own alarm tones / clicks
        // Minimal video config — we never read the screen output, so keep it cheap (but above any
        // minimum-size the API enforces). Audio is what we're after.
        config.width = 128
        config.height = 72
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        onAudio = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onAudio?(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudioCapture stopped: \(error.localizedDescription)")
    }
}
