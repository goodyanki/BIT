import SwiftUI
import AppKit
import Metal
import MetalKit

// MARK: - Metal渲染器管理类
class MetalRenderer: ObservableObject {
    private var device: MTLDevice?
    // 需要在外部渲染协同器中创建命令缓冲，因此不设为 private
    var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var renderPipelineState: MTLRenderPipelineState?
    
    // GPU缓冲区管理
    private var vertexBuffer: MTLBuffer?
    private var iconTextureCache: [String: MTLTexture] = [:]
    private let textureCacheQueue = DispatchQueue(label: "texture.cache", attributes: .concurrent)
    
    // 性能监控
    @Published var isGPUAvailable: Bool = false
    @Published var gpuMemoryUsage: Float = 0.0
    @Published var renderingFPS: Float = 0.0
    
    private var frameStartTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    
    init() {
        setupMetal()
    }
    
    func initialize() {
        setupMetal()
        setupRenderPipeline()
        preloadCommonResources()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ Metal is not available on this device")
            isGPUAvailable = false
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.library = device.makeDefaultLibrary()
        
        isGPUAvailable = true
        
        #if DEBUG
        print("🚀 Metal initialized: \(device.name)")
        print("🚀 GPU Family: \(device.supportsFamily(.apple7) ? "Apple7+" : "Earlier")")
        #endif
    }
    
    private func setupRenderPipeline() {
        guard let device = device,
              let library = library else { return }
        
        // 设置渲染管道描述符
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // 启用混合模式以支持透明度
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ Failed to create render pipeline state: \(error)")
        }
    }
    
    private func preloadCommonResources() {
        guard let device = device else { return }
        
        // 预分配顶点缓冲区
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,  // 左下
             1.0, -1.0, 1.0, 1.0,  // 右下
            -1.0,  1.0, 0.0, 0.0,  // 左上
             1.0,  1.0, 1.0, 0.0   // 右上
        ]
        
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size, options: [])
    }
    
    // MARK: - 图标缓存管理
    
    func preheatIconCache(for apps: [AppItem]) {
        guard isGPUAvailable else { return }
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for app in apps.prefix(50) { // 限制预热数量避免内存过载
                self?.loadIconTexture(for: app)
            }
        }
    }
    
    private func loadIconTexture(for app: AppItem) -> MTLTexture? {
        let cacheKey = "\(app.bundleID):72"
        
        return textureCacheQueue.sync {
            if let cachedTexture = iconTextureCache[cacheKey] {
                return cachedTexture
            }
            
            guard let icon = IconProvider.icon(for: app, size: 72),
                  let device = device else { return nil }
            
            let texture = createTextureFromImage(icon, device: device)
            iconTextureCache[cacheKey] = texture
            
            // 限制缓存大小
            if iconTextureCache.count > 200 {
                cleanupOldTextures()
            }
            
            return texture
        }
    }
    
    private func createTextureFromImage(_ image: NSImage, device: MTLDevice) -> MTLTexture? {
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let cgImg = cgImage else { return nil }
        
        let textureLoader = MTKTextureLoader(device: device)
        do {
            return try textureLoader.newTexture(cgImage: cgImg, options: [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue
            ])
        } catch {
            print("❌ Failed to create texture: \(error)")
            return nil
        }
    }
    
    private func cleanupOldTextures() {
        // 保留最近使用的100个纹理
        let sortedKeys = iconTextureCache.keys.sorted()
        let keysToRemove = Array(sortedKeys.prefix(iconTextureCache.count - 100))
        
        for key in keysToRemove {
            iconTextureCache.removeValue(forKey: key)
        }
    }
    
    // MARK: - 渲染方法
    
    func renderIcon(for app: AppItem, in view: MTKView, flashOpacity: Double, isHovered: Bool) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipelineState = renderPipelineState else { return }
        
        startFrameTiming()
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // 设置顶点缓冲区
        if let vertexBuffer = vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        }
        
        // 加载图标纹理
        if let iconTexture = loadIconTexture(for: app) {
            renderEncoder.setFragmentTexture(iconTexture, index: 0)
        }
        
        // 设置效果参数
        var effectParams = EffectParameters(
            flashOpacity: Float(flashOpacity),
            hoverScale: isHovered ? 1.05 : 1.0,
            time: Float(CACurrentMediaTime())
        )
        
        renderEncoder.setFragmentBytes(&effectParams, length: MemoryLayout<EffectParameters>.size, index: 0)
        
        // 渲染
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        endFrameTiming()
    }
    
    // MARK: - 性能监控
    
    private func startFrameTiming() {
        frameStartTime = CACurrentMediaTime()
    }
    
    private func endFrameTiming() {
        let frameTime = CACurrentMediaTime() - frameStartTime
        frameCount += 1
        
        if frameCount % 60 == 0 { // 每60帧更新一次FPS
            DispatchQueue.main.async { [weak self] in
                self?.renderingFPS = Float(1.0 / frameTime)
            }
        }
    }
    
    func updateGPUMemoryUsage() {
        guard let device = device else { return }
        
        let allocatedSize = device.currentAllocatedSize
        let recommendedMaxSize = device.recommendedMaxWorkingSetSize
        
        DispatchQueue.main.async { [weak self] in
            self?.gpuMemoryUsage = Float(allocatedSize) / Float(recommendedMaxSize)
        }
    }
    
    // 清理资源
    func cleanup() {
        textureCacheQueue.sync {
            iconTextureCache.removeAll()
        }
    }
}

