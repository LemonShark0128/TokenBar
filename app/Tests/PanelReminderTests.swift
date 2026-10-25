import Foundation

@MainActor
func registerPanelReminderTests() {
    test("提醒仅在面板可见满三秒后到期且只交付一次") {
        var timer = PanelReminderTimer()
        timer.update(visible: false, keys: ["风险"], now: 0)
        try check(timer.takeExpired(now: 10).isEmpty)
        timer.update(visible: true, keys: ["风险"], now: 10)
        try check(timer.takeExpired(now: 12.99).isEmpty)
        try checkEqual(timer.takeExpired(now: 13), Set(["风险"]))
        timer.update(visible: true, keys: ["风险"], now: 14)
        try check(timer.takeExpired(now: 20).isEmpty)
    }
    test("提前关闭后重新打开须重新看满三秒") {
        var timer = PanelReminderTimer()
        timer.update(visible: true, keys: ["风险"], now: 0)
        timer.update(visible: false, keys: ["风险"], now: 2)
        try check(timer.takeExpired(now: 4).isEmpty)
        timer.update(visible: true, keys: ["风险"], now: 10)
        try check(timer.takeExpired(now: 12).isEmpty)
        try checkEqual(timer.takeExpired(now: 13), Set(["风险"]))
    }
    test("新提醒独立计时同键刷新不重置") {
        var timer = PanelReminderTimer()
        timer.update(visible: true, keys: ["风险"], now: 0)
        timer.update(visible: true, keys: ["风险", "切换"], now: 2)
        try checkEqual(timer.takeExpired(now: 3), Set(["风险"]))
        try checkEqual(timer.takeExpired(now: 5), Set(["切换"]))
    }
    test("换平台加重及手动移除均取消旧提醒") {
        var timer = PanelReminderTimer()
        timer.update(visible: true, keys: ["旧风险", "切换"], now: 0)
        timer.update(visible: true, keys: ["新风险"], now: 2)
        try check(timer.takeExpired(now: 3).isEmpty)
        try checkEqual(timer.takeExpired(now: 5), Set(["新风险"]))
        timer.update(visible: true, keys: [], now: 6)
        timer.update(visible: true, keys: ["新风险"], now: 7)
        try check(timer.takeExpired(now: 9).isEmpty)
        try checkEqual(timer.takeExpired(now: 10), Set(["新风险"]))
    }
}
