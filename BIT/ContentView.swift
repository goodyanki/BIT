import SwiftUI
import AppKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var keyword: String = ""

    // 过滤后的应用列表
    var filteredApps: [AppItem] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if k.isEmpty {
            return apps
        }
        return apps.filter { item in
            let n1 = item.name.lowercased().contains(k)
            let n2 = item.bundleID.lowercased().contains(k)
            if n1 { return true }
            if n2 { return true }
            return false
        }
    }

    var body: some View {
        ZStack {
            WallpaperBackground()   // 桌面壁纸 + 模糊兜底
            WindowConfigurator()    // 全屏 + 透明窗口

            VStack(spacing: 16) {
                // 顶部毛玻璃搜索条
                ZStack {
                    ManualFrostedPanel(cornerRadius: 16, blurRadius: 20, tintColor: Color.white.opacity(0.25))
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

                        Button("Copy Wallpaper Path") {
                            if let url = currentDesktopWallpaperURL() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                }
                .padding(.top, 40)

                // 网格图标
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                            count: 7
                        ),
                        spacing: 16
                    ) {
                        ForEach(filteredApps) { app in
                            VStack(spacing: 8) {
                                if let icon = IconProvider.icon(for: app, size: 72) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 72, height: 72)
                                        .cornerRadius(16)
                                        .shadow(radius: 3)
                                }
                                Text(app.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(height: 14, alignment: .center)
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                            }
                            .contextMenu {
                                Button("Open") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
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
                    }
                    .padding(.leading, 40)
                    .padding(.trailing, 40)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            apps = AppScanner.scanAllApps()
        }
    }
}
