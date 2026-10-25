import Foundation

@MainActor
private func twoStore(_ ids: [ProviderID], clock: FakeClock) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    let cs = InMemoryCredentialStore()
    var ps: [FakeProvider] = []
    for id in ids {
        try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: id)
        ps.append(FakeProvider([], id: id))
    }
    return UsageStore(providers: ps, credentials: cs, samples: samples, intervalSeconds: 120,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 0)! },
                      defaults: freshDefaults(), settings: { ProviderSettings() })
}

@MainActor
func registerSwitchPresentationTests() {
    test("switchMotionStyleBranches") {
        try checkEqual(SwitchMotion.style(reduceMotion: false), .matchedGeometry)
        try checkEqual(SwitchMotion.style(reduceMotion: true), .fade)
        try checkEqual(SwitchMotion.springResponse, 0.5)
        try checkEqual(SwitchMotion.springDamping, 0.8)
        try checkEqual(SwitchMotion.noticeSeconds, 3)
    }
    testAsync("noticeAfterSwitchAndConsume") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        try check(store.pendingSwitchNotice == nil)
        store.demoSwitch()
        let name = ProviderRegistry.displayName(.siliconflow)
        try checkEqual(store.pendingSwitchNotice, "\(name) 有任务在跑，已切换显示")
        store.consumeAutoSwitch()
        try check(store.lastAutoSwitch == nil)
        try check(store.pendingSwitchNotice == nil)
    }
    testAsync("noticeDroppedAfterManualPin") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        store.demoSwitch()
        store.pinMain(.deepseek)
        try check(store.lastAutoSwitch == nil, "手动设主平台清掉过时提示")
        try check(store.pendingSwitchNotice == nil)
    }
    testAsync("isMainPinnedFollowsPinWindow") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        try check(store.isMainPinned == false)
        store.pinMain(.siliconflow)
        try check(store.isMainPinned)
        clock.now = clock.now.addingTimeInterval(7199)
        try check(store.isMainPinned)
        clock.now = clock.now.addingTimeInterval(2)
        try check(store.isMainPinned == false)
    }
    testAsync("isMainPinnedWhenAutoOff") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        store.setAutoMain(false)
        try check(store.isMainPinned)
        store.setAutoMain(true)
        try check(store.isMainPinned == false)
    }
    testAsync("setAutoMainClearsPin") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        store.pinMain(.siliconflow)
        store.setAutoMain(true)
        try check(store.isMainPinned == false)
        try check(store.switchState.pinnedUntil == nil)
    }
    testAsync("demoSwitchSwapsWithFirstSide") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow], clock: clock)
        store.demoSwitch()
        try checkEqual(store.mainProvider, .siliconflow)
        try checkEqual(store.lastAutoSwitch?.to, .siliconflow)
        try checkEqual(store.switchState.lastSwitchAt, clock.now)
        try check(store.switchState.pinnedUntil == nil)
        store.demoSwitch()
        try checkEqual(store.mainProvider, .deepseek)
        try checkEqual(store.lastAutoSwitch?.to, .deepseek)
    }
    testAsync("demoSwitchPicksFirstSideInPanelOrder") {
        // 三个平台：取面板辅助区同序的第一个（platforms 顺序，排除主平台），不是最后一个
        let clock = FakeClock()
        let store = try twoStore([.deepseek, .siliconflow, .codexPlan], clock: clock)
        let firstSide = store.platforms.first { $0.id != .deepseek && $0.status != .notAdded }?.id
        try checkEqual(firstSide, .siliconflow)
        store.demoSwitch()
        try checkEqual(store.mainProvider, .siliconflow)
        try check(store.switchState.leader == nil)
    }
    testAsync("demoSwitchSinglePlatformNoop") {
        let clock = FakeClock()
        let store = try twoStore([.deepseek], clock: clock)
        store.demoSwitch()
        try checkEqual(store.mainProvider, .deepseek)
        try check(store.lastAutoSwitch == nil)
    }
}
