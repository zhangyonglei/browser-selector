import AppKit
import BrowserSelectorCore
import CoreGraphics

struct ClickCandidate {
    let id: UInt64
    let bundleIdentifier: String
    let pid: pid_t
    let location: CGPoint
    let flags: CGEventFlags
    let clickState: Int64
    let mode: InterceptionMode
    let swallowed: Bool
}

private let clickEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

/// 全局左键监听。
///
/// `defaultTap` 允许吞掉事件：目标应用配置为 `swallowAndReplay` 时先拦下左键，
/// 后台解析 URL；解析失败再把点击回放给原进程。回调本身只做缓存态判断与一次
/// 队列投递，不做 AX、窗口枚举或任何磁盘/网络操作。
final class ClickMonitor {
    private static let replayMagic: Int64 = 0x4253_4C43_0001

    private struct PendingState {
        let id: UInt64
        let point: CGPoint
        let pid: pid_t
        let flags: CGEventFlags
        let clickState: Int64
        let swallowed: Bool
        let createdAt: CFAbsoluteTime
        var upSeen: Bool = false
        var upSwallowed: Bool = false
    }

    private let gate: ClickGate
    private let resolutionQueue = DispatchQueue(
        label: "com.zyl.BrowserSelector.click-resolution",
        qos: .userInteractive
    )
    private let pendingLock = NSLock()
    private var pending: PendingState?
    private var nextIdentifier: UInt64 = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onCandidate: ((ClickCandidate) -> Void)?
    var onOutsideClickWhilePanelVisible: (() -> Void)?

    init(gate: ClickGate) {
        self.gate = gate
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }

        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: clickEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("CGEventTap 创建失败（通常是缺少辅助功能权限）")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        self.tap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil

        pendingLock.lock()
        pending = nil
        pendingLock.unlock()
    }

    /// 协调器处理完一次点击后调用。解析失败时按原样回放被吞掉的点击。
    func finish(candidateID: UInt64, replay: Bool) {
        pendingLock.lock()
        guard let state = pending, state.id == candidateID else {
            pendingLock.unlock()
            return
        }
        pending = nil
        pendingLock.unlock()

        guard replay, state.swallowed else { return }

        // 用户按住拖拽过（mouseUp 没被吞）时不再补发，避免在应用里产生游离点击。
        if state.upSeen && !state.upSwallowed { return }

        replayClick(
            point: state.point,
            pid: state.pid,
            flags: state.flags,
            clickState: state.clickState,
            includeMouseUp: state.upSwallowed
        )
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passThrough
        case .leftMouseDown:
            return handleMouseDown(event: event)
        case .leftMouseUp:
            return handleMouseUp(event: event)
        default:
            return passThrough
        }
    }

    private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if isOwnEvent(event) {
            return passThrough
        }
        if gate.isPanelVisible {
            // 面板内部点击交给 SwiftUI；面板外点击关闭面板并透传。
            if gate.panelContains(event.location) {
                return passThrough
            }
            onOutsideClickWhilePanelVisible?()
            return passThrough
        }

        let point = event.location
        guard let decision = gate.evaluate(point: point, flags: event.flags) else {
            return passThrough
        }

        let identifier = allocateIdentifier()
        let candidate = ClickCandidate(
            id: identifier,
            bundleIdentifier: decision.bundleIdentifier,
            pid: decision.pid,
            location: point,
            flags: event.flags,
            clickState: event.getIntegerValueField(.mouseEventClickState),
            mode: decision.mode,
            swallowed: decision.mode == .swallowAndReplay
        )

        if candidate.swallowed {
            pendingLock.lock()
            pending = PendingState(
                id: identifier,
                point: point,
                pid: decision.pid,
                flags: event.flags,
                clickState: candidate.clickState,
                swallowed: true,
                createdAt: CFAbsoluteTimeGetCurrent()
            )
            pendingLock.unlock()
        }

        resolutionQueue.async { [weak self] in
            self?.onCandidate?(candidate)
        }

        return candidate.swallowed ? nil : passThrough
    }

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if isOwnEvent(event) || event.getIntegerValueField(.eventSourceUserData) == Self.replayMagic {
            return passThrough
        }

        pendingLock.lock()
        guard var state = pending else {
            pendingLock.unlock()
            return passThrough
        }

        state.upSeen = true
        let elapsed = CFAbsoluteTimeGetCurrent() - state.createdAt
        let distance = hypot(event.location.x - state.point.x, event.location.y - state.point.y)
        let shouldSwallow = elapsed < 1.5 && distance < 8
        if shouldSwallow {
            state.upSwallowed = true
        }
        pending = state
        pendingLock.unlock()

        return shouldSwallow ? nil : passThrough
    }

    private func allocateIdentifier() -> UInt64 {
        pendingLock.lock()
        nextIdentifier &+= 1
        let value = nextIdentifier
        pendingLock.unlock()
        return value
    }

    private func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ownPID)
    }

    private func replayClick(
        point: CGPoint,
        pid: pid_t,
        flags: CGEventFlags,
        clickState: Int64,
        includeMouseUp: Bool
    ) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else { return }

        down.flags = flags
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.setIntegerValueField(.eventSourceUserData, value: Self.replayMagic)
        down.postToPid(pid)

        guard includeMouseUp else { return }
        guard let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        up.flags = flags
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.eventSourceUserData, value: Self.replayMagic)
        up.postToPid(pid)
    }
}
