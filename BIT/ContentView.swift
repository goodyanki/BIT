import SwiftUI
import AppKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var keyword: String = ""
    @State private var debouncedKeyword: String = ""
    @State private var currentPage: Int = 0
    @State private var performanceStats: (scanTime: TimeInterval, appCount: Int, gpuUsed: Bool) = (0, 0, false)
    @State private var isMouseInGridArea: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var pageWidth: CGFloat = 0
    
    // 简化的渲染器
    @StateObject private var metalRenderer = MetalRenderer()
    @StateObject private var gpuSearchEngine = GPUSearchEngine()

    // 图标与布局参数
    private let iconSize: CGFloat = 72
    private let tileHPad: CGFloat = 6
    private let tileVPad: CGFloat = 6
    private let titleHeight: CGFloat = 14
    private let tileSpacingV: CGFloat = 8
    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 40

    // 过滤后的应用列表
    var filteredApps: [AppItem] {
        let k = debouncedKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if k.isEmpty { return apps }
        
        return gpuSearchEngine.searchApps(apps, query: k)
    }

    var body: some View {
        ZStack {
            // 简化的背景
            if metalRenderer.isGPUAvailable {
                MetalBackgroundView(renderer: metalRenderer)
                    .ignoresSafeArea()
            } else {
                SolidBackground()
            }
            
            WindowConfigurator()

            VStack(spacing: 16) {
                // 顶部搜索栏
                VStack(spacing: 8) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                )
                                .frame(height: 56)

                            HStack(spacing: 12) {
                                TextField("Search apps…", text: $keyword)
                                    .textFieldStyle(.plain)
                                    .disableAutocorrection(true)
                                    .foregroundColor(.white)
                                    .padding(.leading, 12)
                                    .padding(.trailing, 12)

                                Button("Rescan") { rescanApps() }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 12)
                        }
                        
                        // 拖拽状态指示器
                        HStack(spacing: 4) {
                            Circle().fill(isDragging ? Color.blue : (isMouseInGridArea ? Color.green : Color.orange))
                                .frame(width: 8, height: 8)
                            Text(isDragging ? "Dragging" : (isMouseInGridArea ? "Ready" : "Standby"))
                                .font(.caption2).opacity(0.7)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.15)).cornerRadius(8)
                    }
                    
                    #if DEBUG
                    HStack {
                        Text("📊 Apps: \(filteredApps.count) | Page: \(currentPage + 1) | Offset: \(String(format: "%.0f", dragOffset)) | Dragging: \(isDragging)")
                            .font(.caption2).opacity(0.6)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    #endif
                }
                .padding(.top, 40)

                // 实时跟手的分页网格容器
                VStack(spacing: 12) {
                    GeometryReader { proxy in
                        MouseTrackingView(isMouseInside: $isMouseInGridArea) {
                            RealtimeDragPaginationView(
                                apps: filteredApps,
                                currentPage: $currentPage,
                                dragOffset: $dragOffset,
                                isDragging: $isDragging,
                                pageWidth: $pageWidth,
                                iconSize: iconSize,
                                tileHPad: tileHPad,
                                tileVPad: tileVPad,
                                titleHeight: titleHeight,
                                tileSpacingV: tileSpacingV,
                                gridSpacing: gridSpacing,
                                horizontalPadding: horizontalPadding,
                                availableSize: proxy.size,
                                metalRenderer: metalRenderer,
                                isMouseInArea: isMouseInGridArea
                            )
                        }
                        .onAppear {
                            pageWidth = proxy.size.width
                        }
                        .onChange(of: proxy.size) { newSize in
                            pageWidth = newSize.width
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { initializeApp() }
        .onChange(of: keyword) { newValue in debounceSearch(newValue) }
        .onChange(of: apps) { newApps in updateIconCache(newApps) }
        .onChange(of: filteredApps) { _ in 
            withAnimation(.nativeMacOS) {
                currentPage = 0
                dragOffset = 0
            }
        }
    }
    
    // MARK: - 初始化 & 扫描
    private func initializeApp() {
        metalRenderer.initialize()
        gpuSearchEngine.initialize()
        rescanApps()
    }
    
    private func rescanApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let scannedApps = AppScanner.scanAllApps()
            let stats = AppScanner.getPerformanceStats()
            
            DispatchQueue.main.async {
                apps = scannedApps
                performanceStats = stats
                metalRenderer.preheatIconCache(for: scannedApps)
            }
        }
    }
    
    private func debounceSearch(_ newValue: String) {
        let latest = newValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if latest == keyword {
                debouncedKeyword = latest
            }
        }
    }
    
    private func updateIconCache(_ newApps: [AppItem]) {
        metalRenderer.preheatIconCache(for: newApps)
    }
}

