import AppKit
import BrowserSelectorCore

/// 通过 Launch Services 发现浏览器，首次扫描结果由 AppDelegate 合并进配置。
///
/// 只使用 `urlsForApplications(toOpen:)`：它会覆盖所有注册了 http/https 的应用，
/// 避免递归读取 /Applications 下每个 app 的 Info.plist（实测会增加约 3MB 常驻内存）。
/// 未注册的便携版浏览器走设置页的「添加浏览器」。
final class BrowserCatalog {
    private let queue = DispatchQueue(label: "com.zyl.BrowserSelector.browser-catalog", qos: .utility)

    func scan(completion: @escaping ([DiscoveredBrowser]) -> Void) {
        queue.async {
            var found: [String: DiscoveredBrowser] = [:]

            if let webURL = URL(string: "https://example.com") {
                for appURL in NSWorkspace.shared.urlsForApplications(toOpen: webURL) {
                    guard let browser = Self.makeDiscoveredBrowser(at: appURL) else { continue }
                    if found[browser.bundleIdentifier] == nil {
                        found[browser.bundleIdentifier] = browser
                    }
                }
            }

            let browsers = found.values.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            DispatchQueue.main.async {
                completion(browsers)
            }
        }
    }

    private static func makeDiscoveredBrowser(at appURL: URL) -> DiscoveredBrowser? {
        guard let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard schemes.contains(where: {
            let scheme = $0.lowercased()
            return scheme == "http" || scheme == "https"
        }) else {
            return nil
        }

        guard isWebBrowser(bundleIdentifier: bundleIdentifier, appURL: appURL) else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return DiscoveredBrowser(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            applicationPath: appURL.path
        )
    }

    /// Launch Services 也会返回 iTerm、VLC、URL 路由器等“能打开 URL”的应用，
    /// 这里用已知浏览器 ID 或内嵌浏览器引擎（Chromium/Gecko/WebKit）做二次过滤。
    private static func isWebBrowser(bundleIdentifier: String, appURL: URL) -> Bool {
        if knownBrowserBundleIDs.contains(bundleIdentifier) {
            return true
        }
        if knownBrowserBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return true
        }

        let frameworksURL = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let frameworks = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path) else {
            return false
        }
        return frameworks.contains { name in
            let lowercased = name.lowercased()
            return lowercased.contains("chromium")
                || lowercased.contains("mozilla")
                || lowercased.contains("gecko")
                || lowercased.contains("webkit")
                || lowercased.contains("chrome framework")
        }
    }

    private static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.chromium.Chromium",
        "com.duckduckgo.macos.browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.kagi.kagimacOS",
        "com.kagi.Orion",
        "app.zen-browser.zen",
        "io.github.zen_browser.zen"
    ]

    private static let knownBrowserBundlePrefixes = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser"
    ]
}
