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

    private var screenPipeline: MTLRenderPipelineState!
    private var placeholderPipeline: MTLRenderPipelineState!

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
    public var predictionLead: Float = 0.018

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
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            screenPipeline = try makePipeline(library: library, fragment: "screen_fragment")
            placeholderPipeline = try makePipeline(library: library, fragment: "placeholder_fragment")
        } catch {
            NSLog("GlassesRenderer: shader compile failed: \(error)")
            return nil
        }
    }

    private func makePipeline(library: MTLLibrary, fragment: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screen_vertex")
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: Scene

    public func setScreens(_ newScreens: [SceneScreen]) {
        lock.lock()
        screens = newScreens
        cachedVertexBuffers.removeAll()
        lock.unlock()
    }

    // MARK: Output window lifecycle

    @MainActor
    public func startOutput(on screen: NSScreen) {
        stopOutput()

        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                           backing: .buffered, defer: false, screen: screen)
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

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer = metalLayer
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        window = win

        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor
    public func stopOutput() {
        displayLink?.isPaused = true
        displayLink?.remove(from: .main, forMode: .common)
        displayLink?.invalidate()
        displayLink = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
    }

    public var isRunning: Bool { displayLink != nil }

    // MARK: Rendering

    struct Uniforms {
        var viewProjection: simd_float4x4
    }

    private func currentViewMatrix() -> simd_float4x4 {
        let orientation: simd_quatf
        if let fake = fakePose {
            orientation = fake
        } else {
            let pose = poseStore.latest()
            orientation = pose.predicted(by: predictionLead)
        }
        // View = inverse of head rotation (3DoF: rotation only).
        return simd_float4x4(orientation.inverse)
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
        let aspect = Float(metalLayer.drawableSize.width / max(1, metalLayer.drawableSize.height))
        var uniforms = Uniforms(viewProjection: projectionMatrix(aspect: aspect) * currentViewMatrix())

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        lock.lock()
        let currentScreens = screens
        lock.unlock()

        for screen in currentScreens {
            let geometry = vertexBuffer(for: screen)
            encoder.setVertexBuffer(geometry.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            if let texture = screen.textureProvider() {
                encoder.setRenderPipelineState(screenPipeline)
                encoder.setFragmentTexture(texture, index: 0)
            } else {
                encoder.setRenderPipelineState(placeholderPipeline)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.count)
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
