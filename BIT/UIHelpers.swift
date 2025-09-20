import SwiftUI
import AppKit
import Metal
import MetalKit

// 文件级工具：获取主屏尺寸（macOS）
fileprivate func mainScreenSize() -> CGSize {
    if let size = NSScreen.main?.frame.size { return size }
    return CGSize(width: 1440, height: 900)
}

// MARK: - Simplified Metal渲染器 (Fixed version)
class MetalRenderer: ObservableObject {
    private var device: MTLDevice?
    var commandQueue: MTLCommandQueue?
    
    // 性能监控
    @Published var isGPUAvailable: Bool = false
    @Published var gpuMemoryUsage: Float = 0.0
    @Published var renderingFPS: Float = 0.0
    
    // 简化的图标缓存
    private var iconCache: [String: NSImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache", attributes: .concurrent)
    
    init() {
        setupMetal()
    }
    
    func initialize() {
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ Metal is not available on this device")
            isGPUAvailable = false
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        isGPUAvailable = true
        
        #if DEBUG
        print("🚀 Metal initialized: \(device.name)")
        #endif
    }
    
    // 简化的图标预热（使用CPU缓存代替GPU纹理）
    func preheatIconCache(for apps: [AppItem]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for app in apps.prefix(50) {
                if let icon = IconProvider.icon(for: app, size: 72) {
                    self?.cacheQueue.async(flags: .barrier) {
                        self?.iconCache[app.bundleID] = icon
                    }
                }
            }
        }
    }
    
    func cleanup() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.iconCache.removeAll()
        }
    }
}

// MARK: - 简化的GPU搜索引擎
class GPUSearchEngine: ObservableObject {
    @Published var isGPUSearchAvailable: Bool = false
    
    func initialize() {
        // 暂时禁用GPU搜索，使用CPU实现
        isGPUSearchAvailable = false
    }
    
    func searchApps(_ apps: [AppItem], query: String) -> [AppItem] {
        let lowercaseQuery = query.lowercased()
        return apps.filter { app in
            app.name.lowercased().contains(lowercaseQuery) || 
            app.bundleID.lowercased().contains(lowercaseQuery)
        }.sorted { app1, app2 in
            // 简单排序：名称匹配优先，然后按字母顺序
            let name1Match = app1.name.lowercased().hasPrefix(lowercaseQuery)
            let name2Match = app2.name.lowercased().hasPrefix(lowercaseQuery)
            
            if name1Match != name2Match {
                return name1Match
            }
            
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }
}

// MARK: - 增强的Metal图标视图 - 支持实时拖拽状态
struct MetalIconView: View {
    let app: AppItem
    let size: CGFloat
    let renderer: MetalRenderer
    let flashOpacity: Double
    let isHovered: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            if let icon = IconProvider.icon(for: app, size: size) {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: size, height: size)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(flashOpacity))
                            .animation(.easeOut(duration: 0.1), value: flashOpacity)
                    )
                    .scaleEffect(isHovered ? 1.05 : 1.0)
                    .animation(.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.2), value: isHovered)
                    // 添加实时拖拽时的微妙视觉反馈
                    .brightness(isHovered ? 0.05 : 0.0)
                    .saturation(isHovered ? 1.1 : 1.0)
            } else {
                // 增强的占位图标
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.gray.opacity(0.4),
                                Color.gray.opacity(0.2)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.4, weight: .light))
                            .foregroundColor(.white.opacity(0.6))
                    )
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            }
        }
    }
}

// MARK: - 实时拖拽优化的背景视图
struct MetalBackgroundView: View {
    let renderer: MetalRenderer
    @State private var animationPhase: Double = 0
    @State private var dragInteractionPhase: Double = 0
    
    var body: some View {
        ZStack {
            // 基础渐变 - 更贴近原生Launchpad
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.14, green: 0.14, blue: 0.20), // 中心稍亮
                    Color(red: 0.10, green: 0.10, blue: 0.15), // 中间色
                    Color(red: 0.06, green: 0.06, blue: 0.10), // 边缘深色
                    Color(red: 0.03, green: 0.03, blue: 0.08)  // 最外圈
                ]),
                center: .center,
                startRadius: 100,
                endRadius: 1000
            )
            
            // 动态粒子效果层
            ParticleBackgroundView()
            
            // 拖拽交互响应层
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(0.02 + dragInteractionPhase * 0.03),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 600
                    )
                )
                .scaleEffect(1.0 + sin(animationPhase + dragInteractionPhase) * 0.08)
                .offset(
                    x: cos(animationPhase * 0.7) * 40, 
                    y: sin(animationPhase * 0.5) * 25
                )
                .animation(.linear(duration: 25).repeatForever(autoreverses: false), value: animationPhase)
                .onAppear {
                    animationPhase = .pi * 2
                }
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .dragInteractionChanged)) { notification in
            if let isDragging = notification.object as? Bool {
                withAnimation(.easeInOut(duration: 0.3)) {
                    dragInteractionPhase = isDragging ? 1.0 : 0.0
                }
            }
        }
    }
}

