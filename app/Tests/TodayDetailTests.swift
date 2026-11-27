import Foundation

@MainActor
func registerTodayDetailTests() {
    let now = Date(timeIntervalSince1970: 1792022400)
    let all = Set(TodayCardSize.allCases)
    for (name, start, dx, dy, expected) in [
        ("SM", TodayCardSize.small, 101.0, 0.0, TodayCardSize.medium),
        ("ML", .medium, 0, 51, .large), ("LS", .large, -101, -51, .small),
        ("tiny", .small, 10, 10, .small), ("reverse", .large, 0, -51, .medium)
    ] {
        test("todaySnap" + name) {
            try checkEqual(TodayLayout.snap(start: start, dx: dx, dy: dy, cellWidth: 200, cellHeight: 100, allowed: all), expected)
        }
    }
    test("todaySnapAllowed") {
        try checkEqual(TodayLayout.snap(start: .large, dx: -201, dy: -101, cellWidth: 200, cellHeight: 100, allowed: [.medium, .large]), .medium)
    }
    test("todayRiskRowOnlyWhenNeeded") {
        var a = TodayCard(id: "a", kind: .platform, title: "a")
        let b = TodayCard(id: "b", kind: .platform, title: "b")
        let placements = TodayLayout.place([.init(id: "a", size: .small), .init(id: "b", size: .small)], present: ["a", "b"])
        try check(!TodayCards.needsRiskRow(id: "b", cards: [a,b], placements: placements))
        a.status = "risk"
        try check(TodayCards.needsRiskRow(id: "b", cards: [a,b], placements: placements))
    }
    func data(full: Bool) -> AppData {
        var d = AppData(nowLocal: "2026-10-15", balance: .init(cny: 28, source: "", status: "", ageS: 0),
                        today: .init(costCny: 6, tokens: 20, source: full ? "平台账单" : ""),
                        month: .init(costCny: 38, tokens: 20, source: full ? "平台账单" : ""), models: [], trend7: [], burn: nil)
        d.sides = [.init(id: "codexPlan", name: "Codex", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok"), resetCreditsCount: full ? 2 : nil)]
        if full {
            d.totalTodayCny = 6
            d.apiValue = .init(todayUSD: 2, weekUSD: 4, perProvider: ["codexPlan": 2], partial: false)
            d.trend7 = [.init(date: "10-15", iso: "2026-10-15", totalTokens: 20, byModel: ["m": 20], detail: ["m": .init(tokens: 20, costCny: 6, cacheHit: 0, cacheMiss: 20, output: 0, hitRate: 0)])]
            d.tokenSources = [.init(provider: .codexPlan, byDay: ["2026-10-15": ["gpt": 42]])]
            d.models = (1...10).map { .init(key: "m\($0)", label: "m\($0)", cacheHit: 0, cacheMiss: 0, output: 0, todayTokens: $0, todayCny: Double($0), monthCny: 0, hitRate: 0, calls: 0) }
        }
        return d
    }
    let task = RunningTask(provider: .codexPlan, sessionKey: "t", project: "demo", model: "gpt", startedAt: now, lastActivity: now, tokens: 12)
    for size in [TodayCardSize.medium, .large] {
        for full in [false, true] {
            for (id, kind) in [("codexPlan", TodayCard.Kind.platform), ("deepseek", .platform), ("spend", .spend), ("running", .running), ("trend", .trend)] {
                test("todayDetail_\(id)_\(size)_\(full)") {
                    let d = data(full: full)
                    let card = TodayCard(id: id, kind: kind, title: id, provider: ProviderID(rawValue: id))
                    let result = TodayCards.detail(card, size: size, data: d, running: full ? Array(repeating: task, count: 5) : [], now: now)
                    if !full {
                        try check(result.rows.isEmpty && result.bars.isEmpty && result.tasks.isEmpty)
                    } else {
                        switch id {
                        case "codexPlan":
                            try check(result.rows.contains { $0.value.contains("42") })
                            try checkEqual(result.bars.count, size == .large ? 1 : 0)
                            try checkEqual(result.tasks.count, size == .large ? 3 : 0)
                        case "deepseek":
                            try checkEqual(result.models.count, size == .large ? 8 : 3)
                            try checkEqual(result.models.first?.label, "m10")
                            try checkEqual(result.more, size == .large ? L("today.moreModels", 2) : nil)
                            try checkEqual(result.sparkline.count, 1)
                        case "spend": try checkEqual(result.rows.count, 2); try checkEqual(result.bars.count, size == .large ? 1 : 0)
                        case "running": try checkEqual(result.tasks.count, size == .large ? 5 : 3)
                        default: try check(result.chart != nil)
                        }
                    }
                }
            }
        }
    }
    test("todayPlatformMissingSplitDoesNotBorrowMain") {
        var d = data(full: true); d.tokenSources = []
        let card = TodayCard(id: "codexPlan", kind: .platform, title: "Codex", provider: .codexPlan)
        let result = TodayCards.detail(card, size: .large, data: d, running: [], now: now)
        try check(result.bars.isEmpty)
    }
    test("todayUnreadableNoteOnce") {
        var d = data(full: false)
        d.sides = [.init(id: "claudePlan", name: "Claude", tank: nil, currency: "PCT", todayCost: nil, status: "读不到记录", quotaNote: "读不到记录")]
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "claudePlan" }!
        try checkEqual(TodayCards.bottomNote(card), nil)
    }
    test("todayPickedDayDetail") {
        let rows = TodayCards.dayDetail(data(full: true), iso: "2026-10-15")
        try checkEqual(rows.count, 1)
        try check(rows[0].value.contains("6.00"))
        try check(TodayCards.dayDetail(data(full: true), iso: "missing").isEmpty)
    }
    test("todayPlanMediumHasWeekModelsAndRunning") {
        var d = data(full: true)
        d.tokenSources = [.init(provider: .codexPlan, byDay: [
            "2026-10-15": ["gpt-5.5": 300, "gpt-5.5-mini": 100, "o4": 50, "o3": 10],
            "2026-10-12": ["gpt-5.5": 1000], "2026-10-01": ["gpt-5.5": 99999]])]
        let card = TodayCard(id: "codexPlan", kind: .platform, title: "Codex", provider: .codexPlan)
        let m = TodayCards.detail(card, size: .medium, data: d, running: [task, task], now: now)
        try checkEqual(m.rows.first { $0.id == "week" }?.value, cnCount(1460))   // 10-01 不在近 7 天里
        try check(m.rows.contains { $0.id == "running" && $0.label == L("today.runningCount", 2) })
        try checkEqual(m.models.map(\.value), [cnCount(300), cnCount(100), cnCount(50)])
        let l = TodayCards.detail(card, size: .large, data: d, running: [task], now: now)
        try checkEqual(l.models.count, 4)
        try check(!l.rows.contains { $0.id == "running" })   // 大号直接列任务，不再写个数
    }
    test("todayPaygMediumHasTokensAndWeekSpend") {
        let d = data(full: true)   // 主平台 DeepSeek：近 7 天只有 10-15 一天，花 ¥6、20 token
        let card = TodayCard(id: "deepseek", kind: .platform, title: "DeepSeek", provider: .deepseek)
        let m = TodayCards.detail(card, size: .medium, data: d, running: [], now: now)
        try checkEqual(m.rows.first { $0.id == "weekSpend" }?.value, fmtMoney(6, "CNY"))
        try checkEqual(m.rows.first { $0.id == "tokens" }?.value, cnCount(20))
    }
    test("todayPaygWeekSpendHiddenWhenADayLacksCost") {
        var d = data(full: true)
        d.trend7.append(.init(date: "10-14", iso: "2026-10-14", totalTokens: 30, byModel: ["m": 30], detail: nil))
        let card = TodayCard(id: "deepseek", kind: .platform, title: "DeepSeek", provider: .deepseek)
        let m = TodayCards.detail(card, size: .medium, data: d, running: [], now: now)
        try check(!m.rows.contains { $0.id == "weekSpend" })
    }
    test("todayPaygDetailRunwayUnderOneDay") {
        var d = data(full: true)
        d.burn = .init(cnyPerHourRate: nil, cnyPerDayRate: nil, avgCnyPerDayWeek: 4, runwayDays: 0.25, spike: false)
        let card = TodayCard(id: "deepseek", kind: .platform, title: "DeepSeek", provider: .deepseek)
        try checkEqual(TodayCards.detail(card, size: .medium, data: d, running: [], now: now).rows.first { $0.id == "runway" }?.label, "还能用 6 小时")
        d.burn?.runwayDays = 0.01
        try checkEqual(TodayCards.detail(card, size: .medium, data: d, running: [], now: now).rows.first { $0.id == "runway" }?.label, "还能用不到 1 小时")
        d.burn?.runwayDays = 2.4
        try checkEqual(TodayCards.detail(card, size: .medium, data: d, running: [], now: now).rows.first { $0.id == "runway" }?.label, "还能用 2 天")
    }
}
