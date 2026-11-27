import AppKit
import Combine
import SwiftUI

/// UsageStore → UsageModel：主平台状态变了就重新生成界面数据，并沿用原来的预警和日志
extension UsageModel {
    @MainActor
    func attach(_ store: UsageStore) {
        usageStore = store
        // 系统时区变了（出差、手动改）：马上按新时区重算「今日」
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await store.refresh() }
        }
        // 平台数据变了、或主平台自动切换 / 手动设定了，都重新生成界面数据
        storeSub = store.$platforms.map { _ in () }
            .merge(with: store.$switchState.map { _ in () })
            .merge(with: store.$menuBarProvider.map { _ in () })
            .merge(with: store.$menuBarRotation.map { _ in () })
            .merge(with: store.$spendHistory.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] _ in self?.applyStore() }     // 前面已 receive(on: main)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitoredAgentDirs != AgentDirs.current else { return }
                self.reloadRunningTasks()
            }
        }
        startLogMonitoring()
        retuneRunningTimer()
        reloadRunningTasks()
        store.surfaceVisible = panelShown || widgetVisible
        if refreshPause.paused { store.setPaused(true) }
        store.start(intervalSeconds: refreshSeconds)
    }

    /// 「显示哪个平台」选中后（设置下拉、右键子菜单、引导页共用）：auto = 当前使用，平台 rawValue = 固定它
    @MainActor
    func chooseMain(_ k: String) {
        guard let store = usageStore else { return }
        let pick = SettingsLayout.mainPick(k, current: store.mainProvider)
        if let id = pick.pin { store.pinMain(id) }
        store.setAutoMain(pick.auto)     // switchState 变化经 storeSub → applyStore 刷新界面
    }

    /// 用户 2026-11-13：取数和任务扫描后同步，活动出现、限流、到期都触发菜单栏刷新。
    @MainActor
    private func syncMenuBarPaygActivity() {
        let active = usageStore?.paygActiveIDs(now: fixedNow ?? Date()) ?? []
        if active != menuBarPaygActive { menuBarPaygActive = active }
    }

    @MainActor
    func applyStore() {
        guard let store = usageStore else { return }
        syncMenuBarPaygActivity()
        scheduleAlertFlush() // 没有新提醒的刷新也要送出安静时段积压。
        reconcileTodayLayout()
        let risks = store.risks()
        let kc = StatusPresenter.keychainBanner(store.platforms)
        if kc != keychainBanner { keychainBanner = kc }
        var pruned = bannerDismissal
        let added = Set(store.platforms.filter { $0.status.isShown }.map(\.id))
        pruned.prune(risks: risks, pending: added.subtracting(store.platformsWithReading()))
        if pruned != bannerDismissal {
            bannerDismissal = pruned
            pruned.save(.standard)
        }
        guard let main = store.platforms.first(where: { $0.id == store.mainProvider }) ?? store.platforms.first else { return }
        mainState = main
        mainPinned = store.isMainPinned
        // 面板开着时换了主平台或数据变了，内容高度跟着变：重新定高（原来只在打开面板时量一次）
        defer { if panelShown { onRefit?() } }
        // 面板开着时的新切换也显示提示，由真实面板独立计时。
        if panelShown, let notice = store.pendingSwitchNotice {
            switchNotice = notice
            store.consumeAutoSwitch()
        }
        // Codex 套餐第一次读到额度：日志只写这一句（不写额度数字和日志内容）
        if !codexQuotaLogged, store.platforms.contains(where: { $0.id == .codexPlan && $0.status != .notAdded && $0.snapshot?.quota != nil }) {
            codexQuotaLogged = true
            logLine("已读到 Codex 额度")
        }
        let quotaNow = Date()
        checkQuotaExhausted(store.platforms, now: quotaNow)
        checkQuotaRecovered(store.platforms, now: quotaNow)
        let hidden = store.hiddenPlatforms
        if hidden != hiddenIDs { hiddenIDs = hidden }
        // 由 UsageStore 判断，这里不读钥匙串；平台全隐藏了（主平台也是隐藏的）同样没东西可显示
        needsSetup = !main.status.isShown
        if needsSetup {           // 还没添加平台：不算错误，面板显示添加入口
            data = nil
            menuBarSide = nil
            error = nil
            return
        }
        let others = store.platforms.filter { $0.id != main.id }
        reloadLocalUsageIfDue(store.platforms)
        // 其他平台：保持当前顺序，只处理增减（名次在下次打开面板时才更新）
        let sideIDs = others.filter { $0.status.isShown }.map(\.id)
        sideOrder = SideOrder.reconcile(sideOrder, with: SideOrder.ranked(sideIDs, activity: store.activities()))
        let hasData = main.snapshot != nil || main.lastSample != nil
        let wasErr = error != nil
        error = StatusPresenter.error(for: main, name: ProviderRegistry.displayName(main.id))
        if hasData {
            let now = Date(), zone = TimeZone.autoupdatingCurrent
            let spendHistory = store.spendHistory(now: now, timeZone: zone)
            var d = AppDataMapping.appData(main: main, others: others, now: now, timeZone: zone,
                                           usdToCny: ProviderSettings.load(.standard).usdToCny, localUsage: localUsage,
                                           localBreakdowns: localBreakdowns, spendHistory: spendHistory)
            d.sides = SideOrder.apply(sideOrder, to: d.sides)
            AppDataMapping.applyRisks(&d, main: main.id, risks: risks, now: Date(),
                                      timeZone: .autoupdatingCurrent, currency: d.balance.currency)
            data = d
            // 菜单栏平台就是主平台时不单独取一行：沿用主平台的完整数据（估算今日、续航天数等与原来一致）
            menuBarSide = store.menuBarProvider == main.id ? nil
                : store.platforms.first { $0.id == store.menuBarProvider && $0.status.isShown }
                    .map { AppDataMapping.side($0, now: Date(), timeZone: .autoupdatingCurrent) }
            okCount += main.snapshot != nil && !main.snapshotFromDisk ? 1 : 0
            // 套餐平台不写额度数字（只写平台名）
            let tank = d.balance.isQuota ? "" : " 余额 \(fmtMoney(d.balance.cny, d.balance.currency))"
            if wasErr && error == nil {
                logLine("已恢复刷新：\(mainName)\(tank)")
            } else if okCount == 1 {
                logLine("开始刷新：\(mainName)\(tank) · 每 \(Int(store.currentInterval(main.id).rounded())) 秒（数据来自 App 内置采集）")
            }
        } else {
            data = nil
            menuBarSide = nil       // 主平台没数据时不留着别的平台的旧数字（自查 Bug D）
        }
        refreshPanelDetail()
        refreshWidgetDetail()
        // 各平台的预警线和用量异常：不管主平台有没有数据都按平台检查（第七批自查）
        checkPlatformAlerts(store)
    }
}

