import Foundation

/// 「额度已用完」提醒的去重记录要能存进 UserDefaults：重装 / 重启后同一个窗口不再重复弹（10-18 01:48 重装后 Codex 又弹了一次）
@MainActor
func registerExhaustedAlertMemoryTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let reset = t0.addingTimeInterval(3 * 3600)
    func plan(_ id: ProviderID, used: [Double], resetsAt: Date? = reset, status: PlatformStatus = .ok) -> PlatformState {
        let windows = used.enumerated().map { i, percent in
            QuotaWindow(kind: i == 0 ? .session : .weekly, usedPercent: percent, resetsAt: resetsAt, windowMinutes: nil)
        }
        return PlatformState(id: id, snapshot: ProviderSnapshot(provider: id, balance: nil, today: nil, month: nil,
                             byModel: [], trend7: [], source: .bill, fetchedAt: t0, credential: .ok,
                             quota: Quota(plan: nil, windows: windows, observedAt: t0)), burn: nil, status: status)
    }
    func fired(_ m: inout ExhaustedAlertMemory, _ ps: [PlatformState], _ now: Date) -> [String] {
        m.toFire(ps, now: now).map { "\($0.id.rawValue)|\(QuotaText.windowName($0.window.kind))" }
    }
    test("exhaustedMemoryFiresOncePerWindow") {
        var m = ExhaustedAlertMemory()
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100, 40])], t0), ["codexPlan|\(QuotaText.windowName(.session))"])
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100, 40])], t0.addingTimeInterval(60)), [])
        // 付费按量平台、未添加的平台不提醒
        try checkEqual(fired(&m, [plan(.deepseek, used: [100]), plan(.claudePlan, used: [100], status: .notAdded)], t0), [])
    }
    test("exhaustedMemorySurvivesReload") {
        let d = UserDefaults(suiteName: "tb-test-\(UUID().uuidString)")!
        var m = ExhaustedAlertMemory.load(d)
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100])], t0).count, 1)
        m.save(d)
        var again = ExhaustedAlertMemory.load(d)      // 模拟重装后启动
        try checkEqual(fired(&again, [plan(.codexPlan, used: [100])], t0.addingTimeInterval(120)), [])
        try checkEqual(again, m)
    }
    test("exhaustedMemoryRearmsAfterResetOrRecovery") {
        var m = ExhaustedAlertMemory()
        _ = fired(&m, [plan(.codexPlan, used: [100])], t0)
        // 过了重置时间：窗口不再用完，记录删掉；新窗口（新的重置时间）用完再提醒一次
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100])], reset), [])
        try checkEqual(m.keys, [])
        let next = reset.addingTimeInterval(5 * 3600)
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100], resetsAt: next)], reset.addingTimeInterval(60)).count, 1)
        // 没有重置时间的窗口：回到够用才重新武装
        var n = ExhaustedAlertMemory()
        try checkEqual(fired(&n, [plan(.claudePlan, used: [100], resetsAt: nil)], t0).count, 1)
        try checkEqual(fired(&n, [plan(.claudePlan, used: [100], resetsAt: nil)], t0.addingTimeInterval(600)), [])
        _ = fired(&n, [plan(.claudePlan, used: [60], resetsAt: nil)], t0.addingTimeInterval(900))
        try checkEqual(fired(&n, [plan(.claudePlan, used: [100], resetsAt: nil)], t0.addingTimeInterval(1200)).count, 1)
    }
    test("exhaustedMemoryToleratesResetJitter") {
        // 真机 10-18 23:02–23:19：Claude 已用 100%，每轮读到的重置时间差几十秒，跨分钟就又推一次
        var m = ExhaustedAlertMemory()
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: reset)], t0).count, 1)
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: reset.addingTimeInterval(61))], t0.addingTimeInterval(120)), [])
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: reset.addingTimeInterval(-50))], t0.addingTimeInterval(240)), [])
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: reset.addingTimeInterval(4 * 60))], t0.addingTimeInterval(360)), [])
        // 偶尔读不到重置时间也算同一次
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: nil)], t0.addingTimeInterval(480)), [])
        try checkEqual(fired(&m, [plan(.claudePlan, used: [100], resetsAt: reset)], t0.addingTimeInterval(600)), [])
        // 只留一条记录
        try checkEqual(m.keys.count, 1)
    }
    test("exhaustedMemoryKeepsKeysWithoutReading") {
        var m = ExhaustedAlertMemory()
        _ = fired(&m, [plan(.codexPlan, used: [100]), plan(.claudePlan, used: [100])], t0)
        try checkEqual(m.keys.count, 2)
        // 读不到数（快照为空 / 不在列表里）不当作恢复：记录保留，数据回来也不重弹
        let noData = PlatformState(id: .codexPlan, snapshot: nil, burn: nil, status: .offline)
        try checkEqual(fired(&m, [noData], t0.addingTimeInterval(60)), [])
        try checkEqual(m.keys.count, 2)
        try checkEqual(fired(&m, [plan(.codexPlan, used: [100]), plan(.claudePlan, used: [100])], t0.addingTimeInterval(120)), [])
        // 平台被移除（未添加）：它的记录删掉
        _ = fired(&m, [plan(.claudePlan, used: [100], status: .notAdded), plan(.codexPlan, used: [100])], t0.addingTimeInterval(180))
        try checkEqual(m.keys.count, 1)
    }
}
