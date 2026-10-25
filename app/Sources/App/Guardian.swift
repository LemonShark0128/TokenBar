import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 守护 job / 接管

let kTakeoverName = Notification.Name("com.lemon.deepseek-tokenbar.takeover")
/// 调试：收到这个本机通知就把所有可见窗口（含标题栏按钮）截成 ~/Library/Logs/TokenBar/preview/live-*.png 并记录几何信息。
/// 本机命令行没有屏幕录制权限，这是在真 App 里核对窗口外观/尺寸的唯一办法。
let kSnapshotName = Notification.Name("com.lemon.deepseek-tokenbar.snapshot")

@MainActor
func snapshotWindows() {
    let dir = kLogDir + "/preview"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (i, w) in NSApp.windows.enumerated() where w.isVisible {
        let key = Hud.windows.first(where: { $0.value === w })?.key ?? "win\(i)"
        let close = w.standardWindowButton(.closeButton)
        logLine("快照 \(key)：frame=\(Int(w.frame.width))x\(Int(w.frame.height))@(\(Int(w.frame.minX)),\(Int(w.frame.minY))) "
                + "opaque=\(w.isOpaque) key=\(w.isKeyWindow) close=\(close.map { "\($0.isEnabled)/\($0.isHidden ? "hidden" : "shown")" } ?? "none") "
                + "class=\(type(of: w))")
        guard let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: URL(fileURLWithPath: dir + "/live-\(key).png")) }
            catch { logLine("快照 \(key) 写不进去：\(error.localizedDescription)") }
        }
    }
}
let kGuardianPlistPath = kHome + "/Library/LaunchAgents/\(kGuardianLabel).plist"

/// 守护 job 的 plist：开机自启 + 异常退出（崩溃/被杀）自动重启；正常退出不重启
func guardianPlistXML(exe: String) -> String {
    // 路径可能带 & < > 等（如「~/Apps & Tools/」）：不转义 plist 就坏了，launchctl 加载失败
    let exe = exe.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(kGuardianLabel)</string>
      <key>ProgramArguments</key><array><string>\(exe)</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>ProcessType</key><string>Interactive</string>
    </dict></plist>
    """
}

/// 守护 plist 不存在、或指向的不是现在这份 App（用户把 App 挪了位置）才写；rewritten = 这次改写过
func ensureGuardianPlist() -> (path: String, rewritten: Bool) {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let want = guardianPlistXML(exe: exe)
    if (try? String(contentsOfFile: kGuardianPlistPath, encoding: .utf8)) != want {
        try? FileManager.default.createDirectory(atPath: (kGuardianPlistPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        do {
            try want.write(toFile: kGuardianPlistPath, atomically: true, encoding: .utf8)
            logLine("已写守护 plist：\(kGuardianPlistPath)")
        } catch {
            // 照旧往下走（返回值不变），只是留个痕：开机自启 / 崩溃重启可能不生效
            logLine("守护 plist 写不进去（开机自启和崩溃后自动重启可能不生效）：\(kGuardianPlistPath)：\(error.localizedDescription)")
        }
        return (kGuardianPlistPath, true)
    }
    return (kGuardianPlistPath, false)
}

/// 用户在设置里动过「开机自动启动」开关（动过就尊重他的选择，不再自动补写守护 plist）
let kAutoStartChosenKey = "autoStartChosen"

func autoStartTurnedOff() -> Bool {
    UserDefaults.standard.bool(forKey: kAutoStartChosenKey)
        && !FileManager.default.fileExists(atPath: kGuardianPlistPath)
}

/// 监听「守护实例上位」广播：**只有非守护实例让位**，守护实例自己不听（这样不可能互相让位）。
/// 注意：只有 App 进入 run loop 之后通知才会送达；启动阶段靠 Entry.main 里的轮询兜底。
/// underGuardian：我启动时是不是守护进程（进程内固定，用于决定"要不要让位"）
func watchForTakeover(underGuardian: Bool) {
    DistributedNotificationCenter.default().addObserver(
        forName: kTakeoverName, object: nil, queue: .main) { note in
        let sender = (note.userInfo?["pid"] as? Int) ?? -1
        if sender == Int(getpid()) { return }
        // 通知要等 run loop 起来才送达，可能早已过期：发送者已经退出时再让位，就会一个实例都不剩（实测）
        // 任何本机进程都能发这个广播：进程号超出 pid_t 时不能硬转（会崩）
        guard sender > 0, let pid = pid_t(exactly: sender), kill(pid, 0) == 0 else {
            logLine("忽略过期的接管请求（pid=\(sender) 已不在），本实例继续运行")
            return
        }
        if underGuardian {
            logLine("收到接管请求（来自 pid=\(sender)），我是守护实例，不让位")
            return
        }
        logLine("收到接管请求（来自 pid=\(sender)），本实例（非守护）让位退出")
        exit(0)
    }
}

/// 守护实例上位时广播一次，请非守护的旧实例让位
func broadcastTakeover() {
    DistributedNotificationCenter.default().postNotificationName(
        kTakeoverName, object: nil, userInfo: ["pid": Int(getpid())],
        deliverImmediately: true)
}

func otherInstances() -> [pid_t] {
    let me = ProcessInfo.processInfo.processIdentifier
    var found = Set(NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID)
        .map { $0.processIdentifier })
    // launchd 直接拉起的守护实例在 NSApplication 建好之前不在 LaunchServices 名单里 →
    // 只看 bundle id 会互相看不见：守护实例等 6 秒后退出、手动实例等 8 秒后自己跑（实测两个都没了）。
    // 所以再按可执行文件路径扫一遍进程表。
    if let exe = Bundle.main.executablePath {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(max(0, Int(n))) where pid > 0 {
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf) == exe {
                found.insert(pid)
            }
        }
    }
    return found.filter { $0 != me && $0 > 0 }.sorted()
}

/// 我是不是由守护 job 拉起的？直接问 launchd 那个 job 当前 pid 是不是我。
/// 注意：不能用 XPC_SERVICE_NAME 判断 —— GUI App 即使由自定义 job 拉起，实际也跑在
/// LaunchServices 的 `application.<bundleid>.*` 服务名下。
func guardianJobInfo() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(getuid())/\(kGuardianLabel)"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

func isUnderGuardian() -> Bool {
    (guardianJobInfo() ?? "").contains("pid = \(getpid())")
}

func isGuardianJobLoaded() -> Bool {
    guardianJobInfo() != nil
}

func waitUntilNoOthers(_ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if otherInstances().isEmpty { return true }
        usleep(300_000)
    }
    return otherInstances().isEmpty
}
