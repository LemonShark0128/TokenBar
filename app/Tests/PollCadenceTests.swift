import Foundation

/// 取数时把时钟往后拨（模拟 claude 子进程、网络请求要花几秒）
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class SlowProvider: UsageProvider, @unchecked Sendable {
    let pid: ProviderID, clock: FakeClock, cost: TimeInterval
    private(set) var calls = 0
    init(_ id: ProviderID, clock: FakeClock, cost: TimeInterval) { pid = id; self.clock = clock; self.cost = cost }
    var id: ProviderID { pid }
    var displayName: String { "Slow" }
    var capabilities: Capabilities { Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, dayBoundary: .local) }
    var loginSteps: [LoginStep] { [.apiKey(required: true)] }
    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        calls += 1
        clock.now = clock.now.addingTimeInterval(cost)
        return .success(snap(now))
    }
}

@MainActor
private func cadenceStore(_ ps: [UsageProvider], clock: FakeClock, interval: Int) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-cadence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    let cs = InMemoryCredentialStore()
    for p in ps { try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: p.id) }
    return UsageStore(providers: ps, credentials: cs, samples: samples, intervalSeconds: interval,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: freshDefaults())
}

@MainActor
func registerPollCadenceTests() {
    // 10-19 实测：设 2 分钟，DeepSeek / 硅基流动 / Claude 一半以上的间隔是 135 秒——
    // 下次到点按「这一轮真正开始取数的时刻」算，比 15 秒节拍晚一点，整 2 分钟那一拍就差一点点没到点
    testAsync("pollCadenceFollowsTickNotFetchStart") {
        let clock = FakeClock()
        let start = clock.now
        let slow = SlowProvider(.claudePlan, clock: clock, cost: 3)      // 排在前面、要花 3 秒
        let fast = SlowProvider(.siliconflow, clock: clock, cost: 0)
        let store = try cadenceStore([slow, fast], clock: clock, interval: 120)
        await store.tick()
        clock.now = start.addingTimeInterval(120)                         // 整 2 分钟那一拍
        await store.tick()
        try checkEqual(slow.calls, 2)
        try checkEqual(fast.calls, 2)
    }
    testAsync("pollCadenceToleratesTimerJitter") {
        let clock = FakeClock()
        let start = clock.now
        let p = SlowProvider(.deepseek, clock: clock, cost: 0)
        let store = try cadenceStore([p], clock: clock, interval: 120)
        await store.tick()
        clock.now = start.addingTimeInterval(119.6)                        // 计时器这一拍比上一拍触发得早一点
        await store.tick()
        try checkEqual(p.calls, 2)
        clock.now = start.addingTimeInterval(119.6 + 60)                   // 但不会提前很多
        await store.tick()
        try checkEqual(p.calls, 2)
    }
}