extension UsageModel {
    @MainActor
    private var enabledTaskProviders: Set<ProviderID> {
        guard let store = usageStore else { return [] }
        return Set(store.platforms.filter { MenuBarSecondary.canRun($0.id) && $0.status.isShown }.map(\.id))
    }

    /// 扫一次正在跑的任务（只扫已添加且未隐藏的可运行套餐平台）；结果变了才发布，面板开着时重新定高
    @MainActor
    func reloadRunningTasks(knownOnly: Bool = false) {
        guard fixedNow == nil, !refreshPause.paused, let store = usageStore else { return }
        let enabled = enabledTaskProviders
        monitoredAgentDirs = AgentDirs.current
        logWatcher?.rebuild(dirs: AgentDirs.current, enabled: enabled)
        if runningScanBusy {
            if !knownOnly { runningFullScanPending = true }
            return
        }
        runningGen += 1
        let gen = runningGen
        guard !enabled.isEmpty else {
            store.setRunningTasks([:])
            if !recentRunningAgents.isEmpty { recentRunningAgents = [] }
            if !runningTasks.isEmpty { runningTasks = []; if panelShown { onRefit?() } }
            retuneRunningTimer()
            return
        }
        let dirs = AgentDirs.current
        let cache = runningCache
        let known = Dictionary(grouping: runningTasks.filter { enabled.contains($0.provider) }, by: \.provider)
            .mapValues { $0.map { URL(fileURLWithPath: $0.sessionKey) } }
        runningScanBusy = true
        Task { @MainActor [weak self] in
            let r = await Task.detached(priority: .utility) { () -> [RunningTask] in
                let s = knownOnly ? RunningTasks.scanKnown(known, now: Date(), cache: cache) : RunningTasks.scanDetailed(
                    enabled: enabled, claudeDir: dirs.claudeConfig, codexSessions: dirs.codexSessions, now: Date(),
                    antigravityBrain: dirs.antigravityBrain, cache: cache)
                return s.tasks
            }.value
            guard let self else { return }
            self.runningScanBusy = false
            defer {
                if self.runningFullScanPending && !self.refreshPause.paused {
                    self.runningFullScanPending = false
                    self.reloadRunningTasks()
                }
            }
            guard gen == self.runningGen, !self.refreshPause.paused else { return }   // 晚结束的旧扫描丢掉
            // 菜单栏「自动 / 跟随主面板」要知道各平台最近一次任务活动（每次都交，10 分钟的窗口随时间过去）
            var last: [ProviderID: Date] = [:]
            for t in r { last[t.provider] = max(last[t.provider] ?? t.lastActivity, t.lastActivity) }
            var remembered = self.menuBarLastActivity
            for (id, date) in last { remembered[id] = max(remembered[id] ?? date, date) }
            if remembered != self.menuBarLastActivity { self.menuBarLastActivity = remembered }
            self.usageStore?.setRunningTasks(last)
            self.syncMenuBarPaygActivity()
            let recent = RunningActivity.recentAgents(r, now: Date())
            if recent != self.recentRunningAgents { self.recentRunningAgents = recent }
            if r != self.runningTasks {
                self.runningTasks = r
                if self.panelShown { self.onRefit?() }
            }
            self.retuneRunningTimer()
        }
    }