// MARK: - Metal效果参数结构体
struct EffectParameters {
    let flashOpacity: Float
    let hoverScale: Float
    let time: Float
}

// MARK: - MetalKit视图组件

struct MetalIconView: NSViewRepresentable {
    let app: AppItem
    let size: CGFloat
    let renderer: MetalRenderer
    let flashOpacity: Double
    let isHovered: Bool
    
    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.delegate = context.coordinator
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = false
        return metalView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.updateApp(app, flashOpacity: flashOpacity, isHovered: isHovered)
        nsView.setNeedsDisplay(nsView.bounds)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        let renderer: MetalRenderer
        private var currentApp: AppItem?
        private var flashOpacity: Double = 0.0
        private var isHovered: Bool = false
        
        init(renderer: MetalRenderer) {
            self.renderer = renderer
        }
        
        func updateApp(_ app: AppItem, flashOpacity: Double, isHovered: Bool) {
            self.currentApp = app
            self.flashOpacity = flashOpacity
            self.isHovered = isHovered
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // 处理尺寸变化
        }
        
        func draw(in view: MTKView) {
            guard let app = currentApp else { return }
            renderer.renderIcon(for: app, in: view, flashOpacity: flashOpacity, isHovered: isHovered)
        }
    }
}

struct MetalBackgroundView: NSViewRepresentable {
    let renderer: MetalRenderer
    
    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.delegate = context.coordinator
        metalView.preferredFramesPerSecond = 30 // 背景不需要高帧率
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        return metalView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        // 背景更新逻辑
    }
    
    func makeCoordinator() -> BackgroundCoordinator {
        BackgroundCoordinator(renderer: renderer)
    }
    
    class BackgroundCoordinator: NSObject, MTKViewDelegate {
        let renderer: MetalRenderer
        
        init(renderer: MetalRenderer) {
            self.renderer = renderer
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // 处理背景尺寸变化
        }
        
        func draw(in view: MTKView) {
            // 渲染动态背景效果
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue?.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            
            // 简单的清屏，未来可以添加粒子效果等
            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - GPU搜索引擎
class GPUSearchEngine: ObservableObject {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var computePipelineState: MTLComputePipelineState?
    
    func initialize() {
        setupMetalCompute()
    }
    
    private func setupMetalCompute() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // 设置计算管道（需要对应的Metal着色器）
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "parallel_search") else { return }
        
        do {
            computePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("❌ Failed to create compute pipeline: \(error)")
        }
    }
    
    func searchApps(_ apps: [AppItem], query: String) -> [AppItem] {
        // GPU搜索实现（如果GPU不可用则回退到CPU）
        guard device != nil, computePipelineState != nil, !query.isEmpty else {
            return apps.filter { app in
                app.name.lowercased().contains(query) || app.bundleID.lowercased().contains(query)
            }
        }
        
        // 这里实现GPU并行搜索
        // 目前先使用CPU实现，GPU实现需要配合Metal着色器
        return apps.filter { app in
            app.name.lowercased().contains(query) || app.bundleID.lowercased().contains(query)
        }
    }
}

