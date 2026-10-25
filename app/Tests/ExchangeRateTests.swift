import Foundation

/// 汇率接口的假 client：固定返回一个状态码和响应体，记下请求过的 URL；throwing=true 时模拟断网
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class FakeRateClient: HTTPClient, @unchecked Sendable {
    var status = 200
    var body = ""
    var throwing = false
    private(set) var requested: [URL] = []

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        requested.append(url)
        if throwing { throw URLError(.notConnectedToInternet) }
        return (status, Data(body.utf8))
    }
}

@MainActor
func registerExchangeRateTests() {
    let now = Date(timeIntervalSince1970: 1_792_108_800)   // 2026-10-16 00:00:00 UTC（周五）
    // 照真实返回结构手写，数字是编的；接口会多给一天窗口之前的工作日（10-09），要丢掉
    let sample = """
    {"amount":1.0,"base":"USD","start_date":"2026-10-09","end_date":"2026-10-16","rates":{\
    "2026-10-09":{"CNY":9.0},"2026-10-12":{"CNY":7.1},"2026-10-13":{"CNY":7.2},\
    "2026-10-14":{"CNY":7.3},"2026-10-15":{"CNY":7.4},"2026-10-16":{"CNY":7.35}}}
    """
    func ok(_ r: Result<Decimal, ExchangeRateError>) throws -> Decimal {
        guard case .success(let v) = r else { throw TestFailure(description: "应成功，实际 \(r)") }
        return v
    }

    test("fxURLCoversLast7UTCDays") {
        let u = ExchangeRate.url(now: now)
        try checkEqual(u.absoluteString, "https://api.frankfurter.dev/v1/2026-10-10..2026-10-16?from=USD&to=CNY")
    }
    test("fxAverageSkipsWeekendAndOutOfWindow") {
        // 10-10、10-11 是周末没数据；10-09 在窗口外不算：(7.1+7.2+7.3+7.4+7.35)/5 = 7.27
        let v = try ok(ExchangeRate.average(Data(sample.utf8), from: "2026-10-10", to: "2026-10-16"))
        try checkEqual(v, Decimal(string: "7.27")!)
    }
    test("fxAverageRoundsTo4Places") {
        let body = #"{"rates":{"2026-10-14":{"CNY":7.1},"2026-10-15":{"CNY":7.2},"2026-10-16":{"CNY":7.2}}}"#
        let v = try ok(ExchangeRate.average(Data(body.utf8), from: "2026-10-10", to: "2026-10-16"))
        try checkEqual(v, Decimal(string: "7.1667")!)
    }
    test("fxAverageErrors") {
        func err(_ body: String) -> ExchangeRateError? {
            if case .failure(let e) = ExchangeRate.average(Data(body.utf8), from: "2026-10-10", to: "2026-10-16") { return e }
            return nil
        }
        try checkEqual(err("not json"), .badFormat)
        try checkEqual(err(#"{"amount":1.0}"#), .badFormat)
        try checkEqual(err(#"{"rates":{}}"#), .noData)
        try checkEqual(err(#"{"rates":{"2026-10-09":{"CNY":7.1}}}"#), .noData)          // 只有窗口外的
        try checkEqual(err(#"{"rates":{"2026-10-15":{"EUR":0.9}}}"#), .noData)          // 没有 CNY
        try checkEqual(err(#"{"rates":{"2026-10-15":{"CNY":0}}}"#), .outOfRange)
        try checkEqual(err(#"{"rates":{"2026-10-15":{"CNY":-7}}}"#), .outOfRange)
        try checkEqual(err(#"{"rates":{"2026-10-15":{"CNY":7.1},"2026-10-16":{"CNY":71}}}"#), .outOfRange)
        try checkEqual(err(#"{"rates":{"2026-10-15":{"CNY":0.5}}}"#), .outOfRange)
    }

    testAsync("fxRefreshWritesRateAndTimestamp") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = sample
        let logs = LogLines()
        let r = await ExchangeRate.refresh(client: c, defaults: d, now: now) { @Sendable in logs.add($0) }
        try checkEqual(r, Decimal(string: "7.27")!)
        try checkEqual(ProviderSettings.load(d).usdToCny, Decimal(string: "7.27")!)
        try checkEqual(ExchangeRate.lastUpdated(d), now)
        try checkEqual(c.requested.count, 1)
        try check(logs.lines.allSatisfy { !$0.contains("rates") }, "日志不能带响应内容")
    }
    testAsync("fxRefreshSkipsWithin24h") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.body = sample
        _ = await ExchangeRate.refresh(client: c, defaults: d, now: now) { @Sendable _ in }
        let again = await ExchangeRate.refresh(client: c, defaults: d, now: now.addingTimeInterval(23 * 3600)) { @Sendable _ in }
        try check(again == nil)
        try checkEqual(c.requested.count, 1)
        _ = await ExchangeRate.refresh(client: c, defaults: d, now: now.addingTimeInterval(24 * 3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 2)
        // 时钟被往回拨（上次更新时间在未来）：照样请求，不会卡住
        _ = await ExchangeRate.refresh(client: c, defaults: d, now: now.addingTimeInterval(-3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 3)
    }
    testAsync("fxRefreshFailureKeepsOldValue") {
        let d = freshDefaults()
        var s = ProviderSettings(); s.usdToCny = Decimal(string: "7.05")!; s.save(d)
        let old = now.addingTimeInterval(-2 * 86400)
        d.set(old.timeIntervalSince1970, forKey: ExchangeRate.updatedAtKey)
        for setup in [{ (c: FakeRateClient) in c.throwing = true },
                      { (c: FakeRateClient) in c.status = 500; c.body = "secret-body" },
                      { (c: FakeRateClient) in c.body = #"{"rates":{"2026-10-15":{"CNY":70}}}"# }] {
            let c = FakeRateClient(); setup(c)
            d.removeObject(forKey: ExchangeRate.failedAtKey)   // 每种失败各试一次，不受 6 小时退避影响
            let logs = LogLines()
            let r = await ExchangeRate.refresh(client: c, defaults: d, now: now) { @Sendable in logs.add($0) }
            try check(r == nil)
            try checkEqual(ProviderSettings.load(d).usdToCny, Decimal(string: "7.05")!)
            try checkEqual(ExchangeRate.lastUpdated(d), old)
            try checkEqual(logs.lines, ["汇率更新失败，沿用 ¥7.05"])
        }
    }
    // 直连失败（中国网络常见）时不要每小时等满超时：失败后 6 小时内不再请求，成功后清掉失败记录
    testAsync("fxRefreshBacksOff6hAfterFailure") {
        let d = freshDefaults()
        let c = FakeRateClient(); c.throwing = true
        _ = await ExchangeRate.refresh(client: c, defaults: d, now: now) { @Sendable _ in }
        try checkEqual(ExchangeRate.lastFailed(d), now)
        _ = await ExchangeRate.refresh(client: c, defaults: d, now: now.addingTimeInterval(5 * 3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 1)
        c.throwing = false; c.body = sample
        let r = await ExchangeRate.refresh(client: c, defaults: d, now: now.addingTimeInterval(6 * 3600)) { @Sendable _ in }
        try checkEqual(c.requested.count, 2)
        try checkEqual(r, Decimal(string: "7.27")!)
        try check(ExchangeRate.lastFailed(d) == nil, "成功后清掉失败记录")
    }
    test("fxCaption") {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let r = Decimal(string: "7.05")!
        func cap(updated: Date? = nil, failed: Date? = nil, manual: Bool = false) -> String {
            ExchangeRate.caption(rate: r, updated: updated, failedAt: failed, manual: manual, now: now, timeZone: tz)
        }
        try checkEqual(cap(), "默认值，联网后自动更新")
        // 老用户手填过、还没自动更新成功：显示的是手填的数，不能说「默认值」
        try checkEqual(cap(manual: true), "未自动更新")
        try checkEqual(cap(failed: now.addingTimeInterval(-3600)), "暂时无法获取，沿用 ¥7.05")
        try checkEqual(cap(failed: now.addingTimeInterval(-3600), manual: true), "暂时无法获取，沿用 ¥7.05")
        try checkEqual(cap(updated: now.addingTimeInterval(-3600)), "近 7 天平均 · 欧洲央行 · 10-16 更新")
        // 成功过但之后一直失败、数据已超过 2 天
        try checkEqual(cap(updated: now.addingTimeInterval(-3 * 86400), failed: now.addingTimeInterval(-3600)),
                       "暂时无法获取，沿用 10-13 的数据")
        // 刚失败一次、数据还新：照常显示更新日期
        try checkEqual(cap(updated: now.addingTimeInterval(-86400), failed: now.addingTimeInterval(-3600)),
                       "近 7 天平均 · 欧洲央行 · 10-15 更新")
    }
    test("fxCaptionFromDefaults") {
        let d = freshDefaults()
        try checkEqual(ExchangeRate.caption(d, now: now), "默认值，联网后自动更新")
        // 改预警线等也会 save 一遍设置（连带写入默认汇率）：仍算「默认值」
        ProviderSettings().save(d)
        try checkEqual(ExchangeRate.caption(d, now: now), "默认值，联网后自动更新")
        var s = ProviderSettings(); s.usdToCny = Decimal(string: "7.3")!; s.save(d)
        try checkEqual(ExchangeRate.caption(d, now: now), "未自动更新")
    }
    // 汇率请求走系统代理（直连 frankfurter 在中国网络下常失败）；平台请求仍直连
    test("httpClientProxyOption") {
        try checkEqual(URLSessionHTTPClient().session.configuration.connectionProxyDictionary?.count, 0)
        try check(URLSessionHTTPClient(systemProxy: true).session.configuration.connectionProxyDictionary == nil)
    }
    test("fxLastUpdatedNilByDefault") {
        try check(ExchangeRate.lastUpdated(freshDefaults()) == nil)
    }
}
