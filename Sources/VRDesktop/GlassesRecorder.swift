import AVFoundation
import CoreVideo

/// Records the glasses view to an .mp4: video frames come from the renderer (via appendVideo),
/// audio from the mic (optional, mutable). All writer access is serialised on `queue`.
final class GlassesRecorder: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "glasses.recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var started = false
    private var finishing = false
    private(set) var isRecording = false
    private(set) var outputURL: URL?

    /// Mute the mic (the audio track stays continuous — samples are zeroed) — toggle any time.
    var micMuted = false

    /// Begin recording. The writer is created lazily from the first frame's size. Returns the
    /// planned output URL.
    @discardableResult
    func start() -> URL? {
        guard !isRecording else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/VRDesktop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Glasses \(f.string(from: Date())).mp4")
        outputURL = url; started = false; finishing = false; isRecording = true
        setupMic()
        return url
    }

    private func makeWriter(width: Int, height: Int) {
        guard let url = outputURL, let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        vInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        if writer.canAdd(vInput) { writer.add(vInput) }
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100, AVEncoderBitRateKey: 64000])
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }
        writer.startWriting()
        self.writer = writer; self.videoInput = vInput; self.adaptor = adaptor; self.audioInput = aInput
    }

    private func setupMic() {
        session.beginConfiguration()
        if let dev = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(audioOutput)
        }
        session.commitConfiguration()
        session.startRunning()
    }

    /// Append a rendered frame (called from the renderer, off-main). Starts the session on the first.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        queue.async { [weak self] in
            guard let self, self.isRecording, !self.finishing else { return }
            if self.writer == nil {
                self.makeWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            }
            guard let writer = self.writer, let adaptor = self.adaptor, let input = self.videoInput else { return }
            if !self.started { writer.startSession(atSourceTime: time); self.started = true }
            if input.isReadyForMoreMediaData { adaptor.append(pixelBuffer, withPresentationTime: time) }
        }
    }

    func stop(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isRecording, let writer = self.writer else { completion(nil); return }
            self.isRecording = false; self.finishing = true
            self.session.stopRunning()
            self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
            let url = self.outputURL
            writer.finishWriting {
                DispatchQueue.main.async { completion(writer.status == .completed ? url : nil) }
                self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
            }
        }
    }

    // Audio samples arrive on `queue`.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, started, !finishing, let input = audioInput, input.isReadyForMoreMediaData else { return }
        if micMuted { zero(sampleBuffer) }
        input.append(sampleBuffer)
    }

    /// Zero a sample buffer's audio data in place (silence) so a muted track stays continuous.
    private func zero(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                       totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
           let ptr { memset(ptr, 0, len) }
    }
}