// MARK: - 粒子背景效果
struct ParticleBackgroundView: View {
    @State private var particles: [Particle] = []
    @State private var animationTimer: Timer?
    
    struct Particle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var opacity: Double
        var scale: CGFloat
        var velocity: CGPoint
        var life: Double
    }
    
    var body: some View {
        Canvas { context, size in
            for particle in particles {
                let rect = CGRect(
                    x: particle.x - particle.scale / 2,
                    y: particle.y - particle.scale / 2,
                    width: particle.scale,
                    height: particle.scale
                )
                
                context.opacity = particle.opacity
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.white)
                )
            }
        }
        .onAppear {
            setupParticles()
            startAnimation()
        }
        .onDisappear {
            animationTimer?.invalidate()
        }
    }
    
    private func setupParticles() {
        particles = (0..<20).map { _ in
            Particle(
                x: CGFloat.random(in: 0...mainScreenSize().width),
                y: CGFloat.random(in: 0...mainScreenSize().height),
                opacity: Double.random(in: 0.02...0.08),
                scale: CGFloat.random(in: 1...3),
                velocity: CGPoint(
                    x: CGFloat.random(in: -0.5...0.5),
                    y: CGFloat.random(in: -0.5...0.5)
                ),
                life: 1.0
            )
        }
    }
    
    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { _ in
            updateParticles()
        }
    }
    
    private func updateParticles() {
        for i in particles.indices {
            particles[i].x += particles[i].velocity.x
            particles[i].y += particles[i].velocity.y
            particles[i].life -= 0.001
            
            // 边界回绕
            if particles[i].x < 0 { particles[i].x = mainScreenSize().width }
            if particles[i].x > mainScreenSize().width { particles[i].x = 0 }
            if particles[i].y < 0 { particles[i].y = mainScreenSize().height }
            if particles[i].y > mainScreenSize().height { particles[i].y = 0 }
            
            // 重生粒子
            if particles[i].life <= 0 {
                particles[i] = Particle(
                    x: CGFloat.random(in: 0...mainScreenSize().width),
                    y: CGFloat.random(in: 0...mainScreenSize().height),
                    opacity: Double.random(in: 0.02...0.08),
                    scale: CGFloat.random(in: 1...3),
                    velocity: CGPoint(
                        x: CGFloat.random(in: -0.5...0.5),
                        y: CGFloat.random(in: -0.5...0.5)
                    ),
                    life: 1.0
                )
            }
        }
    }
}

// MARK: - 窗口配置 - 实时拖拽优化
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
            // 基础窗口设置 - 优化拖拽性能
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isMovableByWindowBackground = false
            win.collectionBehavior.insert(.fullScreenPrimary)
            
            // 实时拖拽性能优化
            win.level = .modalPanel
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.displaysWhenScreenProfileChanges = true
            
            // 启用高性能渲染
            if let contentView = win.contentView {
                contentView.wantsLayer = true
                contentView.layer?.drawsAsynchronously = true
            }
            
            // 设置最小窗口尺寸
            win.minSize = NSSize(width: 400, height: 300)
            
            // 启动时进入全屏模式 - 更流畅的动画
            if !win.styleMask.contains(.fullScreen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.6
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
                        context.allowsImplicitAnimation = true
                        win.toggleFullScreen(nil)
                    }
                }
            }
            
            // 监听窗口状态变化
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: win,
                queue: .main
            ) { _ in
                UserDefaults.standard.set(true, forKey: "LaunchpadFullScreen")
                // 全屏后优化性能设置
                win.level = .normal
                #if DEBUG
                print("🖥️ Entered full screen mode - performance optimized")
                #endif
            }
            
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: win,
                queue: .main
            ) { _ in
                UserDefaults.standard.set(false, forKey: "LaunchpadFullScreen")
                #if DEBUG
                print("🖥️ Exited full screen mode")
                #endif
            }
        }
        .frame(width: 0, height: 0)
    }
}

