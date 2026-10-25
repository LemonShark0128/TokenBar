import Foundation

@MainActor
func registerAppDataMappingTests() {
    test("quotaMappingDisplaysSessionAndWeeklySecondLine") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 0)!
        var snapshot = snap(now)
        snapshot.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .weekly, usedPercent: 80, resetsAt: now.addingTimeInterval(86400), windowMinutes: nil),
            QuotaWindow(kind: .session, usedPercent: 20, resetsAt: now.addingTimeInterval(3600), windowMinutes: nil)
        ], observedAt: now)
        let st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .ok)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: tz)
        try checkEqual(d.balance.cny, 80)
        try checkEqual(d.quota?.remainingPercent, 80)
        try check(d.quota?.headline?.hasPrefix("5 小时窗口") == true)
        try check(d.quota?.secondLine?.hasPrefix("本周已用 80%") == true)
        let side = AppDataMapping.side(st, now: now, timeZone: tz)
        try checkEqual(side.quotaRemaining, 80)
        try checkEqual(side.quotaReset, "1:00 后重置")
    }
    test("quotaMappingStaleAndEstimated") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        for minutes in [3, 15] {
            var snapshot = snap(now.addingTimeInterval(Double(-minutes * 60)))
            snapshot.quota = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 95, resetsAt: nil, windowMinutes: nil)], observedAt: now, estimated: true)
            let st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .stale(minutes: 1))
            let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            try checkEqual(AppDataMapping.statusText(st, now: now), "\(minutes) 分钟前 · 未更新")
            try checkEqual(d.quota?.staleNote, "\(minutes) 分钟前 · 未更新")
            try checkEqual(d.quota?.stale, minutes > 10)
            try check(d.quota?.lastUsed?.hasSuffix(" · 推算") == true)
            try checkEqual(AppDataMapping.side(st, now: now).quotaStale, minutes > 10)
        }
    }
    test("quotaDecodesLegacyEstimatedDefault") {
        let q = Quota(plan: nil, windows: [], observedAt: Date())
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: Any]
        obj.removeValue(forKey: "estimated")
        let old = try JSONDecoder().decode(Quota.self, from: JSONSerialization.data(withJSONObject: obj))
        try checkEqual(old.estimated, false)
    }
    test("hitRateTextDashWithoutCacheData") {
        // 硅基流动等没有缓存命中数据：和总览一样显示「—」，不显示 0.00%
        try checkEqual(AppDataMapping.hitRateText(hit: 0, miss: 0, rate: 0), "—")
        try checkEqual(AppDataMapping.hitRateText(hit: 0, miss: 10, rate: 0), "0.00%")
        try checkEqual(AppDataMapping.hitRateText(hit: 3, miss: 1, rate: 75), "75.00%")
    }
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    let shanghai = TimeZone(secondsFromGMT: 28800)!
    func full() async throws -> ProviderSnapshot {
        try await DeepSeekProvider(http: FixtureHTTPClient())
            .fetch(Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"]),
                   now: now, timeZone: shanghai).get()
    }
    func state(_ s: ProviderSnapshot?, status: PlatformStatus = .ok) -> PlatformState {
        PlatformState(id: .deepseek, snapshot: s, burn: nil, status: status, lastSampleAt: nil, lastSample: nil)
    }

    // 启动时 UsageStore 接上前会先读一次旧采集 /api/app：那里没有第二期新加的 sides / total_is_approx
    testAsync("appDataDecodesLegacyCollectorJson") {
        let d = AppDataMapping.appData(main: state(try await full()), others: [], now: now, timeZone: shanghai)
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        var obj = try JSONSerialization.jsonObject(with: enc.encode(d)) as! [String: Any]
        for k in ["sides", "total_is_approx", "total_today_cny", "today_is_utc"] { obj[k] = nil }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let back = try dec.decode(AppData.self, from: JSONSerialization.data(withJSONObject: obj))
        try checkEqual(back.balance.cny, 27.07)
        try checkEqual(back.sides.count, 0)
        try checkEqual(back.totalIsApprox, false)
    }
    // 整分支评审 I-2：明细截断 / 本月按模型只覆盖一部分 → 带到界面数据（旧数据没有这两项）
    testAsync("appDataCarriesDetailIncomplete") {
        var s = try await full()
        let plain = AppDataMapping.appData(main: state(s), others: [], now: now, timeZone: shanghai)
        try checkEqual(plain.trendIncomplete, false)
        try checkEqual(plain.monthModelsIncomplete, false)
        s.detailTruncated = true; s.monthByModelPartial = true
        let d = AppDataMapping.appData(main: state(s), others: [], now: now, timeZone: shanghai)
        try checkEqual(d.trendIncomplete, true)
        try checkEqual(d.monthModelsIncomplete, true)
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        var obj = try JSONSerialization.jsonObject(with: enc.encode(d)) as! [String: Any]
        for k in ["trend_incomplete", "month_models_incomplete"] { obj[k] = nil }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let back = try dec.decode(AppData.self, from: JSONSerialization.data(withJSONObject: obj))
        try checkEqual(back.trendIncomplete, false)
    }
    testAsync("appDataMapping") {
        let d = AppDataMapping.appData(main: state(try await full()), others: [], now: now, timeZone: shanghai)
        try checkEqual(d.balance.cny, 27.07)
        try checkEqual(d.today.costCny, 6.27)
        try checkEqual(d.today.tokens, 63_290_808)
        try checkEqual(d.today.source, "平台账单")
        try checkEqual(d.month.costCny, 38.99)
        try checkEqual(d.trend7.count, 7)
        try checkEqual(d.trend7.last?.date, "10-15")
        try checkEqual(d.models.first?.label, "Flash")
        try checkEqual(d.models.first?.calls, 276)
        try checkEqual(d.nowLocal, "2026-10-15 08:00:00")
        try checkEqual(d.trend7[5].detail?["deepseek-flash"]?.cacheHit, 384_801_407)
    }
    testAsync("balanceOnlyMapping") {
        var s = try await full()
        s.source = .balanceOnly; s.today = nil; s.month = nil; s.byModel = []; s.trend7 = []
        let d = AppDataMapping.appData(main: state(s), others: [], now: now, timeZone: shanghai)
        try checkEqual(d.today.source, "只有余额")
        try checkEqual(d.today.costCny, 0)
        try checkEqual(d.balance.cny, 27.07)
    }
    test("offlineColdStartUsesLastSample") {
        var st = state(nil, status: .offline)
        st.lastSample = Sample(provider: .deepseek, t: now.addingTimeInterval(-1800), balance: 27, cumulativeCost: nil, currency: .cny)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: shanghai)
        try checkEqual(d.balance.cny, 27)
        try checkEqual(d.balance.ageS, 1800)
    }
    // 第 3 条评审 M4：账单里没金额的模型不能写成 ¥0.00，也不能当 0 合进「其他」
    testAsync("chartMainModelWithoutCostIsUnknown") {
        var snap = try await full()
        try check(snap.byModel.count >= 1)
        snap.byModel[0].cost = nil
        let d = AppDataMapping.appData(main: state(snap), others: [], now: now, timeZone: shanghai)
        try checkEqual(d.models[0].todayCostKnown, false)
        let c = d.tokenChart(main: .deepseek)
        let i = c.series.firstIndex { $0.label == AppDataMapping.modelLabel(snap.byModel[0].model) }
        try check(i != nil, "图例里应有这个模型：\(c.series.map(\.label))")
        try checkEqual(c.costText(series: i!), nil)
    }
    // 第 3 条评审 M5：同名模型里有一条没金额，整行就不写花费
    testAsync("tokenSourcesDuplicateModelMissingCostDropsCost") {
        var snap = try await full()
        let last = snap.trend7.count - 1
        try check(!snap.trend7[last].models.isEmpty)
        var dup = snap.trend7[last].models[0]
        dup.cost = nil
        snap.trend7[last].models.append(dup)
        var side = state(snap); side.id = .siliconflow
        let main = state(try await full())
        let src = AppDataMapping.tokenSources(main: main, others: [side], localUsage: [:])
        let sf = src.first { $0.provider == .siliconflow }
        try check(sf != nil)
        try checkEqual(sf?.costByDay?[snap.trend7[last].day]?[dup.model], nil)
    }
    test("modelLabel") {
        try checkEqual(AppDataMapping.modelLabel("deepseek-v4-pro"), "V4 Pro")
        try checkEqual(AppDataMapping.modelLabel("deepseek-flash"), "Flash")
    }

    // ---- 第二期 Task 8：辅助平台、合计 ----
    func cny(_ v: String) -> Money { Money(amount: Decimal(string: v)!, currency: .cny) }
    func sfState(status: PlatformStatus) -> PlatformState {
        let snap = ProviderSnapshot(provider: .siliconflow, balance: cny("12.00"), today: cny("0.50"),
                                    month: cny("3"), byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        return PlatformState(id: .siliconflow, snapshot: snap, burn: nil, status: status, lastSampleAt: now, lastSample: nil)
    }
    let rate = Decimal(string: "7.1")!

    testAsync("sidesMapping") {
        let d = AppDataMapping.appData(main: state(try await full()), others: [sfState(status: .credentialInvalid)],
                                       now: now, timeZone: shanghai, usdToCny: rate)
        try checkEqual(d.sides.count, 1)
        let s = d.sides[0]
        try checkEqual(s.id, "siliconflow")
        try checkEqual(s.name, "硅基流动")
        try checkEqual(s.tank, 12.0)
        try checkEqual(s.currency, "CNY")
        try checkEqual(s.todayCost, 0.5)
        try checkEqual(s.status, "凭据失效")
    }
    test("sidesSkipNotAdded") {
        let none = PlatformState(id: .siliconflow, snapshot: nil, burn: nil, status: .notAdded)
        let d = AppDataMapping.appData(main: state(nil, status: .offline), others: [none], now: now, timeZone: shanghai, usdToCny: rate)
        try checkEqual(d.sides.count, 0)
    }
    testAsync("totalTodayConverted") {
        let only = AppDataMapping.appData(main: state(try await full()), others: [sfState(status: .ok)],
                                          now: now, timeZone: shanghai, usdToCny: rate)
        try checkEqual(only.totalTodayCny, 6.77)
        try check(!only.totalIsApprox, "全是人民币不标 ≈")
    }
    test("usageURLPerProvider") {
        for id in ProviderRegistry.all {
            try check(ProviderRegistry.usageURL(id).scheme == "https", "\(id) 要有 https 用量页")
        }
        try checkEqual(ProviderRegistry.usageURL(.deepseek).absoluteString, "https://platform.deepseek.com/usage")
        try checkEqual(ProviderRegistry.usageURL(.claudePlan).host, "claude.ai")
    }
    test("lowTankNotificationText") {
        let d = StatusPresenter.lowTankNotification(name: "DeepSeek", amount: 8.4, threshold: 10, currency: "CNY")
        try checkEqual(d.title, "DeepSeek 余额不足")
        try checkEqual(d.body, "可用余额 ¥8.40，已低于预警线 ¥10")
    }
}
