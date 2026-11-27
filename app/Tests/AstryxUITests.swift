import Foundation

@MainActor
func registerAstryxUITests() {
    test("警示图标按状态、登录和风险分级") {
        try checkEqual(AlertGlyph.level(), .none)
        try checkEqual(AlertGlyph.level(warn: true), .warning)
        try checkEqual(AlertGlyph.level(riskSeverity: RunwaySeverity.warn.rawValue), .warning)
        try checkEqual(AlertGlyph.level(riskSeverity: RunwaySeverity.danger.rawValue), .error)
        try checkEqual(AlertGlyph.level(status: L("side.tokenInvalid")), .error)
        try checkEqual(AlertGlyph.level(status: L("quota.usedUp")), .error)
        try checkEqual(AlertGlyph.level(quotaBlocked: true, warn: true), .error)
        try checkEqual(AlertGlyph.level(loginHint: "登录"), .error)
        try checkEqual(AlertGlyph.level(status: L("runway.enough")), .none)
    }

    test("节奏差四舍五入后分档，详细文案保留两种读数") {
        try checkEqual(PaceText.describe(remaining: 49.6, pace: 52),
                       "与平均节奏持平：此刻应剩 52%，实际剩 50%")
        try checkEqual(PaceText.describe(remaining: 49.5, pace: 52),
                       "比平均节奏用得快 3 个点：此刻应剩 52%，实际剩 50%")
        try checkEqual(PaceText.describe(remaining: 54.5, pace: 52),
                       "比平均节奏省 3 个点：此刻应剩 52%，实际剩 55%")
        try checkEqual(PaceText.short(remaining: 44, pace: 52), "比平均节奏用得快 8 个点")
    }

    test("精确更新时间看本地日界、年份和分钟") {
        let cal = astryxCalendar()
        let now = astryxDate(26, 0, 2, calendar: cal)
        try checkEqual(StaleTime.absolute(astryxDate(26, 0, 1, calendar: cal), now: now, calendar: cal), "今天 00:01")
        try checkEqual(StaleTime.absolute(astryxDate(25, 23, 59, calendar: cal), now: now, calendar: cal), "昨天 23:59")
        try checkEqual(StaleTime.absolute(astryxDate(24, 14, 3, calendar: cal), now: now, calendar: cal), "11月24日 14:03")
        try checkEqual(StaleTime.absolute(astryxDate(24, 14, 3, year: 2025, calendar: cal), now: now, calendar: cal), "2025年11月24日 14:03")
        try checkEqual(StaleTime.absolute(astryxDate(31, 23, 59, month: 12, year: 2025, calendar: cal),
                                        now: astryxDate(1, 0, 1, month: 1, calendar: cal), calendar: cal), "昨天 23:59")
    }

    test("运行指示区分近期本机活动与按量扣费") {
        let now = astryxDate(26, 12)
        var task = RunningTask(provider: .codexPlan, sessionKey: "x", project: "x", model: nil,
                               startedAt: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-60), tokens: 1)
        try checkEqual(RunningActivity.kind(for: .codexPlan, recentAgents: RunningActivity.recentAgents([task], now: now), paygActive: []), .agent)
        task.lastActivity = now.addingTimeInterval(-61)
        try checkEqual(RunningActivity.recentAgents([task], now: now), [])
        try checkEqual(RunningActivity.kind(for: .deepseek, recentAgents: [], paygActive: [.deepseek]), .payg)
    }

    test("花费变化取整后分涨跌持平，并区分昨日为零与缺数据") {
        try checkEqual(SpendComparison.change(today: 132, yesterday: 100), .increase(32))
        try checkEqual(SpendComparison.change(today: 95.5, yesterday: 100), .decrease(5))
        try checkEqual(SpendComparison.change(today: 104.5, yesterday: 100), .increase(5))
        try checkEqual(SpendComparison.change(today: 104.49, yesterday: 100), .steady)
        try checkEqual(SpendComparison.change(today: 1, yesterday: 0), .zeroYesterday)
        try checkEqual(SpendComparison.change(today: 0, yesterday: 0), nil)
        try checkEqual(SpendComparison.change(today: 1, yesterday: nil), nil)
        // 昨日基数太小：写金额差，不写 +13000%
        try checkEqual(SpendComparison.change(today: 2.7, yesterday: 0.02), .increaseAmount(fmtCNY(2.68)))
        try checkEqual(SpendComparison.change(today: 0.1, yesterday: 0.9), .decreaseAmount(fmtCNY(0.8)))
        try checkEqual(SpendComparison.change(today: 0.55, yesterday: 0.5), .steady)
        try checkEqual(SpendComparison.change(today: 3, yesterday: 1), .increase(200))
    }

    test("昨日同时刻使用两端最近采样，15 分钟边界包含在内") {
        let now = astryxDate(26, 12)
        let samples = [astryxSample(25, 12, 15, 27), astryxSample(24, 23, 45, 20),
                       astryxSample(25, 11, 44, 23), astryxSample(24, 23, 44, 19)]
        try checkEqual(SpendComparison.yesterday(samples, now: now, calendar: astryxCalendar()), 7)
        try checkEqual(SpendComparison.yesterday(Array(samples.dropFirst()), now: now, calendar: astryxCalendar()), nil)
        try checkEqual(SpendComparison.yesterday([samples[0], samples[3]], now: now, calendar: astryxCalendar()), nil)
    }

    test("昨日是月初直接取累计，日内回落后采用新累计") {
        let cal = astryxCalendar()
        try checkEqual(SpendComparison.yesterday([astryxSample(1, 12, 0, 4)],
                                                now: astryxDate(2, 12), calendar: cal), 4)
        try checkEqual(SpendComparison.yesterday([astryxSample(25, 0, 0, 10), astryxSample(25, 9, 0, 12),
                                                 astryxSample(25, 10, 0, 1), astryxSample(25, 12, 0, 13)],
                                                now: astryxDate(26, 12), calendar: cal), 13)
        try checkEqual(SpendComparison.yesterday([astryxSample(30, 23, 59, 40, month: 10)],
                                                now: astryxDate(2, 0, 1), calendar: cal), nil)
    }

    test("多平台同时刻比较用卡片汇率，任一计入平台缺样就没有合计") {
        let cal = astryxCalendar()
        let now = astryxDate(26, 12)
        let local = [astryxSample(25, 0, 0, 1), astryxSample(25, 12, 0, 2)]
        let usd = [astryxSample(25, 0, 0, 5, provider: .openrouter, currency: .usd),
                   astryxSample(25, 12, 0, 7, provider: .openrouter, currency: .usd)]
        let contributing: [ProviderID: Currency] = [.deepseek: .cny, .openrouter: .usd]
        try checkEqual(SpendComparison.total(in: [.deepseek: local, .openrouter: usd], paying: contributing,
                                            now: now, calendar: cal, usdToCny: Decimal(string: "7.1")!), Decimal(string: "15.2"))
        try checkEqual(SpendComparison.total(in: [.deepseek: local], paying: contributing,
                                            now: now, calendar: cal, usdToCny: 7), nil)
    }

    test("昨日同时刻跨夏令时按日历减一天") {
        var cal = astryxCalendar()
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = astryxDate(8, 12, month: 3, calendar: cal)
        var start = astryxSample(7, 0, 0, 29)
        var target = astryxSample(7, 12, 0, 37)
        start.t = astryxDate(7, 0, month: 3, calendar: cal)
        target.t = astryxDate(7, 12, month: 3, calendar: cal)
        try checkEqual(SpendComparison.yesterday([start, target], now: now, calendar: cal), 8)
    }

    test("账单历史只读连接按范围读取累计样本") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-astryx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("samples.sqlite").path
        let store = try SampleStore(path: path)
        let start = astryxSample(24, 23, 45, 20)
        let end = astryxSample(26, 0, 15, 27)
        var withoutCost = astryxSample(25, 12, 0, 24)
        withoutCost.cumulativeCost = nil
        for sample in [end, withoutCost, start, astryxSample(26, 0, 16, 28)] { try store.append(sample) }
        let range = SpendComparison.historyInterval(now: astryxDate(26, 12), calendar: astryxCalendar())!
        let result = try SampleStore.loadCostHistory(path: path, ids: [.deepseek], range: range)
        try checkEqual(result[.deepseek], [start, end])
    }

    test("数据映射仅比较计入今天实付的平台，并保留成功时间") {
        let cal = astryxCalendar()
        let now = astryxDate(26, 12)
        let fetched = astryxDate(26, 11, 41)
        func platform(_ id: ProviderID, amount: Decimal, status: PlatformStatus) -> PlatformState {
            let snapshot = ProviderSnapshot(provider: id, balance: nil, today: Money(amount: amount, currency: .cny),
                                            month: nil, byModel: [], trend7: [], source: .bill, fetchedAt: fetched, credential: .ok)
            return PlatformState(id: id, snapshot: snapshot, burn: nil, status: status)
        }
        var main = platform(.deepseek, amount: 13.2, status: .stale(minutes: 19))
        main.burn = BurnStats(perHourRecent: nil, perHourDay: nil, avgPerDayWeek: 10, runwayDays: nil, spike: false)
        let others = [platform(.siliconflow, amount: 9, status: .hidden), platform(.codexPlan, amount: 99, status: .ok)]
        let history = [ProviderID.deepseek: [astryxSample(25, 0, 0, 5), astryxSample(25, 12, 0, 15)]]
        var d = AppDataMapping.appData(main: main, others: others, now: now, timeZone: cal.timeZone, spendHistory: history)
        try checkEqual(d.mainCardSide?.lastUpdated, fetched)
        try checkEqual(d.totalTodayCny, 13.2)
        try checkEqual(d.yesterdaySameTimeCny, 10)
        let cards = TodayCards.build(d, running: [], now: now, paygActive: [.deepseek])
        let menu = MenuCardRows.build(d, running: [], now: now, paygActive: [.deepseek])
        try checkEqual(cards.first?.lastUpdated, fetched)
        try checkEqual(menu.first?.lastUpdated, fetched)
        try check(cards.first?.a11y.contains("正在运行") == true)
        try check(menu.first?.a11y.contains("正在运行") == true)
        let spend = cards.first { $0.kind == .spend }
        try checkEqual(spend?.spendChange, .increase(32))
        try check(spend?.a11y.contains("比昨天同一时刻多 32%") == true)
        try checkEqual(spend?.spendNote, nil)
        d.yesterdaySameTimeCny = nil
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.kind == .spend }?.spendNote, L("today.paidAboveAvg", 32))
        main.snapshot?.fetchedAt = astryxDate(25, 23, 59)
        let overnight = AppDataMapping.appData(main: main, others: others, now: now, timeZone: cal.timeZone, spendHistory: history)
        try checkEqual(overnight.yesterdaySameTimeCny, nil)
    }
}

private func astryxCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return calendar
}

private func astryxDate(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026,
                        calendar: Calendar = astryxCalendar()) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func astryxSample(_ day: Int, _ hour: Int, _ minute: Int, _ cost: Decimal, month: Int = 11,
                          provider: ProviderID = .deepseek, currency: Currency = .cny) -> Sample {
    Sample(provider: provider, t: astryxDate(day, hour, minute, month: month), balance: nil, cumulativeCost: cost, currency: currency)
}