    @MainActor
    func retuneRunningTimer() {
        guard fixedNow == nil, usageStore != nil, !refreshPause.paused else { return }
        let want = RunningScanCadence.interval(visible: panelShown || widgetVisible,
                                               lastTask: runningTasks.map(\.lastActivity).max(), now: Date())
        guard want != runningScanEvery || (want != nil && runningTimer == nil) else { return }
        runningTimer = nil
        runningScanEvery = want
        guard let want else { return }
        runningTimer = Timer.publish(every: want, tolerance: want * 0.15, on: .main, in: .common).autoconnect()
            .sink { @MainActor [weak self] _ in self?.reloadRunningTasks(knownOnly: want == RunningScanCadence.fast) }
    }

    @MainActor
    func startLogMonitoring() {
        guard fixedNow == nil, !refreshPause.paused else { return }
        if logWatcher == nil {
            logWatcher = AgentLogWatcher { [weak self] changed in
                Task { @MainActor in self?.logsChanged(changed) }
            }
        }
        monitoredAgentDirs = AgentDirs.current
        logWatcher?.rebuild(dirs: AgentDirs.current, enabled: enabledTaskProviders, force: true)
        runningFallbackTimer = Timer.publish(every: RunningScanCadence.fallback, tolerance: 15, on: .main, in: .common).autoconnect()
            .sink { @MainActor [weak self] _ in self?.reloadRunningTasks() }
    }

    /// 日志文件变了：只是已知在跑的会话就只追读它们，扫不到的文件（子代理日志等）不扫，出现新会话才完整扫描。
    /// 原来每次都完整扫描，Agent 持续写日志时每秒列一遍所有会话文件（11-05 实测约 3% CPU）
    @MainActor
    func logsChanged(_ changed: Set<String>) {
        let enabled = enabledTaskProviders
        guard !enabled.isEmpty else { return }
        let dirs = AgentDirs.current
        switch RunningScanTrigger.decide(changed: changed, known: Set(runningTasks.map(\.sessionKey)),
                                         claudeProjects: dirs.claudeConfig.appendingPathComponent("projects"),
                                         codexSessions: dirs.codexSessions,
                                         antigravityBrain: enabled.contains(.geminiPlan) ? dirs.antigravityBrain : nil) {
        case .ignore: break
        case .known: reloadRunningTasks(knownOnly: true)
        case .full: reloadRunningTasks()
        }
    }

    @MainActor
    func setRefreshPaused(_ paused: Bool) {
        guard refreshPause.setPaused(paused) else { return }
        logLine(paused ? "刷新已暂停（锁屏或显示器休眠）" : "刷新已恢复，立即刷新")
        usageStore?.setPaused(paused)
        if paused {
            runningGen += 1
            runningTimer = nil
            runningFallbackTimer = nil
            runningScanEvery = nil
            logWatcher?.stop()
        } else {
            systemIsDark = StatusTheme.systemIsDark()
            startLogMonitoring()
            reloadRunningTasks()
            retuneRunningTimer()
        }
    }

    @MainActor
    func visibilityChanged(shown: Bool) {
        guard let store = usageStore else { return }
        let visible = panelShown || widgetVisible
        Task { @MainActor in await store.setSurfaceVisible(visible) }
        if shown { reloadRunningTasks() } else { retuneRunningTimer() }
    }

    /// 添加了 Claude 套餐 / Codex 套餐才读本机日志；放到后台线程，读完回主线程重新生成界面数据
    @MainActor
    func reloadLocalUsageIfDue(_ platforms: [PlatformState]) {
        let enabled = Set(platforms.filter { ($0.id == .claudePlan || $0.id == .codexPlan) && $0.status.isShown }.map(\.id))
        if localUsage.keys.contains(where: { !enabled.contains($0) }) { localUsage = localUsage.filter { enabled.contains($0.key) } }
        localBreakdowns = localBreakdowns.filter { enabled.contains($0.key) }
        // 套餐平台都移除了：不会再读，顺手放掉缓存
        if enabled.isEmpty { localCache.clear(.claude); localCache.clear(.codex) }
        let now = Date()
        guard let gen = localThrottle.begin(enabled: enabled, now: now) else { return }
        let dirs = AgentDirs.current
        let tz = TimeZone.autoupdatingCurrent
        let cache = localCache
        Task { @MainActor [weak self] in
            let r = await Task.detached(priority: .utility) {
                LocalAgentUsage.readDetailed(enabled: enabled, claudeDir: dirs.claudeConfig,
                                     codexSessions: dirs.codexSessions, now: now, timeZone: tz, cache: cache)
            }.value
            guard let self, self.localThrottle.finish(gen) else { return }   // 晚结束的旧读取丢掉
            let changed = r.tokens != self.localUsage || r.breakdowns != self.localBreakdowns
            self.localUsage = r.tokens
            self.localBreakdowns = r.breakdowns
            self.usageStore?.setActiveMinutes(r.activeMinutes)
            if changed { self.applyStore() }
        }
    }

