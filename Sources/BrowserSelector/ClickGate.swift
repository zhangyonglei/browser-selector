import BrowserSelectorCore
import CoreGraphics
import Foundation

struct WindowSnapshot: Hashable {
    let bounds: CGRect
    let title: String?
}

struct ClickDecision {
    let bundleIdentifier: String
    let pid: pid_t
    let mode: InterceptionMode
}

/// 回调线程与主线程共享的判定状态。所有读写都在锁内完成，回调内只做几次取值。
final class ClickGate {
    private let lock = NSLock()

    private var frontmostBundleID: String?
    private var frontmostPID: pid_t = 0
    private var targets: [String: TargetApplication] = [:]
    private var exclusions = ExclusionRules()
    private var windowsByPID: [pid_t: [WindowSnapshot]] = [:]
    private var windowsUpdatedAt: [pid_t: CFAbsoluteTime] = [:]
    private var panelVisible = false
    private var panelFrame: CGRect?
    private var isPaused = false

    func setTargets(_ applications: [TargetApplication]) {
        var map: [String: TargetApplication] = [:]
        for application in applications where !application.bundleIdentifier.isEmpty {
            map[application.bundleIdentifier] = application
        }
        lock.lock()
        targets = map
        lock.unlock()
    }

    func setExclusions(_ rules: ExclusionRules) {
        lock.lock()
        exclusions = rules
        lock.unlock()
    }

    func setFrontmost(bundleIdentifier: String?, pid: pid_t) {
        lock.lock()
        frontmostBundleID = bundleIdentifier
        frontmostPID = pid
        lock.unlock()
    }

    func setWindows(_ windows: [WindowSnapshot], for pid: pid_t) {
        lock.lock()
        windowsByPID[pid] = windows
        windowsUpdatedAt[pid] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func removeWindows(for pid: pid_t) {
        lock.lock()
        windowsByPID.removeValue(forKey: pid)
        windowsUpdatedAt.removeValue(forKey: pid)
        lock.unlock()
    }

    func setPanelVisible(_ visible: Bool) {
        lock.lock()
        panelVisible = visible
        lock.unlock()
    }

    func setPanelFrame(_ frame: CGRect?) {
        lock.lock()
        panelFrame = frame
        lock.unlock()
    }

    func panelContains(_ point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let panelFrame else { return false }
        return panelFrame.insetBy(dx: -2, dy: -2).contains(point)
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        lock.unlock()
    }

    var isPanelVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return panelVisible
    }

    var windowSnapshotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return windowsByPID.values.reduce(0) { $0 + $1.count }
    }

    func isTarget(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        lock.lock()
        defer { lock.unlock() }
        return targets[bundleIdentifier]?.isEnabled == true
    }

    /// 只做内存判断：不查窗口列表、不碰 AX、不发起 IPC。
    func evaluate(point: CGPoint, flags: CGEventFlags) -> ClickDecision? {
        lock.lock()
        defer { lock.unlock() }

        guard !isPaused, !panelVisible, frontmostPID > 0,
              let bundleIdentifier = frontmostBundleID,
              let target = targets[bundleIdentifier], target.isEnabled else {
            return nil
        }
        return decisionLocked(
            point: point,
            bundleIdentifier: bundleIdentifier,
            mode: target.mode
        )
    }

    private func decisionLocked(
        point: CGPoint,
        bundleIdentifier: String,
        mode: InterceptionMode
    ) -> ClickDecision? {
        guard !exclusions.excludes(bundleIdentifier: bundleIdentifier) else { return nil }

        // 快照超过 5 秒就跳过矩形命中判断，避免窗口移动后漏掉点击。
        if let windows = windowsByPID[frontmostPID], !windows.isEmpty,
           let updatedAt = windowsUpdatedAt[frontmostPID],
           CFAbsoluteTimeGetCurrent() - updatedAt < 5 {
            let hit = windows.first {
                $0.bounds.insetBy(dx: -2, dy: -2).contains(point)
            }
            guard let hit else { return nil }
            if let title = hit.title, exclusions.excludes(windowTitle: title) {
                return nil
            }
        }

        return ClickDecision(bundleIdentifier: bundleIdentifier, pid: frontmostPID, mode: mode)
    }
}
