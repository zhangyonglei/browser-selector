import AppKit
import BrowserSelectorCore
import SwiftUI

struct RuntimeStatus {
    var tapRunning: Bool = false
    var isPaused: Bool = false
    var accessibilityTrusted: Bool = false
    var screenRecordingGranted: Bool = false
    var targetApplicationCount: Int = 0
    var browserCount: Int = 0
    var windowSnapshotCount: Int = 0
    var frontmostApplication: String = "—"
}

final class SettingsModel: ObservableObject {
    @Published var config: AppConfig

    var statusProvider: (() -> RuntimeStatus)?
    var debugLinkAction: (() -> Void)?
    var rescanAction: (() -> Void)?
    var openConfigFolderAction: (() -> Void)?

    private let store: ConfigStore
    private var pendingSave: DispatchWorkItem?

    init(store: ConfigStore) {
        self.store = store
        self.config = store.config
    }

    func configDidChange() {
        pendingSave?.cancel()
        let snapshot = config
        let workItem = DispatchWorkItem { [weak self] in
            self?.store.save(snapshot)
        }
        pendingSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(config)
    }

    func addBrowser(_ browser: BrowserEntry) {
        config.browsers.append(browser)
        configDidChange()
    }

    func removeBrowser(id: String) {
        config.browsers.removeAll { $0.id == id }
        if config.defaultBrowserID == id {
            config.defaultBrowserID = nil
        }
        configDidChange()
    }

    func addTargetApplication(name: String, bundleIdentifier: String, mode: InterceptionMode) {
        let trimmedID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              !config.targetApplications.contains(where: { $0.bundleIdentifier == trimmedID }) else {
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.targetApplications.append(
            TargetApplication(
                displayName: trimmedName.isEmpty ? trimmedID : trimmedName,
                bundleIdentifier: trimmedID,
                mode: mode
            )
        )
        configDidChange()
    }

    func removeTargetApplication(bundleIdentifier: String) {
        config.targetApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        configDidChange()
    }

    func addRoutingRule() {
        guard let browser = config.enabledBrowsers.first else { return }
        config.routingRules.append(
            DomainRule(pattern: "", browserID: browser.id)
        )
        configDidChange()
    }

    func removeRoutingRule(id: UUID) {
        config.routingRules.removeAll { $0.id == id }
        configDidChange()
    }
}

struct SettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

func settingsSectionHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
        Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case browsers
    case targets
    case routing
    case exclusions
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .browsers: return "浏览器"
        case .targets: return "目标应用"
        case .routing: return "域名路由"
        case .exclusions: return "排除规则"
        case .diagnostics: return "诊断"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .browsers: return "safari"
        case .targets: return "app.badge"
        case .routing: return "arrow.triangle.branch"
        case .exclusions: return "nosign"
        case .diagnostics: return "speedometer"
        }
    }
}
