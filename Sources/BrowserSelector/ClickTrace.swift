import Foundation

/// 仅在显式传入 `--trace-clicks` 时输出点击链路诊断，不影响正常运行的“无日志”约束。
enum ClickTrace {
    static let isEnabled = CommandLine.arguments.contains("--trace-clicks")

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[trace] \(message())")
        fflush(stdout)
    }
}
