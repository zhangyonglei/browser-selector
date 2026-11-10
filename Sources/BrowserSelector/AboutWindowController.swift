import AppKit

/// 「关于」窗口：按需创建，关闭后保留实例，避免重复分配。
final class AboutWindowController: NSWindowController {
    private static let contentSize = NSSize(width: 360, height: 300)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于浏览器选择器"
        window.isReleasedWhenClosed = false
        window.contentView = AboutContentView(frame: NSRect(origin: .zero, size: Self.contentSize))
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
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class AboutContentView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "浏览器选择器")
    private let versionLabel = NSTextField(labelWithString: "版本 \(AppVersion.display)")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "在钉钉 / 微信 / QQ 中长按链接，\n在光标位置选择浏览器打开。"
    )
    private let privacyLabel = NSTextField(
        labelWithString: "无网络请求 · 无日志落盘 · 配置只保存在本机"
    )
    private let closeButton = NSButton(title: "好", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        iconView.frame = NSRect(x: (width - 72) / 2, y: 26, width: 72, height: 72)
        nameLabel.frame = NSRect(x: 30, y: 112, width: width - 60, height: 24)
        versionLabel.frame = NSRect(x: 30, y: 139, width: width - 60, height: 16)
        descriptionLabel.frame = NSRect(x: 40, y: 165, width: width - 80, height: 32)
        privacyLabel.frame = NSRect(x: 30, y: 205, width: width - 60, height: 14)
        closeButton.frame = NSRect(x: (width - 70) / 2, y: 238, width: 70, height: 30)
    }

    private func setup() {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.alignment = .center
        addSubview(nameLabel)

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        addSubview(versionLabel)

        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 2
        addSubview(descriptionLabel)

        privacyLabel.font = .systemFont(ofSize: 10)
        privacyLabel.textColor = .tertiaryLabelColor
        privacyLabel.alignment = .center
        addSubview(privacyLabel)

        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
    }

    @objc private func closeClicked() {
        window?.performClose(nil)
    }
}
