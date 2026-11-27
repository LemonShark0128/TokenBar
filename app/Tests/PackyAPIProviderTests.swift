import Foundation

/// 按路径返回样本、记下请求的内联客户端（只在一个测试里顺序使用）
final class PackyHTTPClient: HTTPClient, @unchecked Sendable {
    var routes: [String: (Int, String)]
    /// stat 接口按 start_timestamp 区分今日 / 本月
    var stats: [Int: Decimal] = [:]
    private(set) var requests: [(URL, [String: String])] = []
    init(routes: [String: (Int, String)]) { self.routes = routes }
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        requests.append((url, headers))
        if url.path == "/api/log/self/stat" {
            let start = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "start_timestamp" }?.value.flatMap(Int.init) ?? -1
            guard let q = stats[start] else { return (500, Data()) }
            return (200, Data(#"{"data":{"quota":\#(q),"rpm":0,"tpm":0},"message":"","success":true}"#.utf8))
        }
        guard let r = routes[url.path] else { return (404, Data()) }
        return (r.0, Data(r.1.utf8))
    }
    func count(_ path: String) -> Int { requests.filter { $0.0.path == path }.count }
}

// PackyAPI（11-09 新平台）：控制台访问令牌 + 用户 ID；额度 ÷ quota_per_unit × price = 元
@MainActor
func registerPackyAPIProviderTests() {
    let tz = TimeZone(secondsFromGMT: 28800)!
    // 2026-11-09 12:00 北京时间
    let now = Date(timeIntervalSince1970: 1_794_196_800)
    let today0 = 1_794_153_600, month0 = 1_793_462_400           // 11-09 00:00、11-01 00:00（北京时间）
    let creds = Credentials(values: ["accessToken": "tok-test", "userId": "10086"])
    func cny(_ s: String) -> Money { Money(amount: Decimal(string: s)!, currency: .cny) }
    let status = #"{"data":{"quota_per_unit":500000,"price":1,"quota_display_type":"USD","usd_exchange_rate":7},"success":true}"#
    let me = #"{"data":{"id":10086,"quota":56257777,"used_quota":4242223,"group":"default"},"message":"","success":true}"#
    // 今天 10 点 opus 两行（同模型不同小时）、11 点 sonnet；昨天 23 点（北京时间）一行；8 天前一行（窗口外）
    let rows = #"""
    {"data":[
      {"model_name":"claude-opus-5-5","created_at":1794189600,"token_used":141,"count":3,"quota":369484},
      {"model_name":"claude-opus-5-5","created_at":1794193200,"token_used":59,"count":1,"quota":130516},
      {"model_name":"claude-sonnet-5","created_at":1794193200,"token_used":4752,"count":48,"quota":1117613},
      {"model_name":"claude-sonnet-5","created_at":1794150000,"token_used":1000,"count":2,"quota":250000},
      {"model_name":"old","created_at":1793500000,"token_used":1,"count":1,"quota":1}
    ],"message":"","success":true}
    """#
    func client() -> PackyHTTPClient {
        let c = PackyHTTPClient(routes: ["/api/status": (200, status), "/api/user/self": (200, me), "/api/data/self": (200, rows)])
        c.stats = [today0: 1_617_613, month0: 4_242_223]
        return c
    }

    test("packyRatioIsPriceOverQuotaPerUnit") {
        let obj = try JSONSerialization.jsonObject(with: Data(status.utf8)) as! [String: Any]
        try checkEqual(try PackyAPIProvider.parseRatio(obj).get() * 500000, 1)
        for bad in [#"{"data":{"price":1}}"#, #"{"data":{"quota_per_unit":0,"price":1}}"#, #"{"data":{"quota_per_unit":500000,"price":"1"}}"#] {
            let o = try JSONSerialization.jsonObject(with: Data(bad.utf8)) as! [String: Any]
            guard case .failure(.schemaChanged) = PackyAPIProvider.parseRatio(o) else {
                throw TestFailure(description: "应判格式变化：\(bad)")
            }
        }
    }
    test("packyEnvelopeSortsErrors") {
        func e(_ status: Int, _ body: String) -> ProviderError? {
            if case .failure(let x) = PackyAPIProvider.envelope(status: status, data: Data(body.utf8), path: "/api/user/self?x=1") { return x }
            return nil
        }
        // 令牌无效：new-api 回 200 + success=false
        guard case .auth? = e(200, #"{"message":"无权进行此操作，access token 无效","success":false}"#) else { throw TestFailure(description: "令牌无效应判 auth") }
        guard case .auth? = e(401, #"{"message":"无权进行此操作，未登录且未提供 access token","success":false}"#) else { throw TestFailure(description: "401 应判 auth") }
        guard case .network? = e(200, #"{"message":"数据库繁忙","success":false}"#) else { throw TestFailure(description: "其他业务失败不是凭据问题") }
        // Cloudflare 拦截是 403 + HTML，不能当成令牌失效
        guard case .network(let m)? = e(403, "<!DOCTYPE html><title>Attention Required! | Cloudflare</title>") else { throw TestFailure(description: "CF 403 应判 network") }
        try check(m.contains("Cloudflare") && !m.contains("?"), "说明里写 Cloudflare、不带查询参数")
        guard case .rateLimited? = e(429, "") else { throw TestFailure(description: "429 应判限流") }
        guard case .schemaChanged? = e(200, "not json") else { throw TestFailure(description: "非 JSON 应判格式变化") }
        // 200 但回的是网页（公共 Wi-Fi 登录页）：网络问题
        guard case .network? = e(200, "<html><body>Wi-Fi login</body></html>") else { throw TestFailure(description: "HTML 应判 network") }
        try check(e(200, #"{"data":{},"success":true}"#) == nil)
    }
    test("packySessionNeedsNumericUserIdAndSendsHeaders") {
        let p = PackyAPIProvider(http: PackyHTTPClient(routes: [:]))
        for bad in [["accessToken": "t", "userId": "abc"], ["accessToken": "t", "userId": ""], ["accessToken": "", "userId": "1"],
                    ["accessToken": "t", "userId": "１２"]] {
            guard case .failure(.auth) = p.session(Credentials(values: bad)) else { throw TestFailure(description: "应判凭据不对：\(bad)") }
        }
        let s = try p.session(Credentials(values: ["accessToken": " tok ", "userId": " 42\n"])).get()
        try checkEqual(s.headers["Authorization"], "Bearer tok")
        try checkEqual(s.headers["New-Api-User"], "42")
    }
    test("packyRowsAllowNullData") {
        let o = try JSONSerialization.jsonObject(with: Data(#"{"data":null,"success":true}"#.utf8)) as! [String: Any]
        try checkEqual(try PackyAPIProvider.parseRows(o).get(), [])
        let bad = try JSONSerialization.jsonObject(with: Data(#"{"data":[{"model_name":"m","quota":1}],"success":true}"#.utf8)) as! [String: Any]
        guard case .failure(.schemaChanged) = PackyAPIProvider.parseRows(bad) else { throw TestFailure(description: "缺 created_at 应判格式变化") }
    }
    testAsync("packyFetchBuildsCnySnapshot") {
        let http = client()
        let s = try await PackyAPIProvider(http: http).fetch(creds, now: now, timeZone: tz).get()
        try checkEqual(s.provider, .packyapi)
        try checkEqual(s.source, .bill)
        try checkEqual(s.balance, cny("112.515554"))
        try checkEqual(s.today, cny("3.235226"))
        try checkEqual(s.month, cny("8.484446"))
        // 近 7 天按北京时间分日：今天 3 行、昨天 1 行，8 天前的不算
        try checkEqual(s.trend7.map(\.day), ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09"])
        try checkEqual(s.trend7.last?.tokens, 4952)
        try checkEqual(s.trend7.last?.cost, cny("3.235226"))
        try checkEqual(s.trend7[5].cost, cny("0.5"))
        try checkEqual(s.byModel.map(\.model), ["claude-sonnet-5", "claude-opus-5-5"])
        try checkEqual(s.byModel.last?.output, 200)
        try checkEqual(s.byModel.last?.requests, 4)
        try checkEqual(s.byModel.last?.cost, cny("1"))
        try checkEqual(s.monthByModel?.first?.model, "claude-sonnet-5")
        try checkEqual(s.monthByModelPartial, true)    // 明细从 11-03 起，本月 1、2 号的按模型没拉
        // 每个控制台接口都带 New-Api-User；公开的 /api/status 不带令牌
        for (url, h) in http.requests where url.path != "/api/status" {
            try checkEqual(h["New-Api-User"], "10086")
            try checkEqual(h["Authorization"], "Bearer tok-test")
        }
        try check(http.requests.first { $0.0.path == "/api/status" }?.1["Authorization"] == nil, "status 不带令牌")
    }
    testAsync("packyMonthByModelPartialEarlyInMonth") {
        let http = client()
        let nov3 = Date(timeIntervalSince1970: 1_793_678_400)      // 11-03 12:00 北京时间
        http.stats = [1_793_635_200: 0, month0: 0]
        let s = try await PackyAPIProvider(http: http).fetch(creds, now: nov3, timeZone: tz).get()
        try checkEqual(s.monthByModelPartial, nil)     // 7 天窗口从 10-28 起，盖住了整个本月
        let nov20 = Date(timeIntervalSince1970: 1_795_147_200)     // 11-20 12:00
        http.stats = [1_795_104_000: 0, month0: 0]
        let t = try await PackyAPIProvider(http: http).fetch(creds, now: nov20, timeZone: tz).get()
        try checkEqual(t.monthByModelPartial, true)
    }
    testAsync("packyRatioCachedAndReusedWhenStatusFails") {
        let http = client()
        let p = PackyAPIProvider(http: http)
        _ = try await p.fetch(creds, now: now, timeZone: tz).get()
        _ = try await p.fetch(creds, now: now.addingTimeInterval(60), timeZone: tz).get()
        try checkEqual(http.count("/api/status"), 1)     // 6 小时内不重拉
        // 过期后重拉失败：沿用旧比例，不让整次取数失败
        http.routes["/api/status"] = (502, "")
        let s = try await p.fetch(creds, now: now.addingTimeInterval(7 * 3600), timeZone: tz).get()
        try checkEqual(http.count("/api/status"), 2)
        try checkEqual(s.balance, cny("112.515554"))
        // 从没拉到过比例：整次失败
        guard case .failure(.network) = await PackyAPIProvider(http: http).fetch(creds, now: now, timeZone: tz) else {
            throw TestFailure(description: "没有换算比例时不能出数")
        }
    }
    testAsync("packyDayBucketsFollowTimeZone") {
        // 同一批明细按 UTC 分日：北京时间 11-09 10:00 / 11:00 是 UTC 02:00 / 03:00，仍是 11-09；
        // 北京时间 11-08 23:00 是 UTC 15:00 的 11-08
        let utc = TimeZone(identifier: "UTC")!
        let http = client()
        let utcToday0 = 1_794_182_400, utcMonth0 = 1_793_491_200     // 11-09 00:00Z、11-01 00:00Z
        http.stats = [utcToday0: 0, utcMonth0: 0]
        let s = try await PackyAPIProvider(http: http).fetch(creds, now: now, timeZone: utc).get()
        try checkEqual(s.trend7.last?.day, "2026-11-09")
        try checkEqual(s.trend7.last?.tokens, 4952)
        try checkEqual(s.trend7[5].tokens, 1000)
        // 纽约（UTC-5）：北京时间 11-09 10:00 是纽约 11-08 21:00，今天（纽约 11-08 23:00）四行都在 11-08
        let ny = TimeZone(identifier: "America/New_York")!
        http.stats = [1_794_114_000: 0, 1_793_505_600: 0]          // 11-08 00:00 EST、11-01 00:00 EDT
        let t = try await PackyAPIProvider(http: http).fetch(creds, now: now, timeZone: ny).get()
        try checkEqual(t.trend7.last?.day, "2026-11-08")
        try checkEqual(t.trend7.last?.tokens, 5952)
    }
    testAsync("packyRateLimitedStatusDoesNotReuseOldRatio") {
        let http = client()
        let p = PackyAPIProvider(http: http)
        _ = try await p.fetch(creds, now: now, timeZone: tz).get()
        http.routes["/api/status"] = (429, "")
        guard case .failure(.rateLimited) = await p.fetch(creds, now: now.addingTimeInterval(7 * 3600), timeZone: tz) else {
            throw TestFailure(description: "限流要整次退避，不能沿用旧比例接着发请求")
        }
    }
    testAsync("packyValidateShowsLocalFormatProblem") {
        let r = await PackyAPIProvider(http: client()).validate(Credentials(values: ["accessToken": "t", "userId": "ID: 10086"]))
        try checkEqual(ValidationCopy.message(for: r, provider: .packyapi), "用户 ID 应该是一串数字")
    }
    testAsync("packyValidateSummaryAndInvalidToken") {
        let ok = await PackyAPIProvider(http: client()).validate(creds)
        try checkEqual(ok, .ok(summary: "已连接，余额 ¥112.52"))
        let http = client()
        http.routes["/api/user/self"] = (200, #"{"message":"无权进行此操作，access token 无效","success":false}"#)
        let r = await PackyAPIProvider(http: http).validate(creds)
        guard case .failed(.auth) = r else { throw TestFailure(description: "令牌无效应判 auth") }
        try checkEqual(ValidationCopy.message(for: r, provider: .packyapi), "用户 ID 或访问令牌不对，请检查后重新填写")
    }
    test("packyCredentialCopySaysAccessToken") {
        try checkEqual(ProviderRegistry.credentialKind(.packyapi), .accessToken)
        try checkEqual(StatusPresenter.errorText(.credentialInvalid, name: "PackyAPI", id: .packyapi),
                       "PackyAPI 的访问令牌无效，请在设置里更换访问令牌")
        try checkEqual(AccountState.invalid.label(for: .packyapi), "访问令牌无效")
        try checkEqual(SettingsLayout.urgentAction(.packyapi, state: .invalid, hookGone: false, claudeSource: .terminal)?.title, "更换访问令牌")
        try checkEqual(ProviderRegistry.currency(.packyapi), .cny)
    }
}
