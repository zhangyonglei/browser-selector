import Foundation

/// 从 AX 文本或剪贴板内容里提取合法链接，避免把普通聊天文本误判成 URL。
public enum LinkURLValidator {
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}>，。；：！？）」』】》、")

    public static func normalize(_ raw: String, allowSchemeLess: Bool = true) -> URL? {
        var text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        guard !text.isEmpty, text.count <= 4_096 else { return nil }

        while let last = text.unicodeScalars.last, trailingPunctuation.contains(last) {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }

        if !text.contains("://") {
            guard allowSchemeLess else { return nil }
            let pattern = #"^(?:www\.)?[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+(?:[/?#].*)?$"#
            guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            text = "https://" + text
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              host.contains(".") || host == "localhost" else {
            return nil
        }

        return components.url
    }
}
