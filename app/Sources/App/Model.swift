import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态

@MainActor
final class UsageModel: ObservableObject {
    @Published var data: AppData?
    @Published var bannerDismissal = BannerDismissal.load(.standard)

    var visibleBanner: AppData.RiskBanner? {
        data?.banner.flatMap { bannerDismissal.hides($0) ? nil : $0 }
    }

    func dismissBanner(refit: Bool = true) {
        guard let banner = visibleBanner else { return }
        bannerDismissal.dismiss(banner)
        bannerDismissal.save(.standard)
        let name = ProviderID(rawValue: banner.id).map { ProviderRegistry.logName($0) } ?? "未知平台"
        logLine("关掉预警条：\(name)")
        if refit { onRefit?() }
    }

    /// 第一期起数据来自 UsageStore（不再请求 Python 采集服务）；mainState 是主平台的原始状态
    var usageStore: UsageStore?
    @Published var mainState: PlatformState?
    /// 菜单栏平台的一行数据（数字取它，不取主平台）；没有 store（离屏预览）时为 nil，回落到主平台
    @Published var menuBarSide: AppData.Side?
    /// 还没有任何平台凭据：面板显示「添加第一个平台」
    @Published var needsSetup = false
    /// 标题下的「已自动切换」提示（面板出现时从 UsageStore 取，3 秒后淡出）
    @Published var switchNotice: String? {
        didSet { switchNoticeGeneration += 1 }
    }
    // 两次切换可能文案相同，仍应作为两条新提示分别计时。
    var switchNoticeGeneration = 0
    /// 主平台是否固定（标题旁「已固定」）
    @Published var mainPinned = false
    /// 设置里重新登录（网页登录）后的结果，显示在该平台的账号行下；再次登录时清掉
    @Published var reloginNotes: [ProviderID: ReloginNote] = [:]
    /// Claude 套餐的状态栏钩子（默认路径）。离屏预览只读它的路径，不调用 install / restore
    var claudeInstaller: ClaudeStatusLineInstaller { .standard }
    /// 状态栏钩子还在不在：打开面板、打开设置时读一次（.replaced = 被别人换掉了）
    @Published var claudeHookState: ClaudeStatusLineInstaller.HookState = .notInstalled
    /// Claude 套餐的额度来源（UserDefaults claudePlan.source 的镜像）：打开面板、打开设置时同步；离屏预览直接设
    @Published var claudeSource: ClaudePlanSource = .terminal
    /// 离屏预览固定的「现在」（套餐重置倒计时要可重复）；真 App 为 nil，用当前时间
    var fixedNow: Date?
    /// 渲染预览固定时区（菜单栏读数里的「10:13 重置」不随本机时区变）；真 App 为 nil
    var fixedTimeZone: TimeZone?
    /// 已经提醒过「额度用完」的窗口：持久化保存，重启后同一窗口不重复提醒
    var exhaustedMemory = ExhaustedAlertMemory.load(.standard)
    /// 本次运行是否已经在日志里记过「已读到 Codex 额度」
    var codexQuotaLogged = false
    var panelShown = false {
        didSet { if panelShown != oldValue { visibilityChanged(shown: panelShown) } }
    }
    /// 本机 Claude Code / Codex 用量（近 7 天，按日期 × 模型）；后台线程读，最多每 5 分钟一次
    var localUsage: [ProviderID: DailyModelTokens] = [:]
    var localThrottle = LocalUsageThrottle()
    /// 本机正在跑的 Claude Code / Codex 轮次：每 10 或 30 秒在后台扫一次（RunningScanCadence），只在内存里（离屏预览直接设）
    @Published var runningTasks: [RunningTask] = []
    var runningTimer: AnyCancellable?
    /// 在跑任务扫描当前的间隔（RunningScanCadence：10 或 30 秒）
    var runningScanEvery: TimeInterval = 0
    /// 桌面 App 额度记录的变化时间（文件没变不再解析）
    let desktopProbe = DesktopActivityProbe()
    var runningGen = 0
    /// 本机日志逐文件的解析缓存：没变的文件不再打开（传进后台读取任务）
    let localCache = LocalUsageCache()
    /// 正在跑的任务：没变的会话文件不再读
    let runningCache = RunningTasksCache()
    /// 「其他平台」当前显示的顺序：面板开着时不变，下次打开面板时才按活跃度更新
    var sideOrder: [ProviderID] = []
    var sideOrderTask: Task<Void, Never>?
    var storeSub: AnyCancellable?
    @Published var error: String?
    @Published var updating = false

