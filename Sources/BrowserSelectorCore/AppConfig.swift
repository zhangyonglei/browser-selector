import Foundation

/// 每个目标应用的点击处理方式。
public enum InterceptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 短按透传；按住超过长按阈值且移动很小时，释放时拦截并弹面板。
    case observe
    /// 点击立即吞掉并按规则/面板处理，解析失败时回放原点击。
    case swallowAndReplay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .observe: return "旁路观察（长按）"
        case .swallowAndReplay: return "吞掉并回放（点击）"
        }
    }

    public var detail: String {
        switch self {
        case .observe:
            return "短按完全透传；按住超过长按阈值且移动很小时，释放时拦截这次点击并弹出面板。"
        case .swallowAndReplay:
            return "点击立即吞掉，解析成功弹面板；不是链接或解析失败时把原点击回放给应用，不会双开。"
        }
    }
}

/// 需要监听的聊天类应用。
public struct TargetApplication: Codable, Identifiable, Hashable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String
    public var mode: InterceptionMode
    public var isEnabled: Bool

    public var id: String { bundleIdentifier }

    public init(
        displayName: String,
        bundleIdentifier: String,
        mode: InterceptionMode = .observe,
        isEnabled: Bool = true
    ) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, bundleIdentifier, mode, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        mode = try container.decodeIfPresent(InterceptionMode.self, forKey: .mode) ?? .observe
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// 可启动的浏览器（系统发现或手动添加）。
public struct BrowserEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var applicationPath: String?
    /// 参数模板，`{url}` 会被替换为目标链接；不含占位符时链接追加在末尾。
    public var argumentsTemplate: String
    public var isEnabled: Bool
    /// 手动添加（便携版、自定义路径的 Chromium 等）。
    public var isManual: Bool

    public init(
        id: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        applicationPath: String? = nil,
        argumentsTemplate: String = "",
        isEnabled: Bool = true,
        isManual: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.argumentsTemplate = argumentsTemplate
        self.isEnabled = isEnabled
        self.isManual = isManual
    }

    public static func makeManual(
        displayName: String,
        applicationPath: String?,
        bundleIdentifier: String?,
        argumentsTemplate: String = ""
    ) -> BrowserEntry {
        BrowserEntry(
            id: "manual-\(UUID().uuidString)",
            displayName: displayName,
            bundleIdentifier: bundleIdentifier?.nilIfBlank,
            applicationPath: applicationPath?.nilIfBlank,
            argumentsTemplate: argumentsTemplate,
            isEnabled: true,
            isManual: true
        )
    }

    public var hasCustomArguments: Bool {
        !argumentsTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, applicationPath, argumentsTemplate, isEnabled, isManual
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
        argumentsTemplate = try container.decodeIfPresent(String.self, forKey: .argumentsTemplate) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false

        if id.isEmpty {
            id = bundleIdentifier ?? "manual-\(UUID().uuidString)"
        }
    }
}

