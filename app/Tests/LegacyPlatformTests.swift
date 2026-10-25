import Foundation
import SQLite3

/// 去掉 Claude / OpenAI 按量付费平台（Admin API）后，老用户残留数据要安静地消失：不报错、不崩溃
@MainActor
func registerLegacyPlatformTests() {
    test("adminPlatformsRemovedFromProviderID") {
        try check(ProviderID(rawValue: "claude") == nil, "claude 不再是平台")
        try check(ProviderID(rawValue: "openai") == nil, "openai 不再是平台")
        try checkEqual(ProviderID.allCases, [.deepseek, .siliconflow, .codexPlan, .claudePlan])
        try checkEqual(ProviderRegistry.all, [.deepseek, .siliconflow, .codexPlan, .claudePlan])
    }

    @MainActor func makeLegacyStore(_ d: UserDefaults, ids: [ProviderID] = [.deepseek, .siliconflow]) throws -> UsageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let clock = FakeClock()
        return UsageStore(providers: ids.map { FakeProvider([], id: $0) }, credentials: InMemoryCredentialStore(),
                          samples: samples, intervalSeconds: 120, clock: { clock.now }, defaults: d,
                          settings: { ProviderSettings() })
    }

    // 老用户把 OpenAI 设成了主平台：加载不崩，主平台落到仍存在的平台；「自动切换」开关不因此丢失
    testAsync("legacyMainSwitchOpenAIFallsBack") {
        let d = freshDefaults()
        d.set(Data(#"{"main":"openai","auto":false}"#.utf8), forKey: "mainSwitch")
        let store = try makeLegacyStore(d)
        let main = store.mainProvider
        try check(ProviderID.allCases.contains(main))
        try checkEqual(main, .deepseek)
        try checkEqual(store.switchState.auto, false)
    }
    // 正在计时的候选平台是 Claude：只丢掉候选，主平台和其余设置保留
    testAsync("legacyMainSwitchLeaderDropped") {
        let d = freshDefaults()
        d.set(Data(#"{"main":"siliconflow","auto":false,"leader":"claude","leaderSince":0}"#.utf8), forKey: "mainSwitch")
        let store = try makeLegacyStore(d)
        let s = store.switchState
        try checkEqual(s.main, .siliconflow)
        try checkEqual(s.auto, false)
        try check(s.leader == nil && s.leaderSince == nil, "认不出的候选平台要清掉")
    }
    // 菜单栏平台存的是 "claude"：退回第一个已添加的平台
    testAsync("legacyMenuBarClaudeFallsBack") {
        let d = freshDefaults()
        d.set("claude", forKey: "menuBarProvider")
        let store = try makeLegacyStore(d)
        try checkEqual(store.menuBarProvider, .deepseek)
    }
    // 存的菜单栏平台已被删除：当作没选过（清掉键），之后照「第一个已添加平台」回落，
    // 否则只加了硅基流动的用户会一直停在没添加的 DeepSeek 上
    testAsync("legacyMenuBarKeyClearedSoFallbackKeepsWorking") {
        let d = freshDefaults()
        d.set("openai", forKey: "menuBarProvider")
        _ = try makeLegacyStore(d)
        // 10-19 起菜单栏跟着主平台，旧键启动时删掉
        try check(d.object(forKey: "menuBarProvider") == nil)
    }
    // 磁盘快照里有 claude 的旧快照（还带着已删的 budget 字段）：跳过它，别的平台的快照照常读回
    test("snapshotCacheSkipsLegacyPlatform") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("last-snapshot.json")
        let ds = snap(FakeClock().now)
        let dsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ds)) as! [String: Any]
        var legacy = dsJSON
        legacy["provider"] = "claude"
        legacy["balance"] = nil
        legacy["budget"] = ["monthly": ["amount": 50, "currency": "USD"], "spentThisMonth": ["amount": 3, "currency": "USD"]]
        try JSONSerialization.data(withJSONObject: ["deepseek": dsJSON, "claude": legacy]).write(to: url)
        let cache = SnapshotCache(url: url)
        let got = cache.load()
        try checkEqual(Array(got.keys), [.deepseek])
        try checkEqual(got[.deepseek], ds)
        // 再存一次不会被旧条目卡住
        try cache.save(ds)
        try checkEqual(cache.load()[.deepseek], ds)
    }
    // 采样库里有 openai 的旧行：按平台查询照常，旧行不出现
    test("sampleStoreIgnoresLegacyRows") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("samples.sqlite").path
        let s = try SampleStore(path: path)
        try s.append(Sample(provider: .deepseek, t: Date(timeIntervalSince1970: 1_792_022_400), balance: 5,
                            cumulativeCost: nil, currency: .cny))
        var raw: OpaquePointer?
        try check(sqlite3_open(path, &raw) == SQLITE_OK)
        try check(sqlite3_exec(raw, "INSERT INTO samples(provider, t, balance, cost, currency) VALUES('openai', 1792022500, NULL, '3', 'USD')",
                               nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        try checkEqual(try s.latest(.deepseek)?.balance, Decimal(5))
        try checkEqual(try s.samples(.deepseek, since: .distantPast).count, 1)
        try s.prune(olderThan: Date(timeIntervalSince1970: 1_792_022_600))
        try check(try s.latest(.deepseek) == nil)
    }
}
