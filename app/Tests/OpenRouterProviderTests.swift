import Foundation

/// 记录请求头的内联客户端（只在一个测试里顺序使用）
final class OpenRouterHTTPClient: HTTPClient, @unchecked Sendable {
    let key: (Int, String)
    let credits: (Int, String)
    private(set) var requests: [(URL, [String: String])] = []
    init(key: (Int, String), credits: (Int, String)) { self.key = key; self.credits = credits }
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        requests.append((url, headers))
        switch url.path {
        case "/api/v1/key": return (key.0, Data(key.1.utf8))
        case "/api/v1/credits": return (credits.0, Data(credits.1.utf8))
        default: return (404, Data())
        }
    }
}

// OpenRouter（11-06 新平台）：/key 给今日 / 本月花费和 Key 上限；/credits 给账户余额（官方说要 Management Key，普通 Key 403）
@MainActor
func registerOpenRouterProviderTests() {
    let now = Date(timeIntervalSince1970: 1_792_072_800)
    let tz = TimeZone(secondsFromGMT: 28800)!
    let creds = Credentials(values: ["apiKey": "sk-or-v1-test"])
    func usd(_ s: String) -> Money { Money(amount: Decimal(string: s)!, currency: .usd) }
    // 官方文档示例（节选）
    let limitedKey = #"{"data":{"label":"sk-or-v1-au7...890","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","usage":25.5,"usage_daily":1.25,"usage_weekly":6.5,"usage_monthly":25.5,"byok_usage":17.38,"is_free_tier":false,"is_management_key":false}}"#
    let unlimitedKey = #"{"data":{"label":"k","limit":null,"limit_remaining":null,"limit_reset":null,"usage":3,"usage_daily":0.4,"usage_weekly":1,"usage_monthly":3,"is_free_tier":false}}"#
    let credits = #"{"data":{"total_credits":100.5,"total_usage":25.75}}"#
    let forbidden = #"{"error":{"code":403,"message":"Only management keys can perform this operation"}}"#

    test("openRouterParsesKeyUsageAndLimit") {
        let k = try OpenRouterProvider.parseKey(Data(limitedKey.utf8)).get()
        try checkEqual(k.today, usd("1.25"))
        try checkEqual(k.month, usd("25.5"))
        try checkEqual(k.limitRemaining, usd("74.5"))
        let u = try OpenRouterProvider.parseKey(Data(unlimitedKey.utf8)).get()
        try checkEqual(u.limitRemaining, nil)
        try checkEqual(u.today, usd("0.4"))
    }
    test("openRouterKeySchemaChangesAreNotZero") {
        for bad in [#"{"error":{}}"#, #"{"data":{"usage_daily":1}}"#, #"{"data":{"usage_daily":"x","usage_monthly":1}}"#,
                    #"{"data":{"usage_daily":true,"usage_monthly":1}}"#, "[]"] {
            guard case .failure(.schemaChanged) = OpenRouterProvider.parseKey(Data(bad.utf8)) else {
                throw TestFailure(description: "应判格式变化：\(bad)")
            }
        }
    }
    test("openRouterParsesCreditsBalance") {
        try checkEqual(try OpenRouterProvider.parseCredits(Data(credits.utf8)).get(), usd("74.75"))
        guard case .failure(.schemaChanged) = OpenRouterProvider.parseCredits(Data(#"{"data":{"total_credits":1}}"#.utf8)) else {
            throw TestFailure(description: "缺 total_usage 应判格式变化")
        }
    }
    testAsync("openRouterFetchUsesCreditsBalanceAndApiSpend") {
        let http = OpenRouterHTTPClient(key: (200, unlimitedKey), credits: (200, credits))
        let s = try await OpenRouterProvider(http: http).fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.provider, .openrouter)
        try checkEqual(s.balance, usd("74.75"))
        try checkEqual(s.today, usd("0.4"))
        try checkEqual(s.month, usd("3"))
        try checkEqual(s.source, .bill)
        try checkEqual(http.requests.map { $0.0.absoluteString },
                       ["https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/credits"])
        try check(http.requests.allSatisfy { $0.1["Authorization"] == "Bearer sk-or-v1-test" })
    }
    testAsync("openRouterCredits403FallsBackToKeyLimit") {
        let s = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (403, forbidden)))
            .fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.balance, usd("74.5"))
        try checkEqual(s.today, usd("1.25"))
        try checkEqual(s.credential, .ok)
    }
    testAsync("openRouterCredits403UnlimitedKeyHasNoBalanceButSpend") {
        let s = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, unlimitedKey), credits: (403, forbidden)))
            .fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.balance, nil)
        try checkEqual(s.month, usd("3"))
    }
    testAsync("openRouterAccountBalanceCapsByKeyLimit") {
        // 账户余额比 Key 剩余上限还少：能花的是少的那个
        let small = #"{"data":{"total_credits":10,"total_usage":8}}"#
        let s = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (200, small)))
            .fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.balance, usd("2"))
    }
    testAsync("openRouterErrors") {
        let p401 = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (401, #"{"error":{"code":401,"message":"No auth credentials found"}}"#), credits: (401, "")))
            .fetch(creds, now: now, timeZone: tz)
        guard case .failure(.auth) = p401 else { throw TestFailure(description: "Key 401 应判凭据失效：\(p401)") }
        let p429 = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#), credits: (200, credits)))
            .fetch(creds, now: now, timeZone: tz)
        guard case .failure(.rateLimited) = p429 else { throw TestFailure(description: "Key 429 应判限流：\(p429)") }
        // /credits 限流也要退避（按 IP 的突发限流，两个接口各算各的）
        let c429 = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (429, "")))
            .fetch(creds, now: now, timeZone: tz)
        guard case .failure(.rateLimited) = c429 else { throw TestFailure(description: "Credits 429 应判限流：\(c429)") }
        // /credits 服务端出错（从没读到过账户余额）：不影响花费，余额退回 Key 上限
        let c500 = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (500, "")))
            .fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(c500.balance, usd("74.5"))
        let empty = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (200, credits)))
            .fetch(Credentials(values: [:]), now: now, timeZone: tz)
        guard case .failure(.auth) = empty else { throw TestFailure(description: "没有 Key 应判凭据失效") }
    }
    testAsync("openRouterValidateSummaryInDollars") {
        let ok = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, unlimitedKey), credits: (200, credits))).validate(creds)
        try checkEqual(ok, .ok(summary: "已连接，余额 $74.75"))
        let noBal = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, unlimitedKey), credits: (403, forbidden))).validate(creds)
        try checkEqual(noBal, .ok(summary: "已连接，这把 Key 本月花费 $3.00"))
        // 读不到账户余额、显示的是 Key 剩余上限：不能叫「余额」
        let keyLimit = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (403, forbidden))).validate(creds)
        try checkEqual(keyLimit, .ok(summary: "已连接，Key 还能花 $74.50"))
        let bad = await OpenRouterProvider(http: OpenRouterHTTPClient(key: (401, ""), credits: (401, ""))).validate(creds)
        guard case .failed(.auth) = bad else { throw TestFailure(description: "401 应校验失败") }
    }
    test("openRouterRegistry") {
        try check(ProviderRegistry.all.contains(.openrouter))
        try checkEqual(ProviderRegistry.displayName(.openrouter), "OpenRouter")
        try checkEqual(ProviderRegistry.logName(.openrouter), "OpenRouter")
        try checkEqual(ProviderRegistry.currency(.openrouter), .usd)
        try checkEqual(ProviderRegistry.meter(.openrouter), .money)
        try check(ProviderRegistry.hasBalance(.openrouter))
        try check(ProviderRegistry.credentialKind(.openrouter) == .apiKey)
        try check(!ProviderRegistry.capabilities(.openrouter).estimatesSpendFromBalance)
        try check(!ProviderRegistry.capabilities(.openrouter).hasTokenDetail)
        try check(ProviderRegistry.capabilities(.deepseek).hasTokenDetail)
        try checkEqual(ProviderRegistry.usageURL(.openrouter).absoluteString, "https://openrouter.ai/activity")
        try check(ProviderRegistry.makeProvider(.openrouter, http: InlineHTTPClient { _ in (500, "") }) is OpenRouterProvider)
        // 引导页：在「按量付费」组
        try check(OnboardingPlan.groups.first?.ids.contains(.openrouter) == true)
    }
    test("openRouterCopy") {
        for key in ["ob.gain.openrouter", "ob.openrouter.title", "ob.openrouter.note", "provider.connectedBalanceUsd", "provider.connectedMonthUsd", "provider.connectedKeyLimitUsd"] {
            try check(L10n.text(key, [], lang: .zh) != key && L10n.text(key, [], lang: .en) != key, "缺文案 \(key)")
        }
        try checkEqual(TokenChart.platformShort(.openrouter), "OpenRouter")
        try checkEqual(SettingsLayout.urgentAction(.openrouter, state: .invalid, hookGone: false, claudeSource: .terminal)?.kind, .apiKey)
        try check(SettingsLayout.accountActions(.openrouter, state: .ok, isMain: true).contains { $0.kind == .apiKey })
    }
    test("openRouterHasNoTokenTrendOrCacheStat") {
        func state(_ id: ProviderID, _ c: Currency) -> PlatformState {
            let snap = ProviderSnapshot(provider: id, balance: Money(amount: 8, currency: c), today: Money(amount: 2, currency: c),
                                        month: Money(amount: 3, currency: c), byModel: [], trend7: [], source: .bill,
                                        fetchedAt: now, credential: .ok)
            return PlatformState(id: id, snapshot: snap, burn: nil, status: .ok, lastSampleAt: nil)
        }
        let single = AppDataMapping.appData(main: state(.openrouter, .usd), others: [], now: now, timeZone: tz)
        try check(!BalanceEstimatePresentation.mainHasTokenDetail(single))
        try check(!BalanceEstimatePresentation.showsTokenTrend(single))
        try check(single.totalIsApprox, "美元按汇率换算，合计标约等")
        let mixed = AppDataMapping.appData(main: state(.openrouter, .usd), others: [state(.deepseek, .cny)], now: now, timeZone: tz)
        try check(BalanceEstimatePresentation.showsTokenTrend(mixed))
        let ds = AppDataMapping.appData(main: state(.deepseek, .cny), others: [], now: now, timeZone: tz)
        try check(BalanceEstimatePresentation.mainHasTokenDetail(ds))
    }
    test("alertLineSymbolFollowsPlatformCurrency") {
        // 设置「提醒」页：不是主平台时预警线符号原来写死「¥」，OpenRouter 是美元
        try checkEqual(SettingsLayout.alertSymbol(.openrouter, main: .deepseek, mainCurrency: "CNY"), "$")
        try checkEqual(SettingsLayout.alertSymbol(.kimi, main: .deepseek, mainCurrency: "CNY"), "¥")
        try checkEqual(SettingsLayout.alertSymbol(.openrouter, main: .openrouter, mainCurrency: "USD"), "$")
    }
    testAsync("openRouterTransientCreditsFailureKeepsLastAccountBalance") {
        // 读到过账户余额（Management Key）后 /credits 偶尔 5xx：沿用上次的账户余额，不跳到更高的 Key 上限再跳回来
        let http = SequencedOpenRouterHTTPClient(key: limitedKey, credits: [(200, #"{"data":{"total_credits":10,"total_usage":8}}"#), (502, "")])
        let p = OpenRouterProvider(http: http)
        try checkEqual(try await p.fetch(creds, now: now, timeZone: tz).get().balance, usd("2"))
        try checkEqual(try await p.fetch(creds, now: now, timeZone: tz).get().balance, usd("2"))
        // 换了一把 Key（可能是别的账户）：上一把 Key 的账户余额不能沿用，退回这把 Key 的上限
        let other = Credentials(values: ["apiKey": "sk-or-v1-other"])
        try checkEqual(try await p.fetch(other, now: now, timeZone: tz).get().balance, usd("74.5"))
    }
    testAsync("openRouterDailyAverageFromWeekOrMonth") {
        // 2026-10-15 14:00 UTC 周四：本月已 15 天、本周 4 天 → 用本月 25.5 / 15
        let s = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (403, forbidden)))
            .fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.dailyAverage, DailyAverage(perDay: Decimal(string: "25.5")! / 15, days: 15))
        // 2026-11-01 10:00 UTC 周日：本月才 1 天、本周 7 天 → 用本周 6.5 / 7
        let sunday = Date(timeIntervalSince1970: 1_793_527_200)
        let w = try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, limitedKey), credits: (403, forbidden)))
            .fetch(creds, now: sunday, timeZone: tz).get()
        try checkEqual(w.dailyAverage, DailyAverage(perDay: Decimal(string: "6.5")! / 7, days: 7))
    }
    test("burnUsesPlatformDailyAverageWhenNoDailyBill") {
        let t = Date(timeIntervalSince1970: 1_792_072_800)
        let b = BurnCalculator.stats(samples: [], now: t, tankRemaining: 34, weekCostByDay: [],
                                     dailyAverage: DailyAverage(perDay: 2, days: 15))
        try checkEqual(b.avgPerDayWeek, 2)
        try checkEqual(b.runwayDays, 17)
        try check(b.enoughData)
        // 只覆盖今天一天：和账单只有今天一样，不写续航
        let one = BurnCalculator.stats(samples: [], now: t, tankRemaining: 34, weekCostByDay: [],
                                       dailyAverage: DailyAverage(perDay: 2, days: 1))
        try checkEqual(one.runwayDays, nil)
    }
    testAsync("openRouterStoreUsesUtcMonthAndPlatformAverage") {
        // 北京时间 11/1 零点前后各取一次：本月累计（UTC 月）还没清零，不能当成新月把 $50 全算成这 10 分钟的花费
        var clockNow = Date(timeIntervalSince1970: 1_793_461_800)     // 2026-10-31 15:50 UTC = 11-01 前 23:50 +08
        let key = #"{"data":{"limit":100,"limit_remaining":50,"usage_daily":1,"usage_weekly":5,"usage_monthly":50}}"#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-or-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let cs = InMemoryCredentialStore()
        try cs.save(creds, for: .openrouter)
        let provider = OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, key), credits: (403, forbidden)))
        let store = UsageStore(providers: [provider], credentials: cs, samples: samples, intervalSeconds: 120,
                               clock: { clockNow }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults())
        await store.refresh()
        clockNow = clockNow.addingTimeInterval(600)
        await store.refresh()
        guard let burn = store.platforms.first(where: { $0.id == .openrouter })?.burn else { throw TestFailure(description: "没有续航数据") }
        try checkEqual(burn.perHourDay, 0)
        // 日均来自平台（本月 31 天 $50）→ 续航 = Key 剩余 $50 ÷ 日均
        try checkEqual(burn.avgPerDayWeek, Decimal(50) / 31)
        try checkEqual(burn.runwayDays, Decimal(50) / (Decimal(50) / 31))
        try check(ProviderRegistry.capabilities(.openrouter).billingTimeZone == TimeZone(identifier: "UTC"))
    }
    test("platformAverageDaysReachSideCard") {
        let b = BurnCalculator.stats(samples: [], now: now, tankRemaining: 10, weekCostByDay: [],
                                     dailyAverage: DailyAverage(perDay: 0, days: 3))
        try checkEqual(b.avgDays, 3)
        try checkEqual(BurnCalculator.stats(samples: [], now: now, tankRemaining: 10, weekCostByDay: [1, 1]).avgDays, nil)
        let st = PlatformState(id: .openrouter, snapshot: nil, burn: b, status: .ok, lastSampleAt: nil)
        let side = AppDataMapping.side(st, now: now, timeZone: tz)
        try checkEqual(side.avgDays, 3)
        try checkEqual(try JSONDecoder().decode(AppData.Side.self, from: JSONEncoder().encode(side)).avgDays, 3)
    }
}

/// /credits 按顺序返回预设结果（最后一个重复）
final class SequencedOpenRouterHTTPClient: HTTPClient, @unchecked Sendable {
    let key: String
    var credits: [(Int, String)]
    init(key: String, credits: [(Int, String)]) { self.key = key; self.credits = credits }
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        if url.path == "/api/v1/key" { return (200, Data(key.utf8)) }
        let r = credits.count > 1 ? credits.removeFirst() : credits[0]
        return (r.0, Data(r.1.utf8))
    }
}
