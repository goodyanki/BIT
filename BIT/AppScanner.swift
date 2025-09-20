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
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var results: [AppItem] = []
        var seen = Set<String>()

        for dir in appDirs {
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    if url.pathExtension == "app" {
                        if let bundle = Bundle(url: url) {
                            if let bundleID = bundle.bundleIdentifier {
                                if !seen.contains(bundleID) {
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
                        }
                        e.skipDescendants()
                    }
                }
            }
        }
        // 简单按名称排序
        return results.sorted { a, b in
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

struct IconProvider {
    static func icon(for app: AppItem, size: CGFloat) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
