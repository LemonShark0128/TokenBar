import Foundation

private let t0 = Date(timeIntervalSince1970: 1_792_022_400)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private func start(_ main: ProviderID = .deepseek) -> MainSwitchState { MainSwitchState(main: main, auto: true) }
private let allAdded = Set(ProviderRegistry.all)

/// 用户 2026-10-18：主平台「自动」= 10 分钟内有任务在跑的平台；几个都在跑按平台顺序轮流；都没在跑保持上一次
@MainActor
func registerMainSwitcherTests() {
    test("tasksSwitchToRunning") {
        let s = MainSwitcher.step(start(), lastActivity: [.claudePlan: at(-30)], added: allAdded, now: t0)
        try checkEqual(s.main, .claudePlan)
        try checkEqual(s.lastSwitchAt, t0)
    }
    test("tasksNoneRunningKeepsLast") {
        var s = MainSwitcher.step(start(), lastActivity: [.claudePlan: at(-30)], added: allAdded, now: t0)
        // 任务停了超过 10 分钟：保持 Claude，不回到原来的平台
        s = MainSwitcher.step(s, lastActivity: [.claudePlan: at(-30)], added: allAdded, now: at(700))
        try checkEqual(s.main, .claudePlan)
        s = MainSwitcher.step(s, lastActivity: [:], added: allAdded, now: at(800))
        try checkEqual(s.main, .claudePlan)
    }
    test("tasksRunningWindowIsTenMinutes") {
        let s = MainSwitcher.step(start(), lastActivity: [.codexPlan: at(-601)], added: allAdded, now: t0)
        try checkEqual(s.main, .deepseek)
        let s2 = MainSwitcher.step(start(), lastActivity: [.codexPlan: at(-600)], added: allAdded, now: t0)
        try checkEqual(s2.main, .codexPlan)
    }
    test("tasksBothRunningStartsInRegistryOrder") {
        let s = MainSwitcher.step(start(), lastActivity: [.claudePlan: at(-10), .codexPlan: at(-120)], added: allAdded, now: t0)
        try checkEqual(s.main, .codexPlan)
    }
    test("tasksMinimumOneMinuteBetweenSwitches") {
        var s = MainSwitcher.step(start(), lastActivity: [.claudePlan: at(-5)], added: allAdded, now: t0)
        try checkEqual(s.main, .claudePlan)
        // 30 秒后只剩 Codex：还不到 1 分钟，不换
        s = MainSwitcher.step(s, lastActivity: [.codexPlan: at(30)], added: allAdded, now: at(30))
        try checkEqual(s.main, .claudePlan)
        s = MainSwitcher.step(s, lastActivity: [.codexPlan: at(60)], added: allAdded, now: at(60))
        try checkEqual(s.main, .codexPlan)
        try checkEqual(s.lastSwitchAt, at(60))
    }
    test("tasksIgnoreNotAdded") {
        let s = MainSwitcher.step(start(), lastActivity: [.claudePlan: at(-5)], added: [.deepseek], now: t0)
        try checkEqual(s.main, .deepseek)
    }
    test("tasksSameMainNoSwitchRecorded") {
        let s = MainSwitcher.step(start(.claudePlan), lastActivity: [.claudePlan: at(-5)], added: allAdded, now: t0)
        try checkEqual(s.main, .claudePlan)
        try check(s.lastSwitchAt == nil)
    }
    test("autoOffNeverSwitches") {
        var s = start()
        s.auto = false
        s = MainSwitcher.step(s, lastActivity: [.claudePlan: at(-5)], added: allAdded, now: t0)
        try checkEqual(s.main, .deepseek)
    }
    test("pinPausesTwoHours") {
        var s = MainSwitcher.pin(start(), to: .deepseek, now: t0)
        try checkEqual(s.pinnedUntil, at(7200))
        s = MainSwitcher.step(s, lastActivity: [.claudePlan: at(7190)], added: allAdded, now: at(7199))
        try checkEqual(s.main, .deepseek)
        s = MainSwitcher.step(s, lastActivity: [.claudePlan: at(7190)], added: allAdded, now: at(7200))
        try checkEqual(s.main, .claudePlan)
    }
    test("pinSetsMainWithoutCountingAsSwitch") {
        let s = MainSwitcher.pin(start(), to: .claudePlan, now: t0)
        try checkEqual(s.main, .claudePlan)
        try check(s.lastSwitchAt == nil)
    }
}
