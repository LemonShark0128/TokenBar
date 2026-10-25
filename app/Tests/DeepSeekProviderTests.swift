import Foundation

/// 按 URL 路径返回样本；可替换某个端点的样本或状态码
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class FixtureHTTPClient: HTTPClient, @unchecked Sendable {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/deepseek")
    var overrides: [String: (Int, String)] = [:]   // 端点名 → (状态码, 样本文件)
    private(set) var requested: [URL] = []

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        requested.append(url)
        let name = url.lastPathComponent
        var file: String
        switch name {
        case "balance": file = "balance.json"
        case "get_user_summary": file = "summary.json"
        case "get_api_keys": file = "api_keys.json"
        case "amount", "cost":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = Int(q.first { $0.name == "start" }?.value ?? "0") ?? 0
            let end = Int(q.first { $0.name == "end" }?.value ?? "0") ?? 0
            file = "\(name)_\(end - start == 86400 ? "today" : "30d").json"
        default: return (404, Data())
        }
        var status = 200
        if let o = overrides[name] { status = o.0; file = o.1 }
        return (status, try Data(contentsOf: Self.dir.appendingPathComponent(file)))
    }
}

@MainActor
func registerDeepSeekProviderTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)          // 2026-10-15 08:00 +08:00
    let shanghai = TimeZone(secondsFromGMT: 28800)!
    let keyOnly = Credentials(values: ["apiKey": "sk-test000000000000abcd"])
    let full = Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"])

    testAsync("balanceParsesCny") {
        let r = await DeepSeekProvider(http: FixtureHTTPClient()).fetch(keyOnly, now: now, timeZone: shanghai)
        let s = try r.get()
        try checkEqual(s.balance, Money(amount: Decimal(string: "27.07")!, currency: .cny))
        try checkEqual(s.source, .balanceOnly)
    }
    testAsync("summaryAuthCode40003") {
        let http = FixtureHTTPClient()
        http.overrides["get_user_summary"] = (200, "summary_auth_failed.json")
        let s = try await DeepSeekProvider(http: http).fetch(full, now: now, timeZone: shanghai).get()
        try checkEqual(s.balance?.amount, Decimal(string: "27.07")!)
        try checkEqual(s.source, .balanceOnly)
        try check(s.consoleLoginNeeded, "控制台 40003 应标记需要重新登录控制台")
        try checkEqual(s.credential, .ok)
    }
    testAsync("bizCodeIsBadRequestNotAuth") {
        // 审查后改为：参数错误不让整轮失败，降级为只有余额并说明原因（不是登录失效）
        let http = FixtureHTTPClient()
        http.overrides["amount"] = (200, "biz_invalid_param.json")
        let s = try await DeepSeekProvider(http: http).fetch(full, now: now, timeZone: shanghai).get()
        try checkEqual(s.source, .balanceOnly)
        try check(!s.consoleLoginNeeded, "参数错误不是登录失效")
        try checkEqual(s.consoleProblem, "控制台拒绝了查询参数")
    }
    testAsync("balance401IsAuth") {
        let http = FixtureHTTPClient()
        http.overrides["balance"] = (401, "balance.json")
        let r = await DeepSeekProvider(http: http).fetch(keyOnly, now: now, timeZone: shanghai)
        guard case .failure(.auth) = r else { throw TestFailure(description: "应为 auth，实际 \(r)") }
    }
    test("matchKeyByMask") {
        let keys = [(sensitiveId: "sk-ab12********9999", trackingId: "tid-test-other", name: "other"),
                    (sensitiveId: "sk-test********abcd", trackingId: "tid-test-main", name: "x")]
        try checkEqual(DeepSeekProvider.matchKey(apiKey: "sk-test000000000000abcd", keys: keys), "tid-test-main")
    }
    test("matchKeyNoNameFallback") {
        let keys = [(sensitiveId: "sk-zz99********0000", trackingId: "tid-h", name: "TokenBar")]
        try checkEqual(DeepSeekProvider.matchKey(apiKey: "sk-test000000000000abcd", keys: keys), nil)
        try check(DeepSeekProvider.matchKey(apiKey: "sk-test000000000000abcd",
                                            keys: [(sensitiveId: "sk-zz99********0000", trackingId: "t", name: "a")]) == nil)
    }
    test("dayWindowShanghai") {
        let w = DeepSeekProvider.dayWindow(days: 1, tzSeconds: 28800, now: now)
        try checkEqual([w.start, w.end, w.tz], [1_791_993_600, 1_792_080_000, 28800])
    }
    test("dayWindowFollowsTimezone") {
        let w = DeepSeekProvider.dayWindow(days: 1, tzSeconds: -25200, now: now)
        try checkEqual([w.start, w.end, w.tz], [1_791_961_200, 1_792_047_600, -25200])
    }
    test("dayWindowHalfHourZone") {
        let w = DeepSeekProvider.dayWindow(days: 1, tzSeconds: 19800, now: now)
        try checkEqual([w.start, w.end, w.tz], [1_792_004_400, 1_792_090_800, 18000])
    }
    testAsync("fullSnapshot") {
        let s = try await DeepSeekProvider(http: FixtureHTTPClient()).fetch(full, now: now, timeZone: shanghai).get()
        try checkEqual(s.source, .bill)
        try checkEqual(s.today, Money(amount: Decimal(string: "6.27")!, currency: .cny))
        try checkEqual(s.month, Money(amount: Decimal(string: "38.99")!, currency: .cny))
        let flash = s.byModel.first { $0.model == "deepseek-flash" }
        try checkEqual(flash?.cacheHit, 55_182_976)
        try checkEqual(flash?.cacheMiss, 698_425)
        try checkEqual(flash?.output, 206_416)
        try checkEqual(flash?.requests, 276)
        try checkEqual(flash?.cost?.amount, Decimal(string: "2.68")!)
        try checkEqual(s.byModel.reduce(0) { $0 + $1.cacheHit + $1.cacheMiss + $1.output }, 63_290_808)
        try checkEqual(s.trend7.count, 7)
        try checkEqual(s.trend7.last?.day, "2026-10-15")
        try checkEqual(s.trend7.last?.tokens, 63_290_808)
        try checkEqual(s.trend7[5].tokens, 394_667_538)
        try checkEqual(s.trend7[5].cost?.amount, Decimal(string: "32.72")!)
        let day1014Flash = s.trend7[5].models.first { $0.model == "deepseek-flash" }
        try checkEqual(day1014Flash?.cacheHit, 384_801_407)
        try checkEqual(day1014Flash?.cost?.amount, Decimal(string: "32.72")!)
    }
    testAsync("dayWindowRecomputedPerFetch") {
        let http = FixtureHTTPClient()
        _ = await DeepSeekProvider(http: http).fetch(full, now: now, timeZone: TimeZone(secondsFromGMT: -25200)!)
        let q = http.requested.first { $0.lastPathComponent == "amount" }
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        try checkEqual(q.first { $0.name == "tz" }?.value, "-25200")
        try checkEqual(q.first { $0.name == "api_key_tracking_id" }?.value, "tid-test-main")
    }
    test("parsesUserTokenWrapped") {
        try checkEqual(DeepSeekProvider.extractUserToken(fromLocalStorageValue: #"{"value":"tok-abc","expire":0}"#), "tok-abc")
    }
    test("parsesUserTokenBare") {
        try checkEqual(DeepSeekProvider.extractUserToken(fromLocalStorageValue: "tok-abc"), "tok-abc")
        try check(DeepSeekProvider.extractUserToken(fromLocalStorageValue: "") == nil)
        try check(DeepSeekProvider.extractUserToken(fromLocalStorageValue: "null") == nil)
    }
    testAsync("validateShowsBalance") {
        let r = await DeepSeekProvider(http: FixtureHTTPClient()).validate(keyOnly)
        try checkEqual(r, .ok(summary: "已连接，余额 ¥27.07"))
    }
}
