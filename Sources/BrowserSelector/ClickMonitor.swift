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

struct LongPressCandidate {
    let id: UInt64
    let pid: pid_t
    let location: CGPoint
    let flags: CGEventFlags
    let clickState: Int64
}

struct InteractionConfiguration {
    var longPressDuration: TimeInterval = 3
    var movementTolerance: CGFloat = 8
}

private let clickEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

/// 全局左键监听。
///
/// 默认的 `longPress` 模式不拦截 mouseDown，只记下按下位置与时间；mouseUp 时
/// 若按住超过阈值且几乎没移动，才吞掉这次 release 并进入链接解析，避免普通
/// 点击、拖拽被影响。旧 `click` 模式保留原有的吞掉/回放逻辑。
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

    private struct PressState {
        let id: UInt64
        let point: CGPoint
        let pid: pid_t
        let flags: CGEventFlags
        let clickState: Int64
        let startedAt: CFAbsoluteTime
    }

    private let gate: ClickGate
    private let resolutionQueue = DispatchQueue(
        label: "com.zyl.BrowserSelector.click-resolution",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var pending: PendingState?
    private var pressState: PressState?
    private var pendingLongPress: PressState?
    private var interaction = InteractionConfiguration()
    private var nextIdentifier: UInt64 = 0
    private let ownPID: pid_t

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onCandidate: ((ClickCandidate) -> Void)?
    var onLongPressCandidate: ((LongPressCandidate) -> Void)?
    var onOutsideClickWhilePanelVisible: (() -> Void)?

    init(gate: ClickGate, ownPID: pid_t? = nil) {
        self.gate = gate
        self.ownPID = ownPID ?? ProcessInfo.processInfo.processIdentifier
    }

    var isRunning: Bool { tap != nil }

    func configure(_ configuration: InteractionConfiguration) {
        stateLock.lock()
        interaction = configuration
        stateLock.unlock()
    }

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

        stateLock.lock()
        pending = nil
        pressState = nil
        pendingLongPress = nil
        stateLock.unlock()
    }

    /// 旧「点击触发」模式：协调器处理完一次点击后调用；解析失败时回放被吞掉的点击。
    func finish(candidateID: UInt64, replay: Bool) {
        stateLock.lock()
        guard let state = pending, state.id == candidateID else {
            stateLock.unlock()
            return
        }
        pending = nil
        stateLock.unlock()

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

    /// 长按模式：面板已展示（replay=false）或解析失败（replay=true，把 release 还给应用）。
    func finishLongPress(candidateID: UInt64, replay: Bool) {
        stateLock.lock()
        guard let state = pendingLongPress, state.id == candidateID else {
            stateLock.unlock()
            return
        }
        pendingLongPress = nil
        stateLock.unlock()

        guard replay else { return }
        postMouseUp(
            point: state.point,
            pid: state.pid,
            flags: state.flags,
            clickState: state.clickState
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
            // 面板内部点击交给 AppKit 面板；面板外点击关闭面板并透传。
            if gate.panelContains(event.location) {
                return passThrough
            }
            onOutsideClickWhilePanelVisible?()
            return passThrough
        }

        let point = event.location
        let decision = gate.evaluate(point: point, flags: event.flags)
        ClickTrace.log(
            "mouseDown point=\(Int(point.x)),\(Int(point.y))"
                + " frontmost=\(gate.debugFrontmostBundleID ?? "nil")"
                + " targets=\(gate.debugTargetBundleIDs)"
                + " decision=\(decision.map { "\($0.bundleIdentifier):\($0.mode.rawValue)" } ?? "nil")"
        )
        guard let decision else {
            // 未列入目标应用 / 被禁用 / 命中排除规则：完全旁路。
            return passThrough
        }

        let identifier = allocateIdentifier()

        if decision.mode == .observe {
            let press = PressState(
                id: identifier,
                point: point,
                pid: decision.pid,
                flags: event.flags,
                clickState: event.getIntegerValueField(.mouseEventClickState),
                startedAt: CFAbsoluteTimeGetCurrent()
            )
            stateLock.lock()
            pressState = press
            stateLock.unlock()
            return passThrough
        }

        // 吞掉并回放：点击即处理。
        let candidate = ClickCandidate(
            id: identifier,
            bundleIdentifier: decision.bundleIdentifier,
            pid: decision.pid,
            location: point,
            flags: event.flags,
            clickState: event.getIntegerValueField(.mouseEventClickState),
            mode: decision.mode,
            swallowed: true
        )

        stateLock.lock()
        pending = PendingState(
            id: identifier,
            point: point,
            pid: decision.pid,
            flags: event.flags,
            clickState: candidate.clickState,
            swallowed: true,
            createdAt: CFAbsoluteTimeGetCurrent()
        )
        stateLock.unlock()

        resolutionQueue.async { [weak self] in
            self?.onCandidate?(candidate)
        }

        return nil
    }

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if isOwnEvent(event) || event.getIntegerValueField(.eventSourceUserData) == Self.replayMagic {
            return passThrough
        }

        stateLock.lock()
        let hasPendingClick = pending != nil
        stateLock.unlock()

        if hasPendingClick {
            return handleSwallowMouseUp(event: event)
        }

        return handleLongPressMouseUp(
            event: event,
            configuration: currentConfiguration()
        )
    }

    private func handleSwallowMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        stateLock.lock()
        guard var state = pending else {
            stateLock.unlock()
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
        stateLock.unlock()

        return shouldSwallow ? nil : passThrough
    }

    private func handleLongPressMouseUp(
        event: CGEvent,
        configuration: InteractionConfiguration
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        stateLock.lock()
        guard let state = pressState else {
            stateLock.unlock()
            return passThrough
        }
        pressState = nil
        stateLock.unlock()

        let elapsed = CFAbsoluteTimeGetCurrent() - state.startedAt
        let distance = hypot(event.location.x - state.point.x, event.location.y - state.point.y)
        ClickTrace.log(
            "longPressMouseUp elapsed=\(String(format: "%.2f", elapsed))"
                + " distance=\(String(format: "%.1f", distance))"
                + " threshold=\(configuration.longPressDuration)"
        )
        guard elapsed >= configuration.longPressDuration,
              distance <= configuration.movementTolerance else {
            return passThrough
        }

        stateLock.lock()
        pendingLongPress = state
        stateLock.unlock()

        let candidate = LongPressCandidate(
            id: state.id,
            pid: state.pid,
            location: state.point,
            flags: state.flags,
            clickState: state.clickState
        )
        resolutionQueue.async { [weak self] in
            self?.onLongPressCandidate?(candidate)
        }
        return nil
    }

    private func currentConfiguration() -> InteractionConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return interaction
    }

    private func allocateIdentifier() -> UInt64 {
        stateLock.lock()
        nextIdentifier &+= 1
        let value = nextIdentifier
        stateLock.unlock()
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
        postMouseUp(point: point, pid: pid, flags: flags, clickState: clickState)
    }

    private func postMouseUp(
        point: CGPoint,
        pid: pid_t,
        flags: CGEventFlags,
        clickState: Int64
    ) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let up = CGEvent(
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
