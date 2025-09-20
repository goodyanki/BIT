import SwiftUI
import AppKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var keyword: String = ""
    @State private var debouncedKeyword: String = ""
    @State private var currentPage: Int = 0

    // 图标与单元尺寸（用于自适应计算）
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
        if k.isEmpty {
            return apps
        }
        return apps.filter { item in
            item.name.lowercased().contains(k) || item.bundleID.lowercased().contains(k)
        }
    }

    // 分页数据在 GeometryReader 中按窗口尺寸动态计算

    var body: some View {
        ZStack {
            SolidBackground()      // 纯色背景（定义于 UIHelpers.swift）
            WindowConfigurator()   // 窗口配置（定义于 UIHelpers.swift）

            VStack(spacing: 16) {
                // 顶部搜索条
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

                        Button("Rescan") {
                            apps = AppScanner.scanAllApps()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 40)

                // 横向分页网格 + 页码指示（自适应列/行）
                VStack(spacing: 12) {
                    GeometryReader { proxy in
                        // 可用宽高（去除左右内边距）
                        let availW = max(0, proxy.size.width - horizontalPadding * 2)
                        // 为圆点等留出空间 40
                        let availH = max(0, proxy.size.height - 40)
                        // 单元最小宽高（图标 + 文本 + 内边距）
                        let minTileW = iconSize + tileHPad * 2
                        let minTileH = iconSize + tileVPad * 2 + tileSpacingV + titleHeight
                        // 计算列数与行数（最多 7 列 × 5 行）
                        let cols = min(7, max(1, Int((availW + gridSpacing) / (minTileW + gridSpacing))))
                        let rows = min(5, max(1, Int((availH + gridSpacing) / (minTileH + gridSpacing))))
                        let pageSize = cols * rows

                        // 根据自适应 pageSize 对 filteredApps 分页
                        let pages: [[AppItem]] = stride(from: 0, to: filteredApps.count, by: max(pageSize,1)).map {
                            let end = min($0 + max(pageSize,1), filteredApps.count)
                            return Array(filteredApps[$0..<end])
                        }

                        // 网格列配置（自适应列数）
                        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: max(cols,1))

                        VStack(spacing: 12) {
                            TabView(selection: $currentPage) {
                                ForEach(pages.indices, id: \.self) { index in
                                    let page = pages[index]
                                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                                        ForEach(page) { app in
                                            AppIconTile(app: app)
                                        }
                                        // 占位，避免最后一页对不齐
                                        if page.count < pageSize {
                                            ForEach(0..<(pageSize - page.count), id: \.self) { _ in
                                                Color.clear.frame(height: minTileH)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, horizontalPadding)
                                    .padding(.bottom, 8)
                                    .tag(index)
                                }
                            }
#if os(macOS)
                            .tabViewStyle(DefaultTabViewStyle())
                            // 捕获两指左右轻扫（macOS）
                            .background(
                                SwipeCatcher(
                                    onLeft: { withAnimation(.easeInOut(duration: 0.22)) { currentPage = min(currentPage + 1, max(pages.count - 1, 0)) } },
                                    onRight: { withAnimation(.easeInOut(duration: 0.22)) { currentPage = max(currentPage - 1, 0) } }
                                ).ignoresSafeArea()
                            )
                            // 鼠标/触控拖拽切页（备用）
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 15)
                                    .onEnded { value in
                                        let dx = value.translation.width
                                        let dy = value.translation.height
                                        guard abs(dx) > 40, abs(dx) > abs(dy) else { return }
                                        if dx < 0 {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                currentPage = min(currentPage + 1, max(pages.count - 1, 0))
                                            }
                                        } else {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                currentPage = max(currentPage - 1, 0)
                                            }
                                        }
                                    }
                            )
#else
                            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
#endif
                            // 页码指示器
                            HStack(spacing: 6) {
                                ForEach(0..<(max(pages.count, 1)), id: \.self) { i in
                                    Circle()
                                        .fill(i == min(currentPage, max(pages.count - 1, 0)) ? Color.primary.opacity(0.8) : Color.primary.opacity(0.25))
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .padding(.bottom, 24)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: filteredApps)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            apps = AppScanner.scanAllApps()
            IconProvider.preheat(apps: apps, size: 72)
            debouncedKeyword = keyword
        }
        .onChange(of: keyword) { newValue in
            let latest = newValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if latest == keyword {
                    debouncedKeyword = latest
                }
            }
        }
        .onChange(of: apps) { newApps in
            IconProvider.preheat(apps: newApps, size: 72)
        }
        .onChange(of: filteredApps) { _ in
            currentPage = 0
        }
    }
}

// 自定义 ButtonStyle：按下时缩放，类似 Launchpad 点击反馈
struct LaunchpadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.interpolatingSpring(stiffness: 420, damping: 22), value: configuration.isPressed)
    }
}

// 应用图标单元，带点击缩放与闪光效果
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
            .padding(6)
            .contentShape(Rectangle())
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