// 原生风格背景组件
struct SolidBackground: View {
    var body: some View { 
        // 原生Launchpad的纯色背景
        Color(red: 0.08, green: 0.08, blue: 0.12)
            .ignoresSafeArea()
    }
}

// MARK: - 原生动画支持扩展 - 增强实时拖拽
extension Animation {
    // 原生macOS动画曲线
    static var nativeMacOS: Animation {
        .timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.4)
    }
    
    static var nativeMacOSFast: Animation {
        .timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.25)
    }
    
    static var nativeMacOSSlow: Animation {
        .timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.6)
    }
    
    // 原生Launchpad的弹性动画
    static var nativeLaunchpad: Animation {
        .interpolatingSpring(stiffness: 300, damping: 30, initialVelocity: 0)
    }
    
    // 实时拖拽专用动画
    static var realtimeDrag: Animation {
        .interactiveSpring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.1)
    }
    
    // 拖拽结束回弹动画
    static var dragSnapBack: Animation {
        .interpolatingSpring(stiffness: 400, damping: 25, initialVelocity: 0)
    }
}

// MARK: - 原生macOS颜色支持
extension Color {
    // 原生Launchpad配色
    static var launchpadBackground: Color {
        Color(red: 0.08, green: 0.08, blue: 0.12)
    }
    
    static var launchpadOverlay: Color {
        Color.black.opacity(0.25)
    }
    
    static var launchpadAccent: Color {
        Color.white.opacity(0.9)
    }
    
    static var launchpadSecondary: Color {
        Color.white.opacity(0.3)
    }
    
    // 拖拽状态配色
    static var dragActiveBackground: Color {
        Color(red: 0.10, green: 0.10, blue: 0.15)
    }
    
    static var dragIndicator: Color {
        Color.blue.opacity(0.6)
    }
}

// MARK: - 拖拽交互通知
extension Notification.Name {
    static let dragInteractionChanged = Notification.Name("dragInteractionChanged")
    static let pageTransitionStarted = Notification.Name("pageTransitionStarted")
    static let pageTransitionCompleted = Notification.Name("pageTransitionCompleted")
}

