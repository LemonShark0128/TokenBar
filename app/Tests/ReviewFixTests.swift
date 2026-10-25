import Foundation

/// 记录读取次数和线程；结果可设成找到 / 没有 / 出错
final class RecordingCredentialStore: CredentialStore, @unchecked Sendable {
    var result: CredentialRead
    private(set) var reads = 0
    private(set) var readOnMain: [Bool] = []
    private(set) var saved: Credentials?
    init(_ r: CredentialRead) { result = r }
    func read(_ p: ProviderID) -> CredentialRead {
        reads += 1
        readOnMain.append(Thread.isMainThread)
        return result
    }
    func save(_ c: Credentials, for p: ProviderID) throws { saved = c; result = .found(c) }
    func delete(_ p: ProviderID) throws { result = .notFound }
}

/// fetch 一直挂起，直到 release()；用来制造「上一轮还在取」
final class GatedProvider: UsageProvider, @unchecked Sendable {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    var id: ProviderID { .deepseek }
    var displayName: String { "Gated" }
    var capabilities: Capabilities { Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, dayBoundary: .local) }
    var loginSteps: [LoginStep] { [] }
    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        calls += 1
        if gate != nil { return .failure(.network("并发的第二次取数")) }   // 不覆盖第一个闸门，免得测试挂死
        await withCheckedContinuation { gate = $0 }
        return .success(snap(now))
    }
    var waiting: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
}

func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "tb-test-\(UUID().uuidString)")! }

@MainActor
func makeStore(_ p: UsageProvider, clock: FakeClock, cs: CredentialStore, defaults: UserDefaults) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    return UsageStore(providers: [p], credentials: cs, samples: samples, intervalSeconds: 120,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: defaults)
}

let someKey = Credentials(values: ["apiKey": "sk-test"])

final class SlowReviewCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Credentials(values: ["apiKey": "k1"])
    func read(_ p: ProviderID) -> CredentialRead {
        lock.lock(); defer { lock.unlock() }
        return .found(value)
    }
    func save(_ c: Credentials, for p: ProviderID) throws {
        usleep(300_000)
        lock.lock(); defer { lock.unlock() }
        value = c
    }
    func delete(_ p: ProviderID) throws {}
}

/// 只改指定端点的 JSON，其他响应沿用已有样本。
struct ReviewAmountHTTPClient: HTTPClient {
    var endpoint: String
    var json: String
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        if url.lastPathComponent == endpoint { return (200, Data(json.utf8)) }
        return try await FixtureHTTPClient().get(url, headers: headers)
    }
}

