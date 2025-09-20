import SwiftUI
import AppKit
import Metal
import MetalKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var keyword: String = ""
    @State private var debouncedKeyword: String = ""
    @State private var currentPage: Int = 0
    @State private var performanceStats: (scanTime: TimeInterval, appCount: Int, gpuUsed: Bool) = (0, 0, false)
    
    // GPU 渲染器 & 搜索引擎
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
        
        if apps.count > 100 && metalRenderer.isGPUAvailable {
            return gpuSearchEngine.searchApps(apps, query: k)
        } else {
            return apps.filter { item in
                item.name.lowercased().contains(k) || item.bundleID.lowercased().contains(k)
            }
        }
    }

    var body: some View {
        ZStack {
            // 背景：GPU 或 CPU
            if metalRenderer.isGPUAvailable {
                MetalBackgroundView(renderer: metalRenderer)
                    .ignoresSafeArea()
            } else {
                SolidBackground()
            }
            
            WindowConfigurator()

            VStack(spacing: 16) {
                // 顶部搜索栏 + GPU 状态
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
                                    .padding(.leading, 12)
                                    .padding(.trailing, 12)

                                Button("Rescan") { rescanApps() }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 12)
                        }
                        
                        GPUStatusIndicator(
                            isGPUUsed: performanceStats.gpuUsed,
                            scanTime: performanceStats.scanTime,
                            appCount: performanceStats.appCount
                        )
                    }
                    
                    #if DEBUG
                    PerformanceStatsView(stats: performanceStats, filteredCount: filteredApps.count)
                    #endif
                }
                .padding(.top, 40)

                // 分页网格
                VStack(spacing: 12) {
                    GeometryReader { proxy in
                        GPUOptimizedGridView(
                            apps: filteredApps,
                            currentPage: $currentPage,
                            iconSize: iconSize,
                            tileHPad: tileHPad,
                            tileVPad: tileVPad,
                            titleHeight: titleHeight,
                            tileSpacingV: tileSpacingV,
                            gridSpacing: gridSpacing,
                            horizontalPadding: horizontalPadding,
                            availableSize: proxy.size,
                            metalRenderer: metalRenderer
                        )
                    }
                    .animation(.easeInOut(duration: 0.18), value: filteredApps)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { initializeApp() }
        .onChange(of: keyword) { newValue in debounceSearch(newValue) }
        .onChange(of: apps) { newApps in updateIconCache(newApps) }
        .onChange(of: filteredApps) { _ in currentPage = 0 }
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
                if metalRenderer.isGPUAvailable {
                    metalRenderer.preheatIconCache(for: scannedApps)
                }
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
        if metalRenderer.isGPUAvailable {
            metalRenderer.preheatIconCache(for: newApps)
        } else {
            IconProvider.preheat(apps: newApps, size: 72)
        }
    }
}

// MARK: - GPU 优化网格
struct GPUOptimizedGridView: View {
    let apps: [AppItem]
    @Binding var currentPage: Int
    let iconSize: CGFloat
    let tileHPad: CGFloat
    let tileVPad: CGFloat
    let titleHeight: CGFloat
    let tileSpacingV: CGFloat
    let gridSpacing: CGFloat
    let horizontalPadding: CGFloat
    let availableSize: CGSize
    let metalRenderer: MetalRenderer
    
    var body: some View {
        let layout = calculateGridLayout()
        let pages = createPages(pageSize: layout.pageSize)
        
        VStack(spacing: 12) {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    let page = pages[index]
                    
                    if metalRenderer.isGPUAvailable {
                        GPUAcceleratedGridPage(
                            apps: page,
                            columns: layout.columns,
                            gridSpacing: gridSpacing,
                            horizontalPadding: horizontalPadding,
                            pageSize: layout.pageSize,
                            metalRenderer: metalRenderer
                        )
                    } else {
                        CPUFallbackGridPage(
                            apps: page,
                            columns: layout.columns,
                            gridSpacing: gridSpacing,
                            horizontalPadding: horizontalPadding,
                            pageSize: layout.pageSize
                        )
                    }
                }
            }
#if os(macOS)
            .tabViewStyle(DefaultTabViewStyle())
            .background(
                SwipeCatcher(
                    onLeft: { nextPage(maxPage: max(pages.count - 1, 0)) },
                    onRight: { previousPage() }
                ).ignoresSafeArea()
            )
            .contentShape(Rectangle())
            .highPriorityGesture(createDragGesture(maxPage: max(pages.count - 1, 0)))
#else
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
#endif
            
