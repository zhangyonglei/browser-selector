import AppKit

enum IconRasterizer {
    /// NSWorkspace 返回的图标通常带 1024px 表示，直接保留会解码出数 MB 位图。
    /// 这里一次性栅格化到面板实际使用的小尺寸，只保留几十 KB。
    static func smallIcon(forFile path: String, size: CGFloat = 32) -> NSImage? {
        let source = NSWorkspace.shared.icon(forFile: path)
        guard source.size.width > 0, source.size.height > 0 else { return nil }

        let targetSize = NSSize(width: size, height: size)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}
