import Foundation

/// 第四批第 5 条：「没有恢复时每 6 小时再提醒一次」改成可选间隔，默认 6 小时；0 = 只提醒一次
@MainActor
func registerAlertRepeatTests() {
    test("alertRepeatOptionsDefaultSix") {
        try checkEqual(AlertRepeat.options.map(\.key), ["1", "3", "6", "12", "24", "0"])
        try checkEqual(AlertRepeat.options.map(\.label), ["每 1 小时", "每 3 小时", "每 6 小时", "每 12 小时", "每天一次", "只提醒一次"])
        try checkEqual(AlertRepeat.hours(UserDefaults(suiteName: "tb-test-\(UUID().uuidString)")!), 6)
        let d = UserDefaults(suiteName: "tb-test-\(UUID().uuidString)")!
        d.set(12, forKey: AlertRepeat.key)
        try checkEqual(AlertRepeat.hours(d), 12)
        d.set(7, forKey: AlertRepeat.key)                     // 不在选项里的旧值：回到默认
        try checkEqual(AlertRepeat.hours(d), 6)
    }
    test("alertRepeatShouldFire") {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 刚跌破预警线（之前在线上）：总是提醒
        try check(AlertRepeat.shouldFire(wasAbove: true, lastAt: t0, now: t0.addingTimeInterval(60), hours: 6))
        // 一直在线下：到了间隔才再提醒
        try check(!AlertRepeat.shouldFire(wasAbove: false, lastAt: t0, now: t0.addingTimeInterval(5 * 3600), hours: 6))
        try check(AlertRepeat.shouldFire(wasAbove: false, lastAt: t0, now: t0.addingTimeInterval(6 * 3600), hours: 6))
        try check(AlertRepeat.shouldFire(wasAbove: false, lastAt: t0, now: t0.addingTimeInterval(3600), hours: 1))
        // 只提醒一次：一直在线下就不再提醒
        try check(!AlertRepeat.shouldFire(wasAbove: false, lastAt: t0, now: t0.addingTimeInterval(30 * 24 * 3600), hours: 0))
        // 从没提醒过
        try check(AlertRepeat.shouldFire(wasAbove: false, lastAt: nil, now: t0, hours: 0))
    }
}
