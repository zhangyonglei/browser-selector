import AppKit
import ApplicationServices
import BrowserSelectorCore

struct ExtractedLink {
    enum Source: String {
        case accessibility
        case selectedText
        case clipboard

        var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .selectedText: return "选中文本"
            case .clipboard: return "剪贴板"
            }
        }
    }

    let url: URL
    let source: Source
}

/// 链接提取流水线：AX 命中 → 选中文本 → 剪贴板兜底。
/// 整个过程在专用串行队列执行，主线程与 EventTap 回调都不参与。
final class LinkExtractor {
    private let queue = DispatchQueue(
        label: "com.zyl.BrowserSelector.link-extractor",
        qos: .userInteractive
    )

    func extract(
        at point: CGPoint,
        pid: pid_t,
        clipboardBaseline: Int,
        delayMilliseconds: Int,
        completion: @escaping (ExtractedLink?) -> Void
    ) {
        queue.async {
            let started = CFAbsoluteTimeGetCurrent()

            switch AXLinkReader.probe(at: point, pid: pid) {
            case .link(let url):
                ClickTrace.log("AX link=\(url.absoluteString)")
                completion(ExtractedLink(url: url, source: .accessibility))
                return
            case .noLink:
                ClickTrace.log("AX noLink")
                // AX 树可用但没有链接：直接结束，避免每次普通点击都白等剪贴板延迟。
                if let url = AXLinkReader.selectedTextURL(pid: pid) {
                    ClickTrace.log("selectedText link=\(url.absoluteString)")
                    completion(ExtractedLink(url: url, source: .selectedText))
                } else {
                    completion(nil)
                }
                return
            case .unavailable:
                ClickTrace.log("AX unavailable")
                break
            }

            if let url = AXLinkReader.selectedTextURL(pid: pid) {
                ClickTrace.log("selectedText link=\(url.absoluteString)")
                completion(ExtractedLink(url: url, source: .selectedText))
                return
            }

            let remaining = Double(max(delayMilliseconds, 0)) / 1_000
                - (CFAbsoluteTimeGetCurrent() - started)
            if remaining > 0 {
                Thread.sleep(forTimeInterval: remaining)
            }

            // 只接受点击之后剪贴板确实发生变化的内容，避免把之前复制的旧链接当成结果。
            guard PasteboardProbe.changeCount() != clipboardBaseline,
                  let raw = PasteboardProbe.string(),
                  let url = LinkURLValidator.normalize(raw) else {
                ClickTrace.log("clipboard no change or invalid")
                completion(nil)
                return
            }

            ClickTrace.log("clipboard link=\(url.absoluteString)")
            completion(ExtractedLink(url: url, source: .clipboard))
        }
    }
}

enum AXProbeResult {
    case link(URL)
    case noLink
    case unavailable
}

enum AXLinkReader {
    private enum Attribute {
        static let role = "AXRole" as CFString
        static let parent = "AXParent" as CFString
        static let url = "AXURL" as CFString
        static let linkURL = "AXLinkURL" as CFString
        static let value = "AXValue" as CFString
        static let title = "AXTitle" as CFString
        static let description = "AXDescription" as CFString
        static let selectedText = "AXSelectedText" as CFString
        static let focusedElement = "AXFocusedUIElement" as CFString
    }