// MARK: - 实时拖拽手势处理器 - 完全重写
#if os(macOS)
struct SwipeCatcher: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void

    func makeNSView(context: Context) -> RealtimeDragGestureView {
        let v = RealtimeDragGestureView()
        v.onLeft = onLeft
        v.onRight = onRight
        return v
    }
    
    func updateNSView(_ nsView: RealtimeDragGestureView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
    }

    final class RealtimeDragGestureView: NSView {
        var onLeft: () -> Void = {}
        var onRight: () -> Void = {}
        
        private var lastGestureTime: TimeInterval = 0
        private let gestureThrottleInterval: TimeInterval = 0.8 // 更长的间隔避免与拖拽冲突
        private var isMouseInside: Bool = false
        private var isDragInProgress: Bool = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupRealtimeGestureHandling()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupRealtimeGestureHandling()
        }
        
        private func setupRealtimeGestureHandling() {
            // 移除pan手势识别器，避免与SwiftUI DragGesture冲突
            // 只保留滚轮和键盘支持作为备用输入方式
            setupTrackingForRealtimeDrag()
            
            // 监听拖拽状态变化
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(dragStateChanged(_:)),
                name: .dragInteractionChanged,
                object: nil
            )
        }
        
        private func setupTrackingForRealtimeDrag() {
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
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
            setupTrackingForRealtimeDrag()
        }
        
        // 鼠标状态追踪
        override func mouseEntered(with event: NSEvent) {
            isMouseInside = true
            window?.makeFirstResponder(self)
            #if DEBUG
            print("🖱️ Mouse entered realtime drag area")
            #endif
        }
        
        override func mouseExited(with event: NSEvent) {
            isMouseInside = false
            #if DEBUG
            print("🖱️ Mouse exited realtime drag area")
            #endif
        }
        
        override func mouseMoved(with event: NSEvent) {
            let locationInView = convert(event.locationInWindow, from: nil)
            isMouseInside = bounds.contains(locationInView)
        }
        
        @objc private func dragStateChanged(_ notification: Notification) {
            if let isDragging = notification.object as? Bool {
                isDragInProgress = isDragging
                #if DEBUG
                print("🖱️ Drag state changed: \(isDragging)")
                #endif
            }
        }
        
        // 滚轮支持 - 仅在非拖拽状态下工作
        override func scrollWheel(with event: NSEvent) {
            guard isMouseInside, !isDragInProgress else {
                super.scrollWheel(with: event)
                return
            }
            
            // 实时拖拽模式下的滚轮参数
            if event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2.5 {
                let threshold: CGFloat = 120.0 // 更高的阈值避免意外触发
                let deltaX = event.scrollingDeltaX
                
                if deltaX < -threshold {
                    executeGestureIfAllowed {
                        #if DEBUG
                        print("🖱️ Realtime scroll LEFT - delta: \(deltaX)")
                        #endif
                        onLeft()
                    }
                } else if deltaX > threshold {
                    executeGestureIfAllowed {
                        #if DEBUG
                        print("🖱️ Realtime scroll RIGHT - delta: \(deltaX)")
                        #endif
                        onRight()
                    }
                }
            } else {
                super.scrollWheel(with: event)
            }
        }
        
        // 键盘支持 - 实时拖拽优化
        override func keyDown(with event: NSEvent) {
            guard isMouseInside, !isDragInProgress else {
                super.keyDown(with: event)
                return
            }
            
            switch event.keyCode {
            case 123: // 左箭头
                executeGestureIfAllowed {
                    #if DEBUG
                    print("🖱️ Realtime key LEFT")
                    #endif
                    onRight() // 键盘方向和手势方向相反
                }
            case 124: // 右箭头
                executeGestureIfAllowed {
                    #if DEBUG
                    print("🖱️ Realtime key RIGHT")
                    #endif
                    onLeft()
                }
            case 53: // ESC键 - 退出全屏
                if let window = window, window.styleMask.contains(.fullScreen) {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.6
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
                        window.toggleFullScreen(nil)
                    }
                }
            case 49: // 空格键 - 可用于暂停拖拽
                #if DEBUG
                print("🖱️ Space key pressed - possible pause drag")
                #endif
            default:
                super.keyDown(with: event)
            }
        }
        
        // 防重复执行 - 实时拖拽优化间隔
        private func executeGestureIfAllowed(_ action: () -> Void) {
            let currentTime = Date().timeIntervalSince1970
            if currentTime - lastGestureTime >= gestureThrottleInterval {
                lastGestureTime = currentTime
                
                // 发送页面切换通知
                NotificationCenter.default.post(
                    name: .pageTransitionStarted,
                    object: nil
                )
                
                action()
                
                // 延迟发送完成通知
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(
                        name: .pageTransitionCompleted,
                        object: nil
                    )
                }
            } else {
                #if DEBUG
                print("🖱️ Gesture throttled: too soon after last gesture")
                #endif
            }
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
#endif

// MARK: - 实时拖拽性能优化扩展
extension View {
    // 拖拽状态通知发送
    func onDragStateChange(_ isDragging: Bool) -> some View {
        self.onAppear {
            NotificationCenter.default.post(
                name: .dragInteractionChanged,
                object: isDragging
            )
        }
        .onChange(of: isDragging) { newValue in
            NotificationCenter.default.post(
                name: .dragInteractionChanged,
                object: newValue
            )
        }
    }
    
    // 实时拖拽优化修饰器
    func optimizedForRealtimeDrag() -> some View {
        self
            .drawingGroup() // 合并绘制以提高性能
            .compositingGroup() // 组合渲染优化
    }
}

// MARK: - 拖拽性能监控
class DragPerformanceMonitor: ObservableObject {
    @Published var dragFPS: Double = 0
    @Published var averageFrameTime: Double = 0
    
    private var frameCount: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameTimeSum: Double = 0
    
    func recordFrame() {
        let currentTime = CACurrentMediaTime()
        
        if lastFrameTime > 0 {
            let frameTime = currentTime - lastFrameTime
            frameTimeSum += frameTime
            frameCount += 1
            
            if frameCount >= 10 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.averageFrameTime = self.frameTimeSum / Double(self.frameCount)
                    self.dragFPS = 1.0 / self.averageFrameTime
                    
                    // 重置计数器
                    self.frameCount = 0
                    self.frameTimeSum = 0
                }
            }
        }
        
        lastFrameTime = currentTime
    }
}
