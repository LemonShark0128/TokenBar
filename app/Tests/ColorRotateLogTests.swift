import Foundation

@MainActor
private func rotationStore(_ clock: FakeClock, providers: [FakeProvider]? = nil,
                           log: @escaping (String) -> Void = { _ in }) throws -> UsageStore {
    let ps = providers ?? [.init([], id: .claudePlan, meter: .quota, needsCredentials: false),
                           .init([], id: .codexPlan, meter: .quota, needsCredentials: false)]
    let d = freshDefaults()
    for p in ps { d.set(true, forKey: "accountAdded.\(p.id.rawValue)") }
    let samples = try SampleStore(path: ":memory:")
    return UsageStore(providers: ps, credentials: InMemoryCredentialStore(), samples: samples,
                      intervalSeconds: 120, clock: { clock.now }, defaults: d, log: log)
}

@MainActor
func registerColorRotateLogTests() {
    test("quotaMenuColorIgnoresOtherSignalsAndUsesRiskWindow") {
        // 不接受辅助平台异常或风险严重度作为套餐颜色输入。
        try checkEqual(MenuBarText.quotaSeverity(isQuota: true, usedPercent: 46, risk: nil), .ok)
        let w = QuotaWindow(kind: .session, usedPercent: 79, resetsAt: nil, windowMinutes: 300)
        let q = QuotaRunway(window: w, remainingPercent: 21, risePP: 50, hoursToEmpty: 0.42,
                            resetsAt: nil, state: .runsOut, severity: .danger)
        let r = PlatformRisk(id: .claudePlan, kind: .quota(q), hours: 0.42, atRisk: true, severity: .danger)
        try checkEqual(MenuBarText.quotaSeverity(isQuota: false, usedPercent: 99, risk: r), .ok)
        try checkEqual(MenuBarText.quotaSeverity(isQuota: true, usedPercent: 80, risk: nil), .warn)
        try checkEqual(MenuBarText.quotaSeverity(isQuota: true, usedPercent: 95, risk: nil), .danger)
        try checkEqual(MenuBarText.quotaSeverity(isQuota: false, usedPercent: 95, risk: nil), nil)
        try checkEqual(MenuBarText.quotaSeverity(isQuota: true, usedPercent: .nan, risk: nil), .ok)
    }
    testAsync("mainRotationAlternatesWithoutNoticeOrCooldown") {
        let clock = FakeClock()
        let store = try rotationStore(clock)
        store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
        try checkEqual(store.mainProvider, .codexPlan)
        let cooldown = store.switchState.lastSwitchAt
        store.consumeAutoSwitch()
        let started = clock.now
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .codexPlan)
        // 首次回调略晚，后续回到正常节拍时仍应轮流，不能因不足整 10 秒跳过一次。
        var elapsed: TimeInterval = 10.03
        for expected: ProviderID in [.claudePlan, .codexPlan, .claudePlan] {
            clock.now = started.addingTimeInterval(elapsed)
            elapsed = elapsed < 11 ? 20.01 : 30.02
            store.advanceMainRotation()
            try checkEqual(store.mainProvider, expected)
            try check(store.lastAutoSwitch == nil)
            try checkEqual(store.switchState.lastSwitchAt, cooldown)
            // 扫描不能把轮流显示的平台抢回去。
            store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
            try checkEqual(store.mainProvider, expected)
        }
        store.setRunningTasks([.claudePlan: clock.now])
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .claudePlan)
        store.setRunningTasks([:])
        clock.now = clock.now.addingTimeInterval(10)
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .claudePlan)
    }
    testAsync("mainRotationHonorsPinAndDisabledAuto") {
        let clock = FakeClock()
        let store = try rotationStore(clock)
        store.pinMain(.claudePlan)
        store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
        clock.now = clock.now.addingTimeInterval(10)
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .claudePlan)
        store.setAutoMain(true)
        store.setAutoMain(false)
        clock.now = clock.now.addingTimeInterval(10)
        store.advanceMainRotation()
        try checkEqual(store.mainProvider, .claudePlan)
    }
    testAsync("fetchLogsOnlyTransitionsForMoneyAndQuota") {
        for id: ProviderID in [.deepseek, .siliconflow, .claudePlan] {
            let clock = FakeClock()
            let p = FakeProvider([.failure(.network("超时")), .failure(.network("仍超时")),
                                  .success(snap(clock.now)), .success(snap(clock.now)),
                                  .failure(.rateLimited(retryAfter: nil))],
                                 id: id, meter: id == .claudePlan ? .quota : .money, needsCredentials: false)
            var lines: [String] = []
            let store = try rotationStore(clock, providers: [p], log: { lines.append($0) })
            await store.refresh()
            let name = ProviderRegistry.displayName(id)
            try checkEqual(lines, ["\(name) 取数失败：超时，稍后自动重试"])
            await store.refresh()
            try checkEqual(lines.count, 1)
            await store.refresh()
            try checkEqual(lines.last, "\(name) 取数恢复")
            await store.refresh()
            try checkEqual(lines.count, 2)
            await store.refresh()
            try checkEqual(lines.last, "\(name) 取数失败：被限流，稍后自动重试")
        }
    }

}
