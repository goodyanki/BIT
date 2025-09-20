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

// 纯色背景组件
struct SolidBackground: View {
    var color: Color = Color(NSColor.windowBackgroundColor)
    var body: some View { color.ignoresSafeArea() }
}

// 在整个视图层接收两指左右“轻扫”事件（macOS：NSEvent.type == .swipe）
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

        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        // 两指左右轻扫事件
        override func swipe(with event: NSEvent) {
            // deltaX < 0 表示向左轻扫；> 0 表示向右
            if event.deltaX < 0 { onLeft() }
            else if event.deltaX > 0 { onRight() }
        }
    }
}
#endif
    
