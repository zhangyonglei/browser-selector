import AppKit
import BrowserSelectorCore
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let settingsModel: SettingsModel

    init(
        store: ConfigStore,
        statusProvider: @escaping () -> RuntimeStatus,
        debugLinkAction: @escaping () -> Void,
        rescanAction: @escaping () -> Void
    ) {
        let model = SettingsModel(store: store)
        model.statusProvider = statusProvider
        model.debugLinkAction = debugLinkAction
        model.rescanAction = rescanAction
        model.openConfigFolderAction = {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        }
        self.settingsModel = model

        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "浏览器选择器设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
