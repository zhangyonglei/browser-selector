import AppKit
import BrowserSelectorCore

enum PickerMetrics {
    static let width: CGFloat = 344
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 2
    static let maxVisibleRows = 8
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 30
    static let listVerticalPadding: CGFloat = 6
    static let dividerHeight: CGFloat = 1

    static func visibleRows(_ count: Int) -> Int {
        min(max(count, 1), maxVisibleRows)
    }

    static func listHeight(_ count: Int) -> CGFloat {
        let rows = CGFloat(visibleRows(count))
        let spacing = CGFloat(max(0, visibleRows(count) - 1)) * rowSpacing
        return rows * rowHeight + spacing + listVerticalPadding * 2
    }

    static func panelHeight(_ count: Int) -> CGFloat {
        headerHeight + listHeight(count) + footerHeight + dividerHeight
    }

    static func panelSize(_ count: Int) -> NSSize {
        NSSize(width: width, height: panelHeight(count))
    }
}

final class PickerState {
    let url: URL
    let browsers: [BrowserEntry]
    let icons: [String: NSImage]
    let defaultBrowserID: String?
    private(set) var selectedIndex: Int

    init(url: URL, browsers: [BrowserEntry], icons: [String: NSImage], defaultBrowserID: String?) {
        self.url = url
        self.browsers = browsers
        self.icons = icons
        self.defaultBrowserID = defaultBrowserID
        self.selectedIndex = browsers.firstIndex { $0.id == defaultBrowserID } ?? 0
    }

    func select(_ index: Int) {
        guard browsers.indices.contains(index) else { return }
        selectedIndex = index
    }

    func move(_ delta: Int) {
        guard !browsers.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + browsers.count) % browsers.count
    }

    var selectedBrowser: BrowserEntry? {
        browsers.indices.contains(selectedIndex) ? browsers[selectedIndex] : nil
    }
}

/// 纯 AppKit 面板内容。相比 SwiftUI，显示/关闭后不会让常驻 footprint 抬高约 10MB。
final class PickerContentView: NSVisualEffectView {
    private let pickerState: PickerState
    private let onSelect: (BrowserEntry) -> Void
    private let onCancel: () -> Void
    private let rows: [BrowserRowView]

    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择 · ↩ 打开 · esc 取消")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let topDivider = NSBox()
    private let bottomDivider = NSBox()

    override var isFlipped: Bool { true }

    init(
        state: PickerState,
        onSelect: @escaping (BrowserEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pickerState = state
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.rows = state.browsers.enumerated().map { index, browser in
            let row = BrowserRowView()
            row.configure(
                browser: browser,
                index: index,
                icon: state.icons[browser.id],
                isDefault: browser.id == state.defaultBrowserID
            )
            return row
        }
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshSelection(scrollToVisible: Bool) {
        for (index, row) in rows.enumerated() {
            row.isSelected = index == pickerState.selectedIndex
        }
        guard scrollToVisible, rows.indices.contains(pickerState.selectedIndex) else { return }
        let row = rows[pickerState.selectedIndex]
        row.scrollToVisible(row.bounds)
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        let listHeight = PickerMetrics.listHeight(pickerState.browsers.count)
        let listTop = PickerMetrics.headerHeight

        hostLabel.frame = NSRect(x: 14, y: 10, width: width - 28, height: 17)
        urlLabel.frame = NSRect(x: 14, y: 30, width: width - 28, height: 14)
        topDivider.frame = NSRect(x: 0, y: listTop - 1, width: width, height: 1)

        scrollView.frame = NSRect(x: 0, y: listTop, width: width, height: listHeight)
        listView.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)

        let rowWidth = width - 16
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 8,
                y: PickerMetrics.listVerticalPadding
                    + CGFloat(index) * (PickerMetrics.rowHeight + PickerMetrics.rowSpacing),
                width: rowWidth,
                height: PickerMetrics.rowHeight
            )
        }

        bottomDivider.frame = NSRect(x: 0, y: listTop + listHeight, width: width, height: 1)

