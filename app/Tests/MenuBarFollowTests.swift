import Foundation

// 菜单栏平台：跟随主面板（默认）/ 自动（按 10 分钟内在跑的任务）/ 固定；轮流显示；套餐平台菜单栏写当前会话已用百分比

private let f0 = Date(timeIntervalSince1970: 1_792_022_400)
private func fat(_ s: TimeInterval) -> Date { f0.addingTimeInterval(s) }
private let allAdded = Set(ProviderRegistry.all)

private func quota(_ windows: [QuotaWindow]) -> Quota { Quota(plan: nil, windows: windows, observedAt: f0) }

@MainActor
private func followStore(_ d: UserDefaults, providers: [FakeProvider], lowThreshold: [ProviderID: Decimal] = [:], clock: FakeClock = FakeClock()) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    let cs = InMemoryCredentialStore()
    for p in providers { try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: p.id) }
    return UsageStore(providers: providers, credentials: cs, samples: samples, intervalSeconds: 120,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 0)! }, defaults: d,
                      settings: { var s = ProviderSettings(); s.lowAlerts = lowThreshold; return s })
}

private func twoPlatforms() -> [FakeProvider] {
    [FakeProvider([.success(snap(FakeClock().now))]),
     FakeProvider([.success({ var s = snap(FakeClock().now); s.provider = .siliconflow; return s }())], id: .siliconflow)]
}

