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
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] _ in self?.applyStore() }     // 前面已 receive(on: main)
        retuneRunningTimer()
        reloadRunningTasks()
        store.start(intervalSeconds: refreshSeconds)
    }

    /// 「显示哪个平台」选中后（设置下拉、右键子菜单、引导页共用）：auto = 当前使用，平台 rawValue = 固定它
    @MainActor
    func chooseMain(_ k: String) {
        guard let store = usageStore else { return }
        let pick = SettingsLayout.mainPick(k, current: store.mainProvider)
        if let id = pick.pin { store.pinMain(id) }
        store.setAutoMain(pick.auto)
        objectWillChange.send()
    }

    @MainActor
    func applyStore() {
        guard let store = usageStore else { return }
        let risks = store.risks()
        var pruned = bannerDismissal
        let added = Set(store.platforms.filter { $0.status != .notAdded }.map(\.id))
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
        syncAlertFromSettings()
        // Codex 套餐第一次读到额度：日志只写这一句（不写额度数字和日志内容）
        if !codexQuotaLogged, store.platforms.contains(where: { $0.id == .codexPlan && $0.status != .notAdded && $0.snapshot?.quota != nil }) {
            codexQuotaLogged = true
            logLine("已读到 Codex 额度")
        }
        checkQuotaExhausted(store.platforms, now: Date())
        needsSetup = main.status == .notAdded       // 由 UsageStore 判断，这里不读钥匙串
        if needsSetup {           // 还没添加平台：不算错误，面板显示添加入口
            data = nil
            menuBarSide = nil
            error = nil
            return
        }
        let others = store.platforms.filter { $0.id != main.id }
        reloadLocalUsageIfDue(store.platforms)
        // 其他平台：保持当前顺序，只处理增减（名次在下次打开面板时才更新）
        let sideIDs = others.filter { $0.status != .notAdded }.map(\.id)
        sideOrder = SideOrder.reconcile(sideOrder, with: SideOrder.ranked(sideIDs, activity: store.activities()))
        let hasData = main.snapshot != nil || main.lastSample != nil
        let wasErr = error != nil
        error = StatusPresenter.error(for: main, name: ProviderRegistry.displayName(main.id))
        if hasData {
            var d = AppDataMapping.appData(main: main, others: others, now: Date(), timeZone: .autoupdatingCurrent,
                                           usdToCny: ProviderSettings.load(.standard).usdToCny, localUsage: localUsage)
            d.sides = SideOrder.apply(sideOrder, to: d.sides)
            AppDataMapping.applyRisks(&d, main: main.id, risks: risks, now: Date(),
                                      timeZone: .autoupdatingCurrent, currency: d.balance.currency)
            data = d
            // 菜单栏平台就是主平台时不单独取一行：沿用主平台的完整数据（估算今日、续航天数等与原来一致）
            menuBarSide = store.menuBarProvider == main.id ? nil
                : store.platforms.first { $0.id == store.menuBarProvider && $0.status != .notAdded }
                    .map { AppDataMapping.side($0, now: Date(), timeZone: .autoupdatingCurrent) }
            okCount += main.snapshot != nil && !main.snapshotFromDisk ? 1 : 0
            // 套餐平台不写额度数字（只写平台名）
            let tank = d.balance.isQuota ? "" : " 余额 \(fmtMoney(d.balance.cny, d.balance.currency))"
            if wasErr && error == nil {
                logLine("已恢复刷新：\(mainName)\(tank)")
            } else if okCount == 1 {
                logLine("开始刷新：\(mainName)\(tank) · 每 \(refreshSeconds) 秒（数据来自 App 内置采集）")
            }
        } else {
            data = nil
            menuBarSide = nil       // 主平台没数据时不留着别的平台的旧数字（自查 Bug D）
        }
        // 各平台的预警线和用量异常：不管主平台有没有数据都按平台检查（第七批自查）
        checkPlatformAlerts(store)
    }
}

