import AppKit
import BrowserSelectorCore

final class BrowserIconProvider {
    private var cache: [String: NSImage] = [:]
    private let launcher: BrowserLauncher

    init(launcher: BrowserLauncher) {
        self.launcher = launcher
    }

    func icon(for browser: BrowserEntry) -> NSImage? {
        if let icon = cache[browser.id] {
            return icon
        }
        guard let appURL = launcher.applicationURL(for: browser) else { return nil }
        guard let icon = IconRasterizer.smallIcon(forFile: appURL.path, size: 32) else { return nil }
        if cache.count > 64 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[browser.id] = icon
        return icon
    }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

/// 面板按需创建，关闭时立即释放内容视图，闲置状态不保留视图树。
final class PickerController {
    private let iconProvider: BrowserIconProvider

    private var panel: PickerPanel?
    private var state: PickerState?
    private var contentView: PickerContentView?
    private var keyMonitor: Any?
    private var globalMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var completion: ((BrowserEntry?) -> Void)?
    private var didFinish = false

    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    /// 面板在 CoreGraphics 全局坐标（左上为原点）中的位置，用于 EventTap 判断点击是否落在面板内。
    var panelFrameInGlobalCoordinates: CGRect? {
        guard let panel else { return nil }
        let frame = panel.frame
        let primaryHeight = primaryScreenHeight
        return CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    init(launcher: BrowserLauncher) {
        self.iconProvider = BrowserIconProvider(launcher: launcher)
    }

    func show(
        url: URL,
        browsers: [BrowserEntry],
        defaultBrowserID: String?,
        at point: CGPoint,
        completion: @escaping (BrowserEntry?) -> Void
    ) {
        tearDown()

        guard !browsers.isEmpty else {
            completion(nil)
            return
        }

        self.completion = completion
        self.didFinish = false
        self.previousApp = NSWorkspace.shared.frontmostApplication

        var icons: [String: NSImage] = [:]
        for browser in browsers {
            if let icon = iconProvider.icon(for: browser) {
                icons[browser.id] = icon
            }
        }

        let state = PickerState(
            url: url,
            browsers: browsers,
            icons: icons,
            defaultBrowserID: defaultBrowserID
        )
        self.state = state

        let size = PickerMetrics.panelSize(browsers.count)
        let panel = PickerPanel(size: size)
        let contentView = PickerContentView(state: state) { [weak self] browser in
            self?.dismiss(selecting: browser)
        }
        self.contentView = contentView
        panel.contentView = contentView
        panel.setFrame(frame(for: size, near: point), display: false)

        self.panel = panel
        installMonitors()
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true)
    }

    func dismiss(selecting browser: BrowserEntry?) {
        guard panel != nil, !didFinish else { return }
        didFinish = true

        let callback = completion
        completion = nil

        removeMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        state = nil
        onVisibilityChanged?(false)

        restoreFocus()
        callback?(browser)

        // 面板关闭后把 malloc 空闲页还给系统，避免 footprint 停留在面板显示时的高位。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func tearDown() {
        guard panel != nil else { return }
        didFinish = true
        removeMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        state = nil
        completion = nil
        previousApp = nil
        onVisibilityChanged?(false)
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true, let state = self.state else {
                return event
            }

            switch event.keyCode {
            case 53: // esc
                self.dismiss(selecting: nil)
                return nil
            case 125: // ↓
                state.move(1)
                self.contentView?.refreshSelection(scrollToVisible: true)
                return nil
            case 126: // ↑
                state.move(-1)
                self.contentView?.refreshSelection(scrollToVisible: true)
                return nil
            case 36, 76: // return / keypad enter
                if let browser = state.selectedBrowser {
                    self.dismiss(selecting: browser)
                }
                return nil
            default:
                if let characters = event.charactersIgnoringModifiers,
                   let number = Int(characters),
                   number >= 1,
                   number <= min(9, state.browsers.count) {
                    state.select(number - 1)
                    self.contentView?.refreshSelection(scrollToVisible: true)
                    if let browser = state.selectedBrowser {
                        self.dismiss(selecting: browser)
                    }
                    return nil
                }
                return event
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss(selecting: nil)
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func restoreFocus() {
        defer { previousApp = nil }
        guard let previousApp,
              previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        _ = previousApp.activate(options: [])
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? 0
    }

    private func frame(for size: NSSize, near point: CGPoint) -> NSRect {
        let primaryHeight = primaryScreenHeight
        let appKitPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let screen = NSScreen.screens.first { $0.frame.contains(appKitPoint) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: appKitPoint, size: size)
        }

        var x = appKitPoint.x + 6
        var y = appKitPoint.y - size.height - 6

        if x + size.width > visibleFrame.maxX - 8 {
            x = appKitPoint.x - size.width - 6
        }
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)

        if y < visibleFrame.minY + 8 {
            y = appKitPoint.y + 10
        }
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
