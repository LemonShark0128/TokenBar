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
    private(set) var cleared = 0
    func clearFailure() { cleared += 1 }
}

/// fetch 一直挂起，直到 release()；用来制造「上一轮还在取」
final class GatedProvider: UsageProvider, @unchecked Sendable {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    var id: ProviderID { .deepseek }
    var capabilities: Capabilities { Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60) }
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

/// 测试用 UserDefaults 的 suite 名：临时目录里的绝对路径，plist 就写进那个目录（test.sh 跑完连目录一起删）。
/// 以前用普通名字，每跑一次在 ~/Library/Preferences 留几十个 tb-*.plist（removePersistentDomain 也只清空不删文件）
let testDefaultsDir: String = {
    let dir = NSTemporaryDirectory() + "tb-defaults-\(UUID().uuidString)"
    // 建不出来就直接报错：否则 plist 写不进磁盘，测试可能照样通过，问题被藏住
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    catch { fatalError("建不了测试用 defaults 目录 \(dir)：\(error)") }
    return dir
}()
func testSuiteName(_ tag: String = "test") -> String { testDefaultsDir + "/\(tag)-\(UUID().uuidString)" }
func freshDefaults() -> UserDefaults { UserDefaults(suiteName: testSuiteName())! }

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

/// read() 挂起直到 release()（在后台线程等），用来制造「读钥匙串途中移除平台」
final class GatedCredentialStore: CredentialStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var startedFlag = false
    private var readCount = 0
    private var clearedFlag = false
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var cleared: Bool { lock.lock(); defer { lock.unlock() }; return clearedFlag }
    func clearFailure() { lock.lock(); clearedFlag = true; lock.unlock() }
    private var value: CredentialRead
    init(initial: Credentials = someKey) { value = .found(initial) }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return startedFlag }
    func read(_ p: ProviderID) -> CredentialRead {
        lock.lock(); let gated = !startedFlag; startedFlag = true; readCount += 1; let v = value; lock.unlock()
        if gated { gate.wait() }   // 只拦第一次读：读到的是移除前的旧凭据
        return v
    }
    func release() { gate.signal() }
    func save(_ c: Credentials, for p: ProviderID) throws { lock.lock(); value = .found(c); lock.unlock() }
    func delete(_ p: ProviderID) throws { lock.lock(); value = .notFound; lock.unlock() }
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
        // 11/6 用户定 proposal-keychain-error-ui 乙：读钥匙串出错是单独的状态，不再写成「凭据失效 / API Key 无效」
        try checkEqual(store.platforms[0].status, .keychainUnreadable(status: -25293))
    }
    // 被拒绝后点「重试」：清掉记住的失败、重新读一次，读到就恢复；锁着的不用重试（下一轮自动读）
    testAsync("keychainRetryReadsAgain") {
        let clock = FakeClock(), cs = RecordingCredentialStore(.error(-128))
        let p = FakeProvider([.success(snap(clock.now))])
        let store = try makeStore(p, clock: clock, cs: cs, defaults: freshDefaults())
        await store.refresh()
        try checkEqual(store.platforms[0].status, .keychainUnreadable(status: -128))
        await store.refresh()
        try checkEqual(cs.reads, 1)          // 被拒绝后停下，不反复弹框
        cs.result = .found(someKey)
        await store.retryKeychain()
        try checkEqual(cs.cleared, 1)
        try checkEqual(cs.reads, 2)
        try checkEqual(store.platforms[0].status, .ok)
        try checkEqual(p.calls, 1)
        // 没有读不到钥匙串的平台时，重试什么也不做
        await store.retryKeychain()
        try checkEqual(cs.cleared, 1)
        // 重试后仍被拒绝：照旧是读不到钥匙串、停下
        let cs2 = RecordingCredentialStore(.error(-128))
        let again = try makeStore(FakeProvider([]), clock: clock, cs: cs2, defaults: freshDefaults())
        await again.refresh()
        await again.retryKeychain()
        try checkEqual(again.platforms[0].status, .keychainUnreadable(status: -128))
        await again.refresh()
        try checkEqual(cs2.reads, 2)
    }
    testAsync("keychainReadErrorLogsOncePerCode") {
        // 读钥匙串失败要记日志（带错误码），同一错误码不重复记；读到凭据记「恢复」
        let clock = FakeClock(), cs = RecordingCredentialStore(.error(-25308))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        let store = UsageStore(providers: [FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))])], credentials: cs,
                               samples: try SampleStore(path: dir.appendingPathComponent("s.sqlite").path), intervalSeconds: 120,
                               clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults(),
                               log: { lines.append($0) })
        let name = ProviderRegistry.logName(.deepseek)
        await store.refresh()
        await store.refresh()
        try checkEqual(cs.reads, 2)   // 锁着不停自动刷新，下一轮还会读
        try checkEqual(lines, ["\(name) 读钥匙串失败（-25308 钥匙串已锁），下一轮自动重试"])
        cs.result = .found(someKey)
        await store.refresh()
        try checkEqual(lines.last, "\(name) 读钥匙串恢复")
        try checkEqual(store.platforms[0].status, .ok)
        // 换一个 store（缓存为空）：先锁着，再被拒绝 → 错误码变了再记一行；拒绝后已停，再刷新不重复
        lines = []
        cs.result = .error(-25308)
        let again = UsageStore(providers: [FakeProvider([])], credentials: cs,
                               samples: try SampleStore(path: dir.appendingPathComponent("s2.sqlite").path), intervalSeconds: 120,
                               clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults(),
                               log: { lines.append($0) })
        await again.refresh()
        cs.result = .error(-128)
        await again.refresh()
        await again.refresh()
        try checkEqual(lines, ["\(name) 读钥匙串失败（-25308 钥匙串已锁），下一轮自动重试",
                               "\(name) 读钥匙串失败（-128 用户拒绝），已停止自动刷新，点面板里的「重试」或重新登录后恢复"])
        try checkEqual(again.platforms[0].status, .keychainUnreadable(status: -128))
        try checkEqual(UsageStore.keychainFailureLog("Kimi", -34018), "Kimi 读钥匙串失败（-34018），已停止自动刷新，点面板里的「重试」或重新登录后恢复")
        try checkEqual(UsageStore.keychainFailureLog("Kimi", -26276), "Kimi 读钥匙串失败（-26276 凭据数据损坏），已停止自动刷新，点面板里的「重试」或重新登录后恢复")
    }
    testAsync("removeDuringKeychainReadStaysRemoved") {
        // 读钥匙串途中移除平台：读回来的旧凭据不能再写回缓存和「已添加」，平台保持未添加
        let clock = FakeClock(), defaults = freshDefaults(), cs = GatedCredentialStore()
        let p = FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))])
        let store = try makeStore(p, clock: clock, cs: cs, defaults: defaults)
        async let first: Void = store.refresh()
        defer { cs.release() }   // 中途抛错也放行闸门，免得测试挂死
        var spins = 0
        while !cs.started { await Task.yield(); spins += 1; if spins > 100_000 { throw TestFailure(description: "读取没有开始") } }
        try await store.removeAccount(.deepseek)
        cs.release()
        await first
        try checkEqual(store.platforms[0].status, .notAdded)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .notAdded)
        // 重启（新 store、同一份 UserDefaults）后也是未添加，不是「凭据失效」
        let again = try makeStore(FakeProvider([]), clock: clock, cs: RecordingCredentialStore(.notFound), defaults: defaults)
        await again.refresh()
        try checkEqual(again.platforms[0].status, .notAdded)
    }
    testAsync("reloginRightAfterRemoveDropsOldFields") {
        // 移除时旧读取还在途，马上重新登录只填 apiKey：等着共用旧读取的保存不能把旧 webToken 合并回钥匙串
        let clock = FakeClock(), cs = GatedCredentialStore(initial: Credentials(values: ["apiKey": "old", "webToken": "oldToken"]))
        let store = try makeStore(FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))]),
                                  clock: clock, cs: cs, defaults: freshDefaults())
        async let first: Void = store.refresh()
        defer { cs.release() }
        var spins = 0
        while !cs.started { await Task.yield(); spins += 1; if spins > 100_000 { throw TestFailure(description: "读取没有开始") } }
        try await store.removeAccount(.deepseek)
        async let save: Void = store.saveCredentials(["apiKey": "new"], for: .deepseek)
        // 等保存清完上次拒绝、走到读凭据并开始等在途的旧读取，再放行
        spins = 0
        while !cs.cleared { await Task.yield(); spins += 1; if spins > 100_000 { throw TestFailure(description: "保存没有开始") } }
        for _ in 0..<50 { await Task.yield() }
        cs.release()
        await first
        try await save
        try checkEqual(cs.reads, 1)   // 保存确实共用了那次旧读取（自己另读就没测到这条路）
        try checkEqual(cs.read(.deepseek), .found(Credentials(values: ["apiKey": "new"])))
    }
    testAsync("stuckTickDoesNotRefetchLaterPlatform") {
        // 上一拍卡在 DeepSeek 时，下一拍取了硅基流动；卡住的那拍醒来不能拿旧时刻把硅基流动当成「时钟回拨」再取一次
        let clock = FakeClock(), slow = GatedProvider()
        let sf = FakeProvider([.success(snap(clock.now)), .success(snap(clock.now))], id: .siliconflow)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = UsageStore(providers: [slow, sf], credentials: RecordingCredentialStore(.found(someKey)),
                               samples: try SampleStore(path: dir.appendingPathComponent("s.sqlite").path), intervalSeconds: 120,
                               clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults())
        async let stuck: Void = store.tick()
        defer { slow.release() }
        for _ in 0..<200 where !slow.waiting { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        try check(slow.waiting, "DeepSeek 没开始取")
        clock.now = clock.now.addingTimeInterval(15)
        await store.tick()                       // 下一拍：DeepSeek 在途跳过，取硅基流动
        try checkEqual(sf.calls, 1)
        clock.now = clock.now.addingTimeInterval(10)
        slow.release()
        await stuck
        try checkEqual(sf.calls, 1)
        try checkEqual(slow.calls, 1)
    }
    testAsync("platformDueDuringStuckTickAnchorsAtDueTime") {
        // 硅基流动 T0+20 到点；T0 那拍卡在 DeepSeek 到 T0+25 才轮到它：下次到点 = 原到点 + 间隔，不是 T0 + 间隔
        let clock = FakeClock(), slow = GatedProvider()
        let sf = FakeProvider([.success(snap(clock.now)), .success(snap(clock.now)), .success(snap(clock.now))], id: .siliconflow)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = UsageStore(providers: [slow, sf], credentials: RecordingCredentialStore(.found(someKey)),
                               samples: try SampleStore(path: dir.appendingPathComponent("s.sqlite").path), intervalSeconds: 120,
                               clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults())
        let start = clock.now
        await store.refresh(.siliconflow)        // 硅基流动 start 取过，start+120 到点
        clock.now = start.addingTimeInterval(100)
        let t0 = clock.now
        async let stuck: Void = store.tick()     // DeepSeek 卡住（硅基流动还没到点）
        defer { slow.release() }
        for _ in 0..<200 where !slow.waiting { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        try check(slow.waiting, "DeepSeek 没开始取")
        clock.now = t0.addingTimeInterval(25)    // 卡到 start+125，此时硅基流动已到点
        slow.release()
        await stuck
        try checkEqual(sf.calls, 2)
        try checkEqual(store.nextDueAt(.siliconflow), start.addingTimeInterval(240))
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
        let clock = FakeClock(), p = FakeProvider([.failure(.rateLimited), .success(snap(clock.now))])
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