            PageIndicator(currentPage: currentPage, totalPages: max(pages.count, 1))
                .padding(.bottom, 24)
        }
    }
    
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
        withAnimation(.easeInOut(duration: 0.22)) {
            currentPage = min(currentPage + 1, maxPage)
        }
    }
    
    private func previousPage() {
        withAnimation(.easeInOut(duration: 0.22)) {
            currentPage = max(currentPage - 1, 0)
        }
    }
    
    private func createDragGesture(maxPage: Int) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 40, abs(dx) > abs(dy) else { return }
                if dx < 0 { nextPage(maxPage: maxPage) }
                else { previousPage() }
            }
    }
}

// MARK: - GPU/CPU 网格页
struct GPUAcceleratedGridPage: View {
    let apps: [AppItem]
    let columns: [GridItem]
    let gridSpacing: CGFloat
    let horizontalPadding: CGFloat
    let pageSize: Int
    let metalRenderer: MetalRenderer
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(apps) { app in
                GPUAcceleratedAppTile(app: app, metalRenderer: metalRenderer)
            }
            if apps.count < pageSize {
                ForEach(0..<(pageSize - apps.count), id: \.self) { _ in
                    Color.clear.frame(height: 94)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 8)
    }
}

struct CPUFallbackGridPage: View {
    let apps: [AppItem]
    let columns: [GridItem]
    let gridSpacing: CGFloat
    let horizontalPadding: CGFloat
    let pageSize: Int
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(apps) { app in
                AppIconTile(app: app)
            }
            if apps.count < pageSize {
                ForEach(0..<(pageSize - apps.count), id: \.self) { _ in
                    Color.clear.frame(height: 94)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 8)
    }
}

// MARK: - GPU 图标瓦片
struct GPUAcceleratedAppTile: View {
    let app: AppItem
    let metalRenderer: MetalRenderer
    @State private var flashOpacity: Double = 0.0
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: {
            triggerClickEffect()
            launchApp()
        }) {
            VStack(spacing: 8) {
                MetalIconView(
                    app: app,
                    size: 72,
                    renderer: metalRenderer,
                    flashOpacity: flashOpacity,
                    isHovered: isHovered
                )
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .center)
                    .foregroundColor(.primary)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(LaunchpadButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Open") { launchApp() }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID, forType: .string)
            }
        }
    }
    
    private func triggerClickEffect() {
        withAnimation(.easeOut(duration: 0.08)) { flashOpacity = 0.18 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.easeOut(duration: 0.16)) { flashOpacity = 0.0 }
        }
    }
    
    private func launchApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        }
    }
}

// MARK: - 其它组件
struct GPUStatusIndicator: View {
    let isGPUUsed: Bool
    let scanTime: TimeInterval
    let appCount: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(isGPUUsed ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(isGPUUsed ? "GPU" : "CPU")
                .font(.caption2).opacity(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.black.opacity(0.15)).cornerRadius(8)
    }
}

struct PerformanceStatsView: View {
    let stats: (scanTime: TimeInterval, appCount: Int, gpuUsed: Bool)
    let filteredCount: Int
    
    var body: some View {
        HStack {
            Text("📊 \(stats.appCount) apps | \(String(format: "%.3f", stats.scanTime))s | Showing: \(filteredCount)")
                .font(.caption2).opacity(0.6)
            Spacer()
        }
    }
}

struct PageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalPages, id: \.self) { i in
                Circle()
                    .fill(i == min(currentPage, max(totalPages - 1, 0)) ?
                          Color.primary.opacity(0.8) : Color.primary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

struct LaunchpadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.interpolatingSpring(stiffness: 420, damping: 22), value: configuration.isPressed)
    }
}

struct AppIconTile: View {
    let app: AppItem
    @State private var flashOpacity: Double = 0.0

    var body: some View {
        let iconImage = IconProvider.icon(for: app, size: 72)

        Button(action: {
            withAnimation(.easeOut(duration: 0.08)) { flashOpacity = 0.18 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.16)) { flashOpacity = 0.0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
            }
        }) {
            VStack(spacing: 8) {
                if let icon = iconImage {
                    Image(nsImage: icon)
                        .renderingMode(.original)
                        .interpolation(.high)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(flashOpacity))
                        )
                }
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .center)
                    .foregroundColor(.primary)
            }
            .padding(6).contentShape(Rectangle())
        }
        .buttonStyle(LaunchpadButtonStyle())
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID, forType: .string)
            }
        }
    }
}
