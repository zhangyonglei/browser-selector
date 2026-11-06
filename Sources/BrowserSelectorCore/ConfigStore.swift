import Foundation

public enum AppPaths {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("BrowserSelector", isDirectory: true)
    }

    public static var configFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }
}

/// 配置只在启动、保存时读写磁盘；运行期全部走内存。
public final class ConfigStore {
    public private(set) var config: AppConfig
    public let fileURL: URL
    public var onChange: ((AppConfig) -> Void)?

    private let fileManager: FileManager

    public init(fileURL: URL = AppPaths.configFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.config = AppConfig()
        load()
    }

    public func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            config = AppConfig()
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            decoded.sanitize()
            config = decoded
        } catch {
            archiveBrokenConfig()
            config = AppConfig()
            save()
        }
    }

    @discardableResult
    public func save(_ newConfig: AppConfig? = nil) -> Bool {
        if let newConfig {
            var value = newConfig
            value.sanitize()
            config = value
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    public func update(_ mutate: (inout AppConfig) -> Void) {
        var updated = config
        mutate(&updated)
        updated.sanitize()
        guard updated != config else { return }
        config = updated
        save()
        onChange?(config)
    }

    private func archiveBrokenConfig() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.corrupt-\(stamp).json")
        try? fileManager.moveItem(at: fileURL, to: backup)
    }
}
