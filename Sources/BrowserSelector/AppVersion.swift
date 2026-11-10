import Foundation

/// 版本号来自 app 包的 Info.plist（project.yml / Resources/Info.plist）。
/// `swift run` 直接跑可执行文件时没有 Info.plist，回退到当前发布版本。
enum AppVersion {
    static let shortVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    /// 例："1.0.0（1）"
    static var display: String { "\(shortVersion)（\(build)）" }
}