// MARK: - 实时跟手分页视图
struct RealtimeDragPaginationView: View {
    let apps: [AppItem]
    @Binding var currentPage: Int
    @Binding var dragOffset: CGFloat
    @Binding var isDragging: Bool
    @Binding var pageWidth: CGFloat
    let iconSize: CGFloat
    let tileHPad: CGFloat
    let tileVPad: CGFloat
    let titleHeight: CGFloat
    let tileSpacingV: CGFloat
    let gridSpacing: CGFloat
    let horizontalPadding: CGFloat
    let availableSize: CGSize
    let metalRenderer: MetalRenderer
    let isMouseInArea: Bool
    
    @State private var dragStartTime: Date = Date()
    @State private var lastDragVelocity: CGFloat = 0
    
    var body: some View {
        let layout = calculateGridLayout()
        let pages = createPages(pageSize: layout.pageSize)
        let totalPages = max(pages.count, 1)
        
        VStack(spacing: 12) {
            // 实时跟手的横向容器
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { pageIndex in
                        RealtimeGridPage(
                            apps: pages[pageIndex],
                            columns: layout.columns,
                            gridSpacing: gridSpacing,
                            horizontalPadding: horizontalPadding,
                            pageSize: layout.pageSize,
                            metalRenderer: metalRenderer,
                            isMouseInArea: isMouseInArea,
                            pageWidth: geometry.size.width,
                            isDragging: isDragging
                        )
                        .frame(width: geometry.size.width)
                        .clipped()
                    }
                }
                .offset(x: calculateTotalOffset(containerWidth: geometry.size.width))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isMouseInArea else { return }
                            
                            if !isDragging {
                                isDragging = true
                                dragStartTime = Date()
                            }
                            
                            let translation = value.translation.width
                            let containerWidth = geometry.size.width
                            
                            // 计算拖拽速度
                            // 使用预测结束位移近似速度趋势
                            lastDragVelocity = value.predictedEndTranslation.width - value.translation.width
                            
                            // 实时跟手逻辑
                            let newOffset = calculateRealtimeOffset(
                                translation: translation,
                                containerWidth: containerWidth,
                                totalPages: totalPages
                            )
                            
                            dragOffset = newOffset
                            
                            #if DEBUG
                            let progress = abs(translation) / (containerWidth * 0.5)
                            print("🖱️ Dragging - translation: \(Int(translation)), offset: \(Int(dragOffset)), progress: \(String(format: "%.1f", progress * 100))%")
                            #endif
                        }
                        .onEnded { value in
                            guard isMouseInArea else { return }
                            
                            isDragging = false
                            let translation = value.translation.width
                            // 近似“速度”的量（预测终点相对当前位置的位移）
                            let velocity = value.predictedEndTranslation.width - value.translation.width
                            let containerWidth = geometry.size.width
                            
                            // 智能页面切换判断
                            let shouldChangePage = shouldChangePageOnDragEnd(
                                translation: translation,
                                velocity: velocity,
                                containerWidth: containerWidth,
                                totalPages: totalPages
                            )
                            
                            if shouldChangePage.shouldChange {
                                let newPage = shouldChangePage.targetPage
                                
                                #if DEBUG
                                print("🖱️ Page change: \(currentPage) → \(newPage) (translation: \(Int(translation)), velocity: \(Int(velocity)))")
                                #endif
                                
                                withAnimation(.nativeMacOS) {
                                    currentPage = newPage
                                    dragOffset = 0
                                }
                            } else {
                                // 回弹到当前页
                                #if DEBUG
                                print("🖱️ Snap back to page \(currentPage)")
                                #endif
                                
                                withAnimation(.nativeLaunchpad) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
                .onAppear {
                    pageWidth = geometry.size.width
                }
            }
            .background(
                RealtimeSwipeCatcher(
                    onLeft: { 
                        guard isMouseInArea && !isDragging else { return }
                        nextPage(maxPage: totalPages - 1)
                    },
                    onRight: { 
                        guard isMouseInArea && !isDragging else { return }
                        previousPage()
                    }
                )
            )
            
            RealtimePageIndicator(
                currentPage: currentPage, 
                totalPages: totalPages,
                isActive: isMouseInArea,
                isDragging: isDragging,
                dragProgress: calculateDragProgress()
            )
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - 核心计算逻辑
    
    private func calculateTotalOffset(containerWidth: CGFloat) -> CGFloat {
        let baseOffset = -CGFloat(currentPage) * containerWidth
        return baseOffset + dragOffset
    }
    
    private func calculateRealtimeOffset(
        translation: CGFloat, 
        containerWidth: CGFloat, 
        totalPages: Int
    ) -> CGFloat {
        // 边界检查和阻尼效果
        let isAtFirstPage = currentPage == 0
        let isAtLastPage = currentPage == totalPages - 1
        
        if isAtFirstPage && translation > 0 {
            // 在第一页向右拖拽 - 添加阻尼
            return translation * 0.3
        } else if isAtLastPage && translation < 0 {
            // 在最后一页向左拖拽 - 添加阻尼
            return translation * 0.3
        } else {
            // 正常拖拽 - 完全跟手
            return translation
        }
    }
    
    private func shouldChangePageOnDragEnd(
        translation: CGFloat,
        velocity: CGFloat,
        containerWidth: CGFloat,
        totalPages: Int
    ) -> (shouldChange: Bool, targetPage: Int) {
        
        let threshold = containerWidth * 0.5 // 50% 阈值
        let velocityThreshold: CGFloat = 800  // 速度阈值
        
        // 基于距离的判断
        let distanceBasedChange = abs(translation) > threshold
        
        // 基于速度的判断
        let velocityBasedChange = abs(velocity) > velocityThreshold
        
        if distanceBasedChange || velocityBasedChange {
            var targetPage = currentPage
            
            if translation < 0 && currentPage < totalPages - 1 {
                // 向左拖拽，下一页
                targetPage = currentPage + 1
            } else if translation > 0 && currentPage > 0 {
                // 向右拖拽，上一页
                targetPage = currentPage - 1
            } else {
                // 边界情况，不切换
                return (false, currentPage)
            }
            
            return (true, targetPage)
        }
        
        return (false, currentPage)
    }
    
    private func calculateDragProgress() -> CGFloat {
        guard pageWidth > 0 else { return 0 }
        return abs(dragOffset) / (pageWidth * 0.5)
    }
    
    // MARK: - 布局计算
    
    private func calculateGridLayout() -> (columns: [GridItem], pageSize: Int) {
        let availW = max(0, availableSize.width - horizontalPadding * 2)
        let availH = max(0, availableSize.height - 40)
        let minTileW = iconSize + tileHPad * 2
        let minTileH = iconSize + tileVPad * 2 + tileSpacingV + titleHeight
        
        let cols = min(7, max(1, Int((availW + gridSpacing) / (minTileW + gridSpacing))))
        let rows = min(5, max(1, Int((availH + gridSpacing) / (minTileH + gridSpacing))))
        let pageSize = cols * rows
        
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: max(cols, 1))
        return (columns, pageSize)
    }
    