@MainActor
func registerMenuBarFollowTests() {
    testAsync("storeMenuBarAlwaysFollowsMain") {
        let clock = FakeClock()
        let store = try followStore(freshDefaults(), providers: twoPlatforms(), lowThreshold: [.siliconflow: 100000], clock: clock)
        await store.refresh()
        store.setRunningTasks([.siliconflow: clock.now])
        try checkEqual(store.mainProvider, .siliconflow)
        try checkEqual(store.menuBarProvider, store.mainProvider)
        store.setRunningTasks([.deepseek: clock.now, .siliconflow: clock.now])
        clock.now = clock.now.addingTimeInterval(10)
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .deepseek)
        try checkEqual(store.menuBarProvider, store.mainProvider)
        store.pinMain(.siliconflow)
        store.setAutoMain(false)
        try checkEqual(store.menuBarProvider, .siliconflow)
        try checkEqual(store.menuBarRisk?.id, .siliconflow)
        store.pinMain(.deepseek)
        try checkEqual(store.menuBarProvider, .deepseek)
        try checkEqual(store.menuBarRotation, [.deepseek])
        try check(store.menuBarRisk == nil)
    }
    testAsync("storeOldMenuBarKeysRemovedAtStartup") {
        for value in ["auto", "followMain", "siliconflow", "openai"] {
            let d = freshDefaults()
            d.set(value, forKey: "menuBarProvider")
            d.set(true, forKey: "menuBarProvider.autoMigrated")
            d.set(true, forKey: "menuBarProvider.followMainMigrated")
            let store = try followStore(d, providers: twoPlatforms())
            for key in ["menuBarProvider", "menuBarProvider.autoMigrated", "menuBarProvider.followMainMigrated"] {
                try check(d.object(forKey: key) == nil, "旧菜单栏键应被删除")
            }
            try checkEqual(store.menuBarProvider, store.mainProvider)
        }
    }

    // 主平台「当前使用」轮流用到的列表工具
    test("rotationRunningWindow") {
        let now = f0
        let last: [ProviderID: Date] = [.claudePlan: now.addingTimeInterval(-600), .codexPlan: now.addingTimeInterval(-601)]
        try checkEqual(MenuBarRotation.running(last, now: now), [.claudePlan])
        try checkEqual(MenuBarRotation.next([.deepseek, .codexPlan], after: .deepseek), .codexPlan)
        try checkEqual(MenuBarRotation.next([.deepseek, .codexPlan], after: .codexPlan), .deepseek)
        try checkEqual(MenuBarRotation.next([.deepseek, .codexPlan], after: .claudePlan), .deepseek)
        try checkEqual(MenuBarRotation.keep([.deepseek, .codexPlan], current: .codexPlan), .codexPlan)
        try checkEqual(MenuBarRotation.keep([.deepseek, .codexPlan], current: .claudePlan), .deepseek)
    }

    test("menuBarRiskTitleAndTooltip") {
        let utc = TimeZone(secondsFromGMT: 0)!
        let payg = PaygRunway(hours: 5.6, basis: .recentSpike, severity: .warn, perHourRecent: 4.8, multiple: 21)
        let r1 = PlatformRisk(id: .deepseek, kind: .payg(payg), hours: 5.6, atRisk: true, severity: .warn)
        try checkEqual(MenuBarText.riskTitle(r1, mode: "balance"), "5h36m")
        try checkEqual(MenuBarText.riskTitle(r1, mode: "cost"), "5h36m")
        try check(MenuBarText.riskTitle(r1, mode: "icon") == nil)
        try checkEqual(MenuBarText.riskTooltip(r1, name: "DeepSeek", now: f0, timeZone: utc), "DeepSeek 预计可用时间：5 小时 36 分")
        var short = payg; short.hours = 0.5
        let r1b = PlatformRisk(id: .deepseek, kind: .payg(short), hours: 0.5, atRisk: true, severity: .danger)
        try checkEqual(MenuBarText.riskTooltip(r1b, name: "DeepSeek", now: f0, timeZone: utc), "DeepSeek 预计可用时间：不到 1 小时")

        let w = QuotaWindow(kind: .session, usedPercent: 88, resetsAt: f0.addingTimeInterval(7200), windowMinutes: 300)
        let q = QuotaRunway(window: w, remainingPercent: 12, risePP: 18, hoursToEmpty: 2.0 / 3, resetsAt: w.resetsAt,
                            state: .runsOut, severity: .danger)
        let r2 = PlatformRisk(id: .claudePlan, kind: .quota(q), hours: 2.0 / 3, atRisk: true, severity: .danger)
        // 套餐风险写这个窗口的已用百分比（与「剩 N%」互补：剩 12% → 已用 88%），时长放进悬停提示
        try checkEqual(MenuBarText.riskTitle(r2, mode: "balance"), "已用 88%")
        try checkEqual(MenuBarText.riskTitle(r2, mode: "cost"), "已用 88%")
        var frac = q; frac.remainingPercent = 10.6
        let r2c = PlatformRisk(id: .codexPlan, kind: .quota(frac), hours: 0.1, atRisk: true, severity: .danger)
        try checkEqual(MenuBarText.riskTitle(r2c, mode: "balance"), "已用 90%")
        try checkEqual(MenuBarText.riskTooltip(r2, name: "Claude 套餐", now: f0, timeZone: utc),
                       "Claude 套餐 预计可用时间：40 分钟，下次重置：" + Runway.resetClock(q, now: f0, timeZone: utc)!)
        var noReset = q; noReset.resetsAt = nil
        let r2b = PlatformRisk(id: .claudePlan, kind: .quota(noReset), hours: 2.0 / 3, atRisk: true, severity: .danger)
        try checkEqual(MenuBarText.riskTooltip(r2b, name: "Claude 套餐", now: f0, timeZone: utc), "Claude 套餐 预计可用时间：40 分钟")

        var ex = q; ex.state = .exhausted; ex.hoursToEmpty = 0
        let r3 = PlatformRisk(id: .claudePlan, kind: .quota(ex), hours: 0, atRisk: true, severity: .danger)
        try check(MenuBarText.riskTitle(r3, mode: "balance") == nil)
        try checkEqual(MenuBarText.riskTooltip(r3, name: "Claude 套餐", now: f0, timeZone: utc), "Claude 套餐 额度已用完")

        let r4 = PlatformRisk(id: .siliconflow, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)
        try check(MenuBarText.riskTitle(r4, mode: "balance") == nil)
        try checkEqual(MenuBarText.riskTooltip(r4, name: "硅基流动", now: f0, timeZone: utc), "硅基流动 低于预警线")

        let r5 = PlatformRisk(id: .codexPlan, kind: .none, hours: nil, atRisk: false, severity: .ok)
        try check(MenuBarText.riskTitle(r5, mode: "balance") == nil)
        try check(MenuBarText.riskTooltip(r5, name: "Codex 套餐", now: f0, timeZone: utc) == nil)
        // 只图标模式的「!」角标：用量异常或有风险（低于预警线除外，表盘本身变空）
        try check(MenuBarText.alertBadge(mode: "icon", spike: true, risk: nil))
        try check(MenuBarText.alertBadge(mode: "icon", spike: false, risk: r2))
        try check(!MenuBarText.alertBadge(mode: "icon", spike: false, risk: r4))
        try check(!MenuBarText.alertBadge(mode: "balance", spike: true, risk: r2))
        try check(!MenuBarText.alertBadge(mode: "icon", spike: false, risk: nil))
    }
    // ---------------------------------------------------------------- 菜单栏文字

    test("menuBarTitleMoneyModes") {
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: false, balance: 27.07, today: 1.5, quotaUsed: nil, currency: nil), "¥27.07")
        try checkEqual(MenuBarText.title(mode: "cost", isQuota: false, balance: 27.07, today: 1.5, quotaUsed: nil, currency: nil),
                       "¥1.50\u{2007}")
        try checkEqual(MenuBarText.title(mode: "icon", isQuota: false, balance: 27.07, today: 1.5, quotaUsed: nil, currency: nil), "")
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: false, balance: nil, today: nil, quotaUsed: nil, currency: "USD"),
                       "$ —\u{2007}\u{2007}")
    }
    test("menuBarTitleQuotaShowsSessionUsed") {
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 23.4, currency: "PCT"), "已用 24%")   // 用户 10-19：菜单栏已用 = 100 - 向下取整的剩余
        try checkEqual(MenuBarText.title(mode: "cost", isQuota: true, balance: nil, today: nil, quotaUsed: 23.4, currency: "PCT"), "已用 24%")
        try checkEqual(MenuBarText.title(mode: "icon", isQuota: true, balance: nil, today: nil, quotaUsed: 23.4, currency: "PCT"), "")
        // 没有额度数据
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: nil, currency: "PCT"), "已用 —%")
        try checkEqual(MenuBarText.title(mode: "cost", isQuota: true, balance: nil, today: nil, quotaUsed: .nan, currency: "PCT"), "已用 —%")
    }
    test("menuQuotaReadingPrefersSession") {
        let tz = TimeZone(secondsFromGMT: 28800)!
        let q = quota([QuotaWindow(kind: .weekly, usedPercent: 80, resetsAt: fat(3 * 86400), windowMinutes: nil),
                       QuotaWindow(kind: .session, usedPercent: 23, resetsAt: fat(2 * 3600 + 13 * 60), windowMinutes: 300)])
        let r = MenuBarText.quotaReading(q, now: f0, timeZone: tz)
        try checkEqual(r?.usedPercent, 23)
        try checkEqual(r?.window, "当前会话")
        try checkEqual(r?.reset, "2 小时 13 分后重置")
        // 已过重置时间的会话窗口按 0
        let reset = quota([QuotaWindow(kind: .session, usedPercent: 90, resetsAt: fat(-60), windowMinutes: 300)])
        try checkEqual(MenuBarText.quotaReading(reset, now: f0, timeZone: tz)?.usedPercent, 0)
    }
    test("menuQuotaReadingFallsBackToWeekly") {
        let tz = TimeZone(secondsFromGMT: 28800)!
        let q = quota([QuotaWindow(kind: .weekly, usedPercent: 30, resetsAt: nil, windowMinutes: nil),
                       QuotaWindow(kind: .weeklyModel("Opus"), usedPercent: 64, resetsAt: nil, windowMinutes: nil)])
        let r = MenuBarText.quotaReading(q, now: f0, timeZone: tz)
        try checkEqual(r?.usedPercent, 30)
        try checkEqual(r?.window, "本周")
        try checkEqual(r?.tighter, "本周（Opus）已用 64%")
        try check(r?.reset == nil)
        try check(MenuBarText.quotaReading(nil, now: f0, timeZone: tz) == nil)
        try check(MenuBarText.quotaReading(quota([]), now: f0, timeZone: tz) == nil)
    }
    test("menuQuotaReadingInSide") {
        var st = PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .ok)
        var s = ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                 source: .quota, fetchedAt: f0, credential: .ok)
        s.quota = quota([QuotaWindow(kind: .session, usedPercent: 23, resetsAt: nil, windowMinutes: 300),
                         QuotaWindow(kind: .weekly, usedPercent: 70, resetsAt: nil, windowMinutes: nil)])
        st.snapshot = s
        let side = AppDataMapping.side(st, now: f0, timeZone: TimeZone(secondsFromGMT: 0)!)
        try checkEqual(side.menuQuota?.usedPercent, 23)
        try checkEqual(side.menuQuota?.window, "当前会话")
        try checkEqual(side.quotaRemaining, 77)        // 油箱使用 5 小时显示窗口
    }

    // 最紧的是别的窗口时，补充那个窗口的已用读数
    test("menuQuotaReadingNotesTighterWindow") {
        let tz = TimeZone(secondsFromGMT: 28800)!
        let q = quota([QuotaWindow(kind: .weekly, usedPercent: 92, resetsAt: nil, windowMinutes: nil),
                       QuotaWindow(kind: .session, usedPercent: 3, resetsAt: fat(3600), windowMinutes: 300)])
        let r = MenuBarText.quotaReading(q, now: f0, timeZone: tz)
        try checkEqual(r?.usedPercent, 3)
        try checkEqual(r?.tighter, "本周已用 92%")
        try checkEqual(MenuBarText.quotaTooltip(provider: "Claude 套餐", reading: r),
                       "Claude 套餐 当前会话已用 3% · 本周已用 92% · 1 小时后重置")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Claude 套餐", reading: r, low: true, dim: false),
                       "Claude 套餐 当前会话已用 3%，剩余 97%，本周已用 92%，1 小时后重置，低于预警线")
        // 会话本身最紧：不另写
        let q2 = quota([QuotaWindow(kind: .weekly, usedPercent: 20, resetsAt: nil, windowMinutes: nil),
                        QuotaWindow(kind: .session, usedPercent: 60, resetsAt: nil, windowMinutes: 300)])
        try check(MenuBarText.quotaReading(q2, now: f0, timeZone: tz)?.tighter == nil)
        // 剩余向下取整后取互补：已用 90.4% 写「已用 91%」
        let q3 = quota([QuotaWindow(kind: .weekly, usedPercent: 90.4, resetsAt: nil, windowMinutes: nil),
                        QuotaWindow(kind: .session, usedPercent: 3, resetsAt: nil, windowMinutes: 300)])
        try checkEqual(MenuBarText.quotaReading(q3, now: f0, timeZone: tz)?.tighter, "本周已用 91%")
    }

    // ---------------------------------------------------------------- 读屏

    test("menuBarQuotaA11y") {
        let r = AppData.MenuQuota(usedPercent: 23.4, window: "当前会话", reset: "2 小时 13 分后重置")
        try checkEqual(MenuBarText.quotaUsedText(provider: "Claude 套餐", reading: r), "Claude 套餐 当前会话已用 24%")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Claude 套餐", reading: r, low: false, dim: false),
                       "Claude 套餐 当前会话已用 24%，剩余 76%，2 小时 13 分后重置")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Codex 套餐", reading: AppData.MenuQuota(usedPercent: 95, window: "本周", reset: nil),
                                             low: true, dim: true),
                       "Codex 套餐 本周已用 95%，剩余 5%，低于预警线，数据不是最新")
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Claude 套餐", reading: nil, low: false, dim: false),
                       "Claude 套餐 额度未知")
        try checkEqual(MenuBarText.quotaTooltip(provider: "Claude 套餐", reading: r), "Claude 套餐 当前会话已用 24% · 2 小时 13 分后重置")
        try checkEqual(MenuBarText.quotaTooltip(provider: "Claude 套餐", reading: nil), "Claude 套餐 额度未知")
    }
}
