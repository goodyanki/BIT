import SwiftUI
import AppKit

// --- 窗口配置：隐藏标题栏、透明、进入全屏 ---
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
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isMovableByWindowBackground = false
            win.collectionBehavior.insert(.fullScreenPrimary)
            if !win.styleMask.contains(.fullScreen) {
                win.toggleFullScreen(nil)
            }
        }
        .frame(width: 0, height: 0)
    }
}

// --- 桌面壁纸读取 ---
func currentDesktopWallpaper() -> NSImage? {
    guard let screen = NSScreen.main else { return nil }
    guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
    guard let img = NSImage(contentsOf: url) else { return nil }
    return img
}

// 返回当前主屏幕的壁纸文件 URL
func currentDesktopWallpaperURL() -> URL? {
    guard let screen = NSScreen.main else { return nil }
    return NSWorkspace.shared.desktopImageURL(for: screen)
}

// --- 背景：桌面图片 + 模糊 + 轻微压暗 ---
struct WallpaperBackground: View {
    @State private var image: NSImage? = currentDesktopWallpaper()

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                // 沙盒或时序原因获取失败时，退化为系统采样，避免黑屏
                VisualEffectView(material: .hudWindow, blending: .behindWindow)
                    .ignoresSafeArea()
            }
        }
        // 首次出现时刷新一次（进入全屏后可能需要一点时间）
        .onAppear {
            image = currentDesktopWallpaper()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                image = currentDesktopWallpaper()
            }
        }
        // 监听工作区切换
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            image = currentDesktopWallpaper()
        }
        // 监听壁纸变更（使用分布式通知 com.apple.desktop.changed）
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.desktop.changed"))) { _ in
            image = currentDesktopWallpaper()
        }
        // 屏幕参数变化（外接/分辨率变化）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            image = currentDesktopWallpaper()
        }
    }
}

// --- 毛玻璃层（采样窗口后景） ---
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

// --- 手动毛玻璃：使用壁纸图像进行模糊与着色 ---
struct ManualFrostedPanel: View {
    var cornerRadius: CGFloat = 16
    var blurRadius: CGFloat = 20
    var tintColor: Color = Color.white.opacity(0.25) // 轻微泛白以模拟毛玻璃

    @State private var image: NSImage? = currentDesktopWallpaper()

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: blurRadius)
                    .saturation(1.6)
                    .overlay(tintColor)
            } else {
                // 获取不到壁纸时退化为系统毛玻璃，避免纯黑
                VisualEffectView(material: .hudWindow, blending: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            image = currentDesktopWallpaper()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            image = currentDesktopWallpaper()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.desktop.changed"))) { _ in
            image = currentDesktopWallpaper()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            image = currentDesktopWallpaper()
        }
    }
}
