import Foundation

@MainActor
func registerSiliconFlowProviderTests() {
    // 2026-10-15 22:00 +08:00（样本明细时间都在此之前）
    let now = Date(timeIntervalSince1970: 1_792_072_800)
    let shanghai = TimeZone(secondsFromGMT: 28800)!
    let creds = Credentials(values: ["webToken": "tok-test", "subjectId": "sid-test-0001"])
    func cny(_ s: String) -> Money { Money(amount: Decimal(string: s)!, currency: .cny) }
    @Sendable func query(_ u: URL, _ name: String) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// 默认路由；overrides 按 host+path 末段替换（wallet / agg / items）
    func client(wallet: (Int, String) = (200, "wallet.json"),
                itemsFile: (@Sendable (Int) -> String)? = nil, agg: (Int, String)? = nil,
                console: (Int, String)? = nil) -> RoutedFixtureHTTPClient {
        RoutedFixtureHTTPClient(dir: "siliconflow") { url in
            switch url.path {
            case "/api/v1/subject/profile": return wallet
            case "/api/v1/bill/aggregate_amount":
                if let a = agg { return a }
                let start = Int(query(url, "startTime") ?? "0") ?? 0
                let end = Int(query(url, "endTime") ?? "0") ?? 0
                return (200, end - start > 86_400_000 ? "aggregate_month.json" : "aggregate_today.json")
            case "/api/v1/bill/items":
                let cur = Int(query(url, "current") ?? "1") ?? 1
                return (200, itemsFile?(cur) ?? "items_single.json")
            case "/me/bills": return console
            default: return nil
            }
        }
    }
    let paged: @Sendable (Int) -> String = { $0 == 1 ? "items_page1.json" : "items_page2.json" }

    testAsync("sfBalanceScale") {
        let s = try await SiliconFlowProvider(http: client()).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.balance, cny("27.07"))
        try checkEqual(s.provider, .siliconflow)
        try checkEqual(s.source, .bill)
    }
    testAsync("sfTodayMonthFromAggregate") {
        let http = client()
        let s = try await SiliconFlowProvider(http: http).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.today, cny("1.37"))
        try checkEqual(s.month, cny("4.87"))
        // 窗口：今日 0 点 / 本月 1 日 0 点（+08:00），毫秒
        let agg = http.requested.filter { $0.path.hasSuffix("aggregate_amount") }
        try checkEqual(agg.count, 2)
        try checkEqual(query(agg[0], "startTime"), "1791993600000")
        try checkEqual(query(agg[0], "endTime"), "1792072800000")
        try checkEqual(query(agg[1], "startTime"), "1790784000000")
    }
    testAsync("sfSendsCookieAndSubjectHeaders") {
        let http = client()
        _ = await SiliconFlowProvider(http: http).fetch(creds, now: now, timeZone: shanghai)
        let h = http.requestHeaders[0]
        try checkEqual(h["Cookie"], "__SF_auth.session-token=tok-test")
        try checkEqual(h["X-Subject-Id"], "sid-test-0001")
        try checkEqual(h["Origin"], "https://cloud.siliconflow.cn")
        try checkEqual(h["Referer"], "https://cloud.siliconflow.cn/me/bills")
        try checkEqual(h["accept-language"], "zh-CN")
    }
    testAsync("sfModelsFromItems") {
        let s = try await SiliconFlowProvider(http: client()).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.byModel.map { $0.model }, ["test-model-a", "test-model-b"])
        let a = s.byModel[0], b = s.byModel[1]
        // byModel 是今日（与 DeepSeek 一致，界面拿它算今日 token）；本月看 monthByModel
        try checkEqual(a.cost, cny("0.80")); try checkEqual(a.output, 80_000); try checkEqual(a.requests, 1)
        try checkEqual(b.cost, cny("0.57")); try checkEqual(b.output, 57_000); try checkEqual(b.requests, 1)
        try checkEqual(s.monthByModel?.map { $0.model }, ["test-model-a", "test-model-b"])
        try checkEqual(s.monthByModel?[0].cost, cny("2.80"))
    }
    testAsync("sfTrendFromIncurredAt") {
        let s = try await SiliconFlowProvider(http: client()).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.trend7.count, 7)
        try checkEqual(s.trend7.last?.day, "2026-10-15")
        let byDay = Dictionary(uniqueKeysWithValues: s.trend7.map { ($0.day, $0) })
        try checkEqual(byDay["2026-10-15"]?.cost, cny("1.37"))
        try checkEqual(byDay["2026-10-14"]?.cost, cny("2.00"))
        try checkEqual(byDay["2026-10-10"]?.cost, cny("1.50"))
        try checkEqual(byDay["2026-10-12"]?.cost, cny("0"))
        try checkEqual(byDay["2026-10-15"]?.models.count, 2)
    }
    testAsync("sfItemsStopAtLastPage") {
        let http = client()
        _ = try await SiliconFlowProvider(http: http).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(http.requested.filter { $0.path.hasSuffix("bill/items") }.count, 1)
    }
    testAsync("sfItemsFollowPages") {
        let http = client(itemsFile: paged)
        let s = try await SiliconFlowProvider(http: http, pageSize: 2).fetch(creds, now: now, timeZone: shanghai).get()
        let reqs = http.requested.filter { $0.path.hasSuffix("bill/items") }
        try checkEqual(reqs.map { query($0, "current") }, ["1", "2"])
        try checkEqual(reqs[0].query?.contains("pageSize=2"), true)
        try checkEqual(s.monthByModel?[0].cost, cny("2.80"))
        try checkEqual(s.monthByModel?.count, 2)
    }
    // 真实响应（Task 10 录制）的分页只有 current / pageSize / total，没有 pages
    testAsync("sfItemsPagesFromTotal") {
        let http = client(itemsFile: { $0 == 1 ? "items_nopages_page1.json" : "items_nopages_page2.json" })
        _ = try await SiliconFlowProvider(http: http, pageSize: 2).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(http.requested.filter { $0.path.hasSuffix("bill/items") }.map { query($0, "current") }, ["1", "2"])
    }
    // 整分支评审 I-2：明细只拉近 7 天（本地日界，可跨月）；本月汇总仍从 1 日起
    testAsync("sfItemsWindowIsLast7Days") {
        let http = client()
        let s = try await SiliconFlowProvider(http: http).fetch(creds, now: now, timeZone: shanghai).get()
        let items = http.requested.filter { $0.path.hasSuffix("bill/items") }
        try checkEqual(query(items[0], "startTime"), "1791475200000")      // 10-09 00:00 +08:00
        try checkEqual(query(items[0], "endTime"), "1792072800000")
        try checkEqual(s.detailTruncated, nil)
        // 10-15 时近 7 天盖不住本月 1–8 日：本月按模型不完整
        try checkEqual(s.monthByModelPartial, true)
    }
    testAsync("sfItemsWindowCrossesMonth") {
        let oct3 = Date(timeIntervalSince1970: 1_791_036_000)          // 2026-10-03 22:00 +08:00
        let http = client()
        let s = try await SiliconFlowProvider(http: http).fetch(creds, now: oct3, timeZone: shanghai).get()
        let items = http.requested.filter { $0.path.hasSuffix("bill/items") }
        try checkEqual(query(items[0], "startTime"), "1790438400000")      // 09-27 00:00 +08:00
        try checkEqual(s.trend7.map(\.day), ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30",
                                              "2026-10-01", "2026-10-02", "2026-10-03"])
        // 本月汇总仍从 10-01 起
        let agg = http.requested.filter { $0.path.hasSuffix("aggregate_amount") }
        try checkEqual(query(agg[1], "startTime"), "1790784000000")
        // 近 7 天盖住了本月全部、也没截断：本月按模型完整
        try checkEqual(s.monthByModelPartial, nil)
    }
    // 明细超过页数上限：只取到上限，标不完整（不再静默少算）
    testAsync("sfItemsTruncatedAtMaxPages") {
        let http = client(itemsFile: { _ in "items_many.json" })
        let s = try await SiliconFlowProvider(http: http, pageSize: 2).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(http.requested.filter { $0.path.hasSuffix("bill/items") }.count, SiliconFlowProvider.maxPages)
        try checkEqual(s.detailTruncated, true)
        try checkEqual(s.monthByModelPartial, true)
    }
    testAsync("sfMaxPagesCoversAWeekOfFiveMinuteRows") {
        // 真实明细约 5 分钟一行（每个模型每个计费项）：一个模型输入 + 输出一周约 4032 行
        try check(SiliconFlowProvider.maxPages * 100 >= 7 * 288 * 2, "页数上限盖不住一周")
    }
    testAsync("sfPagedNotTruncated") {
        let s = try await SiliconFlowProvider(http: client(itemsFile: paged), pageSize: 2)
            .fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.detailTruncated, nil)
    }
    testAsync("sfModelNameKeepsVersionDot") {
        try checkEqual(SiliconFlowProvider.item(["objectName": "qwen/qwen3-asr-1.7b.online.input-audio-seconds"]).model,
                       "qwen/qwen3-asr-1.7b")
        try checkEqual(SiliconFlowProvider.item(["objectName": "deepseek-ai/DeepSeek-V3.2.batch.output"]).model,
                       "deepseek-ai/DeepSeek-V3.2")
        // 合成样本的旧格式：最后一段是计费项
        try checkEqual(SiliconFlowProvider.item(["objectName": "test-model-a.输入"]).model, "test-model-a")
    }
    testAsync("sfRecordedResponses") {
        let http = client(wallet: (200, "recorded_wallet.json"), itemsFile: { _ in "recorded_items.json" },
                          agg: (200, "recorded_aggregate_month.json"))
        let s = try await SiliconFlowProvider(http: http).fetch(creds, now: now, timeZone: shanghai).get()
        try checkEqual(s.balance, cny("9.98152"))
        try checkEqual(s.month, cny("0.02"))
        try checkEqual(s.byModel.map(\.model), ["qwen/qwen3-asr-1.7b"])
        try checkEqual(s.byModel[0].output, 84)
        try checkEqual(s.byModel[0].cost, cny("0.01848"))
    }
    testAsync("sfAuthOn401") {
        let r = await SiliconFlowProvider(http: client(wallet: (401, "wallet.json"))).fetch(creds, now: now, timeZone: shanghai)
        guard case .failure(.auth) = r else { throw TestFailure(description: "期望 .auth，实际 \(r)") }
    }
    testAsync("sfBizCodeNot20000") {
        let r = await SiliconFlowProvider(http: client(wallet: (200, "biz_code_40001.json"))).fetch(creds, now: now, timeZone: shanghai)
        guard case .failure(.auth) = r else { throw TestFailure(description: "期望 .auth，实际 \(r)") }
        let r2 = await SiliconFlowProvider(http: client(wallet: (200, "wallet_no_financialinfo.json"))).fetch(creds, now: now, timeZone: shanghai)
        guard case .failure(.schemaChanged) = r2 else { throw TestFailure(description: "期望 .schemaChanged，实际 \(r2)") }
        let r3 = await SiliconFlowProvider(http: client(agg: (200, "biz_code_40001.json"))).fetch(creds, now: now, timeZone: shanghai)
        guard case .failure(.auth) = r3 else { throw TestFailure(description: "汇总业务码期望 .auth，实际 \(r3)") }
    }
    testAsync("sfRateLimitedOn429") {
        let r = await SiliconFlowProvider(http: client(wallet: (429, "wallet.json"))).fetch(creds, now: now, timeZone: shanghai)
        guard case .failure(.rateLimited) = r else { throw TestFailure(description: "期望 .rateLimited，实际 \(r)") }
    }
    testAsync("sfSubjectMissingIsAuth") {
        let c = Credentials(values: ["webToken": "tok-test"])
        let http = client(console: (200, "console_bills_no_subject.html"))
        let r = await SiliconFlowProvider(http: http).fetch(c, now: now, timeZone: shanghai)
        try checkEqual(r, .failure(.auth("硅基流动登录已失效")))
        try checkEqual(http.requested.count, 1)   // 页面解析不出就不再请求接口
    }
    testAsync("sfSubjectFromConsolePage") {
        let c = Credentials(values: ["webToken": "tok-test"])
        let http = client(console: (200, "console_bills.html"))
        let s = try await SiliconFlowProvider(http: http).fetch(c, now: now, timeZone: shanghai).get()
        try checkEqual(s.balance, cny("27.07"))
        try checkEqual(http.requestHeaders[1]["X-Subject-Id"], "sid-test-0001")
    }
    testAsync("sfMissingTokenIsAuth") {
        let r = await SiliconFlowProvider(http: client()).fetch(Credentials(values: [:]), now: now, timeZone: shanghai)
        try checkEqual(r, .failure(.auth("硅基流动登录已失效")))
    }
    testAsync("sfExpiringInThreeDays") {
        let exp = now.timeIntervalSince1970 + 2.5 * 86400
        let c = Credentials(values: ["webToken": "tok-test", "subjectId": "sid-test-0001", "webTokenExpiresAt": "\(Int(exp))"])
        let s = try await SiliconFlowProvider(http: client()).fetch(c, now: now, timeZone: shanghai).get()
        try checkEqual(s.credential, .expiring(days: 2))
    }
    testAsync("sfFarExpiryIsOk") {
        let exp = now.timeIntervalSince1970 + 20 * 86400
        let c = Credentials(values: ["webToken": "tok-test", "subjectId": "sid-test-0001", "webTokenExpiresAt": "\(Int(exp))"])
        let s = try await SiliconFlowProvider(http: client()).fetch(c, now: now, timeZone: shanghai).get()
        try checkEqual(s.credential, .ok)
    }
    testAsync("sfExpiredIsAuth") {
        let exp = now.timeIntervalSince1970 - 60
        let c = Credentials(values: ["webToken": "tok-test", "subjectId": "sid-test-0001", "webTokenExpiresAt": "\(Int(exp))"])
        let http = client()
        let r = await SiliconFlowProvider(http: http).fetch(c, now: now, timeZone: shanghai)
        guard case .failure(.auth) = r else { throw TestFailure(description: "期望 .auth，实际 \(r)") }
        try checkEqual(http.requested.count, 0)
    }
    test("parseSubjectId") {
        try checkEqual(SiliconFlowProvider.parseSubjectId(html: "<script>window.SF_SUBJECT_ID = 'sid-test-0001';</script>"), "sid-test-0001")
        try checkEqual(SiliconFlowProvider.parseSubjectId(html: "<html></html>"), nil)
    }
    test("sfCapabilities") {
        let p = SiliconFlowProvider(http: client())
        try checkEqual(p.capabilities.minPollInterval, 60)
        try check(p.capabilities.hasBalance && p.capabilities.currency == .cny)
        guard case .webLogin(let url, let required)? = p.loginSteps.first, p.loginSteps.count == 1 else { throw TestFailure(description: "loginSteps 不对") }
        try checkEqual(url.absoluteString, "https://cloud.siliconflow.cn/me/bills")
        try check(required)
    }
}