extension UsageModel {
    /// 添加了 Claude 套餐 / Codex 套餐才读本机日志；放到后台线程，读完回主线程重新生成界面数据
    /// 扫一次正在跑的任务（只扫已添加的 Claude / Codex 套餐）；结果变了才发布，面板开着时重新定高
    @MainActor
    func reloadRunningTasks() {
        guard fixedNow == nil, let store = usageStore else { return }
        let enabled = Set(store.platforms.filter { ($0.id == .claudePlan || $0.id == .codexPlan) && $0.status != .notAdded }.map(\.id))
        runningGen += 1
        let gen = runningGen
        guard !enabled.isEmpty else {
            store.setRunningTasks([:])
            Task { await store.setPlanActivity([:]) }
            if !runningTasks.isEmpty { runningTasks = []; if panelShown { onRefit?() } }
            retuneRunningTimer()
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cache = runningCache
        let probe = desktopProbe
        Task { @MainActor [weak self] in
            let (r, activity) = await Task.detached(priority: .utility) { () -> ([RunningTask], [ProviderID: Date]) in
                let s = RunningTasks.scanDetailed(enabled: enabled, claudeDir: home.appendingPathComponent(".claude"),
                                                  codexSessions: home.appendingPathComponent(".codex/sessions"), now: Date(), cache: cache)
                // 刷新频率用的「有没有在用」：会话日志最近修改 + 在跑的任务 + 桌面 App 记到的额度变化
                var activity = s.lastChange
                for t in s.tasks { activity[t.provider] = max(activity[t.provider] ?? t.lastActivity, t.lastActivity) }
                if enabled.contains(.claudePlan), let d = probe.changedAt(ClaudeAppUsageSource.standardURL) {
                    activity[.claudePlan] = max(activity[.claudePlan] ?? d, d)
                }
                return (s.tasks, activity)
            }.value
            guard let self, gen == self.runningGen else { return }   // 晚结束的旧扫描丢掉
            // 菜单栏「自动 / 跟随主面板」要知道各平台最近一次任务活动（每次都交，10 分钟的窗口随时间过去）
            var last: [ProviderID: Date] = [:]
            for t in r { last[t.provider] = max(last[t.provider] ?? t.lastActivity, t.lastActivity) }
            self.usageStore?.setRunningTasks(last)
            await self.usageStore?.setPlanActivity(activity)
            if r != self.runningTasks {
                self.runningTasks = r
                if self.panelShown { self.onRefit?() }
            }
            self.retuneRunningTimer()
        }
    }

    /// 在跑任务扫描的频率：面板或小组件开着、或最近 5 分钟有在跑的任务时每 10 秒，否则每 30 秒。变了才重建计时器
    @MainActor
    func retuneRunningTimer() {
        guard fixedNow == nil, usageStore != nil else { return }
        let want = RunningScanCadence.interval(visible: panelShown || widgetVisible,
                                               lastTask: runningTasks.map(\.lastActivity).max(), now: Date())
        guard want != runningScanEvery || runningTimer == nil else { return }
        runningScanEvery = want
        runningTimer = Timer.publish(every: want, tolerance: want * 0.15, on: .main, in: .common).autoconnect()
            .sink { @MainActor [weak self] _ in self?.reloadRunningTasks() }     // 计时器挂在主 RunLoop 上
    }

    /// 面板或小组件刚打开：马上扫一次，扫描切回每 10 秒
    @MainActor
    func visibilityChanged(shown: Bool) {
        guard usageStore != nil else { return }
        if shown { reloadRunningTasks() } else { retuneRunningTimer() }
    }

    @MainActor
    func reloadLocalUsageIfDue(_ platforms: [PlatformState]) {
        let enabled = Set(platforms.filter { ProviderRegistry.meter($0.id) == .quota && $0.status != .notAdded }.map(\.id))
        if localUsage.keys.contains(where: { !enabled.contains($0) }) { localUsage = localUsage.filter { enabled.contains($0.key) } }
        // 套餐平台都移除了：不会再读，顺手放掉缓存
        if enabled.isEmpty { localCache.clear(.claude); localCache.clear(.codex) }
        let now = Date()
        guard let gen = localThrottle.begin(enabled: enabled, now: now) else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let tz = TimeZone.autoupdatingCurrent
        let cache = localCache
        Task { @MainActor [weak self] in
            let r = await Task.detached(priority: .utility) {
                LocalAgentUsage.read(enabled: enabled, claudeDir: home.appendingPathComponent(".claude"),
                                     codexSessions: home.appendingPathComponent(".codex/sessions"), now: now, timeZone: tz, cache: cache)
            }.value
            guard let self, self.localThrottle.finish(gen) else { return }   // 晚结束的旧读取丢掉
            let changed = r != self.localUsage
            self.localUsage = r
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
    /// 读-改-写 ProviderSettings（汇率、预警线都在里面），随后把主平台预警线同步回镜像
    func updateProviderSettings(_ change: (inout ProviderSettings) -> Void) {
        var s = ProviderSettings.load(.standard)
        change(&s)
        s.save(.standard)
        syncAlertFromSettings()
        objectWillChange.send()
    }

    /// 主平台的预警线 → balanceAlertCny（不回写）
    func syncAlertFromSettings() {
        let v = ProviderSettings.load(.standard).lowAlerts[mainID].map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        guard v != balanceAlertCny else { return }
        syncingAlert = true
        balanceAlertCny = v
        syncingAlert = false
    }
}
