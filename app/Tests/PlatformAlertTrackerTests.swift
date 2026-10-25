import Foundation

/// 第七批自查：每个平台的预警线都要真的提醒（原来只有主平台会），状态按平台分开记，换主平台不串
@MainActor
func registerPlatformAlertTrackerTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    test("trackerExhaustedCoversLowButNotOtherPlatforms") {
        var tr = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.codexPlan), .lowTank(.deepseek)]
        try checkEqual(tr.lowToFire(low, now: t0, repeatHours: 6, covered: [.codexPlan]), [.deepseek])
        // 用完持续超过重复间隔，仍只提醒未被覆盖的平台
        try checkEqual(tr.lowToFire(low, now: t0.addingTimeInterval(7 * 3600), repeatHours: 6,
                                   covered: [.codexPlan]), [.deepseek])
    }
    test("trackerCoveredRepeatStartsAtLastCoveredRound") {
        var tr = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.codexPlan)]
        try checkEqual(tr.lowToFire(low, now: t0, repeatHours: 6, covered: [.codexPlan]), [])
        let lastCovered = t0.addingTimeInterval(7 * 3600)
        try checkEqual(tr.lowToFire(low, now: lastCovered, repeatHours: 6, covered: [.codexPlan]), [])
        // 用完结束但仍在线下：从最后一轮覆盖起算，刚好到间隔才提醒
        try checkEqual(tr.lowToFire(low, now: lastCovered.addingTimeInterval(6 * 3600 - 1), repeatHours: 6), [])
        try checkEqual(tr.lowToFire(low, now: lastCovered.addingTimeInterval(6 * 3600), repeatHours: 6), [.codexPlan])
    }
    test("trackerCoveredRearmsAfterRecovery") {
        var tr = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.codexPlan)]
        // 覆盖时即使不能发低额度提醒，也要记为线下，避免解除覆盖就重复提醒
        try checkEqual(tr.lowToFire(low, now: t0, repeatHours: 0, covered: [.codexPlan], canFire: { _ in false }), [])
        try checkEqual(tr.lowToFire(low, now: t0.addingTimeInterval(60), repeatHours: 0), [])
        // 真正回到线上后，再跌破立即提醒
        try checkEqual(tr.lowToFire([], now: t0.addingTimeInterval(120), repeatHours: 0), [])
        try checkEqual(tr.lowToFire(low, now: t0.addingTimeInterval(180), repeatHours: 0), [.codexPlan])
    }

    func quotaPlatform(_ id: ProviderID, used: [Double], status: PlatformStatus = .ok,
                       resetsAt: Date? = nil) -> PlatformState {
        let windows = used.enumerated().map { i, percent in
            QuotaWindow(kind: i == 0 ? .session : .weekly, usedPercent: percent, resetsAt: resetsAt, windowMinutes: nil)
        }
        return PlatformState(id: id, snapshot: ProviderSnapshot(provider: id, balance: nil, today: nil, month: nil,
                             byModel: [], trend7: [], source: .bill, fetchedAt: t0, credential: .ok,
                             quota: Quota(plan: nil, windows: windows, observedAt: t0)), burn: nil, status: status)
    }
    test("trackerExhaustedPlatformsUsesAnyFullWindow") {
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([
            quotaPlatform(.codexPlan, used: [20, 100]),
            quotaPlatform(.claudePlan, used: [105, 30])
        ], now: t0), Set([.codexPlan, .claudePlan]))
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([
            quotaPlatform(.codexPlan, used: [99, 20]),
            quotaPlatform(.claudePlan, used: [])
        ], now: t0), [])
    }
    test("trackerExhaustedPlatformsExcludesPaygAndNotAdded") {
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([
            quotaPlatform(.deepseek, used: [100]),
            quotaPlatform(.codexPlan, used: [100], status: .notAdded),
            PlatformState(id: .claudePlan, snapshot: nil, burn: nil, status: .ok)
        ], now: t0), [])
        // 与用完提醒一致：离线但仍有未重置的满额快照，也算用完
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([
            quotaPlatform(.claudePlan, used: [100], status: .offline)
        ], now: t0), [.claudePlan])
    }
    test("trackerExhaustedPlatformsUsesEffectiveUsageAfterReset") {
        let st = quotaPlatform(.codexPlan, used: [100], resetsAt: t0.addingTimeInterval(60))
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([st], now: t0), [.codexPlan])
        try checkEqual(PlatformAlertTracker.exhaustedPlatforms([st], now: t0.addingTimeInterval(60)), [])
    }
    test("trackerFiresPerPlatformAndRearms") {
        var tr = PlatformAlertTracker()
        // 硅基流动（非主平台）低于预警线：要提醒
        try checkEqual(tr.lowToFire([.lowTank(.siliconflow)], now: t0, repeatHours: 6), [.siliconflow])
        // 一直在线下：6 小时内不再提醒
        try checkEqual(tr.lowToFire([.lowTank(.siliconflow)], now: t0.addingTimeInterval(3600), repeatHours: 6), [])
        // 另一个平台也跌破：它自己的状态，马上提醒
        try checkEqual(tr.lowToFire([.lowTank(.siliconflow), .lowTank(.deepseek)], now: t0.addingTimeInterval(3700), repeatHours: 6),
                       [.deepseek])
        // 到了间隔再提醒
        try checkEqual(tr.lowToFire([.lowTank(.siliconflow), .lowTank(.deepseek)], now: t0.addingTimeInterval(6 * 3600), repeatHours: 6),
                       [.siliconflow])
        // 充回线上后再跌破：马上提醒（重新武装）
        _ = tr.lowToFire([.lowTank(.deepseek)], now: t0.addingTimeInterval(6 * 3600 + 10), repeatHours: 6)
        try checkEqual(tr.lowToFire([.lowTank(.siliconflow), .lowTank(.deepseek)], now: t0.addingTimeInterval(6 * 3600 + 20), repeatHours: 6),
                       [.siliconflow])
    }
    test("trackerOnlyOnce") {
        var tr = PlatformAlertTracker()
        try checkEqual(tr.lowToFire([.lowTank(.codexPlan)], now: t0, repeatHours: 0), [.codexPlan])
        try checkEqual(tr.lowToFire([.lowTank(.codexPlan)], now: t0.addingTimeInterval(30 * 86400), repeatHours: 0), [])
    }
    test("trackerSpikePerPlatformSixHours") {
        var tr = PlatformAlertTracker()
        try checkEqual(tr.spikeToFire([.spike(.siliconflow)], now: t0), [.siliconflow])
        try checkEqual(tr.spikeToFire([.spike(.siliconflow), .spike(.deepseek)], now: t0.addingTimeInterval(60)), [.deepseek])
        try checkEqual(tr.spikeToFire([.spike(.siliconflow)], now: t0.addingTimeInterval(6 * 3600)), [.siliconflow])
        try checkEqual(tr.spikeToFire([.offline(.deepseek)], now: t0.addingTimeInterval(7 * 3600)), [])
    }
    test("trackerOfflineKeepsState") {
        // 评审 I3：离线 / 凭据失效时没有 lowTank，但不能当成「回到线上」重新武装
        var tr = PlatformAlertTracker()
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0, repeatHours: 6), [.deepseek])
        _ = tr.lowToFire([.offline(.deepseek)], now: t0.addingTimeInterval(60), repeatHours: 6)
        _ = tr.lowToFire([.credentialInvalid(.deepseek)], now: t0.addingTimeInterval(90), repeatHours: 6)
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0.addingTimeInterval(120), repeatHours: 6), [])
        // 真的回到线上（在线且没有 lowTank）才重新武装
        _ = tr.lowToFire([], now: t0.addingTimeInterval(180), repeatHours: 6)
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0.addingTimeInterval(240), repeatHours: 6), [.deepseek])
    }
    test("trackerSkipsUndeliverable") {
        // 评审 I4：这一轮发不出（缺数据）就不记成已提醒，下一轮能发时照常提醒
        var tr = PlatformAlertTracker()
        try checkEqual(tr.lowToFire([.lowTank(.codexPlan)], now: t0, repeatHours: 0, canFire: { _ in false }), [])
        try checkEqual(tr.lowToFire([.lowTank(.codexPlan)], now: t0.addingTimeInterval(60), repeatHours: 0), [.codexPlan])
        try checkEqual(tr.spikeToFire([.spike(.deepseek)], now: t0, canFire: { _ in false }), [])
        try checkEqual(tr.spikeToFire([.spike(.deepseek)], now: t0.addingTimeInterval(60)), [.deepseek])
    }
    // 2026-10-18 重启后重复推送：启动时各平台还在「正在连接」、没有读数，不能当成「回到线上」重新武装
    test("trackerNoReadingKeepsState") {
        var tr = PlatformAlertTracker()
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0, repeatHours: 6), [.deepseek])
        // 重启：DeepSeek 还没取到数（只有已读到的平台算 known）
        _ = tr.lowToFire([], now: t0.addingTimeInterval(60), repeatHours: 6, known: [.codexPlan])
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0.addingTimeInterval(70), repeatHours: 6, known: [.deepseek]), [])
        // 有读数且在线上：照常重新武装
        _ = tr.lowToFire([], now: t0.addingTimeInterval(120), repeatHours: 6, known: [.deepseek])
        try checkEqual(tr.lowToFire([.lowTank(.deepseek)], now: t0.addingTimeInterval(180), repeatHours: 6, known: [.deepseek]), [.deepseek])
    }
    // 启动时还没取到数的平台不算有读数；取到后才算
    testAsync("storePlatformsWithReading") {
        let (store, _) = try makeStore(FakeProvider([.success(snap(FakeClock().now))]), clock: FakeClock())
        try checkEqual(store.platformsWithReading(), [])
        await store.refresh()
        try checkEqual(store.platformsWithReading(), [.deepseek])
    }
}
