import Foundation

/// 按配置顺序匹配域名规则，命中即返回对应浏览器。
///
/// 规则先匹配 host，再匹配完整 URL，使用 `firstMatch` 搜索语义，因此 `github\.com$`
/// 与 `^https://.*\.corp\.com/` 都能按预期工作。
public struct DomainRouter {
    private struct CompiledRule {
        let regex: NSRegularExpression
        let browserID: String
        let pattern: String
    }

    private let rules: [CompiledRule]

    public init(rules: [DomainRule]) {
        self.rules = rules.compactMap { rule in
            guard rule.isEnabled,
                  !rule.browserID.isEmpty,
                  let regex = DomainRouter.compile(rule.pattern) else { return nil }
            return CompiledRule(regex: regex, browserID: rule.browserID, pattern: rule.pattern)
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func browserID(for url: URL) -> String? {
        let host = url.host ?? ""
        let absolute = url.absoluteString
        for rule in rules {
            if DomainRouter.matches(rule.regex, host) || DomainRouter.matches(rule.regex, absolute) {
                return rule.browserID
            }
        }
        return nil
    }

    public static func isValidPattern(_ pattern: String) -> Bool {
        compile(pattern) != nil
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}
