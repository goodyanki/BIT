import Metal
import MetalKit
import AppKit
import SwiftUI

// MARK: - Metal渲染器核心类
class MetalRenderer: ObservableObject {
    // Metal设备和资源
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    
    // 渲染管道
    private var iconRenderPipeline: MTLRenderPipelineState?
    private var backgroundRenderPipeline: MTLRenderPipelineState?
    private var effectRenderPipeline: MTLRenderPipelineState?
    
    // 计算管道（用于并行处理）
    private var textureProcessPipeline: MTLComputePipelineState?
    private var searchComputePipeline: MTLComputePipelineState?
    
    // GPU缓冲区和纹理管理
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var iconTextureAtlas: MTLTexture?
    private var effectTextures: [String: MTLTexture] = [:]
    
    // 缓存系统
    private var iconTextureCache: [String: CachedIconTexture] = [:]
    private let textureCacheQueue = DispatchQueue(label: "metal.texture.cache", attributes: .concurrent)
    private let maxCacheSize = 200
    private let maxGPUMemory = 256 * 1024 * 1024 // 256MB
    
    // 性能监控
    @Published var isGPUAvailable: Bool = false
    @Published var gpuMemoryUsage: Float = 0.0
    @Published var renderingFPS: Float = 0.0
    @Published var currentGPUMemory: Int = 0
    
    // 帧率计算
    private var frameStartTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var fpsUpdateInterval: Int = 60
    private var lastFPSUpdate: CFTimeInterval = 0
    
    // 渲染统计
    private var drawCallCount: Int = 0
    private var textureSwapCount: Int = 0
    
    init() {
        initializeMetal()
    }
    
    // MARK: - Metal初始化
    
    func initialize() {
        initializeMetal()
        setupRenderPipelines()
        setupComputePipelines()
        createBuffers()
        preloadCommonResources()
        startPerformanceMonitoring()
    }
    
    private func initializeMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ Metal is not available on this device")
            isGPUAvailable = false
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // 尝试加载自定义着色器库
        if let path = Bundle.main.path(forResource: "Shaders", ofType: "metallib"),
           let library = try? device.makeLibrary(filepath: path) {
            self.library = library
        } else {
            // 回退到默认库
            self.library = device.makeDefaultLibrary()
        }
        
        isGPUAvailable = true
        
