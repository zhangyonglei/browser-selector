import Foundation
import os

enum Log {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.zyl.BrowserSelector", category: "app")
    #endif

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.error("\(text, privacy: .public)")
        #endif
    }
}
