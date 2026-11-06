import Foundation

/// 把浏览器参数模板解析成 argv。
///
/// - 支持单引号、双引号与反斜杠转义，例如 `--user-data-dir="/tmp/my profile"`。
/// - `{url}` 会被替换为链接；如果模板中没有任何 `{url}`，链接会追加到末尾。
public enum ArgumentTemplate {
    public static func makeArguments(template: String, url: URL) -> [String] {
        var arguments = tokenize(template)
        var foundPlaceholder = false

        for index in arguments.indices {
            if arguments[index].contains("{url}") {
                arguments[index] = arguments[index].replacingOccurrences(of: "{url}", with: url.absoluteString)
                foundPlaceholder = true
            }
        }

        if !foundPlaceholder {
            arguments.append(url.absoluteString)
        }
        return arguments
    }

    public static func tokenize(_ template: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaping = false

        for character in template {
            if isEscaping {
                current.append(character)
                hasCurrent = true
                isEscaping = false
                continue
            }

            if character == "\\" && !inSingleQuote {
                isEscaping = true
                hasCurrent = true
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                hasCurrent = true
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                hasCurrent = true
                continue
            }

            if character.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }

            current.append(character)
            hasCurrent = true
        }

        if hasCurrent {
            tokens.append(current)
        }
        return tokens
    }
}