        cancelButton.sizeToFit()
        let footerY = listTop + listHeight + PickerMetrics.dividerHeight + 7
        cancelButton.frame = NSRect(
            x: width - 14 - cancelButton.frame.width,
            y: footerY,
            width: cancelButton.frame.width,
            height: 16
        )
        hintLabel.frame = NSRect(
            x: 14,
            y: footerY,
            width: max(0, cancelButton.frame.minX - 22),
            height: 14
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func setup() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor.separatorColor.cgColor

        hostLabel.stringValue = pickerState.url.host ?? "打开链接"
        hostLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.maximumNumberOfLines = 1

        urlLabel.stringValue = pickerState.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.maximumNumberOfLines = 1

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 1

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isBordered = false
        cancelButton.font = .systemFont(ofSize: 10, weight: .medium)
        cancelButton.contentTintColor = .secondaryLabelColor
        addSubview(cancelButton)

        for divider in [topDivider, bottomDivider] {
            divider.boxType = .separator
            addSubview(divider)
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = listView

        for (index, row) in rows.enumerated() {
            row.onSelect = { [weak self] in
                guard let self else { return }
                self.pickerState.select(index)
                self.refreshSelection(scrollToVisible: false)
                self.onSelect(self.pickerState.browsers[index])
            }
            row.onHover = { [weak self] in
                guard let self else { return }
                self.pickerState.select(index)
                self.refreshSelection(scrollToVisible: false)
            }
            listView.addSubview(row)
        }

        addSubview(hostLabel)
        addSubview(urlLabel)
        addSubview(scrollView)
        addSubview(hintLabel)

        refreshSelection(scrollToVisible: false)
    }

    @objc private func cancelClicked() {
        onCancel()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class BrowserRowView: NSView {
    var onSelect: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let defaultBadge = BadgeView()
    private let numberBadge = BadgeView()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        addSubview(detailLabel)

        defaultBadge.accent = true
        addSubview(defaultBadge)
        addSubview(numberBadge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(browser: BrowserEntry, index: Int, icon: NSImage?, isDefault: Bool) {
        iconView.image = icon
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        nameLabel.stringValue = browser.displayName
        detailLabel.stringValue = browser.hasCustomArguments ? browser.argumentsTemplate : ""
        detailLabel.isHidden = !browser.hasCustomArguments
        defaultBadge.text = "默认"
        defaultBadge.isHidden = !isDefault
        numberBadge.text = "\(index + 1)"
        numberBadge.isHidden = index >= 9
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let height = bounds.height
        iconView.frame = NSRect(x: 8, y: (height - 20) / 2, width: 20, height: 20)

        let numberSize: CGFloat = 18
        let numberX = bounds.width - 8 - numberSize
        numberBadge.frame = NSRect(x: numberX, y: (height - 18) / 2, width: numberSize, height: 18)

        let defaultWidth: CGFloat = defaultBadge.isHidden ? 0 : 30
        let defaultX = numberX - 6 - defaultWidth
        defaultBadge.frame = NSRect(x: defaultX, y: (height - 16) / 2, width: defaultWidth, height: 16)

        let textRight = defaultBadge.isHidden ? numberX - 6 : defaultX - 6
        let textWidth = max(0, textRight - 36)

        if detailLabel.isHidden {
            nameLabel.frame = NSRect(x: 36, y: (height - 17) / 2, width: textWidth, height: 17)
            detailLabel.frame = .zero
        } else {
            nameLabel.frame = NSRect(x: 36, y: 3, width: textWidth, height: 16)
            detailLabel.frame = NSRect(x: 36, y: 19, width: textWidth, height: 12)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.4, dy: 0.4),
            xRadius: 7,
            yRadius: 7
        )
        border.lineWidth = 0.8
        border.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

private final class BadgeView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }
    var accent: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tint = accent ? NSColor.controlAccentColor : NSColor.labelColor
        tint.withAlphaComponent(accent ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: accent ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
        )
    }
}
