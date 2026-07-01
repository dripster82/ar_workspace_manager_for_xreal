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

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache!
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
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

    /// Load a file URL and begin playing. Forces BGRA output so the frame is a single Metal texture.
    public func load(url: URL) {
        let item = AVPlayerItem(url: url)
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(out)
        lock.lock(); output = out; latest = nil; recentBackings.removeAll(); lock.unlock()
        player.replaceCurrentItem(with: item)
        player.play()
        resolveAspect(item: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public var isPlaying: Bool { player.timeControlStatus == .playing }
    public func togglePlay() { isPlaying ? pause() : play() }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
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
