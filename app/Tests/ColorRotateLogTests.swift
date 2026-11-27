import Foundation

@MainActor
private func rotationStore(_ clock: FakeClock, providers: [FakeProvider]? = nil, defaults: UserDefaults? = nil,
                           log: @escaping (String) -> Void = { _ in }) throws -> UsageStore {
    let ps = providers ?? [.init([], id: .claudePlan, meter: .quota, needsCredentials: false),
                           .init([], id: .codexPlan, meter: .quota, needsCredentials: false)]
    let d = defaults ?? freshDefaults()
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
    // 2026-11-06 乙：几个同时在用不再每 10 秒轮流，固定显示常用平台（近 7 天活跃分钟最多；另一个多 20% 以上、且过了 1 小时才换）
    testAsync("severalRunningShowPreferredWithoutRotation") {
        let clock = FakeClock()
        var lines: [String] = []
        let store = try rotationStore(clock, log: { lines.append($0) })
        store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
        // 还没有活跃分钟数：留在正在显示的（启动时回落到第一个已添加的 Codex 套餐）
        try checkEqual(store.mainProvider, .codexPlan)
        store.setActiveMinutes([.claudePlan: 300, .codexPlan: 120])
        try checkEqual(store.preferredPlatform, .claudePlan)
        try checkEqual(store.mainProvider, .claudePlan)
        try check(lines.contains { $0.contains("常用平台：Claude 套餐") })
        for _ in 0..<3 {
            clock.now = clock.now.addingTimeInterval(10)
            store.advanceMainRotation()
            store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
            try checkEqual(store.mainProvider, .claudePlan)
            try checkEqual(store.menuBarRotation, [.claudePlan])
        }
        // 1 小时内不重算
        store.setActiveMinutes([.claudePlan: 300, .codexPlan: 900])
        try checkEqual(store.preferredPlatform, .claudePlan)
        // 过了 1 小时：只多 20% 以内不换，多 20% 以上才换
        clock.now = clock.now.addingTimeInterval(3600)
        store.setActiveMinutes([.claudePlan: 300, .codexPlan: 360])
        try checkEqual(store.preferredPlatform, .claudePlan)
        clock.now = clock.now.addingTimeInterval(3600)
        store.setRunningTasks([.claudePlan: clock.now, .codexPlan: clock.now])
        store.consumeAutoSwitch()
        store.setActiveMinutes([.claudePlan: 300, .codexPlan: 361])
        try checkEqual(store.preferredPlatform, .codexPlan)
        try checkEqual(store.mainProvider, .codexPlan)
        // 因常用平台变了而换主平台：不弹切换提示
        try check(store.lastAutoSwitch == nil)
        // 常用平台停了、另一个还在跑：切过去
        clock.now = clock.now.addingTimeInterval(120)
        store.setRunningTasks([.claudePlan: clock.now])
        try checkEqual(store.mainProvider, .claudePlan)
        // 移除的正好是常用平台：马上按剩下的重算，不被 1 小时节流卡住
        try await store.removeAccount(.codexPlan)
        try check(store.preferredPlatform == nil)
        store.setActiveMinutes([.claudePlan: 300, .codexPlan: 900])
        try checkEqual(store.preferredPlatform, .claudePlan)
    }
    // 2026-11-06 用户定 proposal-preferred-persist 乙：只存常用平台 id（不存时间），重启后带着 20% 防抖重算
    testAsync("preferredPlatformPersistsAcrossRestart") {
        let clock = FakeClock()
        let d = freshDefaults()
        let first = try rotationStore(clock, defaults: d)
        first.setActiveMinutes([.claudePlan: 1000, .codexPlan: 500])
        try checkEqual(first.preferredPlatform, .claudePlan)
        // 重启：启动就先用存的常用平台，不用等读完日志
        var lines: [String] = []
        let second = try rotationStore(clock, defaults: d, log: { lines.append($0) })
        try checkEqual(second.preferredPlatform, .claudePlan)
        // 不存时间：启动后第一次照常重算，带着防抖（只多 5% 不换），日志照旧写一行常用平台
        second.setActiveMinutes([.claudePlan: 1000, .codexPlan: 1050])
        try checkEqual(second.preferredPlatform, .claudePlan)
        try check(lines.contains("常用平台：Claude 套餐（近 7 天本机活跃 1000 分钟）"), "\(lines)")
        // 同一次启动里再算、没变：不重复写日志
        clock.now = clock.now.addingTimeInterval(3601)
        second.setActiveMinutes([.claudePlan: 1000, .codexPlan: 1050])
        try checkEqual(lines.filter { $0.hasPrefix("常用平台：") }.count, 1)
        // 用量真的变了照样换，并存下来
        second.setActiveMinutes([.claudePlan: 100, .codexPlan: 1050])
        try checkEqual(second.preferredPlatform, .claudePlan)     // 1 小时内不重算
        clock.now = clock.now.addingTimeInterval(3601)
        second.setActiveMinutes([.claudePlan: 100, .codexPlan: 1050])
        try checkEqual(second.preferredPlatform, .codexPlan)
        let third = try rotationStore(clock, defaults: d)
        try checkEqual(third.preferredPlatform, .codexPlan)
        // 移除的不是常用平台：不清
        try await third.removeAccount(.claudePlan)
        try checkEqual(d.string(forKey: UsageStore.preferredPlatformKey), ProviderID.codexPlan.rawValue)
        // 移除常用平台时一起清掉
        try await third.removeAccount(.codexPlan)
        try check(third.preferredPlatform == nil)
        let fourth = try rotationStore(clock, defaults: d)
        try check(fourth.preferredPlatform == nil)
    }
    test("preferredPlatformStoredButNotAddedIsIgnored") {
        let clock = FakeClock()
        let d = freshDefaults()
        d.set(ProviderID.codexPlan.rawValue, forKey: UsageStore.preferredPlatformKey)
        let only = [FakeProvider([], id: .claudePlan, meter: .quota, needsCredentials: false),
                    FakeProvider([], id: .codexPlan, meter: .quota, needsCredentials: false)]
        // 存的是 Codex 套餐，但它没添加（只添加了 Claude 套餐）
        d.set(true, forKey: "accountAdded.claudePlan")
        let store = UsageStore(providers: only, credentials: InMemoryCredentialStore(), samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, clock: { clock.now }, defaults: d)
        try check(store.preferredPlatform == nil)
        try check(d.string(forKey: UsageStore.preferredPlatformKey) == nil)     // 用不上的旧值顺手删掉
        // 认不出的 id 也当没有
        d.set("nope", forKey: UsageStore.preferredPlatformKey)
        let other = UsageStore(providers: only, credentials: InMemoryCredentialStore(), samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, clock: { clock.now }, defaults: d)
        try check(other.preferredPlatform == nil)
    }
    // 活跃分钟：同一分钟多条只算 1；Claude 同一条回复写多行只算一次；7 天以外不算
    test("localActiveMinutes") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tb-active-minutes \(UUID())")
        defer { try? fm.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
        let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        func write(_ path: URL, _ lines: [String]) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: path)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        }
        func reply(_ id: String, _ ts: String) -> String {
            #"{"type":"assistant","timestamp":""# + ts + #"","message":{"id":""# + id + #"","model":"claude-opus","usage":{"input_tokens":10,"output_tokens":5}}}"#
        }
        try write(claude.appendingPathComponent("projects/demo/a.jsonl"), [
            reply("a", "2026-11-01T11:00:05Z"), reply("a", "2026-11-01T11:00:09Z"),   // 同一条回复两行
            reply("b", "2026-11-01T11:00:40Z"),                                      // 同一分钟
            reply("c", "2026-11-01T11:05:00Z"),
            reply("d", "2026-10-20T11:05:00Z")])                                      // 7 天以外
        func count(_ total: Int, _ ts: String) -> String {
            #"{"type":"event_msg","timestamp":""# + ts + #"","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":"# + "\(total)" + #","output_tokens":0,"total_tokens":"# + "\(total)" + #"}}}}"#
        }
        try write(codex.appendingPathComponent("2026/11/01/a.jsonl"), [
            #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            count(100, "2026-11-01T10:00:00Z"), count(200, "2026-11-01T10:00:30Z"), count(300, "2026-11-01T10:02:00Z")])
        let r = LocalAgentUsage.readDetailed(enabled: [.claudePlan, .codexPlan], claudeDir: claude, codexSessions: codex,
                                             now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        try checkEqual(r.activeMinutes, [.claudePlan: 2, .codexPlan: 2])
    }
    // 2026-11-06 乙：切到套餐平台不弹「有任务在跑，已切换显示」（按量付费「余额在减少」照旧，见 PaygActivityTests）
    testAsync("noSwitchNoticeForQuotaPlatforms") {
        let clock = FakeClock()
        let store = try rotationStore(clock)
        clock.now = clock.now.addingTimeInterval(120)
        store.setRunningTasks([.claudePlan: clock.now])
        try checkEqual(store.mainProvider, .claudePlan)
        try check(store.lastAutoSwitch != nil)
        try checkEqual(store.pendingSwitchNotice, nil)
    }
    test("preferredPlatformPick") {
        try checkEqual(PreferredPlatform.pick(minutes: [:], current: nil), nil)
        try checkEqual(PreferredPlatform.pick(minutes: [:], current: .claudePlan), .claudePlan)
        try checkEqual(PreferredPlatform.pick(minutes: [.codexPlan: 10], current: nil), .codexPlan)
        try checkEqual(PreferredPlatform.pick(minutes: [.codexPlan: 10, .claudePlan: 10], current: nil), .claudePlan)
        try checkEqual(PreferredPlatform.pick(minutes: [.codexPlan: 120, .claudePlan: 100], current: .claudePlan), .claudePlan)
        try checkEqual(PreferredPlatform.pick(minutes: [.codexPlan: 121, .claudePlan: 100], current: .claudePlan), .codexPlan)
        try checkEqual(PreferredPlatform.pick(minutes: [.codexPlan: 5, .claudePlan: 0], current: .claudePlan), .codexPlan)
        try checkEqual(PreferredPlatform.choose(running: [.deepseek, .codexPlan], preferred: nil, current: .kimi), .codexPlan)
        try checkEqual(PreferredPlatform.choose(running: [.deepseek, .codexPlan], preferred: .claudePlan, current: .deepseek), .deepseek)
        try checkEqual(PreferredPlatform.choose(running: [.claudePlan, .codexPlan], preferred: .claudePlan, current: .codexPlan), .claudePlan)
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
    testAsync("fetchLogsTransitionsAndReasonChangesForMoneyAndQuota") {
        for id: ProviderID in [.deepseek, .siliconflow, .claudePlan] {
            let clock = FakeClock()
            let p = FakeProvider([.failure(.network("超时")), .failure(.network("仍超时")), .failure(.network("仍超时")),
                                  .success(snap(clock.now)), .success(snap(clock.now)),
                                  .failure(.rateLimited)],
                                 id: id, meter: id == .claudePlan ? .quota : .money, needsCredentials: false)
            var lines: [String] = []
            let store = try rotationStore(clock, providers: [p], log: { lines.append($0) })
            await store.refresh()
            let name = ProviderRegistry.displayName(id)
            try checkEqual(lines, ["\(name) 取数失败：超时，稍后自动重试"])
            await store.refresh()
            try checkEqual(lines.count, 2)
            try checkEqual(lines.last, "\(name) 取数失败：仍超时，稍后自动重试")
            await store.refresh()
            try checkEqual(lines.count, 2)
            await store.refresh()
            try checkEqual(lines.last, "\(name) 取数恢复")
            await store.refresh()
            try checkEqual(lines.count, 3)
            await store.refresh()
            try checkEqual(lines.last, "\(name) 取数失败：被限流，稍后自动重试")
        }
    }

}
