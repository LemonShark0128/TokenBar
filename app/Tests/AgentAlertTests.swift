import Foundation

// 代理场景的两种新提醒：每小时花费超过（按量付费，默认关）、套餐额度恢复（默认开）
@MainActor
func registerAgentAlertTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    test("agentAlertSettingsDefaultsAndRoundTrip") {
        let d = UserDefaults(suiteName: testSuiteName("agent"))!
        d.set(false, forKey: "quotaRunoutAlert")
        var s = ProviderSettings.load(d)
        try check(s.hourlyAlerts.isEmpty)            // 每小时花费超过：默认关
        try check(s.quotaRecoveredAlert)                // 套餐额度恢复：默认开
        s.hourlyAlerts[.deepseek] = 2
        s.quotaRecoveredAlert = false
        s.save(d)
        let r = ProviderSettings.load(d)
        try checkEqual(r.hourlyAlerts, [.deepseek: 2])
        try check(!r.quotaRecoveredAlert)
        try checkEqual(d.object(forKey: "quotaRunoutAlert") as? Bool, false)
        var off = r
        off.hourlyAlerts[.deepseek] = nil
        off.save(d)
        try check(ProviderSettings.load(d).hourlyAlerts.isEmpty)
        // 套餐平台不读每小时花费
        d.set("5", forKey: ProviderSettings.hourlyAlertKey(.codexPlan))
        try check(ProviderSettings.load(d).hourlyAlerts[.codexPlan] == nil)
    }

    test("agentAlertHourlyFiresOncePerHour") {
        var tr = PlatformAlertTracker()
        let th: [ProviderID: Decimal] = [.deepseek: 2, .siliconflow: 5]
        // 超过线的才提醒；没设线的平台不提醒
        try checkEqual(tr.hourlyToFire(rates: [.deepseek: Decimal(string: "4.8")!, .siliconflow: 1, .codexPlan: 99],
                                       thresholds: th, now: t0), [.deepseek])
        // 1 小时内同一平台最多一次
        try checkEqual(tr.hourlyToFire(rates: [.deepseek: 6], thresholds: th, now: t0.addingTimeInterval(3599)), [])
        try checkEqual(tr.hourlyToFire(rates: [.deepseek: 6], thresholds: th, now: t0.addingTimeInterval(3600)), [.deepseek])
        // 等于线不算超过
        try checkEqual(tr.hourlyToFire(rates: [.siliconflow: 5], thresholds: th, now: t0), [])
        // 发不出（缺数据）就不记成已提醒
        try checkEqual(tr.hourlyToFire(rates: [.siliconflow: 6], thresholds: th, now: t0, canFire: { _ in false }), [])
        try checkEqual(tr.hourlyToFire(rates: [.siliconflow: 6], thresholds: th, now: t0.addingTimeInterval(1)), [.siliconflow])
    }



    test("agentAlertNotificationCopy") {
        let n = StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: 5.6)
        try checkEqual(n.title, "DeepSeek 每小时花费超过 ¥2")
        try checkEqual(n.body, "每小时 ¥4.80，预计可用时间：5 小时 36 分")
        try checkEqual(StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: nil).body,
                       "每小时 ¥4.80")
        try checkEqual(StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: 0.5).body,
                       "每小时 ¥4.80，预计可用时间：不到 1 小时")
    }

    test("agentAlertSettingsRows") {
        let s = SettingsLayout.sections(.alerts, added: [.deepseek, .siliconflow, .codexPlan], main: .deepseek, customOpen: [])
        try checkEqual(s[1].rows, [.alertStatus(.siliconflow), .alert(.siliconflow), .hourly(.siliconflow)])
        try checkEqual(s[2].rows, [.alertStatus(.codexPlan), .alert(.codexPlan)])
        // 只有按量付费平台：平台卡包含状态、余额预警与每小时花费。
        let m = SettingsLayout.sections(.alerts, added: [.deepseek], main: .deepseek, customOpen: [])
        try checkEqual(m[0].rows, [.alertStatus(.deepseek), .alert(.deepseek), .hourly(.deepseek)])
        try checkEqual(SettingsLayout.hourlyOptions(symbol: "¥").map(\.label), ["关", "¥1", "¥2", "¥5", "¥10"])
        try checkEqual(SettingsLayout.hourlySelection(nil), "0")
        try checkEqual(SettingsLayout.hourlySelection(5), "5")
    }
}