        #if DEBUG
        print("🚀 Metal initialized successfully")
        print("🚀 Device: \(device.name)")
        print("🚀 Max threads per threadgroup: \(device.maxThreadsPerThreadgroup)")
        print("🚀 Supports family Apple7: \(device.supportsFamily(.apple7))")
        print("🚀 Max buffer length: \(device.maxBufferLength / (1024*1024))MB")
        #endif
    }
    
    private func setupRenderPipelines() {
        guard let device = device, let library = library else { return }
        
        setupIconRenderPipeline(device: device, library: library)
        setupBackgroundRenderPipeline(device: device, library: library)
        setupEffectRenderPipeline(device: device, library: library)
    }
    
    private func setupIconRenderPipeline(device: MTLDevice, library: MTLLibrary) {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Icon Render Pipeline"
        
        // 顶点和片段着色器
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "icon_vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "icon_fragment_main")
        
        // 颜色附件配置
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        // 顶点描述符
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4  // position + texCoord
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            iconRenderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ Failed to create icon render pipeline: \(error)")
        }
    }
    
    private func setupBackgroundRenderPipeline(device: MTLDevice, library: MTLLibrary) {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Background Render Pipeline"
        
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "background_vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "background_fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            backgroundRenderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ Failed to create background render pipeline: \(error)")
        }
    }
    
    private func setupEffectRenderPipeline(device: MTLDevice, library: MTLLibrary) {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Effect Render Pipeline"
        
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "effect_vertex_main")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "effect_fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            effectRenderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ Failed to create effect render pipeline: \(error)")
        }
    }
    
    private func setupComputePipelines() {
        guard let device = device, let library = library else { return }
        
        // 纹理处理管道
        if let function = library.makeFunction(name: "texture_process_compute") {
            do {
                textureProcessPipeline = try device.makeComputePipelineState(function: function)
            } catch {
                print("❌ Failed to create texture process pipeline: \(error)")
            }
        }
        
        // 搜索计算管道
        if let function = library.makeFunction(name: "parallel_search_compute") {
            do {
                searchComputePipeline = try device.makeComputePipelineState(function: function)
            } catch {
                print("❌ Failed to create search compute pipeline: \(error)")
            }
        }
    }
    
    private func createBuffers() {
        guard let device = device else { return }
        
        // 创建顶点缓冲区（全屏四边形）
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,  // 左下 (position.xy, texCoord.xy)
             1.0, -1.0, 1.0, 1.0,  // 右下
            -1.0,  1.0, 0.0, 0.0,  // 左上
             1.0,  1.0, 1.0, 0.0   // 右上
        ]
        
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: [.storageModeShared]
        )
        vertexBuffer?.label = "Fullscreen Quad Vertices"
        
        // 创建统一缓冲区
        let uniformSize = MemoryLayout<UniformData>.size
        uniformBuffer = device.makeBuffer(length: uniformSize, options: [.storageModeShared])
        uniformBuffer?.label = "Uniform Buffer"
    }
    
    private func preloadCommonResources() {
        guard let device = device else { return }
        
        // 创建常用效果纹理
        createEffectTextures(device: device)
        
        // 预分配纹理图集
        createIconTextureAtlas(device: device)
    }
    
    private func createEffectTextures(device: MTLDevice) {
        // 创建渐变纹理用于背景效果
        if let gradientTexture = createGradientTexture(device: device, size: CGSize(width: 256, height: 256)) {
            effectTextures["gradient"] = gradientTexture
        }
        
        // 创建噪声纹理用于粒子效果
        if let noiseTexture = createNoiseTexture(device: device, size: CGSize(width: 128, height: 128)) {
            effectTextures["noise"] = noiseTexture
        }
    }
    
    private func createIconTextureAtlas(device: MTLDevice) {
        let atlasSize = 2048 // 2048x2048 图集
        let textureDescriptor = MTLTextureDescriptor.texture2D(
            pixelFormat: .bgra8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        
        iconTextureAtlas = device.makeTexture(descriptor: textureDescriptor)
        iconTextureAtlas?.label = "Icon Texture Atlas"
    }
    
    // MARK: - 纹理管理
    
    func loadIconTexture(for app: AppItem, size: CGFloat = 72) -> MTLTexture? {
        let cacheKey = "\(app.bundleID):\(Int(size))"
        
        return textureCacheQueue.sync {
            // 检查缓存
            if let cached = iconTextureCache[cacheKey] {
                cached.lastAccessTime = CACurrentMediaTime()
                return cached.texture
            }
            
            // 加载图标
            guard let icon = IconProvider.icon(for: app, size: size),
                  let device = device else { return nil }
            
            let texture = createTextureFromImage(icon, device: device)
            
            if let tex = texture {
                let cachedTexture = CachedIconTexture(
                    texture: tex,
                    size: Int(size),
                    lastAccessTime: CACurrentMediaTime()
                )
                
                iconTextureCache[cacheKey] = cachedTexture
                cleanupCacheIfNeeded()
            }
            
            return texture
        }
    }
    
    private func createTextureFromImage(_ image: NSImage, device: MTLDevice) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let textureLoader = MTKTextureLoader(device: device)
        
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .generateMipmaps: true
        ]
        
        do {
            return try textureLoader.newTexture(cgImage: cgImage, options: options)
        } catch {
            print("❌ Failed to create texture from image: \(error)")
            return nil
        }
    }
    
    private func cleanupCacheIfNeeded() {
        guard iconTextureCache.count > maxCacheSize else { return }
        
        // 按最后访问时间排序，删除最旧的
        let sortedCache = iconTextureCache.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
        let itemsToRemove = sortedCache.prefix(iconTextureCache.count - maxCacheSize)
        
        for (key, _) in itemsToRemove {
            iconTextureCache.removeValue(forKey: key)
        }
        
        #if DEBUG
        print("🧹 Cleaned up texture cache: removed \(itemsToRemove.count) textures")
        #endif
    }
    
    // MARK: - 渲染方法
    
    func renderIcon(
        for app: AppItem,
        in view: MTKView,
        flashOpacity: Double,
        isHovered: Bool,
        transform: CGAffineTransform = .identity
    ) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipeline = iconRenderPipeline else { return }
        
        startFrameTiming()
        
        renderEncoder.label = "Icon Render Pass"
        renderEncoder.setRenderPipelineState(pipeline)
        
        // 设置顶点数据
        if let vertexBuffer = vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        }
        
        // 设置统一数据
        updateUniforms(
            flashOpacity: Float(flashOpacity),
            hoverScale: isHovered ? 1.05 : 1.0,
            transform: transform,
            time: Float(CACurrentMediaTime())
        )
        
        if let uniformBuffer = uniformBuffer {
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        }
        
        // 设置图标纹理
        if let iconTexture = loadIconTexture(for: app) {
            renderEncoder.setFragmentTexture(iconTexture, index: 0)
        }
        
        // 渲染
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.label = "Icon Render Command Buffer"
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        drawCallCount += 1
        endFrameTiming()
    }
    
    func renderBackground(in view: MTKView, time: TimeInterval) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipeline = backgroundRenderPipeline else { return }
        
        renderEncoder.label = "Background Render Pass"
        renderEncoder.setRenderPipelineState(pipeline)
        
        // 设置顶点数据
        if let vertexBuffer = vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        }
        
        // 更新背景统一数据
        updateBackgroundUniforms(time: Float(time), viewSize: view.bounds.size)
        
        if let uniformBuffer = uniformBuffer {
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        }
        
        // 设置效果纹理
        if let gradientTexture = effectTextures["gradient"] {
            renderEncoder.setFragmentTexture(gradientTexture, index: 0)
        }
        
        if let noiseTexture = effectTextures["noise"] {
            renderEncoder.setFragmentTexture(noiseTexture, index: 1)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.label = "Background Render Command Buffer"
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - 统一数据更新
    
    private func updateUniforms(
        flashOpacity: Float,
        hoverScale: Float,
        transform: CGAffineTransform,
        time: Float
    ) {
        guard let uniformBuffer = uniformBuffer else { return }
        
        let uniformData = UniformData(
            flashOpacity: flashOpacity,
            hoverScale: hoverScale,
            time: time,
            transform: matrix_float4x4(transform),
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: matrix_identity_float4x4
        )
        
        let uniformPointer = uniformBuffer.contents().bindMemory(to: UniformData.self, capacity: 1)
        uniformPointer.pointee = uniformData
    }
    
    private func updateBackgroundUniforms(time: Float, viewSize: CGSize) {
        guard let uniformBuffer = uniformBuffer else { return }
        
        let backgroundData = BackgroundUniformData(
            time: time,
            resolution: simd_float2(Float(viewSize.width), Float(viewSize.height)),
            gradientColors: [
                simd_float4(0.1, 0.1, 0.15, 1.0),
                simd_float4(0.15, 0.1, 0.2, 1.0),
                simd_float4(0.05, 0.05, 0.1, 1.0)
            ]
        )
        
        let pointer = uniformBuffer.contents().bindMemory(to: BackgroundUniformData.self, capacity: 1)
        pointer.pointee = backgroundData
    }
    
    // MARK: - 批量预热
    
    func preheatIconCache(for apps: [AppItem]) {
        guard isGPUAvailable else { return }
        
        let batchSize = 10
        let batches = apps.chunked(into: batchSize)
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for batch in batches.prefix(5) { // 限制预热批次
                let group = DispatchGroup()
                
                for app in batch {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        _ = self?.loadIconTexture(for: app)
                        group.leave()
                    }
                }
                
                group.wait()
                Thread.sleep(forTimeInterval: 0.01) // 小延迟避免过载
            }
        }
    }
    
    // MARK: - 性能监控
    
    private func startPerformanceMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePerformanceMetrics()
        }
    }
    
    private func updatePerformanceMetrics() {
        guard let device = device else { return }
        
        DispatchQueue.main.async { [weak self] in
            // 更新GPU内存使用
            let allocated = device.currentAllocatedSize
            let recommended = device.recommendedMaxWorkingSetSize
            self?.gpuMemoryUsage = Float(allocated) / Float(recommended)
            self?.currentGPUMemory = allocated
            
            #if DEBUG
            if let self = self {
                print("📊 GPU Memory: \(allocated / (1024*1024))MB / \(recommended / (1024*1024))MB")
                print("📊 FPS: \(String(format: "%.1f", self.renderingFPS))")
                print("📊 Draw calls: \(self.drawCallCount)")
                print("📊 Texture cache: \(self.iconTextureCache.count)")
            }
            #endif
        }
    }
    
    private func startFrameTiming() {
        frameStartTime = CACurrentMediaTime()
    }
    
    private func endFrameTiming() {
        let frameTime = CACurrentMediaTime() - frameStartTime
        frameCount += 1
        
        let currentTime = CACurrentMediaTime()
        if currentTime - lastFPSUpdate >= 1.0 {
            DispatchQueue.main.async { [weak self] in
                self?.renderingFPS = Float(self?.frameCount ?? 0) / Float(currentTime - (self?.lastFPSUpdate ?? 0))
            }
            lastFPSUpdate = currentTime
            frameCount = 0
        }
    }
    
    // MARK: - 实用纹理创建
    
    private func createGradientTexture(device: MTLDevice, size: CGSize) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2D(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        // 使用计算着色器生成渐变
        // 这里简化实现，实际可以用compute shader生成
        
        return texture
    }
    
    private func createNoiseTexture(device: MTLDevice, size: CGSize) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2D(
            pixelFormat: .r8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        // 生成随机噪声数据
        let dataSize = Int(size.width * size.height)
        var noiseData = [UInt8](repeating: 0, count: dataSize)
        
        for i in 0..<dataSize {
            noiseData[i] = UInt8.random(in: 0...255)
        }
        
        texture.replace(
            region: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)),
            mipmapLevel: 0,
            withBytes: noiseData,
            bytesPerRow: Int(size.width)
        )
        
        return texture
    }
    
    // MARK: - 清理
    
    func cleanup() {
        textureCacheQueue.sync {
            iconTextureCache.removeAll()
            effectTextures.removeAll()
        }
        
        iconTextureAtlas = nil
        vertexBuffer = nil
        uniformBuffer = nil
        
        #if DEBUG
        print("🧹 MetalRenderer cleaned up")
        #endif
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - 数据结构

struct CachedIconTexture {
    let texture: MTLTexture
    let size: Int
    var lastAccessTime: TimeInterval
}

struct UniformData {
    let flashOpacity: Float
    let hoverScale: Float
    let time: Float
    let transform: matrix_float4x4
    let viewMatrix: matrix_float4x4
    let projectionMatrix: matrix_float4x4
}

struct BackgroundUniformData {
    let time: Float
    let resolution: simd_float2
    let gradientColors: [simd_float4]
}

// MARK: - 实用扩展

extension matrix_float4x4 {
    init(_ transform: CGAffineTransform) {
        self.init(
            simd_float4(Float(transform.a), Float(transform.b), 0, 0),
            simd_float4(Float(transform.c), Float(transform.d), 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(Float(transform.tx), Float(transform.ty), 0, 1)
        )
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}