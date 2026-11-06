import AppKit
import BrowserSelectorCore

enum BrowserLaunchError: LocalizedError {
    case applicationNotFound(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound(let name):
            return "找不到「\(name)」的应用路径，请在设置中重新指定。"
        case .launchFailed(let message):
            return "启动浏览器失败：\(message)"
        }
    }
}

final class BrowserLauncher {
    private var cache: [String: URL] = [:]
    private let lock = NSLock()

    func applicationURL(for browser: BrowserEntry) -> URL? {
        let key = cacheKey(for: browser)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var resolved: URL?
        if let path = browser.applicationPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            resolved = URL(fileURLWithPath: path)
        } else if let bundleIdentifier = browser.bundleIdentifier, !bundleIdentifier.isEmpty {
            resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }

        if let resolved {
            lock.lock()
            cache[key] = resolved
            lock.unlock()
        }
        return resolved
    }

    func canResolve(_ browser: BrowserEntry) -> Bool {
        applicationURL(for: browser) != nil
    }

    func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    func open(url: URL, with browser: BrowserEntry, completion: @escaping (Error?) -> Void) {
        guard let appURL = applicationURL(for: browser) else {
            completion(BrowserLaunchError.applicationNotFound(browser.displayName))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        if browser.hasCustomArguments {
            configuration.arguments = ArgumentTemplate.makeArguments(
                template: browser.argumentsTemplate,
                url: url
            )
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            ) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.invalidateCache()
                        completion(BrowserLaunchError.launchFailed(error.localizedDescription))
                    } else {
                        completion(nil)
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.invalidateCache()
                        completion(BrowserLaunchError.launchFailed(error.localizedDescription))
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    private func cacheKey(for browser: BrowserEntry) -> String {
        "\(browser.id)|\(browser.applicationPath ?? "")|\(browser.bundleIdentifier ?? "")"
    }
}
