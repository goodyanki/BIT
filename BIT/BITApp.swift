//
//  BITApp.swift
//  BIT
//
//  Created by yanqi on 2025/9/20.
//

import SwiftUI
import AppKit

@main
struct BITApp: App {
    
    init() {
        // 恢复用户的窗口偏好设置
        setupWindowPreferences()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(
                    minWidth: 400,
                    idealWidth: 1200,
                    maxWidth: CGFloat.infinity,
                    minHeight: 300,
                    idealHeight: 800,
                    maxHeight: CGFloat.infinity
                )
                .onAppear {
                    // 应用启动完成后的设置
                    configureAppBehavior()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
    
    private func setupWindowPreferences() {
        // 设置默认偏好
        if UserDefaults.standard.object(forKey: "LaunchpadFullScreen") == nil {
            UserDefaults.standard.set(true, forKey: "LaunchpadFullScreen")
        }
        
        // 其他应用级别的设置
        UserDefaults.standard.register(defaults: [
            "LaunchpadIconSize": 72.0,
            "LaunchpadAnimationDuration": 0.3,
            "LaunchpadSearchDebounce": 0.12
        ])
    }
    
    private func configureAppBehavior() {
        // 配置应用行为：禁用自动终止（使用 ProcessInfo API）
        ProcessInfo.processInfo.disableAutomaticTermination("BIT active")
        
        // 禁用自动隐藏菜单栏（在全屏模式下）
        if let window = NSApplication.shared.windows.first {
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
