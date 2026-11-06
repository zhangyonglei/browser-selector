import AppKit
import Carbon.HIToolbox

enum PanelKeyCommand {
    case cancel
    case previous
    case next
    case confirm
    case digit(Int)
}

private let panelHotKeySignature: OSType = 0x4253_4C43 // 'BSLC'

private func panelHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return noErr }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == panelHotKeySignature else {
        return noErr
    }

    let manager = Unmanaged<PanelHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.dispatch(identifier.id)
    return noErr
}

/// 面板显示期间注册的 Carbon 全局热键。
///
/// 访问性权限不包含“键盘监听”时，非激活面板收不到 keyDown；Carbon 热键由系统
/// 直接回调注册方，能在不抢焦点、不申请输入监控的前提下支持 esc / ↑↓ / ↩ / 1–9。
final class PanelHotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var commandsByID: [UInt32: PanelKeyCommand] = [:]
    private var onCommand: ((PanelKeyCommand) -> Bool)?

    func activate(onCommand: @escaping (PanelKeyCommand) -> Bool) {
        deactivate()
        self.onCommand = onCommand

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        _ = InstallEventHandler(
            GetApplicationEventTarget(),
            panelHotKeyHandler,
            1,
            &spec,
            userData,
            &eventHandler
        )

        let bindings: [(UInt32, PanelKeyCommand)] = [
            (UInt32(kVK_Escape), .cancel),
            (UInt32(kVK_UpArrow), .previous),
            (UInt32(kVK_DownArrow), .next),
            (UInt32(kVK_Return), .confirm),
            (UInt32(kVK_ANSI_KeypadEnter), .confirm),
            (UInt32(kVK_ANSI_1), .digit(1)),
            (UInt32(kVK_ANSI_2), .digit(2)),
            (UInt32(kVK_ANSI_3), .digit(3)),
            (UInt32(kVK_ANSI_4), .digit(4)),
            (UInt32(kVK_ANSI_5), .digit(5)),
            (UInt32(kVK_ANSI_6), .digit(6)),
            (UInt32(kVK_ANSI_7), .digit(7)),
            (UInt32(kVK_ANSI_8), .digit(8)),
            (UInt32(kVK_ANSI_9), .digit(9))
        ]

        for (index, binding) in bindings.enumerated() {
            let identifier = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: panelHotKeySignature, id: identifier)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.0,
                0,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeyRefs.append(reference)
                commandsByID[identifier] = binding.1
            }
        }
    }

    func deactivate() {
        for reference in hotKeyRefs {
            UnregisterEventHotKey(reference)
        }
        hotKeyRefs.removeAll()
        commandsByID.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onCommand = nil
    }

    fileprivate func dispatch(_ identifier: UInt32) {
        guard let command = commandsByID[identifier] else { return }
        _ = onCommand?(command)
    }

    deinit {
        deactivate()
    }
}
