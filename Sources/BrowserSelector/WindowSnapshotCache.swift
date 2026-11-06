import CoreGraphics
import Foundation

/// 只缓存目标应用的窗口矩形与标题，用于判断点击是否命中了聊天窗口。
final class WindowSnapshotCache {
    private let queue = DispatchQueue(label: "com.zyl.BrowserSelector.window-snapshot", qos: .utility)

    func refresh(pid: pid_t, completion: @escaping ([WindowSnapshot]) -> Void) {
        queue.async {
            completion(Self.windows(for: pid))
        }
    }

    private static func windows(for pid: pid_t) -> [WindowSnapshot] {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [WindowSnapshot] = []
        for info in rawList {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid else { continue }
            if let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer != 0 {
                continue
            }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 {
                continue
            }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else {
                continue
            }
            // 未授予屏幕录制权限时标题为 nil，此时只按矩形命中。
            let title = info[kCGWindowName as String] as? String
            result.append(WindowSnapshot(bounds: bounds, title: title))
        }
        return result
    }
}
