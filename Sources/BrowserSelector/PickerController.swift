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
    private let hotKeys = PanelHotKeyManager()

    private var panel: PickerPanel?
    private var state: PickerState?
    private var contentView: PickerContentView?
    private var keyMonitor: Any?
    private var globalMonitor: Any?
    private var pressedRowIndex: Int?
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
        let contentView = PickerContentView(
            state: state,
            onSelect: { [weak self] browser in
                ClickTrace.log("picker select=\(browser.displayName)")
                self?.dismiss(selecting: browser)
            },
            onCancel: { [weak self] in
                ClickTrace.log("picker cancel")
                self?.dismiss(selecting: nil)
            }
        )
        self.contentView = contentView
        panel.contentView = contentView
        panel.setFrame(frame(for: size, near: point), display: false)
        ClickTrace.log("picker show frame=\(panel.frame) rows=\(browsers.count)")

        self.panel = panel
        installMonitors()
        hotKeys.activate { [weak self] command in
            self?.handleKeyCommand(command) ?? false
        }
        // HUD 面板不抢焦点；键盘通过面板生命周期内的 Carbon 热键转发。
        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
    }

    func dismiss(selecting browser: BrowserEntry?) {
        guard panel != nil, !didFinish else { return }
        didFinish = true

        let callback = completion
        completion = nil
        pressedRowIndex = nil

        removeMonitors()
        hotKeys.deactivate()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        state = nil
        onVisibilityChanged?(false)

        callback?(browser)

        // 面板关闭后把 malloc 空闲页还给系统，避免 footprint 停留在面板显示时的高位。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func tearDown() {
        guard panel != nil else { return }
        didFinish = true
        pressedRowIndex = nil
        removeMonitors()
        hotKeys.deactivate()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        state = nil
        completion = nil
        onVisibilityChanged?(false)
    }

    /// 全局 EventTap 在面板可见时把落在行上的按下交给这里：返回 true 表示
    /// 这次点击已由面板接管，调用方应吞掉该事件，不再交给 AppKit。
    func handlePanelPress(atGlobal point: CGPoint) -> Bool {
        guard !didFinish, let state, let contentView,
              let contentPoint = contentPoint(fromGlobal: point),
              let index = contentView.browserIndex(atContentPoint: contentPoint) else {
            return false
        }
        pressedRowIndex = index
        state.select(index)
        contentView.refreshSelection(scrollToVisible: false)
        contentView.setPressedRow(index)
        ClickTrace.log("picker press row=\(index)")
        return true
    }

    /// 抬起时只有仍落在按下的那一行才提交选择，保留“按下后拖开即取消”的语义。
    @discardableResult
    func handlePanelRelease(atGlobal point: CGPoint) -> Bool {
        let pressed = pressedRowIndex
        pressedRowIndex = nil
        contentView?.setPressedRow(nil)

        guard !didFinish, let state else { return pressed != nil }
        guard let pressed, state.browsers.indices.contains(pressed),
              let contentPoint = contentPoint(fromGlobal: point),
              let index = contentView?.browserIndex(atContentPoint: contentPoint),
              index == pressed else {
            ClickTrace.log("picker press cancelled")
            return true
        }

        let browser = state.browsers[pressed]
        ClickTrace.log("picker select=\(browser.displayName) source=EventTap")
        dismiss(selecting: browser)
        return true
    }

    private func contentPoint(fromGlobal point: CGPoint) -> NSPoint? {
        guard let panel, let contentView else { return nil }
        let appKitPoint = NSPoint(x: point.x, y: primaryScreenHeight - point.y)
        guard panel.frame.contains(appKitPoint) else { return nil }
        return contentView.convert(panel.convertPoint(fromScreen: appKitPoint), from: nil)
    }

    @discardableResult
    func handleKeyCommand(_ command: PanelKeyCommand) -> Bool {
        guard panel != nil, !didFinish, let state else { return false }

        switch command {
        case .cancel:
            dismiss(selecting: nil)
        case .previous:
            state.move(-1)
            contentView?.refreshSelection(scrollToVisible: true)
        case .next:
            state.move(1)
            contentView?.refreshSelection(scrollToVisible: true)
        case .confirm:
            guard let browser = state.selectedBrowser else { return false }
            dismiss(selecting: browser)
        case .digit(let number):
            guard number >= 1, number <= min(9, state.browsers.count) else { return false }
            state.select(number - 1)
            contentView?.refreshSelection(scrollToVisible: true)
            if let browser = state.selectedBrowser {
                dismiss(selecting: browser)
            }
        }
        return true
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil, let command = Self.keyCommand(from: event) else {
                return event
            }
            return self.handleKeyCommand(command) ? nil : event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            ClickTrace.log("picker outsideClick")
            self?.dismiss(selecting: nil)
        }
    }

    private static func keyCommand(from event: NSEvent) -> PanelKeyCommand? {
        switch event.keyCode {
        case 53: // esc
            return .cancel
        case 125: // ↓
            return .next
        case 126: // ↑
            return .previous
        case 36, 76: // return / keypad enter
            return .confirm
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let number = Int(characters),
                  (1...9).contains(number) else {
                return nil
            }
            return .digit(number)
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
