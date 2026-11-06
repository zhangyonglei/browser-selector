import Foundation

/// 每个目标应用的点击处理方式。
public enum InterceptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 先吞掉点击，解析成功后弹面板；解析失败或不是链接时把原点击回放给目标应用。
    case swallowAndReplay
    /// 事件照常透传，只在解析到链接时弹面板。目标应用可能同时用默认浏览器打开链接。
    case observe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .swallowAndReplay: return "吞掉并回放"
        case .observe: return "旁路观察"
        }
    }

    public var detail: String {
        switch self {
        case .swallowAndReplay:
            return "先吞掉点击，解析成功弹选择器，失败时把原点击回放给应用，不会出现双开。"
        case .observe:
            return "点击照常透传给应用，仅解析到链接时弹面板。应用自身可能同时打开默认浏览器。"
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
        mode: InterceptionMode = .swallowAndReplay,
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
        mode = try container.decodeIfPresent(InterceptionMode.self, forKey: .mode) ?? .swallowAndReplay
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
    /// true 时普通点击直接走规则/默认浏览器，只有 Cmd+Click 才弹选择器。
    public var panelOnlyWithCommandModifier: Bool
    /// 剪贴板兜底从点击到读取的等待时间。
    public var clipboardFallbackDelayMilliseconds: Int

    public init(
        panelOnlyWithCommandModifier: Bool = false,
        clipboardFallbackDelayMilliseconds: Int = 50
    ) {
        self.panelOnlyWithCommandModifier = panelOnlyWithCommandModifier
        self.clipboardFallbackDelayMilliseconds = clipboardFallbackDelayMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case panelOnlyWithCommandModifier, clipboardFallbackDelayMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelOnlyWithCommandModifier =
            try container.decodeIfPresent(Bool.self, forKey: .panelOnlyWithCommandModifier) ?? false
        let delay = try container.decodeIfPresent(Int.self, forKey: .clipboardFallbackDelayMilliseconds) ?? 50
        clipboardFallbackDelayMilliseconds = min(max(delay, 0), 1_000)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

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
            TargetApplication(displayName: "钉钉", bundleIdentifier: "5ZSL2CJU2T.com.dingtalk.mac"),
            TargetApplication(displayName: "微信", bundleIdentifier: "com.tencent.xinWeChat"),
            TargetApplication(displayName: "QQ", bundleIdentifier: "com.tencent.qq")
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
