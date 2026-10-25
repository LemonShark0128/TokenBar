import Foundation

@MainActor
func registerQuotaPresentationTests() {
    // 2026-10-15 周四 05:47 UTC
    let now = Date(timeIntervalSince1970: 1_792_043_220)
    let utc = TimeZone(secondsFromGMT: 0)!
    let h: TimeInterval = 3600, m: TimeInterval = 60

    func quota(session: Double, sessionIn: TimeInterval, weekly: Double, weeklyIn: TimeInterval) -> Quota {
        Quota(plan: "plus", windows: [
            QuotaWindow(kind: .session, usedPercent: session, resetsAt: now.addingTimeInterval(sessionIn), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: weekly, resetsAt: now.addingTimeInterval(weeklyIn), windowMinutes: 10080)],
              observedAt: now.addingTimeInterval(-12 * m))
    }
    func planState(_ q: Quota?, note: String? = nil, detail: String? = nil, status: PlatformStatus = .ok,
                   fetchedAgo: TimeInterval = 0) -> PlatformState {
        var s = ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil, byModel: [],
                                 trend7: [], source: .quota, fetchedAt: now.addingTimeInterval(-fetchedAgo), credential: .ok)
        s.quota = q; s.quotaNote = note
        var st = PlatformState(id: .codexPlan, snapshot: s, burn: nil, status: status, lastSampleAt: nil, lastSample: nil)
        st.errorDetail = detail
        return st
    }
    let std = quota(session: 35, sessionIn: 2 * h + 13 * m, weekly: 41, weeklyIn: 7 * 86400 + 2 * h + 13 * m)

    test("quotaUsedPercentAndSideLine") {
        for (remaining, expected): (Double?, String) in [(52, "48%"), (0.4, "100%"), (100, "0%"), (nil, "—%"), (.nan, "—%"), (-1, "100%"), (101, "0%")] {
            try checkEqual(quotaUsedPercent(remaining: remaining), expected)
        }
        var side = AppData.Side(id: "claudePlan", name: "Claude 套餐", tank: nil, currency: "PCT", todayCost: nil, status: "正常", quotaRemaining: 52, quotaReset: "1:43 后重置")
        try checkEqual(side.quotaLine, "Claude 套餐 已用 48% · 1:43 后重置")
        side.quotaRemaining = nil
        try checkEqual(side.quotaLine, "Claude 套餐 已用 —% · 1:43 后重置")
        side.quotaExhausted = QuotaExhausted(clock: "08:00")
        try checkEqual(side.quotaLine, "Claude 套餐 下次重置：08:00")
    }
    test("resetTextUnderAndOver24h") {
        try checkEqual(QuotaText.resetText(now.addingTimeInterval(2 * h + 13 * m), now: now, timeZone: utc), "2 小时 13 分后重置")
        try checkEqual(QuotaText.resetText(now.addingTimeInterval(13 * m), now: now, timeZone: utc), "13 分后重置")
        try checkEqual(QuotaText.resetText(now.addingTimeInterval(7 * 86400 + 2 * h + 13 * m), now: now, timeZone: utc), "周四 08:00 重置")
        try checkEqual(QuotaText.resetCompact(now.addingTimeInterval(2 * h + 13 * m), now: now, timeZone: utc), "2:13 后重置")
        try checkEqual(QuotaText.resetCompact(now.addingTimeInterval(7 * 86400 + 2 * h + 13 * m), now: now, timeZone: utc), "周四 08:00 重置")
        try checkEqual(QuotaText.windowName(.session), "5 小时窗口")
        try checkEqual(QuotaText.windowName(.weeklyModel("GPT-5")), "本周（GPT-5）")
    }
    test("lastUsedText") {
        try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-30), now: now), "刚刚")
        try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-12 * m), now: now), "最近一次使用：12 分钟前")
        try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-3 * h), now: now), "最近一次使用：3 小时前")
        try checkEqual(QuotaText.lastUsed(now.addingTimeInterval(-2 * 86400), now: now), "最近一次使用：2 天前")
    }
    test("mapQuotaMain") {
        let d = AppDataMapping.appData(main: planState(std), others: [], now: now, timeZone: utc)
        try checkEqual(d.balance.cny, 65)
        try check(d.balance.isQuota, "isQuota")
        try checkEqual(d.balance.currency, "PCT")
        let q = d.quota
        try checkEqual(q?.headline, "5 小时窗口 · 2 小时 13 分后重置")
        try checkEqual(q?.secondLine, "本周已用 41% · 周四 08:00 重置")
        try checkEqual(q?.rows.count, 2)
        try checkEqual(q?.lastUsed, "最近一次使用：12 分钟前")
        try check(d.burn == nil, "burn nil")
        try check(d.trend7.isEmpty, "trend empty")
    }
    test("planNameText") {
        try checkEqual(QuotaText.planName(nil), nil)
        try checkEqual(QuotaText.planName(""), nil)
        try checkEqual(QuotaText.planName("plus"), "Plus 套餐")
        try checkEqual(QuotaText.planName("pro"), "Pro 套餐")
    }
    test("mapQuotaPlanAndCompactReset") {
        let d = AppDataMapping.appData(main: planState(std), others: [], now: now, timeZone: utc)
        try checkEqual(d.quota?.plan, "Plus 套餐")
        try checkEqual(d.quota?.rows.first?.resetShort, "2:13 后重置")
        try checkEqual(d.quota?.rows.last?.resetShort, "周四 08:00 重置")
        var noPlan = std; noPlan.plan = nil
        let c = AppDataMapping.appData(main: planState(noPlan), others: [], now: now, timeZone: utc)
        try checkEqual(c.quota?.plan, nil)
        let r = AppDataMapping.appData(main: planState(quota(session: 90, sessionIn: -h, weekly: 41, weeklyIn: 3 * 86400)),
                                       others: [], now: now, timeZone: utc)
        try checkEqual(r.quota?.rows.first?.resetShort, nil)
    }
    test("mapQuotaResetWindowText") {
        let qq = quota(session: 90, sessionIn: -h, weekly: 41, weeklyIn: 3 * 86400)
        let d = AppDataMapping.appData(main: planState(qq), others: [], now: now, timeZone: utc)
        try check(d.quota?.secondLine?.hasPrefix("本周已用 41%") == true)
        try checkEqual(d.quota?.remainingPercent, 100)
        try checkEqual(d.quota?.rows.first?.isReset, true)
    }
    test("mapQuotaNilShowsNote") {
        let d = AppDataMapping.appData(main: planState(nil, note: "还没有额度数据"), others: [], now: now, timeZone: utc)
        try checkEqual(d.quota?.note, "还没有额度数据")
        try check(d.balance.cny == nil, "不能显示 0%")
        let e = AppDataMapping.appData(main: planState(nil, detail: "Codex 日志格式变了，等待 Token Bar 更新"), others: [], now: now, timeZone: utc)
        try checkEqual(e.quota?.note, "Codex 日志格式变了，等待 Token Bar 更新")
    }
    test("totalTodayExcludesQuota") {
        var s = ProviderSnapshot(provider: .deepseek, balance: Money(amount: 20, currency: .cny),
                                 today: Money(amount: 3, currency: .cny), month: nil, byModel: [], trend7: [],
                                 source: .bill, fetchedAt: now, credential: .ok)
        s.fetchedAt = now
        let ds = PlatformState(id: .deepseek, snapshot: s, burn: nil, status: .ok, lastSampleAt: nil, lastSample: nil)
        let d = AppDataMapping.appData(main: ds, others: [planState(std)], now: now, timeZone: utc)
        try checkEqual(d.totalTodayCny, 3)
        try checkEqual(d.totalIsApprox, false)
        try checkEqual(d.quota == nil, true)
    }
    test("quotaSideRow") {
        let qq = quota(session: 41, sessionIn: 2 * h + 13 * m, weekly: 20, weeklyIn: 7 * 86400 + 2 * h)
        let side = AppDataMapping.side(planState(qq, fetchedAgo: 900), now: now, timeZone: utc)
        try checkEqual(side.quotaRemaining, 59)
        try checkEqual(side.quotaReset, "2:13 后重置")
        try check(side.tank == nil, "tank nil")
        try check(side.todayCost == nil, "todayCost nil")
        try checkEqual(side.status, "正常")
    }
    test("exhaustedAlert") {
        let qq = Quota(plan: nil, windows: [QuotaWindow(kind: .weekly, usedPercent: 100,
                       resetsAt: now.addingTimeInterval(7 * 86400 + 2 * h + 13 * m), windowMinutes: nil)], observedAt: now)
        try checkEqual(QuotaText.exhausted(name: "Codex 套餐", window: qq.windows[0], now: now, timeZone: utc),
                       "Codex 套餐 本周额度已用完，周四 08:00 恢复")
        try checkEqual(QuotaText.exhausted(name: "Codex 套餐", window: .session, resetsAt: now.addingTimeInterval(2 * h + 13 * m),
                                           now: now, timeZone: utc), "Codex 套餐 5 小时额度已用完，2 小时 13 分后恢复")
    }
    test("quotaLowAlert") {
        let n = StatusPresenter.quotaLowNotification(name: "Codex 套餐", remaining: 8, threshold: 10)
        try checkEqual(n.title, "Codex 套餐 额度快用完了")
        try checkEqual(n.body, "剩余 8%，已低于预警线 10%")
    }
    test("quotaLowAlertFloorsNearThreshold") {
        let n = StatusPresenter.quotaLowNotification(name: "Codex 套餐", remaining: 9.6, threshold: 10)
        try checkEqual(n.body, "剩余 9%，已低于预警线 10%")
        try checkEqual(A11yText.quotaGauge(provider: "Codex", remainingPercent: 9.6, reset: nil), "Codex 已用 91%")
    }
    test("remainingPercentFloorsEverywhere") {
        // 剩余不夸大：和提醒、通知同一口径（向下取整），夹在 0…100
        try checkEqual(quotaRemainingPercent(9.6), "9%")
        try checkEqual(quotaRemainingPercent(59.99), "59%")
        try checkEqual(quotaRemainingPercent(100), "100%")
        try checkEqual(quotaRemainingPercent(0.4), "0%")
        try checkEqual(quotaRemainingPercent(-0.3), "0%")
        try checkEqual(quotaRemainingPercent(100.4), "100%")
        try checkEqual(quotaRemainingPercent(nil), "—%")
        try checkEqual(quotaRemainingPercent(.nan), "—%")
        try checkEqual(AccountReading.session(9.6).text, "5 小时窗口已用 91%")
        try checkEqual(AccountReading.remaining(9.6).text, "已用 91%")
        try checkEqual(A11yText.quotaGauge(provider: "Codex 套餐", remainingPercent: 0.4, reset: nil), "Codex 套餐 已用 100%")
        // 通用百分比格式化仍保留四舍五入（设置预警线等使用）
        try checkEqual(quotaPercent(40.4), "40%")
    }
    test("quotaFreshnessNeverStale") {
        let st = planState(std, fetchedAgo: 2 * h)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: utc)
        let i = StatusPresenter.Input(state: st, data: d, error: nil, now: now, providerName: "Codex 套餐")
        try checkEqual(StatusPresenter.freshness(i).0, .ok)
        try checkEqual(StatusPresenter.freshness(i).1, "最近一次使用：12 分钟前")
    }
    test("quotaErrorUsesDetail") {
        let st = planState(nil, detail: "Claude 额度数据格式变了", status: .schemaChanged)
        try checkEqual(StatusPresenter.error(for: st, name: "Claude 套餐"), "Claude 额度数据格式变了")
    }
    test("quotaGaugeA11y") {
        try checkEqual(A11yText.quotaGauge(provider: "Codex 套餐", remainingPercent: 59, reset: "5 小时窗口 2 小时 13 分后重置"),
                       "Codex 套餐 已用 41%，5 小时窗口 2 小时 13 分后重置")
        try checkEqual(A11yText.quotaGauge(provider: "Codex 套餐", remainingPercent: nil, reset: nil), "Codex 套餐 已用未知")
    }
    testAsync("moneyMappingUnchanged") {
        let http = FixtureHTTPClient()
        let s = try await DeepSeekProvider(http: http)
            .fetch(Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"]), now: now, timeZone: utc).get()
        let st = PlatformState(id: .deepseek, snapshot: s, burn: nil, status: .ok, lastSampleAt: nil, lastSample: nil)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: utc)
        try check(d.quota == nil, "quota nil")
        try checkEqual(d.balance.isQuota, false)
    }

    // 用户反馈：小组件看不出当前是哪个平台；只在添加了不止一个平台时写平台名，单平台老用户界面不变
    test("widgetTitleOnlyWhenMultiplePlatforms") {
        try checkEqual(AppDataMapping.widgetTitle(mainName: "Codex 套餐", otherCount: 1), "Codex 套餐")
        try checkEqual(AppDataMapping.widgetTitle(mainName: "DeepSeek", otherCount: 3), "DeepSeek")
        try checkEqual(AppDataMapping.widgetTitle(mainName: "DeepSeek", otherCount: 0), nil)
    }

    // 用户反馈：小组件左上角点平台名弹出平台列表，选中就设为主平台（与面板里点辅助行相同）
    test("widgetPlatformMenuMainFirstThenSides") {
        func side(_ id: String, _ name: String) -> AppData.Side {
            AppData.Side(id: id, name: name, tank: nil, currency: "CNY", todayCost: nil, status: "正常")
        }
        let items = AppDataMapping.widgetPlatformMenu(mainID: "deepseek", mainName: "DeepSeek",
                                                      sides: [side("codexPlan", "Codex 套餐"), side("siliconflow", "硅基流动")])
        try checkEqual(items.map(\.id), ["deepseek", "codexPlan", "siliconflow"])
        try checkEqual(items.map(\.title), ["DeepSeek", "Codex 套餐", "硅基流动"])
        try checkEqual(items.map(\.isMain), [true, false, false])
        try checkEqual(AppDataMapping.widgetPlatformMenu(mainID: "deepseek", mainName: "DeepSeek", sides: []).count, 0)
    }
}
