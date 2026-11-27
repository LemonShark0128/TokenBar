import Foundation

@MainActor
func registerAppDataMappingTests() {
    test("claudeOldQuotaKeepsLoginHintAcrossCardsAndMenu") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        var snapshot = snap(now)
        snapshot.quota = Quota(plan: "max", windows: [QuotaWindow(kind: .session, usedPercent: 20,
                              resetsAt: now.addingTimeInterval(3600), windowMinutes: 300)], observedAt: now)
        var st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .credentialInvalid)
        st.errorDetail = L("cli.needsLogin")
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: .gmt)
        try checkEqual(d.mainCardSide?.quotaNote, st.errorDetail)
        try checkEqual(d.mainCardSide?.quotaRemaining, 80)
        try checkEqual(d.mainCardSide?.quotaStale, true)
        try checkEqual(d.quota?.note, st.errorDetail)
        try checkEqual(d.quota?.staleNote, st.errorDetail)
        try checkEqual(d.quota?.stale, true)
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "claudePlan" }
        try checkEqual(card?.footnote, st.errorDetail)
        try checkEqual(card?.dimmed, true)
        try check(card?.a11y.contains(st.errorDetail!) == true)
        let row = MenuCardRows.build(d, running: [], now: now).first!
        try checkEqual(row.state, st.errorDetail)
        try checkEqual(row.stateMultiline, true)
        let cells = MenuBarCells.cells(d, main: .claudePlan, now: now)
        try checkEqual(cells.first?.primaryText, "需登录")
        try check(MenuBarCells.tooltip(cells, now: now).contains(st.errorDetail!))
        try check(A11yText.side(d.mainCardSide!).contains(st.errorDetail!))
        try checkEqual(StatusPresenter.error(for: st, name: "Claude"), st.errorDetail)
    }

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
        let side = AppDataMapping.side(st, now: now, timeZone: tz)
        try checkEqual(side.quotaRemaining, 80)
        try checkEqual(side.quotaReset, "1:00 后重置")
    }
    // 11/6 用户定 round7-scout 第 8 条乙：每周用完、5 小时窗口还有余时，表盘 / 标题 / 菜单栏 / 设置读数都按每周窗口写「已用完」
    test("weeklyExhaustedDrivesReadingWhileSessionHasRoom") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let tz = TimeZone(secondsFromGMT: 0)!
        let weeklyReset = now.addingTimeInterval(2 * 86400 + 7200)
        var snapshot = snap(now)
        snapshot.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(4 * 3600), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 100, resetsAt: weeklyReset, windowMinutes: nil),
            QuotaWindow(kind: .weeklyModel("opus"), usedPercent: 10, resetsAt: weeklyReset, windowMinutes: nil)
        ], observedAt: now)
        let q = snapshot.quota!
        try checkEqual(q.displayWindow(at: now)?.kind, .weekly)
        try checkEqual(q.displayRemainingPercent(at: now), 0)
        let st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .ok)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: tz)
        try checkEqual(d.balance.cny, 0)
        try checkEqual(d.quota?.remainingPercent, 0)
        try check(d.quota?.headline?.hasPrefix("本周") == true, "\(d.quota?.headline ?? "nil")")
        try check(d.quota?.exhausted != nil)
        let side = AppDataMapping.side(st, now: now, timeZone: tz)
        try checkEqual(side.quotaRemaining, 0)
        let menu = MenuBarText.quotaReading(q, now: now, timeZone: tz)
        try checkEqual(menu?.usedPercent, 100)
        try checkEqual(menu?.window, "本周")
        try check(menu?.exhausted != nil)
        try checkEqual(AccountReading.from(balance: nil, quota: q, meter: .quota, now: now), .remaining(0))
        try check(menu?.tighter == nil, "\(menu?.tighter ?? "")")      // 显示的窗口已用完：悬停不再补「当前会话剩 70%」
        // 新样式菜单栏格子、今天页紧凑卡：数字写 0%，不写 5 小时窗口的 70%（审核必须改）
        let cell = MenuBarCells.cells(d, main: .claudePlan, now: now).first { $0.id == .claudePlan }
        try checkEqual(cell?.primaryText, "0%")
        let compact = TodayCards.build(d, running: [], now: now).first { $0.id == "claudePlan" }
        try checkEqual(compact?.compactRemaining, 0)
        try checkEqual(compact?.compactValue, "0%")
        // 只有 Opus 窗口用完、Opus 恢复得更晚：恢复时刻不取 Opus 的（每周窗口用完时按每周窗口）
        var late = q
        late.windows[2].usedPercent = 100
        late.windows[2].resetsAt = weeklyReset.addingTimeInterval(86400)
        try checkEqual(QuotaText.exhaustion(late, now: now, timeZone: tz), QuotaText.exhaustion(q, now: now, timeZone: tz))
        // 每周过了重置时刻：回到按 5 小时窗口
        let later = weeklyReset.addingTimeInterval(1)
        try checkEqual(q.displayWindow(at: later)?.kind, .session)
        // 单模型窗口（本周 Opus）用完不算整个平台用完
        var opus = q
        opus.windows[1].usedPercent = 50
        opus.windows[2].usedPercent = 100
        try checkEqual(opus.displayWindow(at: now)?.kind, .session)
        try checkEqual(AccountReading.from(balance: nil, quota: opus, meter: .quota, now: now), .session(70))
        // 两个都用完：取最晚恢复的那个
        var both = q
        both.windows[0].usedPercent = 100
        try checkEqual(both.displayWindow(at: now)?.kind, .weekly)
    }
    test("quotaMappingStaleAndEstimated") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        for minutes in [3, 15, 90, 1500] {
            var snapshot = snap(now.addingTimeInterval(Double(-minutes * 60)))
            snapshot.quota = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 95, resetsAt: nil, windowMinutes: nil)], observedAt: now, estimated: true)
            let st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .stale(minutes: 1))
            let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            // 11/6 用户定 round7-scout 第 6 条乙：超过 60 分钟写小时、超过 24 小时写天（原来冷启动写「1440 分钟前」）
            let ago = minutes < 60 ? "\(minutes) 分钟前" : minutes < 1440 ? "\(minutes / 60) 小时前" : "\(minutes / 1440) 天前"
            try checkEqual(AppDataMapping.statusText(st, now: now), "\(ago) · 未更新")
            try checkEqual(d.quota?.staleNote, "\(ago) · 未更新")
            try checkEqual(d.quota?.stale, minutes > 10)
            try check(d.quota?.lastUsed?.hasSuffix(" · 推算") == true)
            try checkEqual(AppDataMapping.side(st, now: now).quotaStale, minutes > 10)
        }
        L10n.lang = .en
        defer { L10n.lang = .zh }
        let st = PlatformState(id: .claudePlan, snapshot: snap(now.addingTimeInterval(-900)), burn: nil, status: .stale(minutes: 15))
        try checkEqual(AppDataMapping.statusText(st, now: now), "Stale · 15 min ago")
        let day = PlatformState(id: .claudePlan, snapshot: snap(now.addingTimeInterval(-90000)), burn: nil, status: .stale(minutes: 1500))
        try checkEqual(AppDataMapping.statusText(day, now: now), "Stale · 1 day ago")
        // 按量付费过时：同样换算
        let payg = PlatformState(id: .deepseek, snapshot: snap(now.addingTimeInterval(-7200)), burn: nil, status: .stale(minutes: 120))
        try checkEqual(AppDataMapping.statusText(payg, now: now), "2h ago")
        L10n.lang = .zh
        try checkEqual(AppDataMapping.statusText(payg, now: now), "2 小时前")
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
        try checkEqual(s.status, "登录已过期")      // 硅基流动是网页登录（11/6 第 5 条乙）
        var key = sfState(status: .credentialInvalid); key.id = .kimi
        try checkEqual(AppDataMapping.statusText(key, now: now), "API Key 无效")
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
    testAsync("totalTodayUsdConvertedAndApprox") {
        // 美元按设置汇率换成人民币，合计标「≈」；未添加的平台即使留着旧快照也不计入
        let usdSnap = ProviderSnapshot(provider: .siliconflow, balance: nil, today: Money(amount: Decimal(string: "1.50")!, currency: .usd),
                                       month: nil, byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        let usd = PlatformState(id: .siliconflow, snapshot: usdSnap, burn: nil, status: .ok, lastSampleAt: now, lastSample: nil)
        var gone = sfState(status: .notAdded); gone.id = .codexPlan
        let d = AppDataMapping.appData(main: state(try await full()), others: [usd, gone],
                                       now: now, timeZone: shanghai, usdToCny: rate)
        try checkEqual(d.totalTodayCny, 16.92)   // 6.27 + 1.50 × 7.1
        try check(d.totalIsApprox, "含美元要标 ≈")
        let none = AppDataMapping.appData(main: state(nil, status: .offline), others: [gone],
                                          now: now, timeZone: shanghai, usdToCny: rate)
        try check(none.totalTodayCny == nil, "都没有今日数据时不显示合计")
        try check(!none.totalIsApprox)
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
