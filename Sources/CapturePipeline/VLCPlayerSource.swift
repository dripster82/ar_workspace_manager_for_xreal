import CVLCKit
import Foundation
import Metal
import QuartzCore

/// Plays a video with libvlc (bundled in VLCKit) and exposes each decoded frame as a Metal texture —
/// the same interface as `MediaPlayerSource` (the AVFoundation backend), so the media player can use
/// either. VLC handles what AVFoundation can't: MKV/AVI/WebM containers, AC3/DTS audio, and it
/// renders subtitles (text AND image-based) composited into the frames, so subs look identical for
/// every file. Frames arrive via libvlc's "vmem" callbacks into CPU buffers we own, then upload to a
/// Metal texture on the render thread (one copy per frame — fine for a single video).
///
/// Threading: libvlc invokes the format/lock/display callbacks on its decoder threads and event
/// callbacks on its event thread; everything shared is guarded by `lock`, and user-facing callbacks
/// (onReady/onEnded/onError) are bounced to the main queue.
public final class VLCPlayerSource: @unchecked Sendable {
    /// Called on the main queue when a file can't be played.
    public var onError: ((String) -> Void)?
    /// Called on the main queue when the current item plays to its end (for playlist auto-advance).
    public var onEnded: (() -> Void)?
    /// Called on the main queue when the first frame is ready — owner rebuilds the scene.
    public var onReady: (() -> Void)?

    private let device: MTLDevice
    private var instance: OpaquePointer?
    private var player: OpaquePointer?
    private var media: OpaquePointer?

    private let lock = NSLock()
    // Double-buffered CPU frames: VLC decodes into `back` (lock callback), display swaps it to
    // `front`; the render thread uploads `front` while VLC writes the next frame into `back`.
    private var front: UnsafeMutableRawPointer?
    private var back: UnsafeMutableRawPointer?
    private var frameW = 0, frameH = 0, framePitch = 0
    private var frameDirty = false
    private var gotFirstFrame = false
    private var pauseAfterFirstFrame = false
    /// Ring of textures: each new frame uploads into the NEXT texture, so the returned texture's
    /// object identity changes per frame. The renderer keys its sharpen-mip cache on that identity
    /// (same object → skip re-blit), so reusing one texture froze the corner screens; the ring also
    /// avoids CPU-writing a texture the GPU may still be sampling from a prior in-flight frame.
    private var textureRing: [MTLTexture] = []
    private var ringIndex = 0
    private var current: MTLTexture?
    private var _aspect: Float = 16.0 / 9.0
    private var loaded = false

    public init(device: MTLDevice) {
        self.device = device
        instance = libvlc_new(0, nil)
        if instance == nil { NSLog("VLCPlayerSource: libvlc_new failed") }
    }

    deinit {
        stopLocked()
        if let instance { libvlc_release(instance) }
        freeBuffers()
    }