@MainActor
func registerReviewFixTests() {
    test("costKnownBySource") {
        for (source, known) in [("平台账单", true), ("只有余额", false), ("离线", false)] {
            try checkEqual(AppData.CostTok(costCny: 0, tokens: 0, source: source).known, known)
        }
    }
    test("accountStateWithoutFreshSnapshot") {
        let now = Date()
        for status: PlatformStatus in [.schemaChanged, .rateLimited(until: now), .stale(minutes: 1), .offline] {
            var st = PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: status)
            try checkEqual(AccountState.of(st), .offline)
            st.snapshot = snap(now); st.snapshotFromDisk = true
            try checkEqual(AccountState.of(st), .offline)
        }
        var st = PlatformState(id: .deepseek, snapshot: snap(now), burn: nil, status: .ok)
        try checkEqual(AccountState.of(st), .ok)
        st.snapshot?.source = .balanceOnly
        try checkEqual(AccountState.of(st), .balanceOnly)
    }
    test("strictAmountAcceptsZero") {
        try checkEqual(DeepSeekProvider.decStrict("0"), 0)
        try checkEqual(DeepSeekProvider.decStrict(NSNumber(value: 0)), 0)
    }

    testAsync("concurrentCredentialSavesMerge") {
        let clock = FakeClock(), cs = SlowReviewCredentialStore()
        let store = try makeStore(FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))]),
                                        clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        async let key: Void = store.saveCredentials(["apiKey": "k2"], for: .deepseek)
        async let token: Void = store.saveCredentials(["webToken": "t"], for: .deepseek)
        _ = try await (key, token)
        try checkEqual(cs.read(.deepseek), .found(Credentials(values: ["apiKey": "k2", "webToken": "t"])))
    }
    for (suffix, field) in [("Missing", ""), ("Invalid", #""total_balance":"oops""#)] {
        testAsync("deepseekBalance" + suffix) {
            let http = ReviewAmountHTTPClient(endpoint: "balance", json: "{\"balance_infos\":[{" + field + "}]}")
            let result = await DeepSeekProvider(http: http).fetchBalance("k")
            guard case .failure(.schemaChanged) = result else { throw TestFailure(description: "金额异常应为 schemaChanged") }
        }
    }
    for (suffix, field) in [("Missing", ""), ("Invalid", #""balance":"oops""#)] {
        testAsync("sfWallet" + suffix) {
            let http = ReviewAmountHTTPClient(endpoint: "profile", json: "{\"code\":20000,\"data\":{\"financialInfo\":{" + field + "}}}")
            let result = await SiliconFlowProvider(http: http).wallet(.init(headers: [:], credential: .ok))
            guard case .failure(.schemaChanged) = result else { throw TestFailure(description: "金额异常应为 schemaChanged") }
        }
    }
    for (suffix, field) in [("Missing", ""), ("Invalid", #""netAmount":"oops""#)] {
        testAsync("sfAggregate" + suffix) {
            let http = ReviewAmountHTTPClient(endpoint: "aggregate_amount", json: "{\"code\":20000,\"data\":{" + field + "}}")
            let result = await SiliconFlowProvider(http: http).aggregate(.init(headers: [:], credential: .ok), startMs: 0, endMs: 1)
            guard case .failure(.schemaChanged) = result else { throw TestFailure(description: "金额异常应为 schemaChanged") }
        }
    }

    // 审查 Important 1：钥匙串读取不在主线程，且只读一次
    testAsync("readsCredentialsOffMain") {
        let clock = FakeClock(), cs = RecordingCredentialStore(.found(someKey))
        let store = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        try checkEqual(cs.readOnMain, [false])
    }
    testAsync("credentialsReadOnceAcrossRefreshes") {
        let clock = FakeClock(), cs = RecordingCredentialStore(.found(someKey))
        let p = FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))])
        let store = try makeStore(p, clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        clock.now = clock.now.addingTimeInterval(600)
        await store.tick()
        try checkEqual(p.calls, 2)
        try checkEqual(cs.reads, 1)
    }
    // 审查 Important 2：没添加过 → 未添加；添加过但读不到 / 读出错 → 凭据失效
    testAsync("neverAddedIsNotAdded") {
        let clock = FakeClock(), p = FakeProvider([])
        let store = try makeStore(p, clock: clock, cs: RecordingCredentialStore(.notFound), defaults: freshDefaults())
        await store.refresh()
        try checkEqual(store.platforms[0].status, .notAdded)
        try checkEqual(p.calls, 0)
    }
    testAsync("addedThenMissingIsInvalid") {
        let clock = FakeClock(), defaults = freshDefaults()
        let first = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock,
                                        cs: RecordingCredentialStore(.found(someKey)), defaults: defaults)
        await first.refresh()
        let second = try makeStore(FakeProvider([]), clock: clock, cs: RecordingCredentialStore(.notFound), defaults: defaults)
        await second.refresh()
        try checkEqual(second.platforms[0].status, .credentialInvalid)
    }
    testAsync("readErrorIsInvalidNotNotAdded") {
        let clock = FakeClock()
        let store = try makeStore(FakeProvider([]), clock: clock, cs: RecordingCredentialStore(.error(-25293)),
                                        defaults: freshDefaults())
        await store.refresh()
        try checkEqual(store.platforms[0].status, .credentialInvalid)
    }
    testAsync("removeAccountMarksNotAdded") {
        let clock = FakeClock(), defaults = freshDefaults(), cs = RecordingCredentialStore(.found(someKey))
        let store = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cs: cs, defaults: defaults)
        await store.refresh()
        try await store.removeAccount(.deepseek)
        let st = store.platforms[0]
        try checkEqual(st.status, .notAdded)
        try check(st.snapshot == nil)
        let again = try makeStore(FakeProvider([]), clock: clock, cs: RecordingCredentialStore(.notFound), defaults: defaults)
        await again.refresh()
        try checkEqual(again.platforms[0].status, .notAdded)
    }
    testAsync("saveMergesWithExistingValues") {
        let clock = FakeClock(), cs = RecordingCredentialStore(.found(someKey))
        let store = try makeStore(FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))]),
                                        clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        try await store.saveCredentials(["webToken": "tok"], for: .deepseek)
        try checkEqual(cs.saved?.values, ["apiKey": "sk-test", "webToken": "tok"])
    }
    // 整分支评审 I-5：重新登录拿到会话型 Cookie（没有到期时间）时，空值表示删掉旧的到期时间
    testAsync("saveEmptyValueRemovesKey") {
        let clock = FakeClock()
        let cs = RecordingCredentialStore(.found(Credentials(values: ["webToken": "old", "webTokenExpiresAt": "1"])))
        let store = try makeStore(FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))]),
                                        clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        try await store.saveCredentials(["webToken": "new", "webTokenExpiresAt": ""], for: .deepseek)
        try checkEqual(cs.saved?.values, ["webToken": "new"])
    }
    // 审查 Important 7：同一平台不并发取数；手动刷新也遵守限流退避和凭据失效停止
    testAsync("tickSkipsWhileFetchInFlight") {
        let clock = FakeClock(), p = GatedProvider()
        let store = try makeStore(p, clock: clock, cs: RecordingCredentialStore(.found(someKey)), defaults: freshDefaults())
        let first = Task { await store.refresh() }
        for _ in 0..<200 where !p.waiting { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        clock.now = clock.now.addingTimeInterval(600)
        await store.tick()
        await store.refresh()
        try checkEqual(p.calls, 1)
        p.release()
        await first.value
    }
    testAsync("refreshRespectsRateLimitBackoff") {
        let clock = FakeClock(), p = FakeProvider([.failure(.rateLimited(retryAfter: nil)), .success(snap(clock.now))])
        let store = try makeStore(p, clock: clock, cs: RecordingCredentialStore(.found(someKey)), defaults: freshDefaults())
        await store.refresh()
        await store.refresh()
        try checkEqual(p.calls, 1)
    }
    testAsync("authStopsUntilCredentialsSaved") {
        let clock = FakeClock(), p = FakeProvider([.failure(.auth("HTTP 401")), .success(snap(clock.now))])
        let store = try makeStore(p, clock: clock, cs: RecordingCredentialStore(.found(someKey)), defaults: freshDefaults())
        await store.refresh()
        await store.refresh()
        try checkEqual(p.calls, 1)
        try await store.saveCredentials(["apiKey": "sk-new"], for: .deepseek)
        try checkEqual(p.calls, 2)
        try checkEqual(store.platforms[0].status, .ok)
    }
    // 第 7 条评审 I2：启动时读钥匙串被拒会记住失败；用户重新登录时要清掉失败再读，不能直接抛错
    testAsync("saveCredentialsRetriesAfterRememberedDenial") {
        let clock = FakeClock(), ops = FakeKeychainOperations(), defaults = freshDefaults()
        let cs = KeychainCredentialStore(servicePrefix: "fake", ops: ops, defaults: defaults)
        ops.copyStatus["fake.all|credentials"] = -128
        let store = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cs: cs, defaults: defaults)
        try checkEqual(await store.readCredentials(.deepseek), .error(-128))
        ops.copyStatus = [:]                     // 这次用户点了「允许」
        try await store.saveCredentials(["apiKey": "sk-test-new"], for: .deepseek)
        try checkEqual(cs.load(.deepseek), Credentials(values: ["apiKey": "sk-test-new"]))
    }
    // 审查 Important 6：默认时区跟随系统变化
    testAsync("defaultTimeZoneAutoupdates") {
        try checkEqual(UsageStore.defaultTimeZone(), TimeZone.autoupdatingCurrent)
    }
    // 审查 Important 3：没有 7 天日均（只有余额）时不报「花得比平时快」
    test("noSpikeWithoutWeekAverage") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let samples = (0...6).map { i in
            Sample(provider: .deepseek, t: now.addingTimeInterval(Double(i - 6) * 600),
                   balance: Decimal(30 - i), cumulativeCost: nil, currency: .cny)
        }
        let s = BurnCalculator.stats(samples: samples, now: now, tankRemaining: 24, weekCostByDay: [])
        try check(s.perHourRecent != nil, "前提：近 1 小时时速可算")
        try check(!s.spike, "没有 7 天日均时不应判定异常")
    }
    // 审查 Important 4：31 号也要从 1 号开始算本月
    testAsync("monthWindowCoversFirstOn31st") {
        let http = FixtureHTTPClient()
        let oct31noon = Date(timeIntervalSince1970: 1_793_419_200)      // 2026-10-31 12:00 +08:00
        let full = Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"])
        _ = await DeepSeekProvider(http: http).fetch(full, now: oct31noon, timeZone: TimeZone(secondsFromGMT: 28800)!)
        let starts = http.requested.filter { $0.lastPathComponent == "cost" }.compactMap { u in
            URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start" }?.value.flatMap(Int.init)
        }
        try check(starts.contains(1_790_784_000), "长窗口应从 10-01 00:00 +08 开始，实际 \(starts)")
    }
    // 审查 Important 8：控制台认不出 Key / 参数错误 → 降级为只有余额并说明原因，余额照常更新
    testAsync("unmatchedKeyDegradesToBalanceOnly") {
        let http = FixtureHTTPClient()
        http.overrides["get_api_keys"] = (200, "api_keys_nomatch.json")
        let full = Credentials(values: ["apiKey": "sk-zzzzzzzzzzzzzzzzzzzz", "webToken": "tok-test"])
        let s = try await DeepSeekProvider(http: http).fetch(full, now: Date(timeIntervalSince1970: 1_792_022_400),
                                                            timeZone: TimeZone(secondsFromGMT: 28800)!).get()
        try checkEqual(s.source, .balanceOnly)
        try checkEqual(s.balance?.amount, Decimal(string: "27.07")!)
        try checkEqual(s.consoleProblem, "控制台里没认出这把 Key")
    }
    // 审查 Important 5：冷启动断网、有历史采样 → 口径标「离线」，不当成「只有余额」
    test("offlineWithLastSampleIsTaggedOffline") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let st = PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .offline,
                               lastSampleAt: now.addingTimeInterval(-1800),
                               lastSample: Sample(provider: .deepseek, t: now.addingTimeInterval(-1800), balance: 27,
                                                  cumulativeCost: nil, currency: .cny))
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 28800)!)
        try checkEqual(d.today.source, "离线")
        try checkEqual(d.balance.ageS, 1800)
    }
    // 控制台对没用过的模型也返回全 0 的数据：不进模型明细，免得选项卡挤满空模型
    testAsync("unusedModelsAreDropped") {
        let http = FixtureHTTPClient()
        http.overrides["amount"] = (200, "amount_today_with_unused.json")
        let full = Credentials(values: ["apiKey": "sk-test000000000000abcd", "webToken": "tok-test"])
        let s = try await DeepSeekProvider(http: http).fetch(full, now: Date(timeIntervalSince1970: 1_792_022_400),
                                                            timeZone: TimeZone(secondsFromGMT: 28800)!).get()
        try checkEqual(s.byModel.map(\.model), ["deepseek-flash", "deepseek-v4-pro"])
        let dayModels = Set(s.trend7.flatMap { $0.models.map(\.model) })
        try check(!dayModels.contains("deepseek-chat & deepseek-reasoner"), "单日明细也不应有零用量模型：\(dayModels)")
    }
}
