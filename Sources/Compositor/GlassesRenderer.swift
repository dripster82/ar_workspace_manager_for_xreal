import AppKit
import GlassesDriver
import Metal
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

    private let poseStore: PoseStore
    private let lock = NSLock()
    private var screens: [SceneScreen] = []
    private var cachedVertexBuffers: [UUID: (buffer: MTLBuffer, count: Int)] = [:]

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

    public private(set) var framesPerSecond: Double = 0
    private var frameCount = 0
    private var lastFPSUpdate = CACurrentMediaTime()

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
        if valid == 1 { mipTargets.removeAll() }
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
        guard sharpenAnisotropy > 1, let blit = commandBuffer.makeBlitCommandEncoder() else { return [:] }
        var result: [UUID: MTLTexture] = [:]
        for s in screens {
            guard let src = s.textureProvider(), src.width > 0, src.height > 0 else { continue }
            guard let target = mipTarget(for: s.id, width: src.width, height: src.height) else { continue }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: target)
            result[s.id] = target
        }
        blit.endEncoding()
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
        return t
    }

    // MARK: Scene

    public func setScreens(_ newScreens: [SceneScreen]) {
        lock.lock()
        screens = newScreens
        cachedVertexBuffers.removeAll()
        lock.unlock()
        mipTargets.removeAll()
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
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 2
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
        let fullWidth = Double(metalLayer.drawableSize.width)
        let height = Double(metalLayer.drawableSize.height)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        let currentScreens = screens
        lock.unlock()

        // Mipmap blits (if sharpening) must run before the render pass on the same buffer.
        let sharpTextures = prepareSharpTextures(currentScreens, commandBuffer: commandBuffer)

        let w = drawable.texture.width, h = drawable.texture.height
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0
        if sampleCount > 1 {
            guard let ms = msaaTextures(width: w, height: h) else { return }
            pass.colorAttachments[0].texture = ms.color
            pass.colorAttachments[0].resolveTexture = drawable.texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = ms.depth
        } else {
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = singleDepth(width: w, height: h)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setDepthStencilState(depthState)

        let orientation = currentOrientation()

        if stereoEnabled {
            // Two viewports across a 3840×1080 frame; each eye is half-width, 16:9.
            let eyeWidth = fullWidth / 2
            let aspect = Float(eyeWidth / max(1, height))
            let projection = projectionMatrix(aspect: aspect)
            let eyes: [(x: Double, offset: Float)] = [(0, -ipd / 2), (eyeWidth, ipd / 2)]
            for eye in eyes {
                encoder.setViewport(MTLViewport(originX: eye.x, originY: 0,
                                                width: eyeWidth, height: height,
                                                znear: 0, zfar: 1))
                let vp = projection * viewMatrix(orientation: orientation, eyeOffsetX: eye.offset)
                drawScreens(currentScreens, viewProjection: vp, encoder: encoder, sharp: sharpTextures)
            }
        } else {
            let aspect = Float(fullWidth / max(1, height))
            let vp = projectionMatrix(aspect: aspect) * viewMatrix(orientation: orientation, eyeOffsetX: 0)
            drawScreens(currentScreens, viewProjection: vp, encoder: encoder, sharp: sharpTextures)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSUpdate >= 1.0 {
            framesPerSecond = Double(frameCount) / (now - lastFPSUpdate)
            frameCount = 0
            lastFPSUpdate = now
        }
    }

    private func drawScreens(_ screens: [SceneScreen], viewProjection: simd_float4x4,
                             encoder: MTLRenderCommandEncoder, sharp: [UUID: MTLTexture]) {
        var uniforms = Uniforms(viewProjection: viewProjection)
        for screen in screens {
            let geometry = vertexBuffer(for: screen)
            encoder.setVertexBuffer(geometry.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
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
