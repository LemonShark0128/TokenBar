import Foundation

@MainActor
func registerSnapshotCacheTests() {
    func tempCache() throws -> SnapshotCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotCache(url: dir.appendingPathComponent("last-snapshot.json"))
    }

    testAsync("coldStartOfflineRestoresDiskSnapshot") {
        let cache = try tempCache()
        let clock = FakeClock()
        let saved = snap(clock.now)
        let (first, _) = try makeStore(FakeProvider([.success(saved)]), clock: clock, cache: cache)
        await first.refresh()

        // 冷启动：新的 store、断网
        clock.now = clock.now.addingTimeInterval(1800)
        let (second, _) = try makeStore(FakeProvider([.failure(.network("断网"))]), clock: clock, cache: cache)
        await second.refresh()
        let st = second.platforms[0]
        try checkEqual(st.status, .offline)
        try checkEqual(st.snapshot, saved)
        try check(st.snapshotFromDisk, "从磁盘读回的快照要标为旧数据")
    }
    testAsync("restoredSnapshotStaysOfflineUntilSuccess") {
        let cache = try tempCache()
        let clock = FakeClock()
        let (first, _) = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cache: cache)
        await first.refresh()
        clock.now = clock.now.addingTimeInterval(600)
        let fresh = snap(clock.now.addingTimeInterval(1200), balance: 20)
        let (second, _) = try makeStore(FakeProvider([.failure(.network("断网")), .failure(.network("断网")),
                                                            .success(fresh)]), clock: clock, cache: cache)
        await second.refresh()
        clock.now = clock.now.addingTimeInterval(600)
        await second.refresh()
        try checkEqual(second.platforms[0].status, .offline)     // 不能因为有了磁盘快照就变成「稍旧」
        clock.now = clock.now.addingTimeInterval(600)
        await second.refresh()
        let st = second.platforms[0]
        try checkEqual(st.status, .ok)
        try checkEqual(st.snapshot, fresh)
        try check(!st.snapshotFromDisk, "取数成功后不再是旧数据")
    }
    testAsync("snapshotCacheHasNoCredentials") {
        let cache = try tempCache()
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cache: cache)
        await store.refresh()
        let text = try String(contentsOf: cache.url, encoding: .utf8)
        try check(text.contains("27.07"), "应写入快照内容")
        try check(!text.contains("sk-test") && !text.contains("apiKey"), "快照文件里不能有凭据")
    }
    testAsync("removeAccountClearsSnapshotCache") {
        let cache = try tempCache()
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock, cache: cache)
        await store.refresh()
        try await store.removeAccount(.deepseek)
        try check(cache.load()[.deepseek] == nil, "移除账号后不应再留它的快照")
    }
    test("restoredSnapshotMapsAsOfflineBalance") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        var st = PlatformState(id: .deepseek, snapshot: snap(now.addingTimeInterval(-1800)), burn: nil, status: .offline)
        st.snapshotFromDisk = true
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 28800)!)
        try checkEqual(d.balance.status, "离线")
        try checkEqual(d.balance.ageS, 1800)
        try checkEqual(d.today.source, "平台账单")     // 账单数据照常显示，只是标为旧的
    }
}