    /// 打开面板时按近 1 小时活跃度重排「其他平台」：名次变了先显示旧顺序，再用动画挪到新位置；减弱动态效果时直接换
    @MainActor
    func reorderSidesOnOpen() {
        guard let store = usageStore, let d = data else { return }
        let ids = sideOrder.filter { id in d.sides.contains { $0.id == id.rawValue } }
        let ranked = SideOrder.ranked(ids, activity: store.activities())
        guard ranked != ids else { return }
        let apply = { [weak self] in
            guard let self else { return }
            self.sideOrder = SideOrder.reconcile(ranked, with: self.sideOrder)
            if var cur = self.data {
                cur.sides = SideOrder.apply(self.sideOrder, to: cur.sides)
                AppDataMapping.orderSidesByRisk(&cur, risks: store.risks())
                self.data = cur
            }
        }
        sideOrderTask?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { apply(); return }
        sideOrderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)        // 先让用户看到旧位置
            guard !Task.isCancelled, self.panelShown else { return }
            withAnimation(.spring(response: SwitchMotion.springResponse, dampingFraction: SwitchMotion.springDamping)) { apply() }
        }
    }

    /// 打开前准备内容以量高度；此处不启动提醒计时，也不把面板标成可见。
    @MainActor
    func panelAppeared() {
        detailPlatform = nil
        panelDetailModel = nil
        refreshClaudeHookState()
        reorderSidesOnOpen()
        guard let store = usageStore else { return }
        mainPinned = store.isMainPinned
        guard let n = store.pendingSwitchNotice else { return }
        store.consumeAutoSwitch()
        switchNotice = n
    }

    @MainActor
    func panelDisappeared() {
        panelShown = false
        // 未看满三秒的切换提示保留，下次真正打开时重新计时。
        trendPick = nil       // 下次打开面板时「近 7 天 token」回到今天
    }
}

extension UsageModel {
    /// 调试：把主平台快照写到 debug-dump.json 给 parity.sh 对账（快照里没有凭据）
    /// id 为 nil 时取主平台（dumpstore:siliconflow 取指定平台）
    @MainActor
    func dumpStore(_ id: ProviderID? = nil) {
        let st = id.flatMap { i in usageStore?.platforms.first { $0.id == i } } ?? (id == nil ? mainState : nil)
        guard let snap = st?.snapshot else { logLine("dumpstore：还没有快照"); return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        do {
            try enc.encode(snap).write(to: dir.appendingPathComponent("debug-dump.json"))
            logLine("dumpstore：已写 debug-dump.json（取数时间 \(snap.fetchedAt)）")
        } catch { logLine("dumpstore 失败：\(error)") }
    }

    /// 调试：用 App 里的硅基流动登录态取一次，把各接口的 JSON 正文写到 sf-record/（不含请求头、HTML）。
    /// 正文可能含账户信息，进仓库前要脱敏
    @MainActor
    func recordSiliconFlow() {
        guard let store = usageStore else { return }
        Task {
            guard case .found(let c) = await store.readCredentials(.siliconflow) else {
                logLine("recordsf：还没添加硅基流动"); return
            }
            let rec = RecordingHTTPClient(inner: URLSessionHTTPClient())
            let r = await SiliconFlowProvider(http: rec).fetch(c, now: Date(), timeZone: .current)
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TokenBar/sf-record")
            try? FileManager.default.removeItem(at: dir)
            do {
                let files = try rec.write(to: dir)
                let ok: String
                if case .failure(let e) = r { ok = "取数失败 \(e)" } else { ok = "取数成功" }
                logLine("recordsf：\(ok)，写了 \(files.count) 个文件")
            } catch { logLine("recordsf 失败：\(error)") }
        }
    }
}

extension UsageModel {
    /// 读-改-写 ProviderSettings（汇率、预警线都在里面），随后通知界面刷新
    func updateProviderSettings(_ change: (inout ProviderSettings) -> Void) {
        var s = ProviderSettings.load(.standard)
        change(&s)
        s.save(.standard)
        objectWillChange.send()
    }
}
