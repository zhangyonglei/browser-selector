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
                completion(ExtractedLink(url: url, source: .accessibility))
                return
            case .noLink:
                // AX 树可用但没有链接：直接结束，避免每次普通点击都白等剪贴板延迟。
                if let url = AXLinkReader.selectedTextURL(pid: pid) {
                    completion(ExtractedLink(url: url, source: .selectedText))
                } else {
                    completion(nil)
                }
                return
            case .unavailable:
                break
            }

            if let url = AXLinkReader.selectedTextURL(pid: pid) {
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
                completion(nil)
                return
            }

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
    }

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
            if let url = url(on: node) {
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

    private static func url(on element: AXUIElement) -> URL? {
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
        } else if role == Role.staticText {
            if let raw = stringValue(of: element, attribute: Attribute.value),
               raw.count <= 2_048,
               let url = LinkURLValidator.normalize(raw, allowSchemeLess: false) {
                return url
            }
        }
        return nil
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
