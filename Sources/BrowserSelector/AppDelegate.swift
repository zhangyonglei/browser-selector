import AppKit
import BrowserSelectorCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let configStore = ConfigStore()
    private let clickGate = ClickGate()
    private let windowCache = WindowSnapshotCache()
    private let linkExtractor = LinkExtractor()
    private let browserCatalog = BrowserCatalog()
    private let browserLauncher = BrowserLauncher()

    private var clickMonitor: ClickMonitor?
    private var pickerController: PickerController!
    private var settingsWindowController: SettingsWindowController?
    private var settingsCloseObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem?
    private var statusLabelItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var permissionItem: NSMenuItem?

    private var router = DomainRouter(rules: [])
    private var isPaused = false
    private var didPromptAccessibility = false
    private var isScanningBrowsers = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: .browserSelectorShowSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }

        pickerController = PickerController(launcher: browserLauncher)
        pickerController.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.clickGate.setPanelFrame(
                visible ? self.pickerController.panelFrameInGlobalCoordinates : nil
            )
            self.clickGate.setPanelVisible(visible)
            if !visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.refreshFrontmost()
                }
            }
        }

        configStore.onChange = { [weak self] config in
            self?.apply(config)
        }

        setupStatusItem()
        apply(configStore.config)
        observeWorkspace()
        refreshFrontmost()

        let arguments = CommandLine.arguments
        if !arguments.contains("--no-scan"), configStore.config.browsers.isEmpty {
            scanBrowsers()
        }

        if let seconds = benchmarkDurationFromArguments() {
            if !arguments.contains("--no-tap") {
                startMonitoring(promptIfNeeded: false)
            }
            runBenchmark(seconds: seconds)
            return
        }

        if arguments.contains("--benchmark-panel") {
            runPanelBenchmark()
            return
        }

        if arguments.contains("--benchmark-click") {
            runClickGateBenchmark()
            NSApp.terminate(nil)
            return
        }

        if arguments.contains("--test-longpress") {
            runLongPressSelfTest()
            NSApp.terminate(nil)
            return
        }

        if arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.previewPicker(centered: true)
            }
            return
        }

        if let renderIndex = arguments.firstIndex(of: "--render-preview") {
            let path = arguments.count > renderIndex + 1
                ? arguments[renderIndex + 1]
                : NSTemporaryDirectory() + "browser-selector-panel.png"
            renderPreview(to: path)
            NSApp.terminate(nil)
            return
        }

        startMonitoring(promptIfNeeded: true)
    }

    // MARK: - 配置

    private func apply(_ config: AppConfig) {
        router = DomainRouter(rules: config.routingRules)
        clickGate.setTargets(config.enabledTargetApplications)
        clickGate.setExclusions(config.exclusions)
        clickGate.setPaused(isPaused)
        clickMonitor?.configure(interactionConfiguration())
        updateStatusItemTitle()
        refreshFrontmost()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "cursorarrow.click.2",
                accessibilityDescription: "浏览器选择器"
            ) ?? NSImage(
                systemSymbolName: "cursorarrow.click",
                accessibilityDescription: "浏览器选择器"
            ) ?? NSImage(
                systemSymbolName: "link",
                accessibilityDescription: "浏览器选择器"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "浏览器选择器"
        }

        let menu = NSMenu()
        menu.delegate = self

        let label = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        statusLabelItem = label

        menu.addItem(.separator())
        menu.addItem(makeMenuItem("设置…", action: #selector(openSettings), key: ","))
        let pause = makeMenuItem(
            "暂停拦截",
            action: #selector(togglePause),
            key: "p",
            modifiers: [.command, .shift]
        )
        menu.addItem(pause)
        pauseItem = pause
        menu.addItem(makeMenuItem("重新扫描浏览器", action: #selector(rescanBrowsers), key: ""))

        menu.addItem(.separator())
        let permission = makeMenuItem(
            "授予辅助功能权限…",
            action: #selector(openAccessibilitySettings),
            key: ""
        )
        menu.addItem(permission)
        permissionItem = permission
        menu.addItem(makeMenuItem("重新检测权限并启动", action: #selector(retryMonitoring), key: ""))
        menu.addItem(makeMenuItem("屏幕录制权限…", action: #selector(openScreenRecordingSettings), key: ""))

        menu.addItem(.separator())
        menu.addItem(makeMenuItem("测试光标处链接", action: #selector(debugLinkAtCursor), key: ""))
        menu.addItem(makeMenuItem("预览选择面板", action: #selector(previewPickerMenuAction), key: ""))
        menu.addItem(makeMenuItem("诊断信息…", action: #selector(showDiagnostics), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("退出", action: #selector(quit), key: "q"))

        item.menu = menu
        statusItem = item
        updateStatusItemTitle()
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusItemTitle()
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshFrontmost()
        }
    }

    private func updateStatusItemTitle() {
        statusLabelItem?.title = statusText()
        pauseItem?.title = isPaused ? "恢复拦截" : "暂停拦截"
        statusItem?.button?.appearsDisabled = isPaused || !PermissionManager.isAccessibilityTrusted
    }

    private func statusText() -> String {
        if isPaused { return "已暂停" }
        if !PermissionManager.isAccessibilityTrusted { return "未授权辅助功能" }
        if clickMonitor?.isRunning == true { return "监听中" }
        return "监听未运行"
    }

    // MARK: - 监听

    private func startMonitoring(promptIfNeeded: Bool) {
        guard !isPaused else {
            stopMonitoring()
            updateStatusItemTitle()
            return
        }

        guard PermissionManager.isAccessibilityTrusted else {
            stopMonitoring()
            if promptIfNeeded, !didPromptAccessibility {
                didPromptAccessibility = true
                PermissionManager.promptAccessibility()
            }
            updateStatusItemTitle()
            return
        }

        if clickMonitor?.isRunning == true {
            updateStatusItemTitle()
            return
        }

        let monitor = ClickMonitor(gate: clickGate)
        monitor.configure(interactionConfiguration())
        monitor.onCandidate = { [weak self] candidate in
            self?.handle(candidate)
        }
        monitor.onLongPressCandidate = { [weak self] candidate in
            self?.handleLongPress(candidate)
        }
        monitor.onOutsideClickWhilePanelVisible = { [weak self] in
            DispatchQueue.main.async {
                self?.pickerController.dismiss(selecting: nil)
            }
        }

        if monitor.start() {
            clickMonitor = monitor
            ClickTrace.log("tap started trusted=\(PermissionManager.isAccessibilityTrusted ? 1 : 0)")
        } else {
            clickMonitor = nil
            ClickTrace.log("tap start failed trusted=\(PermissionManager.isAccessibilityTrusted ? 1 : 0)")
        }
        updateStatusItemTitle()
    }

    private func stopMonitoring() {
        clickMonitor?.stop()
        clickMonitor = nil
    }

    private func interactionConfiguration() -> InteractionConfiguration {
        let behavior = configStore.config.behavior
        return InteractionConfiguration(
            longPressDuration: Double(behavior.longPressDurationMilliseconds) / 1_000,
            movementTolerance: 8
        )
    }

    private func handleLongPress(_ candidate: LongPressCandidate) {
        let baseline = PasteboardProbe.changeCount()
        let delay = configStore.config.behavior.clipboardFallbackDelayMilliseconds

        linkExtractor.extract(
            at: candidate.location,
            pid: candidate.pid,
            clipboardBaseline: baseline,
            delayMilliseconds: delay
        ) { [weak self] result in
            guard let self else { return }
            guard let result else {
                Log.debug("长按未解析到链接，回放 mouseUp pid=\(candidate.pid)")
                ClickTrace.log("longPress result=nil replay mouseUp")
                self.clickMonitor?.finishLongPress(candidateID: candidate.id, replay: true)
                return
            }
            Log.debug("长按解析到链接 \(result.url.absoluteString)（\(result.source.displayName)）")
            ClickTrace.log("longPress result=\(result.url.absoluteString) source=\(result.source.displayName)")
            DispatchQueue.main.async {
                self.showPicker(url: result.url, candidate: candidate)
            }
        }
    }

    private func handle(_ candidate: ClickCandidate) {
        let baseline = PasteboardProbe.changeCount()
        let delay = configStore.config.behavior.clipboardFallbackDelayMilliseconds

        linkExtractor.extract(
            at: candidate.location,
            pid: candidate.pid,
            clipboardBaseline: baseline,
            delayMilliseconds: delay
        ) { [weak self] result in
            guard let self else { return }
            guard let result else {
                Log.debug("未解析到链接，回放点击 pid=\(candidate.pid)")
                ClickTrace.log("swallow result=nil replay click")
                self.clickMonitor?.finish(candidateID: candidate.id, replay: true)
                return
            }
            Log.debug("解析到链接 \(result.url.absoluteString)（\(result.source.displayName)）")
            ClickTrace.log("swallow result=\(result.url.absoluteString) source=\(result.source.displayName)")
            DispatchQueue.main.async {
                self.route(url: result.url, candidate: candidate)
            }
        }
    }

    private func route(url: URL, candidate: ClickCandidate) {
        let config = configStore.config
        let forcePanel = candidate.flags.contains(.maskCommand)

        if !forcePanel,
           let browserID = router.browserID(for: url),
           let browser = config.browser(withID: browserID),
           browser.isEnabled,
           browserLauncher.canResolve(browser) {
            launch(url: url, browser: browser)
            clickMonitor?.finish(candidateID: candidate.id, replay: false)
            return
        }

        if !forcePanel, config.behavior.panelOnlyWithCommandModifier {
            if let defaultBrowser = config.effectiveDefaultBrowser,
               browserLauncher.canResolve(defaultBrowser) {
                launch(url: url, browser: defaultBrowser)
                clickMonitor?.finish(candidateID: candidate.id, replay: false)
            } else {
                clickMonitor?.finish(candidateID: candidate.id, replay: true)
            }
            return
        }

        showPicker(url: url, candidate: candidate)
    }

    private func showPicker(url: URL, candidate: ClickCandidate) {
        guard presentPicker(url: url, at: candidate.location) else {
            clickMonitor?.finish(candidateID: candidate.id, replay: true)
            return
        }
        clickMonitor?.finish(candidateID: candidate.id, replay: false)
    }

    private func showPicker(url: URL, candidate: LongPressCandidate) {
        guard presentPicker(url: url, at: candidate.location) else {
            clickMonitor?.finishLongPress(candidateID: candidate.id, replay: true)
            return
        }
        clickMonitor?.finishLongPress(candidateID: candidate.id, replay: false)
    }

    private func presentPicker(url: URL, at point: CGPoint) -> Bool {
        let config = configStore.config
        let browsers = config.enabledBrowsers.filter { browserLauncher.canResolve($0) }
        ClickTrace.log(
            "presentPicker url=\(url.absoluteString)"
                + " browsers=\(browsers.map { $0.displayName })"
                + " at=\(Int(point.x)),\(Int(point.y))"
        )
        guard !browsers.isEmpty else {
            scanBrowsers()
            return false
        }

        pickerController.show(
            url: url,
            browsers: browsers,
            defaultBrowserID: config.effectiveDefaultBrowser?.id,
            at: point
        ) { [weak self] selectedBrowser in
            guard let self, let selectedBrowser else { return }
            self.launch(url: url, browser: selectedBrowser)
        }
        return true
    }

    private func launch(url: URL, browser: BrowserEntry) {
        browserLauncher.open(url: url, with: browser) { [weak self] error in
            guard let error else { return }
            self?.presentError(error)
        }
    }

    // MARK: - 浏览器扫描

    private func scanBrowsers() {
        guard !isScanningBrowsers else { return }
        isScanningBrowsers = true
        browserCatalog.scan { [weak self] discovered in
            guard let self else { return }
            self.isScanningBrowsers = false
            self.configStore.update { config in
                config.merge(discovered: discovered)
            }
            self.browserLauncher.invalidateCache()
            self.updateStatusItemTitle()
        }
    }

    // MARK: - 应用 / 窗口状态

    private func observeWorkspace() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            clickGate.setFrontmost(
                bundleIdentifier: application.bundleIdentifier,
                pid: application.processIdentifier
            )
            if shouldSnapshotWindows(for: application.bundleIdentifier) {
                refreshWindows(for: application.processIdentifier)
            }
        } else {
            refreshFrontmost()
        }

        if !PermissionManager.isAccessibilityTrusted { return }
        if clickMonitor?.isRunning != true, !isPaused {
            startMonitoring(promptIfNeeded: false)
        }
    }

    @objc private func workspaceApplicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        clickGate.removeWindows(for: application.processIdentifier)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        if PermissionManager.isAccessibilityTrusted, !isPaused {
            startMonitoring(promptIfNeeded: false)
        }
        refreshFrontmost()
    }

    @objc func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshFrontmost()
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshFrontmost()
    }

    private func refreshFrontmost() {
        let application = NSWorkspace.shared.frontmostApplication
        clickGate.setFrontmost(
            bundleIdentifier: application?.bundleIdentifier,
            pid: application?.processIdentifier ?? 0
        )
        if let application, shouldSnapshotWindows(for: application.bundleIdentifier) {
            refreshWindows(for: application.processIdentifier)
        }
    }

    private func shouldSnapshotWindows(for bundleIdentifier: String?) -> Bool {
        clickGate.isTarget(bundleIdentifier: bundleIdentifier)
    }

    private func refreshWindows(for pid: pid_t) {
        windowCache.refresh(pid: pid) { [weak self] windows in
            self?.clickGate.setWindows(windows, for: pid)
        }
    }

    // MARK: - 菜单动作

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(
                store: configStore,
                statusProvider: { [weak self] in self?.runtimeStatus() ?? RuntimeStatus() },
                debugLinkAction: { [weak self] in self?.debugLinkAtCursor() },
                rescanAction: { [weak self] in self?.scanBrowsers() }
            )
            if let window = controller.window {
                settingsCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self?.refreshFrontmost()
                    }
                }
            }
            settingsWindowController = controller
        }
        settingsWindowController?.present()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        clickGate.setPaused(isPaused)
        if isPaused {
            stopMonitoring()
        } else {
            startMonitoring(promptIfNeeded: false)
        }
        updateStatusItemTitle()
    }

    @objc private func rescanBrowsers() {
        scanBrowsers()
    }

    @objc private func retryMonitoring() {
        didPromptAccessibility = false
        startMonitoring(promptIfNeeded: true)
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.promptAccessibility()
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        PermissionManager.requestScreenRecording()
    }

    @objc private func debugLinkAtCursor() {
        guard PermissionManager.isAccessibilityTrusted else {
            presentInformation(
                title: "需要辅助功能权限",
                message: "请先在「系统设置 → 隐私与安全性 → 辅助功能」中勾选浏览器选择器，然后重试。"
            )
            return
        }

        let point = CGEvent(source: nil)?.location ?? .zero
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let baseline = PasteboardProbe.changeCount()
        let delay = configStore.config.behavior.clipboardFallbackDelayMilliseconds

        linkExtractor.extract(
            at: point,
            pid: pid,
            clipboardBaseline: baseline,
            delayMilliseconds: delay
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.presentInformation(
                        title: "识别到链接",
                        message: "\(result.url.absoluteString)\n\n来源：\(result.source.displayName)"
                    )
                } else {
                    self.presentInformation(
                        title: "未识别到链接",
                        message: "光标处没有可用的 AX 链接或新的剪贴板内容。请确认光标位于链接上，并且目标应用已开启辅助功能。"
                    )
                }
            }
        }
    }

    @objc private func previewPickerMenuAction() {
        previewPicker(centered: false)
    }

    private func previewPicker(centered: Bool) {
        let browsers = previewBrowsers()
        guard !browsers.isEmpty else { return }

        let point: CGPoint
        if centered {
            let visibleFrame = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? visibleFrame.maxY
            point = CGPoint(x: visibleFrame.midX, y: primaryHeight - visibleFrame.midY)
        } else {
            point = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 400)
        }

        pickerController.show(
            url: URL(string: "https://github.com/qwen-code/browser-selector/pull/42/files")!,
            browsers: browsers,
            defaultBrowserID: configStore.config.effectiveDefaultBrowser?.id ?? browsers.first?.id,
            at: point
        ) { _ in }
    }

    private func previewBrowsers() -> [BrowserEntry] {
        let configured = configStore.config.enabledBrowsers.filter { browserLauncher.canResolve($0) }
        if !configured.isEmpty {
            return configured
        }
        return [
            BrowserEntry(
                id: "com.apple.Safari",
                displayName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            ),
            BrowserEntry(
                id: "com.google.Chrome",
                displayName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        ]
    }

    private func renderPreview(to path: String) {
        let browsers = previewBrowsers()
        guard !browsers.isEmpty else { return }

        var icons: [String: NSImage] = [:]
        for browser in browsers {
            guard let appURL = browserLauncher.applicationURL(for: browser),
                  let icon = IconRasterizer.smallIcon(forFile: appURL.path, size: 32) else {
                continue
            }
            icons[browser.id] = icon
        }

        let state = PickerState(
            url: URL(string: "https://github.com/qwen-code/browser-selector/pull/42/files")!,
            browsers: browsers,
            icons: icons,
            defaultBrowserID: configStore.config.effectiveDefaultBrowser?.id ?? browsers.first?.id
        )
        let size = PickerMetrics.panelSize(browsers.count)
        let content = PickerContentView(
            state: state,
            onSelect: { _ in },
            onCancel: {}
        )
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()

        let padding: CGFloat = 24
        let container = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: size.width + padding * 2,
                height: size.height + padding * 2
            )
        )
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.frame.origin = NSPoint(x: padding, y: padding)
        container.addSubview(content)

        guard let representation = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            return
        }
        container.cacheDisplay(in: container.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("panel preview written to \(path)")
        fflush(stdout)
    }

    @objc private func showDiagnostics() {
        let status = runtimeStatus()
        let message = """
        拦截：\(status.isPaused ? "已暂停" : (status.tapRunning ? "监听中" : "未运行"))
        辅助功能：\(status.accessibilityTrusted ? "已授权" : "未授权")
        屏幕录制：\(status.screenRecordingGranted ? "已授权" : "未授权")
        内存（RSS）：\(Diagnostics.formattedBytes(Diagnostics.residentMemoryBytes()))
        内存（Footprint）：\(Diagnostics.formattedBytes(Diagnostics.physicalFootprintBytes()))
        累计 CPU：\(String(format: "%.2f s", Diagnostics.cpuSeconds()))
        浏览器 / 目标应用：\(status.browserCount) / \(status.targetApplicationCount)
        窗口缓存：\(status.windowSnapshotCount) 个窗口

        配置文件：
        \(AppPaths.configFileURL.path)
        """
        presentInformation(title: "浏览器选择器诊断", message: message)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 辅助

    private func runtimeStatus() -> RuntimeStatus {
        RuntimeStatus(
            tapRunning: clickMonitor?.isRunning == true,
            isPaused: isPaused,
            accessibilityTrusted: PermissionManager.isAccessibilityTrusted,
            screenRecordingGranted: PermissionManager.hasScreenRecording,
            targetApplicationCount: configStore.config.enabledTargetApplications.count,
            browserCount: configStore.config.enabledBrowsers.count,
            windowSnapshotCount: clickGate.windowSnapshotCount,
            frontmostApplication: NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        )
    }

    private func presentInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1b}"
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }

    // MARK: - 基准测试

    private func benchmarkDurationFromArguments() -> Double? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--benchmark") else { return nil }
        if arguments.count > index + 1, let value = Double(arguments[index + 1]), value > 0 {
            return value
        }
        return 5
    }

    private func runBenchmark(seconds: Double) {
        let duration = max(seconds, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let startCPU = Diagnostics.cpuSeconds()
            let startDate = Date()

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                let elapsed = Date().timeIntervalSince(startDate)
                let cpu = Diagnostics.cpuSeconds() - startCPU
                let cpuPercent = elapsed > 0 ? (cpu / elapsed) * 100 : 0
                let rss = Diagnostics.residentMemoryBytes()
                let footprint = Diagnostics.physicalFootprintBytes()
                let tapRunning = self.clickMonitor?.isRunning == true

                let line = "benchmark idle_seconds=\(String(format: "%.2f", elapsed))"
                    + " cpu_seconds=\(String(format: "%.4f", cpu))"
                    + " cpu_percent=\(String(format: "%.3f", cpuPercent))"
                    + " rss_bytes=\(rss)"
                    + " footprint_bytes=\(footprint)"
                    + " ax_trusted=\(PermissionManager.isAccessibilityTrusted ? 1 : 0)"
                    + " tap_running=\(tapRunning ? 1 : 0)"
                    + " browsers=\(self.configStore.config.browsers.count)"
                print(line)
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    /// 验证面板是懒加载且关闭后释放：分别打印显示时与关闭后的 footprint。
    private func runPanelBenchmark() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.previewPicker(centered: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            print("benchmark_panel footprint_visible_bytes=\(Diagnostics.physicalFootprintBytes())")
            fflush(stdout)
            self.pickerController.dismiss(selecting: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("benchmark_panel footprint_after_dismiss_bytes=\(Diagnostics.physicalFootprintBytes())")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// 观测 EventTap 回调里最重的一段纯内存判断（含锁、窗口矩形命中）。
    private func runClickGateBenchmark() {
        let targetBundleID = "com.zyl.BrowserSelector.benchmark-target"
        clickGate.setTargets([
            TargetApplication(
                displayName: "Benchmark",
                bundleIdentifier: targetBundleID,
                mode: .observe
            )
        ])
        clickGate.setExclusions(ExclusionRules())
        clickGate.setFrontmost(bundleIdentifier: targetBundleID, pid: getpid())
        clickGate.setWindows(
            [WindowSnapshot(bounds: CGRect(x: 0, y: 0, width: 4_000, height: 4_000), title: nil)],
            for: getpid()
        )

        let point = CGPoint(x: 1_200, y: 800)
        let iterations = 200_000
        let start = CFAbsoluteTimeGetCurrent()
        var hits = 0
        for _ in 0..<iterations {
            if clickGate.evaluate(point: point, flags: []) != nil {
                hits += 1
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let nanosecondsPerCall = elapsed / Double(iterations) * 1_000_000_000
        print(
            "benchmark_click iterations=\(iterations)"
                + " total_seconds=\(String(format: "%.4f", elapsed))"
                + " ns_per_call=\(String(format: "%.1f", nanosecondsPerCall))"
                + " hits=\(hits)"
        )
        fflush(stdout)
    }

    /// 不依赖真实点击/权限的长按状态机自测。
    private func runLongPressSelfTest() {
        let gate = ClickGate()
        gate.setTargets([
            TargetApplication(
                displayName: "SelfTest",
                bundleIdentifier: "com.zyl.BrowserSelector.selftest",
                mode: .observe
            )
        ])
        gate.setFrontmost(
            bundleIdentifier: "com.zyl.BrowserSelector.selftest",
            pid: getpid()
        )
        gate.setWindows(
            [WindowSnapshot(
                bounds: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000),
                title: nil
            )],
            for: getpid()
        )

        let monitor = ClickMonitor(gate: gate, ownPID: 0)
        monitor.configure(
            InteractionConfiguration(
                longPressDuration: 0.3,
                movementTolerance: 8
            )
        )

        let callbackFired = DispatchSemaphore(value: 0)
        var callbackCount = 0
        monitor.onLongPressCandidate = { candidate in
            callbackCount += 1
            monitor.finishLongPress(candidateID: candidate.id, replay: false)
            callbackFired.signal()
        }

        let point = CGPoint(x: 100, y: 100)
        func mouseEvent(_ type: CGEventType, at location: CGPoint) -> CGEvent {
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .left
            )!
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }

        _ = monitor.handle(
            type: .leftMouseDown,
            event: mouseEvent(.leftMouseDown, at: point)
        )
        Thread.sleep(forTimeInterval: 0.35)
        let longPressResult = monitor.handle(
            type: .leftMouseUp,
            event: mouseEvent(.leftMouseUp, at: point)
        )
        let longPressSwallowed = longPressResult == nil
        let longPressFired = callbackFired.wait(timeout: .now() + 1) == .success

        _ = monitor.handle(
            type: .leftMouseDown,
            event: mouseEvent(.leftMouseDown, at: point)
        )
        Thread.sleep(forTimeInterval: 0.05)
        let shortPressResult = monitor.handle(
            type: .leftMouseUp,
            event: mouseEvent(.leftMouseUp, at: point)
        )
        let shortPressPassed = shortPressResult != nil

        _ = monitor.handle(
            type: .leftMouseDown,
            event: mouseEvent(.leftMouseDown, at: point)
        )
        Thread.sleep(forTimeInterval: 0.35)
        let dragResult = monitor.handle(
            type: .leftMouseUp,
            event: mouseEvent(.leftMouseUp, at: CGPoint(x: point.x + 50, y: point.y))
        )
        let dragPassed = dragResult != nil

        // 吞掉并回放：点击立即吞下，不等长按。
        let swallowCallback = DispatchSemaphore(value: 0)
        var swallowCount = 0
        monitor.onCandidate = { candidate in
            swallowCount += 1
            monitor.finish(candidateID: candidate.id, replay: false)
            swallowCallback.signal()
        }
        gate.setTargets([
            TargetApplication(
                displayName: "SwallowSelfTest",
                bundleIdentifier: "com.zyl.BrowserSelector.selftest",
                mode: .swallowAndReplay
            )
        ])
        let swallowDownResult = monitor.handle(
            type: .leftMouseDown,
            event: mouseEvent(.leftMouseDown, at: point)
        )
        let swallowDownSwallowed = swallowDownResult == nil
        _ = monitor.handle(
            type: .leftMouseUp,
            event: mouseEvent(.leftMouseUp, at: point)
        )
        let swallowFired = swallowCallback.wait(timeout: .now() + 1) == .success

        // 未列入目标应用：完全旁路。
        gate.setTargets([])
        let unlistedDown = monitor.handle(
            type: .leftMouseDown,
            event: mouseEvent(.leftMouseDown, at: point)
        )
        let unlistedUp = monitor.handle(
            type: .leftMouseUp,
            event: mouseEvent(.leftMouseUp, at: point)
        )
        let unlistedPassed = unlistedDown != nil && unlistedUp != nil

        let passed = longPressSwallowed
            && longPressFired
            && shortPressPassed
            && dragPassed
            && callbackCount == 1
            && swallowDownSwallowed
            && swallowFired
            && swallowCount == 1
            && unlistedPassed
        print(
            "longpress_selftest"
                + " passed=\(passed ? 1 : 0)"
                + " swallowed=\(longPressSwallowed ? 1 : 0)"
                + " callback=\(longPressFired ? 1 : 0)"
                + " short_pass=\(shortPressPassed ? 1 : 0)"
                + " drag_pass=\(dragPassed ? 1 : 0)"
                + " callbacks=\(callbackCount)"
                + " swallow_down=\(swallowDownSwallowed ? 1 : 0)"
                + " swallow_cb=\(swallowFired ? 1 : 0)"
                + " unlisted_pass=\(unlistedPassed ? 1 : 0)"
        )
        fflush(stdout)
    }
}