    private enum Role {
        static let link = "AXLink"
        static let staticText = "AXStaticText"
        static let textArea = "AXTextArea"
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s\x{FFFC}]+"#,
        options: [.caseInsensitive]
    )

    static func probe(at point: CGPoint, pid: pid_t) -> AXProbeResult {
        guard AXIsProcessTrusted() else { return .unavailable }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &elementRef
        ) == .success, var node = elementRef else {
            return .unavailable
        }

        var depth = 0
        while depth < 40 {
            if let url = url(on: node, point: point) {
                return .link(url)
            }
            guard let parent = elementValue(of: node, attribute: Attribute.parent) else { break }
            node = parent
            depth += 1
        }
        return .noLink
    }

    static func selectedTextURL(pid: pid_t) -> URL? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let focused = elementValue(of: appElement, attribute: Attribute.focusedElement) else {
            return nil
        }

        if let text = stringValue(of: focused, attribute: Attribute.selectedText),
           let url = LinkURLValidator.normalize(text, allowSchemeLess: false) {
            return url
        }
        return nil
    }

    private static func url(on element: AXUIElement, point: CGPoint) -> URL? {
        for attribute in [Attribute.url, Attribute.linkURL] {
            if let raw = stringValue(of: element, attribute: attribute),
               let url = LinkURLValidator.normalize(raw) {
                return url
            }
        }

        guard let role = stringValue(of: element, attribute: Attribute.role) else { return nil }

        if role == Role.link {
            for attribute in [Attribute.value, Attribute.title, Attribute.description] {
                if let raw = stringValue(of: element, attribute: attribute),
                   let url = LinkURLValidator.normalize(raw, allowSchemeLess: false) {
                    return url
                }
            }
            return descendantURL(in: element, depth: 0)
        }

        if role == Role.staticText || role == Role.textArea {
            if let raw = stringValue(of: element, attribute: Attribute.value),
               raw.count <= 4_096,
               let url = LinkURLValidator.normalize(raw, allowSchemeLess: false) {
                return url
            }

            // 输入框里键入的 URL 不应被当成链接；只读消息文本区才允许按点击位置提取。
            if role == Role.textArea, isEditable(element) {
                return nil
            }
            return urlFromText(element, point: point)
        }

        return nil
    }

    /// 钉钉等应用把 URL 渲染在只读文本区里，没有 AXLink/AXURL。
    /// 用 AXRangeForPosition 把点击坐标映射成字符范围，再匹配该范围内的 URL。
    private static func urlFromText(_ element: AXUIElement, point: CGPoint) -> URL? {
        guard let text = stringValue(of: element, attribute: Attribute.value),
              text.utf16.count <= 20_000,
              text.range(of: "http", options: .caseInsensitive) != nil else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: text.utf16.count)
        let matches = urlRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty, let clickedRange = textRange(at: point, in: element) else {
            return nil
        }

        let nsText = text as NSString
        for match in matches {
            let end = match.range.location + match.range.length
            let intersects = NSIntersectionRange(clickedRange, match.range).length > 0
                || (clickedRange.location >= match.range.location && clickedRange.location <= end)
            guard intersects else { continue }

            let raw = nsText.substring(with: match.range)
            if let url = LinkURLValidator.normalize(raw, allowSchemeLess: false) {
                return url
            }
        }
        return nil
    }

    private static func textRange(at point: CGPoint, in element: AXUIElement) -> NSRange? {
        var location = point
        guard let parameter = AXValueCreate(.cgPoint, &location) else { return nil }

        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXRangeForPosition" as CFString,
            parameter,
            &result
        ) == .success,
            let result,
            CFGetTypeID(result) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(result as! AXValue, .cfRange, &range),
              range.location >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: max(range.length, 0))
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &value) == .success,
           let number = value as? NSNumber,
           number.boolValue {
            return true
        }

        // 钉钉输入框与只读消息都暴露 AXTextArea + AXShowMenu，但输入框是当前焦点。
        if let focused = booleanValue(of: element, attribute: kAXFocusedAttribute as CFString),
           focused {
            return true
        }

        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String] {
            return actions.contains("AXConfirm") || actions.contains("AXInsertText")
        }
        return false
    }

    private static func booleanValue(of element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private static func descendantURL(in element: AXUIElement, depth: Int) -> URL? {
        guard depth <= 3 else { return nil }
        if let raw = stringValue(of: element, attribute: Attribute.value),
           raw.count <= 4_096,
           let url = LinkURLValidator.normalize(raw, allowSchemeLess: false) {
            return url
        }
        for child in elementChildren(of: element) {
            if let url = descendantURL(in: child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    private static func elementChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success, let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private static func stringValue(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func elementValue(of element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
