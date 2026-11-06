import AppKit
import BrowserSelectorCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                Group {
                    switch section {
                    case .general:
                        GeneralSettingsView(model: model)
                    case .browsers:
                        BrowsersSettingsView(model: model)
                    case .targets:
                        TargetsSettingsView(model: model)
                    case .routing:
                        RoutingSettingsView(model: model)
                    case .exclusions:
                        ExclusionsSettingsView(model: model)
                    case .diagnostics:
                        DiagnosticsSettingsView(model: model)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }
        .frame(width: 900, height: 620)
        .onChange(of: model.config) { _ in
            model.configDidChange()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(section == item ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("BrowserSelector 1.0")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
        }
        .padding(12)
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var refreshToken = 0

    var body: some View {
        let _ = refreshToken
        VStack(alignment: .leading, spacing: 18) {
            settingsSectionHeader(
                "通用",
                "点击钉钉、微信、QQ 聊天窗口中的链接时，在光标位置选择浏览器打开。"
            )

            SettingsCard {
                permissionRow(
                    title: "辅助功能",
                    detail: "读取链接、拦截点击所必需",
                    granted: PermissionManager.isAccessibilityTrusted
                ) {
                    PermissionManager.promptAccessibility()
                    PermissionManager.openAccessibilitySettings()
                }
                Divider()
                permissionRow(
                    title: "屏幕录制（可选）",
                    detail: "仅用于读取窗口标题，支持按标题排除",
                    granted: PermissionManager.hasScreenRecording
                ) {
                    PermissionManager.requestScreenRecording()
                }
                HStack {
                    Text("授权后若状态未刷新，点右侧按钮重新检测。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新检测") { refreshToken += 1 }
                        .controlSize(.small)
                }
            }

            SettingsCard {
                HStack {
                    Text("默认浏览器")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: defaultBrowserBinding) {
                        Text("未设置").tag("")
                        ForEach(model.config.browsers.filter { $0.isEnabled }) { browser in
                            Text(browser.displayName).tag(browser.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "仅在按住 ⌘ 时弹出选择器",
                        isOn: $model.config.behavior.panelOnlyWithCommandModifier
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text("关闭：普通点击直接弹面板（域名规则仍优先）；开启：普通点击走规则/默认浏览器，⌘+点击强制弹面板。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(
                        "剪贴板兜底延迟：\(model.config.behavior.clipboardFallbackDelayMilliseconds) ms",
                        value: $model.config.behavior.clipboardFallbackDelayMilliseconds,
                        in: 0...500,
                        step: 10
                    )
                    .font(.system(size: 12))
                    Text("AX 读取失败时，等待该时长后检查剪贴板是否出现新链接。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 8) {
                    Button("重新扫描浏览器") { model.rescanAction?() }
                        .controlSize(.small)
                    Button("打开配置目录") { model.openConfigFolderAction?() }
                        .controlSize(.small)
                    Spacer()
                }
            }

            Text("退出后设置会自动保存。配置仅在启动与保存时写入磁盘，运行期保留在内存中。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var defaultBrowserBinding: Binding<String> {
        Binding(
            get: { model.config.defaultBrowserID ?? "" },
            set: { model.config.defaultBrowserID = $0.isEmpty ? nil : $0 }
        )
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("已授权")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button("去授权", action: action)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 浏览器

private struct BrowsersSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(
                "浏览器",
                "面板按这里的顺序展示；参数模板支持 {url} 占位符，未包含占位符时链接追加在末尾。"
            )

            SettingsCard {
                if model.config.browsers.isEmpty {
                    Text("尚未发现浏览器，点下方「重新扫描浏览器」。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($model.config.browsers) { $browser in
                        BrowserRowEditor(
                            browser: $browser,
                            isDefault: model.config.defaultBrowserID == browser.id,
                            onMakeDefault: { model.config.defaultBrowserID = browser.id },
                            onDelete: browser.isManual
                                ? { model.removeBrowser(id: browser.id) }
                                : nil
                        )
                        if browser.id != model.config.browsers.last?.id {
                            Divider()
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("重新扫描浏览器") { model.rescanAction?() }
                    .controlSize(.small)
                Spacer()
                Button("添加浏览器…") { showingAddSheet = true }
                    .controlSize(.small)
            }

            Text("手动添加适用于便携版或自定义路径的 Chromium；填写 .app 路径或 Bundle ID 任一即可。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddBrowserSheet { browser in
                model.addBrowser(browser)
            }
        }
    }
}

private struct BrowserRowEditor: View {
    @Binding var browser: BrowserEntry
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconView
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("浏览器名称", text: $browser.displayName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))

                    if isDefault {
                        Text("默认")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    } else {
                        Button("设为默认", action: onMakeDefault)
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }

                    Spacer(minLength: 4)

                    Toggle("", isOn: $browser.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    if browser.isManual, let onDelete {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("移除这个手动添加的浏览器")
                    }
                }

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                TextField("参数模板（可选），例如 --incognito {url}", text: $browser.argumentsTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
        .opacity(browser.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = SettingsIconCache.icon(for: browser) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if browser.isManual {
            return browser.applicationPath ?? browser.bundleIdentifier ?? "手动添加"
        }
        return browser.bundleIdentifier ?? browser.applicationPath ?? ""
    }
}

private enum SettingsIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for browser: BrowserEntry) -> NSImage? {
        let key = (browser.applicationPath ?? browser.bundleIdentifier ?? browser.id) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        var url: URL?
        if let path = browser.applicationPath, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else if let bundleID = browser.bundleIdentifier, !bundleID.isEmpty {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        guard let url else { return nil }
        guard let image = IconRasterizer.smallIcon(forFile: url.path, size: 28) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct AddBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (BrowserEntry) -> Void

    @State private var name = ""
    @State private var path = ""
    @State private var bundleIdentifier = ""
    @State private var argumentsTemplate = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加浏览器")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("名称").font(.system(size: 12))
                    TextField("例如 Chrome Canary", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("应用路径").font(.system(size: 12))
                    HStack(spacing: 6) {
                        TextField("/Applications/…app", text: $path)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseApplication() }
                    }
                }
                GridRow {
                    Text("Bundle ID").font(.system(size: 12))
                    TextField("可选，例如 com.google.Chrome.canary", text: $bundleIdentifier)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("参数模板").font(.system(size: 12))
                    TextField("可选，例如 --incognito {url}", text: $argumentsTemplate)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("路径与 Bundle ID 至少填写一个。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var canAdd: Bool {
        !trimmed(name).isEmpty
            && (!trimmed(path).isEmpty || !trimmed(bundleIdentifier).isEmpty)
    }

    private func add() {
        let entry = BrowserEntry.makeManual(
            displayName: trimmed(name),
            applicationPath: trimmed(path),
            bundleIdentifier: trimmed(bundleIdentifier),
            argumentsTemplate: argumentsTemplate
        )
        onAdd(entry)
        dismiss()
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        path = url.path
        if trimmed(name).isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
        if trimmed(bundleIdentifier).isEmpty, let bundle = Bundle(url: url) {
            bundleIdentifier = bundle.bundleIdentifier ?? ""
        }
    }

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 目标应用

private struct TargetsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var newName = ""
    @State private var newBundleIdentifier = ""
    @State private var newMode: InterceptionMode = .swallowAndReplay

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(
                "目标应用",
                "只有列表中的应用会被拦截；不在列表中的应用完全旁路，不受影响。"
            )

            SettingsCard {
                if model.config.targetApplications.isEmpty {
                    Text("列表为空，当前不会拦截任何应用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.config.targetApplications.indices), id: \.self) { index in
                        TargetApplicationRow(
                            application: $model.config.targetApplications[index],
                            onDelete: {
                                model.removeTargetApplication(
                                    bundleIdentifier: model.config.targetApplications[index].bundleIdentifier
                                )
                            }
                        )
                        Divider()
                    }
                }

                addRow
            }

            Text("钉钉/微信/QQ 的 Bundle ID 已预置。Electron 版本建议用「吞掉并回放」；若应用会自己打开默认浏览器且你不介意双开，可改成「旁路观察」。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("名称（可选）", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            TextField("Bundle ID，例如 com.tencent.xinWeChat", text: $newBundleIdentifier)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Picker("", selection: $newMode) {
                ForEach(InterceptionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button("添加") {
                model.addTargetApplication(
                    name: newName,
                    bundleIdentifier: newBundleIdentifier,
                    mode: newMode
                )
                newName = ""
                newBundleIdentifier = ""
            }
            .disabled(newBundleIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct TargetApplicationRow: View {
    @Binding var application: TargetApplication
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("显示名称", text: $application.displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 100)
                TextField("Bundle ID", text: $application.bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Toggle("", isOn: $application.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                Picker("", selection: $application.mode) {
                    ForEach(InterceptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                Text(application.mode.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .opacity(application.isEnabled ? 1 : 0.55)
    }
}

// MARK: - 域名路由

private struct RoutingSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(
                "域名路由",
                "命中的链接跳过选择面板，直接用指定浏览器打开。规则按顺序匹配，支持正则。"
            )

            SettingsCard {
                if model.config.routingRules.isEmpty {
                    Text("还没有规则。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($model.config.routingRules) { $rule in
                        RoutingRuleRow(
                            rule: $rule,
                            browsers: model.config.browsers,
                            onDelete: { model.removeRoutingRule(id: rule.id) }
                        )
                        if rule.id != model.config.routingRules.last?.id {
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Button("添加规则") { model.addRoutingRule() }
                    .controlSize(.small)
                    .disabled(model.config.enabledBrowsers.isEmpty)
                Spacer()
            }

            SettingsCard {
                Text("示例")
                    .font(.system(size: 11, weight: .semibold))
                Text(#"(^|\.)corp\.com$    →  公司内网走 Safari"#)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(#"github\.com$    →  用 Chrome 打开 GitHub"#)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(#"^https://.*\.docs\.example\.com/    →  匹配完整 URL"#)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoutingRuleRow: View {
    @Binding var rule: DomainRule
    let browsers: [BrowserEntry]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                TextField(#"正则，例如 (^|\.)corp\.com$"#, text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                if !rule.pattern.isEmpty, !DomainRouter.isValidPattern(rule.pattern) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("正则表达式无效，这条规则不会生效")
                }
            }

            Picker("", selection: $rule.browserID) {
                ForEach(browsers) { browser in
                    Text(browser.displayName).tag(browser.id)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

// MARK: - 排除规则

private struct ExclusionsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(
                "排除规则",
                "每行一条。命中 Bundle ID 或窗口标题的应用不会被拦截。"
            )

            SettingsCard {
                Text("排除的 Bundle ID")
                    .font(.system(size: 11, weight: .semibold))
                TextEditor(text: bundleIdentifierBinding)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                Text("例如 com.tencent.xinWeChat")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            SettingsCard {
                Text("窗口标题关键词")
                    .font(.system(size: 11, weight: .semibold))
                TextEditor(text: windowTitleBinding)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                Text("需要屏幕录制权限才能读取窗口标题；未授权时只按 Bundle ID 排除。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var bundleIdentifierBinding: Binding<String> {
        Binding(
            get: { model.config.exclusions.bundleIdentifiers.joined(separator: "\n") },
            set: { model.config.exclusions.bundleIdentifiers = Self.lines(from: $0) }
        )
    }

    private var windowTitleBinding: Binding<String> {
        Binding(
            get: { model.config.exclusions.windowTitleSubstrings.joined(separator: "\n") },
            set: { model.config.exclusions.windowTitleSubstrings = Self.lines(from: $0) }
        )
    }

    private static func lines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 诊断

private struct DiagnosticsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var status = RuntimeStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(
                "诊断",
                "快照式数据，不做后台轮询。完整测量方法见仓库 PERFORMANCE.md。"
            )

            SettingsCard {
                infoRow("拦截状态", status.isPaused ? "已暂停" : (status.tapRunning ? "监听中" : "未运行"))
                Divider()
                infoRow("辅助功能", status.accessibilityTrusted ? "已授权" : "未授权")
                Divider()
                infoRow("屏幕录制", status.screenRecordingGranted ? "已授权" : "未授权")
                Divider()
                infoRow("当前前台应用", status.frontmostApplication)
                Divider()
                infoRow("内存占用（RSS）", Diagnostics.formattedBytes(Diagnostics.residentMemoryBytes()))
                Divider()
                infoRow("内存占用（Footprint）", Diagnostics.formattedBytes(Diagnostics.physicalFootprintBytes()))
                Divider()
                infoRow("累计 CPU 时间", String(format: "%.2f s", Diagnostics.cpuSeconds()))
                Divider()
                infoRow("浏览器 / 目标应用", "\(status.browserCount) / \(status.targetApplicationCount)")
                Divider()
                infoRow("窗口缓存", "\(status.windowSnapshotCount) 个窗口")
                Divider()
                infoRow("配置文件", AppPaths.configFileURL.path)
            }

            HStack(spacing: 8) {
                Button("刷新") { refresh() }
                    .controlSize(.small)
                Button("测试光标处链接") { model.debugLinkAction?() }
                    .controlSize(.small)
                Button("打开配置目录") { model.openConfigFolderAction?() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = model.statusProvider?() ?? RuntimeStatus()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
