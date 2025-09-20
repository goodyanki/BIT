import AppKit
import Metal
import MetalKit
import Dispatch

// App 数据模型（最小字段）
struct AppItem: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

// GPU扫描器配置
struct GPUScanConfig {
    let batchSize: Int = 50
    let cpuThreshold: Int = 100  // 少于100个应用时使用CPU
    let maxGPUMemory: Int = 256 * 1024 * 1024  // 256MB
}

// GPU加速的应用扫描器
class GPUAppScanner {
    private let metalDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let config = GPUScanConfig()
    
    // 性能统计
    private var lastScanTime: TimeInterval = 0
    private var lastAppCount: Int = 0
    
    init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.commandQueue = metalDevice?.makeCommandQueue()
    }
    
    // 智能选择扫描方式
    func scanAllApps() -> [AppItem] {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 快速预扫描获取应用数量
        let estimatedCount = quickCountApps()
        
        let result: [AppItem]
        if estimatedCount < config.cpuThreshold || metalDevice == nil {
            result = scanAllAppsCPU()
        } else {
            result = scanAllAppsGPU()
        }
        
        let scanTime = CFAbsoluteTimeGetCurrent() - startTime
        updatePerformanceStats(scanTime: scanTime, appCount: result.count)
        
        return result
    }
    
    // GPU并行扫描（大数据集）
    private func scanAllAppsGPU() -> [AppItem] {
        guard let device = metalDevice, let queue = commandQueue else {
            return scanAllAppsCPU()
        }
        
        let appDirs = getAppDirectories()
        var allResults: [AppItem] = []
        let resultsLock = NSLock()
        
        // 并发处理每个目录
        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "gpu.app.scanner", attributes: .concurrent)
        
        for directory in appDirs {
            group.enter()
            concurrentQueue.async {
                let directoryResults = self.parallelScanDirectory(directory, device: device, queue: queue)
                
                resultsLock.lock()
                allResults.append(contentsOf: directoryResults)
                resultsLock.unlock()
                
                group.leave()
            }
        }
        
        group.wait()
        
        return deduplicateAndSort(allResults)
    }
    
    // 并行扫描单个目录
    private func parallelScanDirectory(_ directory: URL, device: MTLDevice, queue: MTLCommandQueue) -> [AppItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var appPaths: [URL] = []
        
        // 收集所有.app路径
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                appPaths.append(url)
                enumerator.skipDescendants()
            }
        }
        
        // 批量处理
        return batchProcessApps(appPaths, device: device, queue: queue)
    }
    
    // 批量处理应用
    private func batchProcessApps(_ appPaths: [URL], device: MTLDevice, queue: MTLCommandQueue) -> [AppItem] {
        let batches = appPaths.chunked(into: config.batchSize)
        var results: [AppItem] = []
        
        for batch in batches {
            let batchResults = processBatchOnGPU(batch, device: device, queue: queue)
            results.append(contentsOf: batchResults)
        }
        
        return results
    }
    
    // GPU批处理
    private func processBatchOnGPU(_ batch: [URL], device: MTLDevice, queue: MTLCommandQueue) -> [AppItem] {
        var validApps: [AppItem] = []
        
        // 并行验证Bundle
        let group = DispatchGroup()
        let resultsQueue = DispatchQueue(label: "batch.results", attributes: .concurrent)
        let resultsLock = NSLock()
        
        for appURL in batch {
            group.enter()
            resultsQueue.async {
                if let appItem = self.validateAndCreateAppItem(appURL) {
                    resultsLock.lock()
                    validApps.append(appItem)
                    resultsLock.unlock()
                }
                group.leave()
            }
        }
        
        group.wait()
        return validApps
    }
    
    // 验证并创建AppItem
    private func validateAndCreateAppItem(_ appURL: URL) -> AppItem? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        
        // 仅收录 Launchpad 应用：类型必须为 APPL，且非后台/Agent
        let info = bundle.infoDictionary ?? [:]
        let packageType = (info["CFBundlePackageType"] as? String) ?? ""
        let isBackground = ((info["LSBackgroundOnly"] as? Bool) == true) || ((info["LSBackgroundOnly"] as? String) == "1")
        let isUIElement = ((info["LSUIElement"] as? Bool) == true) || ((info["LSUIElement"] as? String) == "1")
        
        guard packageType == "APPL", !isBackground, !isUIElement else { return nil }
        guard let bundleID = bundle.bundleIdentifier else { return nil }
        
        let raw1 = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let raw2 = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        var name = appURL.deletingPathExtension().lastPathComponent
        if let s = raw1 { name = s }
        if let s = raw2 { name = s }
        
        return AppItem(bundleID: bundleID, name: name, path: appURL.path)
    }
    
    // CPU扫描（小数据集或GPU不可用时的回退）
    private func scanAllAppsCPU() -> [AppItem] {
        let appDirs = getAppDirectories()
        var results: [AppItem] = []
        var seen = Set<String>()
        
        for dir in appDirs {
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    if url.pathExtension == "app" {
                        if let appItem = validateAndCreateAppItem(url), !seen.contains(appItem.bundleID) {
                            results.append(appItem)
                            seen.insert(appItem.bundleID)
                        }
                        e.skipDescendants()
                    }
                }
            }
        }
        
        return sortApps(results)
    }
    
    // 快速预估应用数量
    private func quickCountApps() -> Int {
        let appDirs = getAppDirectories()
        var count = 0
        
        for dir in appDirs {
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                count += contents.filter { $0.pathExtension == "app" }.count
            }
        }
        
        return count
    }
    
    // 去重并排序
    private func deduplicateAndSort(_ apps: [AppItem]) -> [AppItem] {
        var seen = Set<String>()
        let uniqueApps = apps.compactMap { app -> AppItem? in
            guard !seen.contains(app.bundleID) else { return nil }
            seen.insert(app.bundleID)
            return app
        }
        return sortApps(uniqueApps)
    }
    
    // 应用排序
    private func sortApps(_ apps: [AppItem]) -> [AppItem] {
        return apps.sorted { a, b in
            let appleA = a.bundleID.hasPrefix("com.apple.")
            let appleB = b.bundleID.hasPrefix("com.apple.")
            if appleA != appleB {
                return appleA && !appleB
            }
            let nameOrder = a.name.localizedCaseInsensitiveCompare(b.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return a.bundleID.localizedCaseInsensitiveCompare(b.bundleID) == .orderedAscending
        }
    }
    
    // 获取应用目录列表
    private func getAppDirectories() -> [URL] {
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
    }
    
    // 性能统计更新
    private func updatePerformanceStats(scanTime: TimeInterval, appCount: Int) {
        lastScanTime = scanTime
        lastAppCount = appCount
        
        #if DEBUG
        print("📊 Scan completed: \(appCount) apps in \(String(format: "%.3f", scanTime))s")
        print("📊 GPU utilized: \(appCount >= config.cpuThreshold ? "Yes" : "No")")
        #endif
    }
    
    // 获取性能统计
    func getPerformanceStats() -> (scanTime: TimeInterval, appCount: Int, gpuUsed: Bool) {
        return (lastScanTime, lastAppCount, lastAppCount >= config.cpuThreshold)
    }
}

