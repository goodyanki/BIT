import AppKit

// App 数据模型（最小字段）
struct AppItem: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

struct AppScanner {
    static func scanAllApps() -> [AppItem] {
        let appDirs: [URL] = [
            // 仅扫描 Launchpad 常见目录，避免暴露底层组件
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
        var results: [AppItem] = []
        var seen = Set<String>()

        for dir in appDirs {
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    if url.pathExtension == "app" {
                        if let bundle = Bundle(url: url) {
                            // 仅收录 Launchpad 应用：类型必须为 APPL，且非后台/Agent
                            let info = bundle.infoDictionary ?? [:]
                            let packageType = (info["CFBundlePackageType"] as? String) ?? ""
                            let isBackground = ((info["LSBackgroundOnly"] as? Bool) == true) || ((info["LSBackgroundOnly"] as? String) == "1")
                            let isUIElement = ((info["LSUIElement"] as? Bool) == true) || ((info["LSUIElement"] as? String) == "1")
                            guard packageType == "APPL", !isBackground, !isUIElement else {
                                e.skipDescendants();
                                continue
                            }

                            if let bundleID = bundle.bundleIdentifier, !seen.contains(bundleID) {
                                let raw1 = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                let raw2 = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                var name = url.deletingPathExtension().lastPathComponent
                                if let s = raw1 { name = s }
                                if let s = raw2 { name = s }
                                let item = AppItem(bundleID: bundleID, name: name, path: url.path)
                                results.append(item)
                                seen.insert(bundleID)
                            }
                        }
                        e.skipDescendants()
                    }
                }
            }
        }
        // 排序：苹果自带应用（bundleID 以 com.apple. 开头）在前，其余按名称字母排序
        return results.sorted { a, b in
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
}

struct IconProvider {
    private static let cache = NSCache<NSString, NSImage>()

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
        base.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        cache.setObject(image, forKey: key)
        return image
    }

    // 后台预热图标缓存，减少首次滚动或筛选卡顿
    static func preheat(apps: [AppItem], size: CGFloat) {
        let appsToHeat = apps
        DispatchQueue.global(qos: .utility).async {
            for app in appsToHeat {
                _ = self.icon(for: app, size: size)
            }
        }
    }
}