    private func createPages(pageSize: Int) -> [[AppItem]] {
        stride(from: 0, to: apps.count, by: max(pageSize, 1)).map {
            let end = min($0 + max(pageSize, 1), apps.count)
            return Array(apps[$0..<end])
        }
    }
    
    private func nextPage(maxPage: Int) {
        guard currentPage < maxPage else { return }
        
        withAnimation(.nativeMacOS) {
            currentPage += 1
            dragOffset = 0
        }
    }
    
    private func previousPage() {
        guard currentPage > 0 else { return }
        
        withAnimation(.nativeMacOS) {
            currentPage -= 1
            dragOffset = 0
        }
    }
}

// MARK: - 实时响应网格页
struct RealtimeGridPage: View {
    let apps: [AppItem]
    let columns: [GridItem]
    let gridSpacing: CGFloat
    let horizontalPadding: CGFloat
    let pageSize: Int
    let metalRenderer: MetalRenderer
    let isMouseInArea: Bool
    let pageWidth: CGFloat
    let isDragging: Bool
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(apps) { app in
                RealtimeAppTile(
                    app: app, 
                    metalRenderer: metalRenderer,
                    isInteractive: isMouseInArea && !isDragging, // 拖拽时禁用交互
                    isDragging: isDragging
                )
            }
            // 填充空位
            if apps.count < pageSize {
                ForEach(0..<(pageSize - apps.count), id: \.self) { _ in
                    Color.clear.frame(height: 94)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 8)
        .frame(width: pageWidth)
        .opacity(isDragging ? 0.9 : 1.0) // 拖拽时轻微透明
        .animation(.easeOut(duration: 0.1), value: isDragging)
    }
}

// MARK: - 实时响应应用瓦片
struct RealtimeAppTile: View {
    let app: AppItem
    let metalRenderer: MetalRenderer
    let isInteractive: Bool
    let isDragging: Bool
    @State private var flashOpacity: Double = 0.0
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    
    var body: some View {
        Button(action: {
            guard !isDragging else { return } // 拖拽时不响应点击
            triggerNativeClickEffect()
            launchApp()
        }) {
            VStack(spacing: 8) {
                MetalIconView(
                    app: app,
                    size: 72,
                    renderer: metalRenderer,
                    flashOpacity: flashOpacity,
                    isHovered: isHovered && isInteractive
                )
                .scaleEffect(isPressed ? 0.95 : (isHovered ? 1.02 : 1.0))
                .scaleEffect(isDragging ? 0.98 : 1.0) // 拖拽时轻微缩小
                
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .center)
                    .foregroundColor(.white)
                    .opacity(isInteractive ? 1.0 : 0.8)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .allowsHitTesting(!isDragging) // 拖拽时禁用点击
        .onHover { hovering in
            if isInteractive {
                withAnimation(.easeInOut(duration: 0.15)) { 
                    isHovered = hovering 
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .contextMenu {
            Button("Open") { 
                guard !isDragging else { return }
                launchApp() 
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID, forType: .string)
            }
        }
    }
    
    private func triggerNativeClickEffect() {
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.2 }
        withAnimation(.easeOut(duration: 0.15).delay(0.06)) { flashOpacity = 0.0 }
    }
    
    private func launchApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        }
    }
}