    @Published var themeMode: ThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "themeMode")
            applyAppAppearance()
        }
    }
    /// 系统当前是否深色（跟随系统时用；系统外观一变就更新这里，从而触发界面重绘）
    @Published var systemIsDark: Bool = StatusTheme.systemIsDark()

    @Published var refreshSeconds: Int {
        didSet {
            UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds")
            restartTimer()
        }
    }
    @Published var launchAtLogin: Bool
    @Published var showSettings = false
    /// 设置窗当前页、「高级」是否展开、选了「自定义」预警线的非主平台（只在内存里，不存）
    @Published var settingsPage: SettingsPage = .platform
    @Published var alertCustomOpen: Set<ProviderID> = []
    /// 面板（popover）高度：每次打开时按内容量出来，不再写死 820
    @Published var panelHeight: CGFloat = 820
    /// 面板里「Token 明细」展开与否（展开后要重新定高 → onRefit）
    @Published var detailOpen = false
    /// 面板「近 7 天 token」选中的日期；nil = 今天。关面板时回到今天
    @Published var trendPick: String?
    var onRefit: (() -> Void)?

    /// 点「近 7 天 token」的柱子：选中那天（图例行数会变，重新定高）
    func pickTrendDay(_ iso: String?) {
        trendPick = iso
        onRefit?()
    }

    @Published var widgetVisible = false {
        didSet { if widgetVisible != oldValue { visibilityChanged(shown: widgetVisible) } }
    }
    /// 菜单栏显示什么：balance（余额）/ cost（今日花费）/ icon（只显示图标）—— 不再轮播
    @Published var mbMode: String {
        didSet { UserDefaults.standard.set(mbMode, forKey: "mbMode") }
    }
    /// 小组件当前页：balance（余额）/ tokens（今日 Token），在小组件里点切换
    @Published var widgetPage: String {
        didSet { UserDefaults.standard.set(widgetPage, forKey: "widgetPage") }
    }
    /// 异常时从屏幕顶部弹出提醒条（替代原来常驻的顶部状态条）
    /// 花费飙升（近 1 小时是平时的 N 倍）时也提醒：默认关，打开后弹通知 / 提醒条、菜单栏加橙点
    @Published var spikeAlertsOn: Bool = UserDefaults.standard.bool(forKey: StatusPresenter.spikeAlertsKey) {
        didSet { UserDefaults.standard.set(spikeAlertsOn, forKey: StatusPresenter.spikeAlertsKey) }
    }
    /// 余额 / 额度一直低于预警线时隔多久再提醒（小时，0 = 只提醒一次），默认 6
    @Published var alertRepeatHours: Int = AlertRepeat.hours(.standard) {
        didSet { UserDefaults.standard.set(alertRepeatHours, forKey: AlertRepeat.key) }
    }
    var onOpenPanel: (() -> Void)?
    @Published var selectedModel: String?
    @Published var trendModel: String?
    @Published var openedDay: AppData.Day?
    @Published var fuelFullCny: Double {
        didSet { UserDefaults.standard.set(fuelFullCny, forKey: "fuelFullCny") }
    }

    /// 主平台的预警线（0 = 关闭）。唯一数据源是 ProviderSettings.lowAlerts；这里是它的镜像，
    /// 通知、提醒条、菜单栏橙色照旧读它。设置里「油箱」的预警线改的就是主平台这一项。
    /// 低于它就弹一次通知；充回线上再重新武装。
    @Published var balanceAlertCny: Double {
        didSet {
            guard !syncingAlert else { return }
            updateProviderSettings { s in
                s.lowAlerts[self.mainID] = self.balanceAlertCny > 0
                    ? Decimal(string: String(self.balanceAlertCny), locale: Locale(identifier: "en_US_POSIX")) : nil
            }
        }
    }
    var syncingAlert = false
    /// 设置页里选的是「自定义」金额
    @Published var balanceAlertCustom: Bool {
        didSet { UserDefaults.standard.set(balanceAlertCustom, forKey: "balanceAlertCustom") }
    }

    /// 面板右上角 × 只关面板（由状态栏控制器注入，程序继续在后台跑）
    var onClosePanel: (() -> Void)?

    // MARK: - 余额预警（检查和发送在 ModelAlerts.swift）

    /// 每次成功取到余额后检查一次：低于预警线 → 弹一次；充回线上 → 重新武装
    /// 近 1 小时花费超过近 7 天日均时速的 3 倍 → 提醒用量异常增加，6 小时内只提醒一次
    /// 按平台记的提醒状态（每个平台的预警线各自提醒；换主平台不串）
    var platformAlerts = PlatformAlertTracker.load(.standard)

    /// 真正的退出：先摘掉看门狗 job 再退，否则 10 秒后会被重新拉起
    func quitForReal() {
        logLine("用户请求退出，同时停止守护")
        for label in [kGuardianLabel, kAppAgentLabel] {
            runProc("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    /// 汇率：每小时看一眼，满 24 小时才真的请求（睡眠错过整点也不要紧）。检查更新跟着同一个节拍判断
    var fxTimer: Timer?
    var updateLaunchTimer: Timer?
    /// 检查更新：上次看到的、比本机新的版本（右键菜单多一项，设置页显示）
    @Published var availableUpdate: UpdateCheck.Release? = kRendering ? nil : UpdateCheck.available(.standard, current: UpdateCheck.currentVersion)
    /// 设置里点「现在检查」的结果（只在内存里）；正在查时 updateChecking = true
    @Published var updateOutcome: UpdateCheck.Outcome?
    @Published var updateChecking = false
    @Published var autoUpdateCheck: Bool = kRendering || UpdateCheck.isEnabled(.standard) {
        didSet { UpdateCheck.setEnabled(autoUpdateCheck, .standard); logLine("自动检查更新：\(autoUpdateCheck ? "开" : "关")") }
    }
    var okCount = 0
    let startedAt = Date()

    init() {
        let d = UserDefaults.standard
        let resolvedTheme: ThemeMode
        if let raw = d.string(forKey: "themeMode"), let m = ThemeMode(rawValue: raw) {
            resolvedTheme = m
        } else if let oldDark = d.object(forKey: "dark") as? Bool {   // 迁移旧的「深色开关」设置
            resolvedTheme = oldDark ? .dark : .light
        } else {
            resolvedTheme = .system
        }
        themeMode = resolvedTheme
        d.set(resolvedTheme.rawValue, forKey: "themeMode")
        let rs = d.object(forKey: "refreshSeconds") as? Int ?? 30
        refreshSeconds = [60, 120, 300].contains(rs) ? rs : 60     // 没存过或旧的 30 秒：按 60 秒（最短取数间隔）
        fuelFullCny = d.object(forKey: "fuelFullCny") as? Double ?? 50
        // 预警线来自 ProviderSettings（含旧 balanceAlertCny 的一次性迁移）；启动时主平台先按 DeepSeek 读，store 就绪后会同步
        balanceAlertCny = ProviderSettings.load(d).lowAlerts[.deepseek].map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        balanceAlertCustom = d.object(forKey: "balanceAlertCustom") as? Bool ?? false
        // 旧版是多选 + 轮播；迁移成单选：只勾了「今日花费」的沿用花费，其余一律显示余额
        mbMode = d.string(forKey: "mbMode")
            ?? ((d.object(forKey: "mbShowCost") as? Bool ?? false) && !(d.object(forKey: "mbShowBalance") as? Bool ?? true)
                ? "cost" : "balance")
        widgetPage = d.string(forKey: "widgetPage") ?? "balance"
        launchAtLogin = FileManager.default.fileExists(atPath: kHome + "/Library/LaunchAgents/\(kGuardianLabel).plist")
        // 离屏预览只用固定数据：不写采集配置、不启动服务或后台刷新。
        guard !kRendering else { return }
        requestNotificationAuthOnce()
        // 刷新由 AppMain 紧接着 attach 的 UsageStore 调度
        startExchangeRateRefresh()
        // 睡眠唤醒后立刻刷新一次，避免醒来先看到旧数字
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // 回调在主队列上，但闭包被声明成 @Sendable：用 Task { @MainActor } 让编译器检查
            Task { @MainActor in
                guard let self = self else { return }
                logLine("系统唤醒，立即刷新")
                self.systemIsDark = StatusTheme.systemIsDark()
                self.fetch()
            }
        }
        // 跟随系统时：系统外观一变就更新（进而触发界面重绘）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let now = StatusTheme.systemIsDark()
                guard now != self.systemIsDark else { return }
                self.systemIsDark = now
                logLine("系统外观变化：现在\(now ? "深色" : "浅色")（当前模式：\(self.themeLabel)）")
            }
        }
        logLine("主题：\(themeLabel)（系统当前\(systemIsDark ? "深色" : "浅色")）")
        applyAppAppearance()
    }

    /// 刷新间隔改了：UsageStore 按新间隔重新调度
    func restartTimer() {
        guard let s = usageStore else { return }
        let secs = refreshSeconds
        DispatchQueue.main.async { s.start(intervalSeconds: secs) }
    }

    var currentModel: AppData.ModelUse? {
        guard let ms = data?.models, !ms.isEmpty else { return nil }
        if let k = selectedModel, let m = ms.first(where: { $0.key == k }) { return m }
        return ms.first
    }

    var trendModelKey: String? {
        guard let ms = data?.models, !ms.isEmpty else { return nil }
        if let k = trendModel, ms.contains(where: { $0.key == k }) { return k }
        return ms.first?.key
    }

    /// 手动刷新：交给 UsageStore（结果经 applyStore 回到界面）
    func fetch() {
        guard let s = usageStore else { return }
        updating = true
        Task { @MainActor in
            await s.refresh()
            self.updating = false
        }
    }

    /// 「开机自动启动」= 注册/注销守护 job（同一个 job 负责开机自启 + 异常退出自动重启）
    func toggleAutoStart() {
        let path = kHome + "/Library/LaunchAgents/\(kGuardianLabel).plist"
        UserDefaults.standard.set(true, forKey: kAutoStartChosenKey)
        if launchAtLogin {
            // ⚠️ 不能 bootout：本实例多半就是这个 job 拉起的，bootout 会把自己一起杀掉（实测图标直接消失）。
            // 改为 disable（下次登录不再加载）+ 删 plist；本次会话里守护照旧，退出 App 走「退出」菜单。
            runProc("/bin/launchctl", ["disable", "gui/\(getuid())/\(kGuardianLabel)"])
            do {
                try FileManager.default.removeItem(atPath: path)
                logLine("已关闭开机自动启动（下次登录生效；当前实例继续运行）")
            } catch {
                logLine("关闭开机自动启动失败：删不掉 \(path)（\(error.localizedDescription)）")
            }
        } else {
            // 从 dmg 里直接运行时路径是临时的：不写守护 plist（推出 dmg 后开机自启会指向不存在的文件）
            guard !AppLocation.isTransient(Bundle.main.bundlePath) else {
                logLine("从临时位置运行：先把 Token Bar 拖进「应用程序」再开开机自动启动")
                return
            }
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            do {
                // 新用户的家目录里可能还没有 LaunchAgents
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try guardianPlistXML(exe: exe).write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                logLine("开机自动启动没开成：写不了 \(path)（\(error.localizedDescription)）")
                return
            }
            runProc("/bin/launchctl", ["enable", "gui/\(getuid())/\(kGuardianLabel)"])
            if !isGuardianJobLoaded() {
                runProc("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path])
            }
            logLine("已开启开机自动启动（崩溃/被杀会自动重启；手动退出不会）")
        }
        // 以 plist 是否真的在为准（删除失败时开关不能假装关掉了）
        launchAtLogin = FileManager.default.fileExists(atPath: path)
    }
}