    public var hasMedia: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return gotFirstFrame }
    public var aspect: Float { lock.lock(); defer { lock.unlock() }; return _aspect }

    public var currentTime: Double {
        guard let player else { return 0 }
        return Double(libvlc_media_player_get_time(player)) / 1000
    }

    public var duration: Double {
        guard let player else { return 0 }
        let ms = libvlc_media_player_get_length(player)
        return ms > 0 ? Double(ms) / 1000 : 0
    }

    public var isPlaying: Bool {
        guard let player else { return false }
        return libvlc_media_player_is_playing(player) != 0
    }

    // MARK: Control

    /// Load a file URL and (optionally) begin playing. `startAt` resumes at a saved position.
    /// `autoplay: false` still has to run the pipeline briefly to decode the first frame (vmem gets
    /// frames only while playing), so it starts MUTED and pauses on the first frame.
    public func load(url: URL, startAt: Double = 0, autoplay: Bool = true) {
        guard let instance else { onError?("VLC engine unavailable"); return }
        stopLocked()

        guard let m = libvlc_media_new_path(instance, url.path) else {
            DispatchQueue.main.async { self.onError?("Couldn't open \(url.lastPathComponent)") }
            return
        }
        if startAt > 0 { libvlc_media_add_option(m, ":start-time=\(startAt)") }
        media = m

        guard let p = libvlc_media_player_new_from_media(m) else {
            DispatchQueue.main.async { self.onError?("Couldn't create a player for this file") }
            return
        }
        player = p

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        libvlc_video_set_format_callbacks(p, vlcSetupCB, vlcCleanupCB)
        libvlc_video_set_callbacks(p, vlcLockCB, nil, vlcDisplayCB, opaque)

        if let em = libvlc_media_player_event_manager(p) {
            libvlc_event_attach(em, libvlc_event_type_t(libvlc_MediaPlayerEndReached.rawValue), vlcEventCB, opaque)
            libvlc_event_attach(em, libvlc_event_type_t(libvlc_MediaPlayerEncounteredError.rawValue), vlcEventCB, opaque)
        }

        lock.lock()
        loaded = true
        gotFirstFrame = false
        frameDirty = false
        pauseAfterFirstFrame = !autoplay
        lock.unlock()

        if !autoplay { libvlc_audio_set_mute(p, 1) }   // silent while grabbing the resume frame
        libvlc_media_player_play(p)
    }

    public func play() {
        guard let player else { return }
        libvlc_audio_set_mute(player, 0)
        libvlc_media_player_play(player)
    }

    public func pause() {
        guard let player else { return }
        libvlc_media_player_set_pause(player, 1)
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    public func stop() {
        stopLocked()
        lock.lock(); loaded = false; gotFirstFrame = false; frameDirty = false; lock.unlock()
    }

    /// Seek by a relative offset in seconds (negative = back), clamped to the item's bounds.
    public func seek(by seconds: Double) {
        guard let player else { return }
        let dur = duration
        var target = currentTime + seconds
        if dur > 0 { target = min(target, dur - 0.5) }
        libvlc_media_player_set_time(player, libvlc_time_t(max(0, target) * 1000))
    }

    private func stopLocked() {
        if let player {
            libvlc_media_player_stop(player)
            libvlc_media_player_release(player)
        }
        player = nil
        if let media { libvlc_media_release(media) }
        media = nil
    }

    private func freeBuffers() {
        front?.deallocate(); front = nil
        back?.deallocate(); back = nil
    }

    // MARK: Frame path (called from the libvlc callbacks below)

    /// Format setup: allocate double buffers for the decoded size and request BGRA output.
    fileprivate func setup(width: inout UInt32, height: inout UInt32,
                           pitch: inout UInt32, lines: inout UInt32) -> UInt32 {
        let w = Int(width), h = Int(height)
        let p = (w * 4 + 63) & ~63          // 64-byte-aligned pitch keeps libvlc's blitters happy
        let l = (h + 31) & ~31
        lock.lock()
        freeBuffers()
        front = UnsafeMutableRawPointer.allocate(byteCount: p * l, alignment: 64)
        back = UnsafeMutableRawPointer.allocate(byteCount: p * l, alignment: 64)
        frameW = w; frameH = h; framePitch = p
        _aspect = h > 0 ? Float(w) / Float(h) : 16.0 / 9.0
        textureRing = []; current = nil      // recreate at the new size on next upload
        lock.unlock()
        pitch = UInt32(p); lines = UInt32(l)
        return 1
    }

    fileprivate func lockFrame(planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
        lock.lock()
        planes?[0] = back
        lock.unlock()
    }

    fileprivate func displayFrame() {
        var fireReady = false
        var pauseNow = false
        lock.lock()
        swap(&front, &back)
        frameDirty = true
        if !gotFirstFrame {
            gotFirstFrame = true
            fireReady = true
            pauseNow = pauseAfterFirstFrame
            pauseAfterFirstFrame = false
        }
        lock.unlock()
        if fireReady || pauseNow {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if pauseNow, let p = self.player {
                    libvlc_media_player_set_pause(p, 1)
                    libvlc_audio_set_mute(p, 0)      // un-mute for when the user presses play
                }
                if fireReady { self.onReady?() }
            }
        }
    }

    fileprivate func handleEvent(_ type: libvlc_event_type_t) {
        // Never call libvlc synchronously from its own event thread — bounce to main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch Int(type) {
            case Int(libvlc_MediaPlayerEndReached.rawValue): self.onEnded?()
            case Int(libvlc_MediaPlayerEncounteredError.rawValue):
                self.onError?("VLC couldn't play this file (corrupt or unsupported stream).")
            default: break
            }
        }
    }

    /// Current frame as a Metal texture, pulled on the render thread. A new frame uploads into the
    /// next ring texture (fresh identity — see `textureRing`); otherwise the previous one is returned.
    public var latestTexture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard gotFirstFrame, let front, frameW > 0, frameH > 0 else { return current }
        if frameDirty {
            if textureRing.isEmpty {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: frameW, height: frameH, mipmapped: false)
                d.usage = [.shaderRead]
                textureRing = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
                guard !textureRing.isEmpty else { return nil }
            }
            ringIndex = (ringIndex + 1) % textureRing.count
            let tex = textureRing[ringIndex]
            tex.replace(region: MTLRegionMake2D(0, 0, frameW, frameH), mipmapLevel: 0,
                        withBytes: front, bytesPerRow: framePitch)
            current = tex
            frameDirty = false
        }
        return current
    }
}

// MARK: - C callbacks (libvlc threads; trampoline into the instance via `opaque`)

private func vlcSetupCB(opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                        chroma: UnsafeMutablePointer<CChar>?,
                        width: UnsafeMutablePointer<UInt32>?, height: UnsafeMutablePointer<UInt32>?,
                        pitches: UnsafeMutablePointer<UInt32>?, lines: UnsafeMutablePointer<UInt32>?) -> UInt32 {
    guard let raw = opaque?.pointee, let chroma, let width, let height, let pitches, let lines else { return 0 }
    let source = Unmanaged<VLCPlayerSource>.fromOpaque(raw).takeUnretainedValue()
    // Request BGRA ("RV32" is BGRX; "BGRA" preserves the fourcc our Metal path expects).
    memcpy(chroma, "BGRA", 4)
    return source.setup(width: &width.pointee, height: &height.pointee,
                        pitch: &pitches.pointee, lines: &lines.pointee)
}

private func vlcCleanupCB(opaque: UnsafeMutableRawPointer?) {
    // Buffers are freed/reallocated in setup() and deinit; nothing to do per-teardown.
}

private func vlcLockCB(opaque: UnsafeMutableRawPointer?,
                       planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
    guard let opaque else { return nil }
    Unmanaged<VLCPlayerSource>.fromOpaque(opaque).takeUnretainedValue().lockFrame(planes: planes)
    return nil
}

private func vlcDisplayCB(opaque: UnsafeMutableRawPointer?, picture: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    Unmanaged<VLCPlayerSource>.fromOpaque(opaque).takeUnretainedValue().displayFrame()
}

private func vlcEventCB(event: UnsafePointer<libvlc_event_t>?, opaque: UnsafeMutableRawPointer?) {
    guard let event, let opaque else { return }
    Unmanaged<VLCPlayerSource>.fromOpaque(opaque).takeUnretainedValue()
        .handleEvent(libvlc_event_type_t(event.pointee.type))
}
