import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionManager {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum PasteboardProbe {
    static func changeCount() -> Int {
        if Thread.isMainThread {
            return NSPasteboard.general.changeCount
        }
        return DispatchQueue.main.sync { NSPasteboard.general.changeCount }
    }

    static func string() -> String? {
        if Thread.isMainThread {
            return NSPasteboard.general.string(forType: .string)
        }
        return DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
    }
}