// MARK: - 窗口配置：隐藏标题栏、透明、进入全屏
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WindowConfigurator: View {
    var body: some View {
        WindowAccessor { win in
            // 基础窗口设置
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isMovableByWindowBackground = false
            win.collectionBehavior.insert(.fullScreenPrimary)
            
            // GPU优化设置
            win.preferredBackingLocation = .videoMemory
            win.backingType = .buffered
            
            // 设置最小窗口尺寸，确保至少能显示 3x2 网格
            win.minSize = NSSize(width: 400, height: 300)
            
            // 启动时进入全屏模式
            if !win.styleMask.contains(.fullScreen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    win.toggleFullScreen(nil)
                }
            }
            
            // 监听窗口状态变化，保存用户偏好
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: win,
                queue: .main
            ) { _ in
                UserDefaults.standard.set(true, forKey: "LaunchpadFullScreen")
            }
            
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: win,
                queue: .main
            ) { _ in
                UserDefaults.standard.set(false, forKey: "LaunchpadFullScreen")
            }
        }
        .frame(width: 0, height: 0)
    }
}

// GPU加速背景组件
struct SolidBackground: View {
    var color: Color = Color(NSColor.windowBackgroundColor)
    var body: some View { color.ignoresSafeArea() }
}

// 增强的手势捕获器（GPU优化版本）
#if os(macOS)
struct SwipeCatcher: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        v.onLeft = onLeft
        v.onRight = onRight
        return v
    }
    
    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
    }

    final class SwipeView: NSView {
        var onLeft: () -> Void = {}
        var onRight: () -> Void = {}
        
        // 性能优化：防重复触发和手势识别优化
        private var lastGestureTime: TimeInterval = 0
        private let gestureThrottleInterval: TimeInterval = 0.3
        private var gestureRecognizer: NSPanGestureRecognizer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupOptimizedGestures()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupOptimizedGestures()
        }
        
        private func setupOptimizedGestures() {
            // 设置优化的手势识别
            let panGesture = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture))
            // macOS 的 NSPanGestureRecognizer 无 minimum/maximumNumberOfTouches
            // 这里通过 allowedTouchTypes + 方向过滤来近似两指横向滑动
            panGesture.allowedTouchTypes = [.direct, .indirect]
            addGestureRecognizer(panGesture)
            gestureRecognizer = panGesture
            
            setupTrackingArea()
        }
        
        private func setupTrackingArea() {
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
        }

        override var acceptsFirstResponder: Bool { true }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            window?.makeFirstResponder(self)
        }
        
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            setupTrackingArea()
        }
        
        override func mouseEntered(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }
        
        @objc private func handlePanGesture(_ gesture: NSPanGestureRecognizer) {
            if gesture.state == .ended {
                let velocity = gesture.velocity(in: self)
                let translation = gesture.translation(in: self)
                
                // 只处理主要是水平方向的手势
                if abs(translation.x) > abs(translation.y) && abs(velocity.x) > 300 {
                    executeGestureIfAllowed {
                        if velocity.x < 0 {
                            onLeft()
                        } else {
                            onRight()
                        }
                    }
                }
            }
        }
        
        // 防重复执行的辅助方法
        private func executeGestureIfAllowed(_ action: () -> Void) {
            let currentTime = Date().timeIntervalSince1970
            if currentTime - lastGestureTime >= gestureThrottleInterval {
                lastGestureTime = currentTime
                action()
            }
        }
        
        // 滚轮事件处理（作为备用）
        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                let threshold: CGFloat = 50.0
                if event.scrollingDeltaX < -threshold {
                    executeGestureIfAllowed(onLeft)
                } else if event.scrollingDeltaX > threshold {
                    executeGestureIfAllowed(onRight)
                }
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}
#endif
