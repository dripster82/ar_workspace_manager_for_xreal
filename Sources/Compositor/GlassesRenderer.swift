import AppKit
import GlassesDriver
import Metal
import MetalKit
import QuartzCore
import simd

/// Renders the AR scene fullscreen onto a target NSScreen (the glasses, or any
/// external monitor as a stand-in) using CAMetalLayer + CAMetalDisplayLink.
public final class GlassesRenderer: NSObject {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    // Recreated per output session: reusing a layer/display-link across virtual-display
    // add/remove cycles leaves stale entries in QuartzCore's display link list and
    // crashes the WindowServer notification path (notifyDisplayAdded).
    private var metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?
    private var window: NSWindow?
    private var targetDisplayID: CGDirectDisplayID = 0
    private var screenObserver: NSObjectProtocol?

    private var screenPipeline: MTLRenderPipelineState!
    private var placeholderPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var msaaColorTexture: MTLTexture?
    private var depthTextureMS: MTLTexture?
    private var depthTextureSingle: MTLTexture?
    private static let depthFormat: MTLPixelFormat = .depth32Float
    private var library: MTLLibrary!

    /// MSAA sample count: 1 (off), 2, 4, or 8. Changing it rebuilds the pipelines.
    public private(set) var sampleCount = 4
    /// Anisotropic sharpening level for screen content: 1 = off, else 2/4/8/16.
    /// Higher = crisper minified/angled text (mipmaps + anisotropic filtering), more GPU cost.
    public private(set) var sharpenAnisotropy = 1
    private var linearSampler: MTLSamplerState!
    private var sharpSampler: MTLSamplerState!
    private var mipTargets: [UUID: MTLTexture] = [:]
    // Identity of the capture texture last blitted+mipped per screen, so we skip
    // regenerating mipmaps for frames whose source pixels haven't changed (capture
    // runs at 30fps; rendering up to the glasses' full refresh).
    private var mipSourceVersion: [UUID: ObjectIdentifier] = [:]

    /// Supersample factor: 1.0 = off; renders the scene at scale× the display then
    /// downsamples, smoothing interior edges/lines while keeping text crisp.
    public private(set) var renderScale: Double = 1.0
    private var ssColorTexture: MTLTexture?
    private var downscalePipeline: MTLRenderPipelineState!

    // Screen-space help overlay (drawn on top of everything).
    private var overlayPipeline: MTLRenderPipelineState!
    private var helpTexture: MTLTexture?
    public var showHelp = false

