import Network
import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: UsageModel?
    var status: StatusBarController?
    private var subs = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let m = UsageModel()
        model = m
        // 第一期：数据由 App 内置采集（UsageStore）提供；凭据在钥匙串，采样历史在 Application Support
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        // 采样库打不开（磁盘满、权限等）：本次只在内存里记采样，照样取数显示（旧版这里退回 Python 采集服务，已删）
        let opened = try? SampleStore(path: supportDir.appendingPathComponent("samples.sqlite").path)
        if opened == nil { logLine("采样库打不开，本次采样只记在内存里（重启后历史清空）") }
        if let samples = opened ?? (try? SampleStore(path: ":memory:")) {
            let creds = KeychainCredentialStore()
            let store = UsageStore(providers: ProviderRegistry.all.map { ProviderRegistry.makeProvider($0, http: URLSessionHTTPClient(), log: { logLine($0) }) },
                                   credentials: creds,
                                   samples: samples, intervalSeconds: m.refreshSeconds,
                                   snapshotCache: SnapshotCache(url: supportDir.appendingPathComponent("last-snapshot.json")),
                                   log: { logLine($0) })
            m.attach(store)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { m.startupAccountsCheck() }
            // 上次开着常驻小组件：重启后恢复（自查第 5 条）
            if UserDefaults.standard.bool(forKey: "widgetVisible") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if !m.widgetVisible { m.toggleWidget() } }
            }
            // 网络从断开恢复时立即刷新一次（系统唤醒沿用原来的立即刷新）
            // 回调在主队列上（start(queue: .main)），但系统把它声明成 @Sendable：用 Task { @MainActor } 回到主线程，
            // 「上次是不是断网」只在主线程读写
            pathMonitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor in self?.networkChanged(online: online) }
            }
            pathMonitor.start(queue: .main)
        } else {
            logLine("采样库打不开，内存库也建不起来：无法取数")
        }
        status = StatusBarController(model: m)
        logLine("状态栏就绪：左键开面板，右键出菜单（含真正退出）")
        // object = 逗号分隔的要先打开的窗口（panel,settings,widget,detail），留空则只截图。
        // 调试钩子任何本机进程都能触发（改设置、截图、导出快照），发布版默认不注册；
        // 开发时先 `defaults write com.lemon.deepseek-tokenbar debugHooks -bool true` 再重启 App（app/tools/post.swift 发通知）
        if UserDefaults.standard.bool(forKey: "debugHooks") {
            logLine("调试钩子已打开（debugHooks）")
            DistributedNotificationCenter.default().addObserver(
                forName: kSnapshotName, object: nil, queue: .main) { [weak self] note in
                let opens = ((note.object as? String) ?? "").split(separator: ",").map(String.init)
                // 回调在主队列上，但闭包被声明成 @Sendable：用 Task { @MainActor } 让编译器检查（调试钩子，晚一拍无所谓）
                Task { @MainActor in self?.debugHook(opens, m) }
            }
        }
    }

    /// 调试钩子：按 object 里列的名字逐个打开窗口 / 改设置，最后截图
    private func debugHook(_ opens: [String], _ m: UsageModel) {
        for o in opens {
            switch o {
            case "panel": self.status?.togglePanel()
            case "settings": m.openSettings()
            case "demoswitch": m.usageStore?.demoSwitch()     // 调试：主平台与第一个辅助平台互换
            case "widget": m.toggleWidget()
            case "detail": if let d = m.data?.trend7.last { m.openDetail(d) }
            case "diagmb":
                if let b = self.status?.statusButton {
                    logLine("菜单栏诊断：主题=\(m.themeLabel) 系统深色=\(StatusTheme.systemIsDark()) "
                            + "button=\(b.effectiveAppearance.name.rawValue) "
                            + "window.appearance=\(b.window?.appearance?.name.rawValue ?? "nil") "
                            + "window.effective=\(b.window?.effectiveAppearance.name.rawValue ?? "nil") "
                            + "NSApp.appearance=\(NSApp.appearance?.name.rawValue ?? "nil") "
                            + "标题=「\(b.attributedTitle.string)」 图标template=\(b.image?.isTemplate ?? false) "
                            + "变灰=\(b.appearsDisabled) 模式=\(m.mbMode) 信号=\(m.menuSignal)")
                }
            case "mb:balance": m.mbMode = "balance"
            case "mb:cost": m.mbMode = "cost"
            case "mb:icon": m.mbMode = "icon"
            case "mbsize":
                // 量菜单栏项：系统分到的窗口宽、按钮自然宽、图标宽、文字宽（pt）
                if let b = self.status?.statusButton {
                    let tw = b.attributedTitle.size().width
                    logLine(String(format: "菜单栏尺寸 模式=%@ 窗口=%.1fx%.1f 按钮fitting=%.1f 图标=%.1f 文字=%.1f 标题=「%@」",
                                   m.mbMode, b.window?.frame.width ?? 0, b.window?.frame.height ?? 0,
                                   b.fittingSize.width, b.image?.size.width ?? 0, tw, b.attributedTitle.string))
                }
            case "menuinfo": self.status?.debugMenuOpenPanel()
            case "dumpstore": self.model?.dumpStore()
            case let c where c.hasPrefix("dumpstore:"):
                if let id = ProviderID(rawValue: String(c.dropFirst("dumpstore:".count))) { self.model?.dumpStore(id) }
            case "recordsf": self.model?.recordSiliconFlow()
            case "widgetback": m.returnToPanel()
            case "menucard":
                // 只为核对：按右键菜单同样的方式建一次信息卡，记录尺寸（真菜单要人点开才会出现）
                let h = MenuCardHost(model: m) {}
                logLine(String(format: "信息卡自检：%.0fx%.0f", h.frame.width, h.frame.height))
            case "wpage:balance": m.widgetPage = "balance"
            case "wpage:tokens": m.widgetPage = "tokens"
            case "theme:light": m.themeMode = .light
            case "theme:dark": m.themeMode = .dark
            case "theme:system": m.themeMode = .system
            case "diagclose":
                // 谁接住了红色关闭键位置的点击？再程序化按一次，看窗口会不会关
                for (k, w) in Hud.windows where w.isVisible {
                    guard let b = w.standardWindowButton(.closeButton), let frame = w.contentView?.superview else { continue }
                    let pt = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: frame)
                    let hit = frame.hitTest(pt)
                    var chain: [String] = []
                    var v: NSView? = hit
                    while let x = v, chain.count < 6 { chain.append(String(describing: type(of: x))); v = x.superview }
                    logLine("关闭键诊断 \(k)：hitTest → \(chain.joined(separator: " < "))")
                    b.performClick(nil)
                    logLine("关闭键诊断 \(k)：performClick 后 visible=\(w.isVisible) 小组件开关=\(m.widgetVisible)")
                }
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (opens.isEmpty ? 0 : 1.5)) { snapshotWindows() }
    }

    /// 网络从断开恢复时立即刷新一次
    private var wasOffline = false
    private func networkChanged(online: Bool) {
        if online {
            if wasOffline { DispatchQueue.main.async { logLine("网络已恢复，立即刷新"); self.model?.fetch() } }
            wasOffline = false
        } else {
            wasOffline = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// 日志在后台队列写：退出前同步刷完，别丢最后几行
    func applicationWillTerminate(_ note: Notification) {
        AppLogger.shared.flush()
    }
}

@main
struct Entry {
    /// 后台常驻的关键：禁用 App Nap（否则无窗口时定时器被降频/冻结）与系统自动回收
    static let kKeepAliveReason = "Token Bar：持续轮询用量并在菜单栏实时显示"
    @MainActor static var activity: NSObjectProtocol?
    @MainActor static var delegateRef: AppDelegate?      // NSApplication.delegate 是弱引用，必须自己持有

    @MainActor
    static func main() {
        #if DEVTOOLS
        // 开发工具入口（生成图标、离屏渲染预览）：只有 build.sh --devtools 编的版本才有
        if CommandLine.arguments.contains("--icon") {
            IconMaker.run()
            return
        }
        if CommandLine.arguments.contains(where: { $0 == "--render" || $0 == "--render-check" }) {
            // 预览的界面语言：默认中文（基准图是中文，结果才可重复）；--lang en 出英文预览
            let args = CommandLine.arguments
            let lang = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            L10n.lang = Lang(rawValue: lang ?? "zh") ?? .zh
            RenderMode.run()
            return
        }
        #endif

        // 单实例规则（非对称）：受守护的实例永远赢，非守护实例让位。
        // 让位靠两条：(1) 广播通知（对**已经跑起来**的旧实例生效，它们随时听）；
        //             (2) 启动阶段轮询（通知在 run loop 起来前送不到）。
        let underGuardian = isUnderGuardian()
        watchForTakeover(underGuardian: underGuardian)

        if !otherInstances().isEmpty {
            if underGuardian {
                // 我是守护实例：广播接管，等非守护的旧实例自己退
                broadcastTakeover()
                if waitUntilNoOthers(6) {
                    logLine("接管完成：旧实例已让位，本实例（受守护）继续运行")
                } else {
                    logLine("仍有实例 \(otherInstances()) 未让位（可能是旧版本），本实例退出以保持单图标")
                    exit(0)
                }
            } else {
                logLine("已有实例在运行（\(otherInstances())），本次启动直接退出")
                exit(0)
            }
        } else if AppLocation.isTransient(Bundle.main.bundlePath) {
            // 从 dmg 里直接打开（或被系统隔离运行）：路径是临时的，不写开机自启，照常运行这一次
            logLine("从临时位置运行（\(Bundle.main.bundlePath)）：不设开机自启，请把 Token Bar 拖进「应用程序」再打开")
        } else if !underGuardian && !autoStartTurnedOff() {
            // 当前没有任何实例：把守护实例叫起来（它将成为唯一实例），我们能让位就让位
            // （用户在设置里关掉了开机自启时不走这条：否则手动打开一次就把 plist 补回去，等于偷偷重新开启）
            let (plist, rewritten) = ensureGuardianPlist()
            if rewritten && isGuardianJobLoaded() {
                // App 挪了位置：已加载的 job 还记着旧路径，kickstart 会拉起旧位置的那份（或拉不起来）。
                // 走到这里时没有其他实例在跑，bootout 不会杀到谁；重新注册成新路径
                runProc("/bin/launchctl", ["bootout", "gui/\(getuid())/\(kGuardianLabel)"], wait: true)
                logLine("App 换了位置：守护 job 已按新路径重新注册")
                runProc("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
            } else if isGuardianJobLoaded() {
                runProc("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(kGuardianLabel)"])
            } else {
                runProc("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
            }
            var handed = false
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let p = otherInstances().first {
                    usleep(1_500_000)                     // 观察 1.5 秒，确认它站稳了
                    if otherInstances().contains(p) { handed = true; break }
                }
                usleep(300_000)
            }
            if handed {
                logLine("守护实例已接手（\(otherInstances())），本实例让位退出")
                exit(0)
            }
            logLine("守护未接手，本实例继续运行（未受守护）")
        }

        ProcessInfo.processInfo.disableAutomaticTermination(kKeepAliveReason)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: kKeepAliveReason)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegateRef = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        logLine("启动：pid=\(getpid()) 防休眠降频已开启")
        app.run()
    }
}
