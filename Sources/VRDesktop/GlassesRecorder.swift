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
    /// Preferred mic uniqueID, or nil for the system default.
    var preferredMicID: String?

    /// Mix the Mac's system output audio (meeting voices, music, app SFX) into the recording.
    /// Fed by `appendSystemAudio` from a `SystemAudioCapture`; folded into the mic track below.
    var recordSystemAudio = false
    /// Common audio rate for the mic track AND the system-audio source, so mixing is a plain
    /// sample-wise add with no resampling. Mono throughout.
    static let sampleRate = 48_000
    // Buffered system-audio samples (Int16, mono, 48 kHz) awaiting the next mic buffer to mix into.
    private let systemLock = NSLock()
    private var systemRing: [Int16] = []

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
        systemLock.lock(); systemRing.removeAll(keepingCapacity: true); systemLock.unlock()
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
            AVSampleRateKey: Self.sampleRate, AVEncoderBitRateKey: 64000])
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }
        writer.startWriting()
        self.writer = writer; self.videoInput = vInput; self.adaptor = adaptor; self.audioInput = aInput
    }

    private func setupMic() {
        session.beginConfiguration()
        let dev = preferredMicID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        if let dev, let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(audioOutput) {
            // Pin a concrete interleaved PCM format so the AAC writer input gets a predictable
            // buffer — without this the device delivers e.g. non-interleaved float and the
            // transcode produces static.
            audioOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
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

    // Mic samples arrive on `queue`. The mic is the recording's audio heartbeat: each buffer is the
    // slot we fold the buffered system audio into. Muting zeros the mic first, so "system audio only"
    // is just: record system audio + mute the mic.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, started, !finishing, let input = audioInput, input.isReadyForMoreMediaData else { return }
        if micMuted { zero(sampleBuffer) }
        if recordSystemAudio { mixSystemAudio(into: sampleBuffer) }
        input.append(sampleBuffer)
    }

    // Converts whatever format SCK delivers (it may ignore our mono/rate request and hand back
    // stereo float at its own rate) into the canonical 48 kHz mono Int16 the mic track uses.
    private lazy var systemTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: true)
    private var systemConverter: AVAudioConverter?
    private var systemInFormat: AVAudioFormat?

    /// Receive a system-audio buffer from `SystemAudioCapture`, convert it to 48 kHz mono Int16, and
    /// queue it for the next mic buffer to mix in. Called on the capture's own (serial) queue.
    func appendSystemAudio(_ sb: CMSampleBuffer) {
        guard isRecording, recordSystemAudio, let target = systemTargetFormat,
              let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let inFormat = AVAudioFormat(streamDescription: asbd) else { return }

        if systemConverter == nil || systemInFormat != inFormat {
            systemConverter = AVAudioConverter(from: inFormat, to: target)
            systemInFormat = inFormat
        }
        guard let converter = systemConverter else { return }

        let inFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard inFrames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames) else { return }
        inBuf.frameLength = inFrames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(inFrames), into: inBuf.mutableAudioBufferList) == noErr else { return }

        let ratio = target.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inFrames) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
        var supplied = false
        var convErr: NSError?
        let result = converter.convert(to: outBuf, error: &convErr) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        guard result != .error, let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return }
        let outN = Int(outBuf.frameLength)
        let p = ch[0]

        systemLock.lock()
        systemRing.reserveCapacity(systemRing.count + outN)
        for i in 0..<outN { systemRing.append(p[i]) }
        // Cap the backlog (~0.5 s) so clock drift / a stalled mic can't grow it without bound.
        let maxFrames = Self.sampleRate / 2
        if systemRing.count > maxFrames { systemRing.removeFirst(systemRing.count - maxFrames) }
        systemLock.unlock()
    }

    /// Add the buffered system audio into this mic buffer (Int16 mono) in place, sample-by-sample
    /// with clipping. Same rate/channels on both sides, so no resampling.
    private func mixSystemAudio(into sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let ptr else { return }
        let n = len / MemoryLayout<Int16>.size
        systemLock.lock()
        let take = min(n, systemRing.count)
        let sys = take > 0 ? Array(systemRing.prefix(take)) : []
        if take > 0 { systemRing.removeFirst(take) }
        systemLock.unlock()
        guard take > 0 else { return }
        ptr.withMemoryRebound(to: Int16.self, capacity: n) { mic in
            for i in 0..<take {
                let s = Int32(mic[i]) + Int32(sys[i])
                mic[i] = Int16(max(-32768, min(32767, s)))
            }
        }
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