// MARK: - 实时响应分页指示器
struct RealtimePageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    let isActive: Bool
    let isDragging: Bool
    let dragProgress: CGFloat
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { i in
                let isCurrentPage = i == currentPage
                let opacity = calculateDotOpacity(for: i)
                let scale = calculateDotScale(for: i)
                
                Circle()
                    .fill(Color.white.opacity(opacity))
                    .frame(width: 6 * scale, height: 6 * scale)
                    .animation(.easeOut(duration: 0.2), value: dragProgress)
                    .animation(.nativeMacOSFast, value: currentPage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(isActive ? 0.25 : 0.15))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isActive ? 0.2 : 0.1), lineWidth: 0.5)
                )
        )
        .scaleEffect(isActive ? 1.05 : 1.0)
        .scaleEffect(isDragging ? 1.1 : 1.0) // 拖拽时放大
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }
    
    private func calculateDotOpacity(for index: Int) -> CGFloat {
        let isCurrentPage = index == currentPage
        let baseOpacity: CGFloat = isCurrentPage ? (isActive ? 0.9 : 0.7) : (isActive ? 0.3 : 0.2)
        
        if isDragging {
            // 拖拽时增加当前页和相邻页的透明度
            if isCurrentPage {
                return min(1.0, baseOpacity + dragProgress * 0.2)
            } else if abs(index - currentPage) == 1 {
                return min(0.8, baseOpacity + dragProgress * 0.3)
            }
        }
        
        return baseOpacity
    }
    
    private func calculateDotScale(for index: Int) -> CGFloat {
        let isCurrentPage = index == currentPage
        let baseScale: CGFloat = isCurrentPage ? 1.5 : 1.0
        
        if isDragging && isCurrentPage {
            return baseScale + dragProgress * 0.2
        }
        
        return baseScale
    }
}

// MARK: - 实时手势捕获器
struct RealtimeSwipeCatcher: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void

    func makeNSView(context: Context) -> RealtimeSwipeView {
        let view = RealtimeSwipeView()
        view.onLeft = onLeft
        view.onRight = onRight
        return view
    }
    
    func updateNSView(_ nsView: RealtimeSwipeView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
    }
}

class RealtimeSwipeView: NSView {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    
    private var lastGestureTime: TimeInterval = 0
    private let gestureThrottleInterval: TimeInterval = 0.6
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRealtimeGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRealtimeGestures()
    }
    
    private func setupRealtimeGestures() {
        // 滚轮手势用于快速切页（不拖拽的情况）
        // 主要的拖拽交互由DragGesture处理
    }
    
    override func scrollWheel(with event: NSEvent) {
        // 快速滚轮切页
        if event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 {
            let threshold: CGFloat = 100.0
            let deltaX = event.scrollingDeltaX
            
            if deltaX < -threshold {
                executeGestureIfAllowed(onLeft)
            } else if deltaX > threshold {
                executeGestureIfAllowed(onRight)
            }
        } else {
            super.scrollWheel(with: event)
        }
    }
    
    private func executeGestureIfAllowed(_ action: () -> Void) {
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastGestureTime >= gestureThrottleInterval {
            lastGestureTime = currentTime
            action()
        }
    }
}

// MARK: - 鼠标追踪视图 (保持不变)
struct MouseTrackingView<Content: View>: NSViewRepresentable {
    @Binding var isMouseInside: Bool
    let content: () -> Content
    
    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMouseStateChange = { inside in
            DispatchQueue.main.async {
                isMouseInside = inside
            }
        }
        
        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        return view
    }
    
    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        if let hostingView = nsView.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content()
        }
    }
}

class MouseTrackingNSView: NSView {
    var onMouseStateChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupTracking()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTracking()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }
    
    private func setupTracking() {
        updateTrackingAreas()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existingTrackingArea = trackingArea {
            removeTrackingArea(existingTrackingArea)
        }
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseStateChange?(true)
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseStateChange?(false)
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let locationInView = convert(event.locationInWindow, from: nil)
        let isInside = bounds.contains(locationInView)
        onMouseStateChange?(isInside)
    }
}