    private struct OverlayVertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }

    private let poseStore: PoseStore
    private let lock = NSLock()
    private var screens: [SceneScreen] = []
    private var cachedVertexBuffers: [UUID: (buffer: MTLBuffer, count: Int)] = [:]
    // Wide-canvas atlas textures, keyed by canvas screen id (recreated when the pixel size
    // changes). Each frame the member tiles are composited into the atlas, then the canvas
    // mesh samples it — so the merged image curves as one surface.
    private var canvasAtlases: [UUID: MTLTexture] = [:]

    /// When non-nil, overrides the IMU pose (UI fake-pose slider for glasses-free testing).
    public var fakePose: simd_quatf? {
        get { lock.lock(); defer { lock.unlock() }; return _fakePose }
        set { lock.lock(); _fakePose = newValue; lock.unlock() }
    }
    private var _fakePose: simd_quatf?

    /// Pose-prediction lead time in seconds.
    public var predictionLead: Float = 0.021

    /// Side-by-side stereo (experimental): render the scene twice into the left/right
    /// halves of a 3840×1080 frame so the glasses give each eye its own perspective.
    public var stereoEnabled = false
    /// Interpupillary distance in metres (eye separation).
    public var ipd: Float = 0.063

    /// When set, the next rendered frame writes stage2 (merged atlas) and stage3 (final curved
    /// frame) JPEGs into this directory, then clears itself. See `dumpTexture`.
    public var debugDumpDir: URL?
    /// Crosshair markers (atlas pixel coords, top-left origin) drawn onto the stage2 dump.
    public var debugStage2Markers: [(x: Int, y: Int, color: CGColor)] = []
    /// Called (off the main thread) after a debug dump, with the list of files written.
    public var onDebugDumpComplete: (([String]) -> Void)?

    public private(set) var framesPerSecond: Double = 0
    private var frameCount = 0
    private var lastFPSUpdate = CACurrentMediaTime()

    /// Frame-timing diagnostics: logs frames that overran the refresh interval (dropped
    /// frames) and their GPU time, to distinguish render stalls from tracking issues.
    public var frameLoggingEnabled = false
    public var frameLog: ((String) -> Void)?
    private var lastFrameStart: TimeInterval = 0
    private var droppedFrames = 0

    public init?(poseStore: PoseStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.poseStore = poseStore
        super.init()
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
            screenPipeline = try makePipeline(library: library, fragment: "screen_fragment")
            placeholderPipeline = try makePipeline(library: library, fragment: "placeholder_fragment")
        } catch {
            NSLog("GlassesRenderer: shader compile failed: \(error)")
            return nil
        }
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDesc)

        let lin = MTLSamplerDescriptor()
        lin.minFilter = .linear; lin.magFilter = .linear
        linearSampler = device.makeSamplerState(descriptor: lin)
        rebuildSharpSampler()

        let dDesc = MTLRenderPipelineDescriptor()
        dDesc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        dDesc.fragmentFunction = library.makeFunction(name: "blit_fragment")
        dDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        downscalePipeline = try? device.makeRenderPipelineState(descriptor: dDesc)

        let oDesc = MTLRenderPipelineDescriptor()
        oDesc.vertexFunction = library.makeFunction(name: "overlay_vertex")
        oDesc.fragmentFunction = library.makeFunction(name: "overlay_fragment")
        oDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        oDesc.colorAttachments[0].isBlendingEnabled = true   // premultiplied-alpha over
        oDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        oDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        oDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        oDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlayPipeline = try? device.makeRenderPipelineState(descriptor: oDesc)
    }

    /// Provide the help HUD image (from rasterized SwiftUI) and show it. Rasterizes the
    /// CGImage into a known BGRA premultiplied buffer (robust across CGImage formats that
    /// MTKTextureLoader can reject). Returns false if the texture couldn't be made.
    @discardableResult
    public func setHelpImage(_ cgImage: CGImage) -> Bool {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return false }
        let bytesPerRow = w * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo),
              let data = ctx.data else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return false }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        helpTexture = tex
        showHelp = true
        return true
    }

    public func clearHelp() { showHelp = false }

    /// Copy a (possibly GPU-private) texture's level 0 into a readable buffer and write it as a
    /// JPEG. Used by the debug stage-capture to inspect the pipeline (raw → merged → curved).
    /// `markers` (atlas pixel coords, top-left origin) are drawn as coloured crosshairs.
    @discardableResult
    public func dumpTexture(_ src: MTLTexture, to url: URL,
                            markers: [(x: Int, y: Int, color: CGColor)] = []) -> Bool {
        let w = src.width, h = src.height
        guard w > 0, h > 0 else { return false }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let dst = device.makeTexture(descriptor: desc),
              let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return false }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        dst.getBytes(&data, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // bgra8 bytes read as little-endian 32-bit words are 0xAARRGGBB → ARGB / skip-first.
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return false }
        // Draw crosshair markers. CGContext origin is bottom-left, but the buffer is top-down,
        // so flip y. Sizes scale with the image so they're visible on a multi-thousand-px atlas.
        let arm = max(8, h / 80), thick = max(3, h / 300)
        for m in markers {
            ctx.setFillColor(m.color)
            let cy = h - m.y
            ctx.fill(CGRect(x: m.x - arm, y: cy - thick / 2, width: 2 * arm, height: thick))
            ctx.fill(CGRect(x: m.x - thick / 2, y: cy - arm, width: thick, height: 2 * arm))
        }
        guard let cg = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return false }
        do { try jpeg.write(to: url); return true } catch { return false }
    }

    /// Set supersample factor (1.0 off, up to 2.0).
    public func setRenderScale(_ scale: Double) {
        let valid = min(2.0, max(1.0, scale))
        guard valid != renderScale else { return }
        renderScale = valid
        ssColorTexture = nil
    }

    private func ssColor(width: Int, height: Int) -> MTLTexture? {
        let w = max(1, width), h = max(1, height)
        if let t = ssColorTexture, t.width == w, t.height == h { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        ssColorTexture = device.makeTexture(descriptor: desc)
        return ssColorTexture
    }

    private func rebuildSharpSampler() {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.maxAnisotropy = max(1, min(16, sharpenAnisotropy))
        sharpSampler = device.makeSamplerState(descriptor: d)
    }

    /// Set the anisotropic sharpening level (1 = off, 2, 4, 8, 16).
    public func setSharpenAnisotropy(_ n: Int) {
        let valid = [1, 2, 4, 8, 16].contains(n) ? n : 1
        guard valid != sharpenAnisotropy else { return }
        sharpenAnisotropy = valid
        rebuildSharpSampler()
        if valid == 1 { mipTargets.removeAll(); mipSourceVersion.removeAll() }
    }

    /// MSAA levels this GPU actually supports (1 = off is always allowed).
    public func supportedSampleCounts() -> [Int] {
        [1, 2, 4, 8].filter { $0 == 1 || device.supportsTextureSampleCount($0) }
    }

    /// Set MSAA level (1 = off, 2, 4, 8); rebuilds pipelines and discards stale MSAA targets.
    /// Falls back to the highest supported level if the requested one isn't available.
    public func setSampleCount(_ n: Int) {
        var valid = [1, 2, 4, 8].contains(n) ? n : 4
        if valid > 1 && !device.supportsTextureSampleCount(valid) {
            valid = supportedSampleCounts().filter { $0 <= valid }.max() ?? 1
        }
        guard valid != sampleCount else { return }
        sampleCount = valid
        do {
            screenPipeline = try makePipeline(library: library, fragment: "screen_fragment")
            placeholderPipeline = try makePipeline(library: library, fragment: "placeholder_fragment")
        } catch { NSLog("GlassesRenderer: pipeline rebuild failed: \(error)") }
        msaaColorTexture = nil
        depthTextureMS = nil
    }

    private func makePipeline(library: MTLLibrary, fragment: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screen_vertex")
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.depthAttachmentPixelFormat = Self.depthFormat
        desc.rasterSampleCount = sampleCount // MSAA
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// MSAA color target (memoryless on Apple GPUs — free bandwidth-wise) and a matching
    /// multisample depth buffer; both rebuilt when the drawable size changes.
    private func msaaTextures(width: Int, height: Int) -> (color: MTLTexture, depth: MTLTexture)? {
        let w = max(1, width), h = max(1, height)
        if let c = msaaColorTexture, let d = depthTextureMS, c.width == w, c.height == h {
            return (c, d)
        }
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        colorDesc.textureType = .type2DMultisample
        colorDesc.sampleCount = sampleCount
        colorDesc.usage = .renderTarget
        colorDesc.storageMode = .memoryless

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: w, height: h, mipmapped: false)
        depthDesc.textureType = .type2DMultisample
        depthDesc.sampleCount = sampleCount
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .memoryless

        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else { return nil }
        msaaColorTexture = color
        depthTextureMS = depth
        return (color, depth)
    }

    /// Single-sample depth (for MSAA off).
    private func singleDepth(width: Int, height: Int) -> MTLTexture? {
        let w = max(1, width), h = max(1, height)
        if let d = depthTextureSingle, d.width == w, d.height == h { return d }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: w, height: h, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        depthTextureSingle = device.makeTexture(descriptor: desc)
        return depthTextureSingle
    }

    /// When sharpening, blit each screen's capture into a mipmapped texture and generate
    /// mips so anisotropic sampling can smooth minified/angled content (e.g. small text).
    private func prepareSharpTextures(_ screens: [SceneScreen],
                                      commandBuffer: MTLCommandBuffer) -> [UUID: MTLTexture] {
        guard sharpenAnisotropy > 1 else { return [:] }
        var result: [UUID: MTLTexture] = [:]
        var blit: MTLBlitCommandEncoder?
        for s in screens {
            guard let src = s.textureProvider(), src.width > 0, src.height > 0 else { continue }
            guard let target = mipTarget(for: s.id, width: src.width, height: src.height) else { continue }
            result[s.id] = target
            // Skip the blit + mipmap regeneration when this screen's capture texture is the
            // same object we last mipped (no new 30fps frame since): the mips are still valid.
            let version = ObjectIdentifier(src)
            if mipSourceVersion[s.id] == version { continue }

            if blit == nil { blit = commandBuffer.makeBlitCommandEncoder() }
            guard let blit else { continue }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: target)
            mipSourceVersion[s.id] = version
        }
        blit?.endEncoding()
        return result
    }

    private func mipTarget(for id: UUID, width: Int, height: Int) -> MTLTexture? {
        if let t = mipTargets[id], t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        mipTargets[id] = t
        mipSourceVersion[id] = nil // fresh target: force a re-blit next frame
        return t
    }

    // MARK: Scene

    public func setScreens(_ newScreens: [SceneScreen]) {
        lock.lock()
        screens = newScreens
        cachedVertexBuffers.removeAll()
        lock.unlock()
        mipTargets.removeAll()
        mipSourceVersion.removeAll()
        canvasAtlases.removeAll()
    }

    /// Atlas render target for a wide-canvas screen (recreated on size change). Mipmapped so
    /// anisotropic sharpening has lower levels to sample; storage is private (GPU-only).
    private func canvasAtlas(for id: UUID, width: Int, height: Int) -> MTLTexture? {
        let w = max(1, width), h = max(1, height)
        if let t = canvasAtlases[id], t.width == w, t.height == h { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        canvasAtlases[id] = t
        return t
    }

    /// Composite each wide-canvas screen's live tiles into its atlas: one render pass per
    /// canvas, drawing every tile's source into its destination sub-rect (scaled to match the
    /// FOV-derived canvas density). Runs before the scene pass so the atlas is ready to sample.
    private func compositeCanvases(_ screens: [SceneScreen], commandBuffer: MTLCommandBuffer) {
        guard let pipe = downscalePipeline else { return }
        for s in screens where s.isCanvas {
            guard let atlas = canvasAtlas(for: s.id, width: s.canvasPixelWidth,
                                          height: s.canvasPixelHeight) else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = atlas
            pass.colorAttachments[0].loadAction = .clear      // gaps between screens stay black
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.setRenderPipelineState(pipe)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            for tile in s.canvasTiles {
                guard let src = tile.sourceProvider(), src.width > 0, src.height > 0 else { continue }
                enc.setViewport(MTLViewport(originX: Double(tile.destX), originY: Double(tile.destY),
                                            width: Double(tile.destWidth), height: Double(tile.destHeight),
                                            znear: 0, zfar: 1))
                enc.setFragmentTexture(src, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            if sharpenAnisotropy > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: atlas)
                blit.endEncoding()
            }
        }
    }

    // MARK: Output window lifecycle

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// Keep the output window glued to its target display: creating/removing virtual
    /// displays re-arranges the global screen layout and moves every origin around.
    @MainActor
    private func repinToTargetScreen() {
        guard let window, targetDisplayID != 0,
              let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == targetDisplayID })
        else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        // The display's resolution may have changed (e.g. mono ↔ SBS 3840×1080);
        // keep the Metal layer's backing store matched to it.
        let scale = screen.backingScaleFactor
        let wanted = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        if metalLayer.drawableSize != wanted {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = wanted
        }
    }

    @MainActor
    public func startOutput(on screen: NSScreen) {
        stopOutput()
        targetDisplayID = Self.displayID(of: screen)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repinToTargetScreen() }
        }

        // contentRect is relative to `screen`'s own origin, so use a zero-origin rect;
        // then pin the window to the screen's global frame explicitly.
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                           styleMask: .borderless,
                           backing: .buffered, defer: false, screen: screen)
        win.setFrame(screen.frame, display: true)
        win.level = .screenSaver
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.fullScreenPrimary, .stationary]

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = true   // vsync off was tested and made jumping worse
        metalLayer.maximumDrawableCount = 3
        let scale = screen.backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: screen.frame.width * scale,
                                         height: screen.frame.height * scale)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = metalLayer
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        window = win
        NSLog("GlassesRenderer: target screen '%@' frame=%@; window frame=%@; window.screen='%@'",
              screen.localizedName, NSStringFromRect(screen.frame),
              NSStringFromRect(win.frame), win.screen?.localizedName ?? "nil")
        if win.screen != screen {
            // Window Server placed us elsewhere — force the frame again.
            win.setFrame(screen.frame, display: true)
            NSLog("GlassesRenderer: corrected to '%@', now on '%@'",
                  NSStringFromRect(win.frame), win.screen?.localizedName ?? "nil")
        }

        // The display arrangement can keep settling for a few seconds after virtual
        // displays are added; re-pin until the window is solidly on the target screen.
        for delay in [0.5, 1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.repinToTargetScreen()
            }
        }

        // Run the display link on a dedicated thread so heavy main-thread UI work (e.g. the
        // control-panel SwiftUI updates) can't stall rendering and cause head-tracking jumps.
        // Drive rendering from the main run loop. (A dedicated render thread was tried but a
        // manually-run run loop serviced the display link with ~50ms stalls — dropped frames
        // that read as a head-tracking "snap". GPU time is <1ms, so main-loop pacing is fine.)
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor
    public func stopOutput() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        targetDisplayID = 0
        displayLink?.isPaused = true
        displayLink?.remove(from: .main, forMode: .common)
        displayLink?.invalidate()
        displayLink = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
    }

    public var isRunning: Bool { displayLink != nil }

    /// Diagnostics: the output window's current frame and the screen AppKit thinks it's on.
    @MainActor
    public var outputWindowInfo: (frame: CGRect, screenName: String)? {
        guard let window else { return nil }
        return (window.frame, window.screen?.localizedName ?? "none")
    }

    /// Move the output window to an absolute global position (debug positioning).
    @MainActor
    public func moveOutput(to origin: CGPoint) {
        window?.setFrameOrigin(origin)
    }

    // MARK: Rendering

    struct Uniforms {
        var viewProjection: simd_float4x4
    }

    private func currentOrientation() -> simd_quatf {
        if let fake = fakePose { return fake }
        return poseStore.latest().predicted(by: predictionLead)
    }

    /// View matrix for one eye. `eyeOffsetX` is the eye's position in head space
    /// (−ipd/2 = left, +ipd/2 = right, 0 = mono cyclopean view).
    private func viewMatrix(orientation: simd_quatf, eyeOffsetX: Float) -> simd_float4x4 {
        let rotation = simd_float4x4(orientation.inverse)
        guard eyeOffsetX != 0 else { return rotation }
        var translate = matrix_identity_float4x4
        translate.columns.3.x = -eyeOffsetX // world shifts opposite the camera
        return translate * rotation
    }

    private func projectionMatrix(aspect: Float) -> simd_float4x4 {
        // XREAL Air 2: ~46° diagonal FOV. Vertical FOV ≈ 23° for 16:9.
        let fovY: Float = 23.0 * .pi / 180
        let near: Float = 0.1, far: Float = 100
        let yScale = 1 / tanf(fovY / 2)
        let xScale = yScale / aspect
        let zRange = far - near
        return simd_float4x4(columns: (
            SIMD4(xScale, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, -(far + near) / zRange, -1),
            SIMD4(0, 0, -2 * far * near / zRange, 0)
        ))
    }

    func renderFrame(drawable: CAMetalDrawable) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Frame-pacing diagnostics: a CPU interval well over the refresh period means a
        // dropped frame (the head-tracking "snap"); GPU time over budget is the usual cause.
        let frameStart = CACurrentMediaTime()
        if frameLoggingEnabled, lastFrameStart > 0 {
            let interval = (frameStart - lastFrameStart) * 1000
            if interval > 12 {
                droppedFrames += 1
                commandBuffer.addCompletedHandler { [weak self] cb in
                    let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    self?.frameLog?(String(format: "frame gap=%.1fms gpu=%.1fms drops=%d",
                                           interval, gpuMs, self?.droppedFrames ?? 0))
                }
            }
        }
        lastFrameStart = frameStart

        lock.lock()
        let currentScreens = screens
        lock.unlock()

        // Wide-canvas atlases and mipmap blits (if sharpening) must run before the scene pass.
        compositeCanvases(currentScreens, commandBuffer: commandBuffer)
        let sharpTextures = prepareSharpTextures(currentScreens, commandBuffer: commandBuffer)

        let outW = drawable.texture.width, outH = drawable.texture.height
        let supersample = renderScale > 1.001
        // Scene render dimensions (supersampled when render scale > 1).
        let rw = supersample ? Int((Double(outW) * renderScale).rounded()) : outW
        let rh = supersample ? Int((Double(outH) * renderScale).rounded()) : outH

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        // Where the (single-sample) scene ends up: the drawable directly, or an offscreen
        // buffer we then blit into the drawable. We force the offscreen path when supersampling
        // OR when a debug dump is pending (the drawable is framebufferOnly and can't be read).
        let dumpDir = debugDumpDir
        let offscreen = supersample || dumpDir != nil
        let sceneTarget: MTLTexture
        if offscreen {
            guard let ss = ssColor(width: rw, height: rh) else { return }
            sceneTarget = ss
        } else {
            sceneTarget = drawable.texture
        }

        if sampleCount > 1 {
            guard let ms = msaaTextures(width: rw, height: rh) else { return }
            pass.colorAttachments[0].texture = ms.color
            pass.colorAttachments[0].resolveTexture = sceneTarget
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = ms.depth
        } else {
            pass.colorAttachments[0].texture = sceneTarget
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = singleDepth(width: rw, height: rh)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setDepthStencilState(depthState)
        encodeScene(encoder: encoder, width: Double(rw), height: Double(rh),
                    screens: currentScreens, sharp: sharpTextures)
        encoder.endEncoding()

        // Blit the offscreen scene into the drawable (supersample downscale, or debug-dump path).
        if offscreen, let dp = downscalePipeline {
            let dpass = MTLRenderPassDescriptor()
            dpass.colorAttachments[0].texture = drawable.texture
            dpass.colorAttachments[0].loadAction = .dontCare
            dpass.colorAttachments[0].storeAction = .store
            if let denc = commandBuffer.makeRenderCommandEncoder(descriptor: dpass) {
                denc.setRenderPipelineState(dp)
                denc.setFragmentTexture(sceneTarget, index: 0)
                denc.setFragmentSamplerState(linearSampler, index: 0)
                denc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                denc.endEncoding()
            }
        }

        drawHelpOverlay(commandBuffer: commandBuffer, drawable: drawable)

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Debug dump: wait for the frame to finish, then write the merged atlas (stage2) and the
        // final curved scene (stage3) to disk. Cleared so it only fires once per request.
        if let dumpDir {
            commandBuffer.waitUntilCompleted()
            var written: [String] = []
            for s in currentScreens where s.isCanvas {
                if let atlas = canvasAtlases[s.id],
                   dumpTexture(atlas, to: dumpDir.appendingPathComponent("stage2.jpg"),
                               markers: debugStage2Markers) {
                    written.append("stage2.jpg (\(atlas.width)×\(atlas.height) merged flat canvas; "
                        + "red=wrap centre green=FOV centre blue=glasses centre)")
                }
            }
            if dumpTexture(sceneTarget, to: dumpDir.appendingPathComponent("stage3.jpg")) {
                written.append("stage3.jpg (\(sceneTarget.width)×\(sceneTarget.height) final curved frame)")
            }
            debugDumpDir = nil
            debugStage2Markers = []
            onDebugDumpComplete?(written)
        }

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSUpdate >= 1.0 {
            framesPerSecond = Double(frameCount) / (now - lastFPSUpdate)
            frameCount = 0
            lastFPSUpdate = now
        }
    }

    /// Draw the help HUD as a centered, alpha-blended quad on top of the final frame
    /// (in each eye half when stereo), so it appears above everything.
    private func drawHelpOverlay(commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) {
        guard showHelp, let tex = helpTexture, let pipe = overlayPipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setFragmentSamplerState(linearSampler, index: 0)
        enc.setFragmentTexture(tex, index: 0)

        let W = drawable.texture.width, H = drawable.texture.height
        let regions: [(x: Int, w: Int)] = stereoEnabled ? [(0, W / 2), (W / 2, W / 2)] : [(0, W)]
        let texAspect = Float(tex.width) / Float(max(1, tex.height))
        for region in regions {
            let regionW = Float(region.w), regionH = Float(H)
            var panelH = regionH * 0.6   // ~15% smaller than before
            var panelW = panelH * texAspect
            if panelW > regionW * 0.8 { panelW = regionW * 0.8; panelH = panelW / texAspect }
            let nw = panelW / regionW * 2, nh = panelH / regionH * 2
            enc.setViewport(MTLViewport(originX: Double(region.x), originY: 0,
                                        width: Double(region.w), height: Double(H),
                                        znear: 0, zfar: 1))
            var verts = [
                OverlayVertex(position: SIMD2(-nw/2,  nh/2), uv: SIMD2(0, 0)),
                OverlayVertex(position: SIMD2( nw/2,  nh/2), uv: SIMD2(1, 0)),
                OverlayVertex(position: SIMD2(-nw/2, -nh/2), uv: SIMD2(0, 1)),
                OverlayVertex(position: SIMD2( nw/2,  nh/2), uv: SIMD2(1, 0)),
                OverlayVertex(position: SIMD2( nw/2, -nh/2), uv: SIMD2(1, 1)),
                OverlayVertex(position: SIMD2(-nw/2, -nh/2), uv: SIMD2(0, 1)),
            ]
            enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<OverlayVertex>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
    }

    /// Draw the AR scene (mono or stereo) into the current encoder at the given target size.
    /// Anchored screens use the head rotation; floating (head-locked) screens skip it so they
    /// stay fixed in the field of view.
    private func encodeScene(encoder: MTLRenderCommandEncoder, width: Double, height: Double,
                             screens: [SceneScreen], sharp: [UUID: MTLTexture]) {
        let orientation = currentOrientation()
        let anchored = screens.filter { !$0.headLocked }
        let floating = screens.filter { $0.headLocked }

        func drawEye(viewportX: Double, eyeWidth: Double, eyeOffset: Float) {
            encoder.setViewport(MTLViewport(originX: viewportX, originY: 0,
                                            width: eyeWidth, height: height, znear: 0, zfar: 1))
            let projection = projectionMatrix(aspect: Float(eyeWidth / max(1, height)))
            // Anchored: include head rotation. Floating: identity rotation (just the eye offset).
            let anchoredVP = projection * viewMatrix(orientation: orientation, eyeOffsetX: eyeOffset)
            let floatingVP = projection * viewMatrix(orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                     eyeOffsetX: eyeOffset)
            if !anchored.isEmpty { drawScreens(anchored, viewProjection: anchoredVP, encoder: encoder, sharp: sharp) }
            if !floating.isEmpty { drawScreens(floating, viewProjection: floatingVP, encoder: encoder, sharp: sharp) }
        }

        if stereoEnabled {
            let eyeWidth = width / 2
            drawEye(viewportX: 0, eyeWidth: eyeWidth, eyeOffset: -ipd / 2)
            drawEye(viewportX: eyeWidth, eyeWidth: eyeWidth, eyeOffset: ipd / 2)
        } else {
            drawEye(viewportX: 0, eyeWidth: width, eyeOffset: 0)
        }
    }

    private func drawScreens(_ screens: [SceneScreen], viewProjection: simd_float4x4,
                             encoder: MTLRenderCommandEncoder, sharp: [UUID: MTLTexture]) {
        var uniforms = Uniforms(viewProjection: viewProjection)
        for screen in screens {
            let geometry = vertexBuffer(for: screen)
            encoder.setVertexBuffer(geometry.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            if screen.isCanvas {
                // Wide canvas: sample the pre-composited atlas (mipmapped when sharpening).
                if let atlas = canvasAtlases[screen.id] {
                    encoder.setRenderPipelineState(screenPipeline)
                    encoder.setFragmentTexture(atlas, index: 0)
                    encoder.setFragmentSamplerState(sharpenAnisotropy > 1 ? sharpSampler : linearSampler, index: 0)
                } else {
                    encoder.setRenderPipelineState(placeholderPipeline)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.count)
                continue
            }
            if let mipped = sharp[screen.id] {
                encoder.setRenderPipelineState(screenPipeline)
                encoder.setFragmentTexture(mipped, index: 0)
                encoder.setFragmentSamplerState(sharpSampler, index: 0)
            } else if let texture = screen.textureProvider() {
                encoder.setRenderPipelineState(screenPipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(linearSampler, index: 0)
            } else {
                encoder.setRenderPipelineState(placeholderPipeline)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.count)
        }
    }

    private func vertexBuffer(for screen: SceneScreen) -> (buffer: MTLBuffer, count: Int) {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedVertexBuffers[screen.id] { return cached }
        let verts = screen.vertices()
        let buffer = device.makeBuffer(bytes: verts,
                                       length: verts.count * MemoryLayout<SceneScreen.Vertex>.stride,
                                       options: .storageModeShared)!
        let entry = (buffer, verts.count)
        cachedVertexBuffers[screen.id] = entry
        return entry
    }
}

extension GlassesRenderer: CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(_ link: CAMetalDisplayLink,
                                 needsUpdate update: CAMetalDisplayLink.Update) {
        renderFrame(drawable: update.drawable)
    }
}
