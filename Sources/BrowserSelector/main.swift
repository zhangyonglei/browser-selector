import AppKit

guard SingleInstanceGuard.shared.acquire() else {
    DistributedNotificationCenter.default().postNotificationName(
        .browserSelectorShowSettings,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    // 给已运行实例一点时间接收通知，再安静退出。
    Thread.sleep(forTimeInterval: 0.15)
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
