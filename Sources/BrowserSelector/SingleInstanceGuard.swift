import AppKit
import Darwin
import Foundation
import BrowserSelectorCore

extension Notification.Name {
    static let browserSelectorShowSettings = Notification.Name("com.zyl.BrowserSelector.showSettings")
}

/// 进程级单实例锁。
///
/// 先检查同 Bundle ID 的运行实例，再用 `flock(LOCK_EX | LOCK_NB)` 持有
/// `~/Library/Application Support/BrowserSelector/BrowserSelector.lock`。
/// 锁由内核随进程释放，不需要手动清理；锁文件本身可以常驻。
final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    private static let bundleIdentifier = "com.zyl.BrowserSelector"
    private var lockDescriptor: Int32 = -1

    private init() {}

    func acquire() -> Bool {
        let hasOtherInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .contains { application in
                application.processIdentifier != getpid() && !application.isTerminated
            }
        if hasOtherInstance {
            return false
        }

        let directory = AppPaths.applicationSupportDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            // 无法创建目录时不要把应用直接挡在门外。
            return true
        }

        let path = directory.appendingPathComponent("BrowserSelector.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return true }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0

        if fcntl(descriptor, F_SETLK, &lock) == 0 {
            lockDescriptor = descriptor
            return true
        }

        close(descriptor)
        return false
    }

    deinit {
        guard lockDescriptor >= 0 else { return }
        var unlock = flock()
        unlock.l_type = Int16(F_UNLCK)
        unlock.l_whence = Int16(SEEK_SET)
        unlock.l_start = 0
        unlock.l_len = 0
        _ = fcntl(lockDescriptor, F_SETLK, &unlock)
        close(lockDescriptor)
    }
}
