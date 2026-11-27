// Token Bar —— 菜单栏常驻的用量面板（原生 SwiftUI）
import AppKit
import SwiftUI


let kAppAgentLabel = "com.lemon.deepseek-tokenbar"
let kGuardianLabel = "com.lemon.deepseek-tokenbar.alive"
let kBundleID = "com.lemon.deepseek-tokenbar"
let kHome = NSHomeDirectory()
/// 日志在 macOS 标准位置（「控制台」App 里能直接看）
let kLogDir = kHome + "/Library/Logs/TokenBar"
/// 面板宽度（A 版从 456 收到 360）
let kPanelWidth: CGFloat = 360
/// 离屏自检（--render）：ImageRenderer 画不出 NSVisualEffectView，此时背景退回纯色
let kRendering = CommandLine.arguments.contains(where: { $0 == "--render" || $0 == "--render-check" })

/// 存一项用户偏好。离屏渲染时不写：预览和正在用的 App 共用同一个偏好域，预览途中会把主题、小组件页等改来改去，
/// 中途退出（或用户这时启动 App）就会留下预览用的值。只管 UsageModel 和 Glass 的偏好；
/// 其他地方写 UserDefaults 要自己判断 kRendering（新加偏好时请走这里）
func savePref(_ value: Any?, forKey key: String) {
    guard !kRendering else { return }
    UserDefaults.standard.set(value, forKey: key)
}

/// 超过 1 MB 滚动为 app.log.1（只留一份）
let kLogFile = AppLogger.shared.file

/// 写日志：复用一个时间格式化器，写文件在后台串行队列；退出前 AppLogger.shared.flush() 刷完
func logLine(_ s: String) {
    AppLogger.shared.log(s)
}

/// wait：等它跑完（下一步依赖它的结果时用，如先 bootout 再 bootstrap）
func runProc(_ path: String, _ args: [String], wait: Bool = false) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // 输出一律丢给 /dev/null：接 Pipe 又没人读，输出超过管道缓冲（约 64KB）子进程会卡住
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { logLine("执行失败 \(path): \(error.localizedDescription)"); return }
    if wait { p.waitUntilExit() }
}
