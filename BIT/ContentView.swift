import SwiftUI
import AppKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var keyword: String = ""
    @State private var debouncedKeyword: String = ""
    @State private var currentPage: Int = 0

    // 布局：固定 7 列 × 5 行，类似 Launchpad
    private let columnsCount = 7
    private let rowsCount = 5
    private var pageSize: Int { columnsCount * rowsCount }
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columnsCount)
    }

    // 过滤后的应用列表
    var filteredApps: [AppItem] {
        let k = debouncedKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if k.isEmpty {
            return apps
        }
        return apps.filter { item in
            let n1 = item.name.lowercased().contains(k)
            let n2 = item.bundleID.lowercased().contains(k)
            return n1 || n2
        }
    }

    // 分页后的数据
    var pages: [[AppItem]] {
        guard pageSize > 0 else { return [] }
        var result: [[AppItem]] = []
        var i = 0
        while i < filteredApps.count {
            let end = min(i + pageSize, filteredApps.count)
            result.append(Array(filteredApps[i..<end]))
            i = end
        }
        return result
    }

    var body: some View {
        ZStack {
            SolidBackground()      // 纯色背景
            WindowConfigurator()   // 全屏 + 透明窗口

            VStack(spacing: 16) {
                // 顶部毛玻璃搜索条
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
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                }
                .padding(.top, 40)

                // 横向分页网格
                VStack(spacing: 12) {
                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { index in
                            let page = pages[index]
                            LazyVGrid(columns: gridColumns, spacing: 16) {
                                ForEach(page) { app in
                                    AppIconTile(app: app)
                                }
                                // 用空白占位填满最后一页，保证左右对齐
                                if page.count < pageSize {
                                    ForEach(0..<(pageSize - page.count), id: \.self) { _ in
                                        Color.clear.frame(width: 0, height: 0)
                                    }
                                }
                            }
                            .padding(.horizontal, 40)
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
                    // 双指左右滑动或拖拽切页（macOS）
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 15)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > 40, abs(dx) > abs(dy) else { return }
                                if dx < 0 {
                                    // 向左滑，下一页
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        currentPage = min(currentPage + 1, max(pages.count - 1, 0))
                                    }
                                } else {
                                    // 向右滑，上一页
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        currentPage = max(currentPage - 1, 0)
                                    }
                                }
                            }
                    )
#else
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
#endif
                    .animation(.easeInOut(duration: 0.18), value: pages.count)

                    // 页码指示器（圆点）
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
            .ignoresSafeArea()
        }
        .onAppear {
            apps = AppScanner.scanAllApps()
            // 预热图标缓存，减少首次渲染抖动
            IconProvider.preheat(apps: apps, size: 72)
            debouncedKeyword = keyword
        }
        .onChange(of: keyword) { newValue in
            // 防抖，减少频繁过滤和视图重排
            let latest = newValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if latest == keyword {
                    debouncedKeyword = latest
                }
            }
        }
        .onChange(of: apps) { newApps in
            // 新结果时也做一次预热
            IconProvider.preheat(apps: newApps, size: 72)
        }
        .onChange(of: filteredApps) { _ in
            // 过滤结果变化时重置或钳制页码
            let count = pages.count
            if count == 0 { currentPage = 0 }
            else { currentPage = min(currentPage, count - 1) }
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
            // 闪光动画
            withAnimation(.easeOut(duration: 0.08)) { flashOpacity = 0.18 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.16)) { flashOpacity = 0.0 }
            }
            // 略微延迟启动，保留点击反馈的观感
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
                            // 快速白色闪光叠加
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