/// 域名正则路由：命中后跳过选择面板，直接用指定浏览器打开。
public struct DomainRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var pattern: String
    public var browserID: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        browserID: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.browserID = browserID
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, browserID, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        browserID = try container.decodeIfPresent(String.self, forKey: .browserID) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public struct ExclusionRules: Codable, Hashable, Sendable {
    public var bundleIdentifiers: [String]
    public var windowTitleSubstrings: [String]

    public init(bundleIdentifiers: [String] = [], windowTitleSubstrings: [String] = []) {
        self.bundleIdentifiers = bundleIdentifiers
        self.windowTitleSubstrings = windowTitleSubstrings
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifiers, windowTitleSubstrings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        windowTitleSubstrings = try container.decodeIfPresent([String].self, forKey: .windowTitleSubstrings) ?? []
    }

    public func excludes(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    public func excludes(windowTitle: String) -> Bool {
        windowTitleSubstrings.contains {
            !$0.isEmpty && windowTitle.localizedCaseInsensitiveContains($0)
        }
    }
}

public struct BehaviorSettings: Codable, Hashable, Sendable {
    /// 长按阈值，仅对「旁路观察（长按）」的目标应用生效。
    public var longPressDurationMilliseconds: Int
    /// true 时普通点击直接走规则/默认浏览器，只有 Cmd+Click 才弹选择器（吞掉模式）。
    public var panelOnlyWithCommandModifier: Bool
    /// 剪贴板兜底从点击到读取的等待时间。
    public var clipboardFallbackDelayMilliseconds: Int

    public init(
        longPressDurationMilliseconds: Int = 3_000,
        panelOnlyWithCommandModifier: Bool = false,
        clipboardFallbackDelayMilliseconds: Int = 50
    ) {
        let longPress = min(max(longPressDurationMilliseconds, 500), 10_000)
        self.longPressDurationMilliseconds = longPress
        self.panelOnlyWithCommandModifier = panelOnlyWithCommandModifier
        self.clipboardFallbackDelayMilliseconds = clipboardFallbackDelayMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case longPressDurationMilliseconds
        case panelOnlyWithCommandModifier, clipboardFallbackDelayMilliseconds
    }

    /// 设置页以秒展示与编辑；配置仍以毫秒存储，便于兼容旧版本。
    public var longPressDurationSeconds: Double {
        get { Double(longPressDurationMilliseconds) / 1_000 }
        set {
            let milliseconds = Int((newValue * 1_000).rounded())
            longPressDurationMilliseconds = min(max(milliseconds, 500), 10_000)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let longPress = try container.decodeIfPresent(Int.self, forKey: .longPressDurationMilliseconds) ?? 3_000
        longPressDurationMilliseconds = min(max(longPress, 500), 10_000)
        panelOnlyWithCommandModifier =
            try container.decodeIfPresent(Bool.self, forKey: .panelOnlyWithCommandModifier) ?? false
        let delay = try container.decodeIfPresent(Int.self, forKey: .clipboardFallbackDelayMilliseconds) ?? 50
        clipboardFallbackDelayMilliseconds = min(max(delay, 0), 1_000)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var behavior: BehaviorSettings
    public var targetApplications: [TargetApplication]
    public var browsers: [BrowserEntry]
    public var routingRules: [DomainRule]
    public var exclusions: ExclusionRules
    public var defaultBrowserID: String?

    public init(
        version: Int = AppConfig.currentVersion,
        behavior: BehaviorSettings = BehaviorSettings(),
        targetApplications: [TargetApplication] = AppConfig.defaultTargetApplications,
        browsers: [BrowserEntry] = [],
        routingRules: [DomainRule] = [],
        exclusions: ExclusionRules = ExclusionRules(),
        defaultBrowserID: String? = nil
    ) {
        self.version = version
        self.behavior = behavior
        self.targetApplications = targetApplications
        self.browsers = browsers
        self.routingRules = routingRules
        self.exclusions = exclusions
        self.defaultBrowserID = defaultBrowserID
    }

    public static var defaultTargetApplications: [TargetApplication] {
        [
            TargetApplication(
                displayName: "钉钉",
                bundleIdentifier: "5ZSL2CJU2T.com.dingtalk.mac",
                mode: .observe
            ),
            TargetApplication(
                displayName: "微信",
                bundleIdentifier: "com.tencent.xinWeChat",
                mode: .observe
            ),
            TargetApplication(
                displayName: "QQ",
                bundleIdentifier: "com.tencent.qq",
                mode: .observe
            )
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case version, behavior, targetApplications, browsers, routingRules, exclusions, defaultBrowserID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AppConfig.currentVersion
        behavior = try container.decodeIfPresent(BehaviorSettings.self, forKey: .behavior) ?? BehaviorSettings()
        targetApplications =
            try container.decodeIfPresent([TargetApplication].self, forKey: .targetApplications)
            ?? AppConfig.defaultTargetApplications
        browsers = try container.decodeIfPresent([BrowserEntry].self, forKey: .browsers) ?? []
        routingRules = try container.decodeIfPresent([DomainRule].self, forKey: .routingRules) ?? []
        exclusions = try container.decodeIfPresent(ExclusionRules.self, forKey: .exclusions) ?? ExclusionRules()
        defaultBrowserID = try container.decodeIfPresent(String.self, forKey: .defaultBrowserID)
    }

    public var enabledTargetApplications: [TargetApplication] {
        targetApplications.filter { $0.isEnabled && !$0.bundleIdentifier.isEmpty }
    }

    public var enabledBrowsers: [BrowserEntry] {
        browsers.filter { $0.isEnabled && !$0.displayName.isEmpty }
    }

    public func browser(withID id: String?) -> BrowserEntry? {
        guard let id else { return nil }
        return browsers.first { $0.id == id }
    }

    public var effectiveDefaultBrowser: BrowserEntry? {
        if let browser = browser(withID: defaultBrowserID), browser.isEnabled {
            return browser
        }
        return enabledBrowsers.first
    }

    /// 合并一次 Launch Services 扫描结果：已存在的条目保留用户的名称与参数，只刷新路径。
    /// - Returns: 配置是否发生变化。
    @discardableResult
    public mutating func merge(discovered: [DiscoveredBrowser]) -> Bool {
        guard !discovered.isEmpty else { return false }
        var changed = false
        var indexByBundleID: [String: Int] = [:]
        for (index, browser) in browsers.enumerated() {
            guard let bundleID = browser.bundleIdentifier, !bundleID.isEmpty else { continue }
            if indexByBundleID[bundleID] == nil {
                indexByBundleID[bundleID] = index
            }
        }

        for found in discovered {
            guard !found.bundleIdentifier.isEmpty else { continue }
            if let index = indexByBundleID[found.bundleIdentifier] {
                if !browsers[index].isManual,
                   browsers[index].applicationPath != found.applicationPath {
                    browsers[index].applicationPath = found.applicationPath
                    changed = true
                }
                continue
            }

            browsers.append(
                BrowserEntry(
                    id: found.bundleIdentifier,
                    displayName: found.displayName,
                    bundleIdentifier: found.bundleIdentifier,
                    applicationPath: found.applicationPath
                )
            )
            indexByBundleID[found.bundleIdentifier] = browsers.count - 1
            changed = true
        }

        if defaultBrowserID == nil, let first = enabledBrowsers.first {
            defaultBrowserID = first.id
            changed = true
        }
        return changed
    }

    /// 清理损坏或重复的条目，但保留用户正在编辑中的空行。
    public mutating func sanitize() {
        var seenTargetBundleIDs = Set<String>()
        targetApplications = targetApplications.filter { application in
            let bundleID = application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { return true }
            return seenTargetBundleIDs.insert(bundleID).inserted
        }
        for index in targetApplications.indices {
            targetApplications[index].bundleIdentifier =
                targetApplications[index].bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            targetApplications[index].displayName =
                targetApplications[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var seenBrowserIDs = Set<String>()
        browsers = browsers.filter { browser in
            guard !browser.id.isEmpty else { return false }
            return seenBrowserIDs.insert(browser.id).inserted
        }
        for index in browsers.indices where browsers[index].displayName.isEmpty {
            browsers[index].displayName = browsers[index].bundleIdentifier ?? "浏览器"
        }

        exclusions.bundleIdentifiers = exclusions.bundleIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        exclusions.windowTitleSubstrings = exclusions.windowTitleSubstrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// 一次系统扫描发现的浏览器。
public struct DiscoveredBrowser: Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String
    public var applicationPath: String

    public init(bundleIdentifier: String, displayName: String, applicationPath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationPath = applicationPath
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