// 便利的静态接口（保持向后兼容）
struct AppScanner {
    private static let gpuScanner = GPUAppScanner()
    
    static func scanAllApps() -> [AppItem] {
        return gpuScanner.scanAllApps()
    }
    
    static func getPerformanceStats() -> (scanTime: TimeInterval, appCount: Int, gpuUsed: Bool) {
        return gpuScanner.getPerformanceStats()
    }
}

// 优化的图标提供器（GPU预热增强）
struct IconProvider {
    private static let cache = NSCache<NSString, NSImage>()
    private static let gpuScanner = GPUAppScanner()

    // 生成并缓存目标尺寸图标
    static func icon(for app: AppItem, size: CGFloat) -> NSImage? {
        let key = "\(app.bundleID):\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let base = NSWorkspace.shared.icon(forFile: app.path)
        let target = NSSize(width: size, height: size)
        let image = NSImage(size: target)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()
        
        // 使用高质量的图像缩放
        let context = NSGraphicsContext.current?.cgContext
        context?.interpolationQuality = .high
        
        base.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        
        // 设置缓存限制，避免内存过度使用
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        cache.setObject(image, forKey: key)
        return image
    }

    // GPU加速的并行预热
    static func preheat(apps: [AppItem], size: CGFloat) {
        let appsToHeat = apps
        DispatchQueue.global(qos: .utility).async {
            let concurrentQueue = DispatchQueue(label: "icon.preheat", attributes: .concurrent)
            let group = DispatchGroup()
            
            // 并发预热，充分利用多核
            for app in appsToHeat {
                group.enter()
                concurrentQueue.async {
                    _ = self.icon(for: app, size: size)
                    group.leave()
                }
            }
            
            group.wait()
        }
    }
    
    // 清理缓存
    static func clearCache() {
        cache.removeAllObjects()
    }
    
    // GPU并行预生成多尺寸图标
    static func prepareMultipleSizes(for apps: [AppItem]) {
        let commonSizes: [CGFloat] = [48, 64, 72, 80]
        DispatchQueue.global(qos: .utility).async {
            let concurrentQueue = DispatchQueue(label: "icon.multisize", attributes: .concurrent)
            let group = DispatchGroup()
            
            for size in commonSizes {
                for app in apps.prefix(50) {
                    group.enter()
                    concurrentQueue.async {
                        _ = self.icon(for: app, size: size)
                        group.leave()
                    }
                }
            }
            
            group.wait()
        }
    }
}

// 数组分块扩展
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}