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
            
            // 设置最小窗口尺寸，确保至少能显示 3x2 网格
            win.minSize = NSSize(width: 400, height: 300)
            
            // 启动时进入全屏模式
            if !win.styleMask.contains(.fullScreen) {
                // 延迟执行，确保窗口完全加载
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

// 纯色背景组件
struct SolidBackground: View {
    var color: Color = Color(NSColor.windowBackgroundColor)
    var body: some View { color.ignoresSafeArea() }
}

// 修复后的手势捕获器
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
        
        // 防重复触发的时间戳
        private var lastGestureTime: TimeInterval = 0
        private let gestureThrottleInterval: TimeInterval = 0.5

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupTrackingArea()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
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
        
        // 防重复执行的辅助方法
        private func executeGestureIfAllowed(_ action: () -> Void) {
            let currentTime = Date().timeIntervalSince1970
            if currentTime - lastGestureTime >= gestureThrottleInterval {
                lastGestureTime = currentTime
                action()
            }
        }
        
        // 只使用滚轮事件，移除 swipe 事件避免重复
        override func scrollWheel(with event: NSEvent) {
            // 检查是否是触控板的双指滑动
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