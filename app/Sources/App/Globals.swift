// Token Bar —— 菜单栏常驻的用量面板（原生 SwiftUI）
import AppKit
import Combine
import SwiftUI
import UserNotifications


let kAppAgentLabel = "com.lemon.deepseek-tokenbar"
let kGuardianLabel = "com.lemon.deepseek-tokenbar.alive"
let kBundleID = "com.lemon.deepseek-tokenbar"
let kHome = NSHomeDirectory()
/// 日志在 macOS 标准位置（「控制台」App 里能直接看）
let kLogDir = kHome + "/Library/Logs/TokenBar"
let kLog = URL(fileURLWithPath: kLogDir + "/app.log")
/// 采样库、快照所在目录
let kSupportDir = kHome + "/Library/Application Support/TokenBar"
/// 面板宽度（A 版从 456 收到 360）
let kPanelWidth: CGFloat = 360
/// 离屏自检（--render）：ImageRenderer 画不出 NSVisualEffectView，此时背景退回纯色
let kRendering = CommandLine.arguments.contains(where: { $0 == "--render" || $0 == "--render-check" })

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
    // wait 时输出丢给 /dev/null：管道没人读，输出多了子进程会卡住
    if wait { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
    else { p.standardOutput = Pipe(); p.standardError = Pipe() }
    do { try p.run() } catch { logLine("执行失败 \(path): \(error.localizedDescription)"); return }
    if wait { p.waitUntilExit() }
}
