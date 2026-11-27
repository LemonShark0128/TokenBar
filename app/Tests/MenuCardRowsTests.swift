import Foundation

@MainActor
func registerMenuCardRowsTests() {
    let now = Date(timeIntervalSince1970: 1792022400)
    func data() -> AppData {
        var d = AppData(nowLocal: "2026-10-15 00:00:00", balance: .init(cny: 6.01, source: "平台", status: "可用", ageS: 0),
                        today: .init(costCny: 2.53, tokens: 20, source: "平台账单"),
                        month: .init(costCny: 34.92, tokens: 20, source: "平台账单"), models: [], trend7: [],
                        burn: .init(cnyPerHourRate: nil, cnyPerDayRate: nil, avgCnyPerDayWeek: 6, runwayDays: 1, spike: nil))
        func row(_ id: String, _ used: Double, _ hours: Double) -> AppData.QuotaRow {
            .init(id: id, name: id == "session" ? "会话" : "本周", usedPercent: used, isReset: false, reset: nil,
                  windowKind: id, resetsAt: now.addingTimeInterval(hours * 3600))
        }
        d.sides = [.init(id: "claudePlan", name: "Claude 套餐", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok"),
                         quotaRemaining: 47, quotaRows: [row("session", 53, 1), row("weekly", 42, 36)]),
                   .init(id: "codexPlan", name: "Codex 套餐", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok"),
                         quotaRemaining: 0, quotaExhausted: QuotaExhausted(clock: "21:36"),
                         quotaRows: [row("session", 100, 2), row("weekly", 83, 104)], riskText: L("quota.usedUp"), riskSeverity: 2),
                   .init(id: "siliconflow", name: "硅基流动", tank: 9.87, currency: "CNY", todayCost: 0, status: L("side.ok"),
                         monthCost: 0.09, runwayDays: 400, avgCnyPerDayWeek: 0.02)]
        d.totalTodayCny = 2.53
        return d
    }
    test("menuCardRowsMatchTodayCards") {
        let d = data()
        let rows = MenuCardRows.build(d, running: [], now: now)
        let cards = TodayCards.build(d, running: [], now: now).filter { $0.kind == .platform }
        try checkEqual(rows.map(\.id), cards.map(\.id))
        for (r, c) in zip(rows, cards) { try checkEqual(r.state, c.status ?? c.stateLineShort ?? c.stateLine ?? c.runwayChip) }
        try checkEqual(rows.first?.isMain, true); try checkEqual(rows.dropFirst().contains { $0.isMain }, false)
    }
    test("menuCardRowsContent") {
        let rows = MenuCardRows.build(data(), running: [], now: now)
        let ds = rows.first { $0.id == "deepseek" }!
        try checkEqual(ds.state, L("today.runwayTopUp", "1")); try check(ds.warn); try checkEqual(ds.value, "¥6.01")
        // 11/6 用户定 round7-scout 第 4 条乙：英文菜单卡位置窄，用短写，不被截成「About 7 days · Top...」；中文不变
        L10n.lang = .en
        defer { L10n.lang = .zh }
        let en = MenuCardRows.build(data(), running: [], now: now).first { $0.id == "deepseek" }!
        try checkEqual(en.state, "≈1 day · top up")
        let card = TodayCards.build(data(), running: [], now: now).first { $0.id == "deepseek" }!
        try checkEqual(card.stateLine, "About 1 day · Top up")      // 今天页卡片照旧
        L10n.lang = .zh
        let codex = rows.first { $0.id == "codexPlan" }!
        try checkEqual(codex.state, L("today.usedUpBack", "21:36")); try checkEqual(codex.severity, 2)
        try checkEqual(codex.windows.count, 0)   // 用完只写一行
        try checkEqual(codex.value, quotaLeftText(0))
        let claude = rows.first { $0.id == "claudePlan" }!
        try checkEqual(claude.windows.map(\.value), [quotaLeftText(47), quotaLeftText(58)])
        try checkEqual(claude.value, quotaLeftText(47))
        let sf = rows.first { $0.id == "siliconflow" }!
        try checkEqual(sf.state, L("today.runwayLong")); try check(!sf.warn)
    }
    // 只有「本周（Opus）」用完、套餐还能用：菜单卡不能收成一行写「剩余 0%」（同表盘 / 今天卡的口径，单模型窗口不算整个平台用完）
    test("menuCardRowsModelWindowUsedUpIsNotPlanUsedUp") {
        var d = data()
        d.sides[0].quotaRows.append(.init(id: "本周（Opus）", name: "本周（Opus）", usedPercent: 100, isReset: false, reset: nil,
                                          windowKind: "weeklyModel:opus", resetsAt: now.addingTimeInterval(36 * 3600)))
        let claude = MenuCardRows.build(d, running: [], now: now).first { $0.id == "claudePlan" }!
        try checkEqual(claude.value, quotaLeftText(47))
        try checkEqual(claude.windows.count, 2)       // 卡片只画 5 小时和每周两条
        // 真用完（有 quotaExhausted）照旧收成一行、读数取见底的
        let codex = MenuCardRows.build(d, running: [], now: now).first { $0.id == "codexPlan" }!
        try checkEqual(codex.windows.count, 0); try checkEqual(codex.value, quotaLeftText(0))
    }
    test("menuCardRowsTasksUnderTheirPlatform") {
        let task = RunningTask(provider: .claudePlan, sessionKey: "k", project: "形象库", model: "opus 5.5",
                               startedAt: now, lastActivity: now, tokens: 10)
        let rows = MenuCardRows.build(data(), running: [task], now: now)
        try checkEqual(rows.first { $0.id == "claudePlan" }?.tasks.map(\.project), ["形象库"])
        try checkEqual(rows.filter { $0.id != "claudePlan" }.flatMap(\.tasks).count, 0)
    }
    test("menuCardExhaustedValueUsesEmptyWindow") {
        var d = data()
        // Codex 本周用完、会话还剩 60%
        d.sides[1].quotaRows = [.init(id: "session", name: "会话", usedPercent: 40, isReset: false, reset: nil, windowKind: "session",
                                      resetsAt: now.addingTimeInterval(7200)),
                                .init(id: "weekly", name: "本周", usedPercent: 100, isReset: false, reset: nil, windowKind: "weekly",
                                      resetsAt: now.addingTimeInterval(86400 * 3))]
        let codex = MenuCardRows.build(d, running: [], now: now).first { $0.id == "codexPlan" }!
        try checkEqual(codex.value, quotaLeftText(0)); try checkEqual(codex.windows.count, 0)
    }
    test("menuCardOrphanTaskGoesUnderMain") {
        let task = RunningTask(provider: .codexPlan, sessionKey: "k", project: "x", model: nil, startedAt: now, lastActivity: now, tokens: 1)
        var d = data(); d.sides.removeAll { $0.id == "codexPlan" }
        let rows = MenuCardRows.build(d, running: [task], now: now)
        try checkEqual(rows.first?.tasks.map(\.project), ["x"])
    }
    test("menuCardPaidLine") {
        var d = data()
        try checkEqual(MenuCardRows.paidLine(d), L("menu.paidToday", "", "¥2.53"))
        d.totalIsApprox = true
        try checkEqual(MenuCardRows.paidLine(d), L("menu.paidToday", "≈", "¥2.53"))
        d.totalTodayCny = nil
        try checkEqual(MenuCardRows.paidLine(d), nil)
    }
}
