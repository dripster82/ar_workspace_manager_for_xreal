import AVFoundation
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Plays a video file (local or on a mounted network drive) with `AVPlayer` and exposes each decoded
/// frame as a Metal texture — the same `latestTexture` interface as `CaptureSource`, so the renderer
/// can draw it as a `SceneScreen` with no screen capture involved. Because the app decodes the media
/// itself (no `ScreenCaptureKit`), there's no screen-recording session and none of the DRM-blackout
/// that capture hits. (FairPlay-protected streaming services still can't be played — they provide no
/// openable URL and would return black to a texture output anyway — this is for your own media.)
public final class MediaPlayerSource: @unchecked Sendable {
    public let player = AVPlayer()

    /// Called on the main queue when a file can't be played (unsupported container/codec, missing
    /// file, no video track, …) with a user-facing message.
    public var onError: ((String) -> Void)?
    /// Called on the main queue when the current item plays to its end (for playlist auto-advance).
    public var onEnded: (() -> Void)?
    /// Called on the main queue when the item becomes ready to play (a frame is available) — lets the
    /// owner rebuild the scene so the screen only appears once there's real video, not a blank box.
    public var onReady: (() -> Void)?

    /// True once the current item is ready to play (has decodable frames). False while loading or on
    /// failure — used to avoid drawing an empty/garbage screen.
    public var isReady: Bool { player.currentItem?.status == .readyToPlay }

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache!
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var latest: (texture: MTLTexture, backing: CVMetalTexture)?
    /// Keep a few recent CVMetalTexture backings alive so a texture handed to the renderer isn't freed
    /// under an in-flight GPU frame (same lifetime concern as CaptureSource).
    private var recentBackings: [CVMetalTexture] = []
    /// Content aspect (width / height), updated once the track's natural size is known.
    private var _aspect: Float = 16.0 / 9.0

    public init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    public var aspect: Float { lock.lock(); defer { lock.unlock() }; return _aspect }
    private func setAspect(_ a: Float) { lock.lock(); _aspect = a; lock.unlock() }
    public var hasMedia: Bool { player.currentItem != nil }

    /// Seconds into the current item (0 if none). Used to persist resume position.
    public var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    /// Total length of the current item in seconds (0 if unknown / no item).
    public var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    private var pendingSeek: Double = 0

    /// Load a file URL. Forces BGRA output so the frame is a single Metal texture. `startAt` seeks to a
    /// saved position once the item is ready; `autoplay` false loads it paused (for resume-on-launch).
    /// Reports load failures (e.g. unsupported containers like .mkv) via `onError`.
    public func load(url: URL, startAt: Double = 0, autoplay: Bool = true) {
        statusObs?.invalidate()
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        pendingSeek = startAt

        let item = AVPlayerItem(url: url)
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(out)
        lock.lock(); output = out; latest = nil; recentBackings.removeAll(); lock.unlock()

        // Surface a load failure with a helpful message (macOS/AVFoundation can't open Matroska/MKV,
        // AVI, WMV, FLV, WebM and some codecs — the frame would otherwise just stay blank).
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                if self.pendingSeek > 0 {
                    let t = self.pendingSeek; self.pendingSeek = 0
                    self.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                }
                DispatchQueue.main.async { self.onReady?() }
            }
            guard item.status == .failed else { return }
            let ext = url.pathExtension.uppercased()
            let unsupported = ["MKV", "AVI", "WMV", "FLV", "WEBM", "TS", "M2TS", "OGV"]
            let msg = unsupported.contains(ext)
                ? "\(ext) isn't supported by macOS video — convert it to MP4 or MOV (H.264/HEVC)."
                : (item.error?.localizedDescription ?? "Couldn't open this video.")
            DispatchQueue.main.async { self.onError?(msg) }
        }
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.onEnded?() }

        player.replaceCurrentItem(with: item)
        if autoplay { player.play() } else { player.pause() }
        resolveAspect(item: item)
    }

    /// Seek by a relative offset in seconds (negative = back), clamped to the item's bounds.
    public func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let dur = item.duration.seconds
        let now = player.currentTime().seconds
        let target = max(0, min(now + seconds, dur.isFinite ? dur - 0.1 : now + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public var isPlaying: Bool { player.timeControlStatus == .playing }
    public func togglePlay() { isPlaying ? pause() : play() }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObs?.invalidate(); statusObs = nil
        if let endObs { NotificationCenter.default.removeObserver(endObs); self.endObs = nil }
        lock.lock(); output = nil; latest = nil; recentBackings.removeAll(); lock.unlock()
    }

    /// Current frame as a Metal texture, pulled on the render thread. Syncs to the player clock via the
    /// output's item time; returns the last texture when there's no new frame this display refresh.
    public var latestTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let output else { return latest?.texture }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return latest?.texture }

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
        if let cv, let tex = CVMetalTextureGetTexture(cv) {
            latest = (tex, cv)
            recentBackings.append(cv)
            if recentBackings.count > 3 { recentBackings.removeFirst() }
        }
        return latest?.texture
    }

    /// Read the video track's display aspect (natural size · preferred transform) once loaded.
    private func resolveAspect(item: AVPlayerItem) {
        Task { [weak self] in
            guard let self,
                  let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let t = try? await track.load(.preferredTransform) else { return }
            let display = size.applying(t)
            let w = abs(display.width), h = abs(display.height)
            guard w > 0, h > 0 else { return }
            self.setAspect(Float(w / h))
        }
    }
}
