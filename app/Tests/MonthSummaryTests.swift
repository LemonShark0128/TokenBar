import Foundation

@MainActor
func registerMonthSummaryTests() {
    func cny(_ v: Decimal) -> Money { Money(amount: v, currency: .cny) }
    func use(_ model: String, _ tokens: Int, _ cost: Decimal) -> ModelUsage {
        ModelUsage(model: model, cacheHit: tokens / 2, cacheMiss: tokens / 4, output: tokens - tokens / 2 - tokens / 4,
                   requests: 1, cost: cny(cost))
    }
    /// 2026-09-15 … 2026-10-15 共 31 天：flash 每天 100 token / ¥1；pro 只在 9 月用过
    func crossMonthDays() -> [DayUsage] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(secondsFromGMT: 0); fmt.dateFormat = "yyyy-MM-dd"
        let start = fmt.date(from: "2026-09-15")!
        return (0..<31).map { i in
            let day = fmt.string(from: start.addingTimeInterval(Double(i) * 86400))
            var models = [use("deepseek-flash", 100, 1)]
            if day.hasPrefix("2026-09") { models.append(use("deepseek-pro", 1000, 5)) }
            return DayUsage(day: day, tokens: models.reduce(0) { $0 + $1.cacheHit + $1.cacheMiss + $1.output },
                            cost: cny(models.reduce(0) { $0 + ($1.cost?.amount ?? 0) }), models: models)
        }
    }

    test("monthByModelOnlyCountsThisMonth") {
        let days = crossMonthDays()
        try checkEqual(days.first?.day, "2026-09-15")
        try checkEqual(days.last?.day, "2026-10-15")
        let m = ProviderSnapshot.monthByModel(days, month: "2026-10")
        try checkEqual(m.map(\.model), ["deepseek-flash"])            // pro 只在 9 月用过，不算
        try checkEqual(m[0].cacheHit + m[0].cacheMiss + m[0].output, 15 * 100)
        try checkEqual(m[0].requests, 15)
        try checkEqual(m[0].cost, cny(15))
    }
    testAsync("fullSnapshotHasMonthByModel") {
        let s = try await DeepSeekProvider(http: FixtureHTTPClient())
            .fetch(Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"]),
                   now: Date(timeIntervalSince1970: 1_792_022_400), timeZone: TimeZone(secondsFromGMT: 28800)!).get()
        let flash = s.monthByModel?.first { $0.model == "deepseek-flash" }
        try checkEqual(flash.map { $0.cacheHit + $0.cacheMiss + $0.output }, 394_667_538 + 63_290_808)
        try checkEqual(flash?.cost, cny(Decimal(string: "38.99")!))
    }
    test("mappingUsesMonthNotSevenDays") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let days = crossMonthDays()
        var s = snap(now)
        s.byModel = [use("deepseek-flash", 100, 1)]
        s.trend7 = Array(days.suffix(7))
        s.monthByModel = ProviderSnapshot.monthByModel(days, month: "2026-10")
        let st = PlatformState(id: .deepseek, snapshot: s, burn: nil, status: .ok)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 28800)!)
        try checkEqual(d.month.tokens, 15 * 100)                       // 不是近 7 天合计 700
        try checkEqual(d.models.first { $0.key == "deepseek-flash" }?.monthCny, 15)
    }
}
