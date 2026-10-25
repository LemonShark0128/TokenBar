import Foundation

// 代理场景的两种新提醒：每小时花费超过（按量付费，默认关）、套餐重置前会用完（默认开）
@MainActor
func registerAgentAlertTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let utc = TimeZone(secondsFromGMT: 0)!

    test("agentAlertSettingsDefaultsAndRoundTrip") {
        let d = UserDefaults(suiteName: "tb-agent-\(UUID().uuidString)")!
        var s = ProviderSettings.load(d)
        try check(s.hourlyAlerts.isEmpty)            // 每小时花费超过：默认关
        try check(s.quotaRunoutAlert)                // 套餐重置前会用完：默认开
        s.hourlyAlerts[.deepseek] = 2
        s.quotaRunoutAlert = false
        s.save(d)
        let r = ProviderSettings.load(d)
        try checkEqual(r.hourlyAlerts, [.deepseek: 2])
        try check(!r.quotaRunoutAlert)
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

    func quotaRisk(_ id: ProviderID, state: QuotaRunway.State, resetsAt: Date?, below: Bool = false) -> PlatformRisk {
        let w = QuotaWindow(kind: .session, usedPercent: 88, resetsAt: resetsAt, windowMinutes: 300)
        let q = QuotaRunway(window: w, remainingPercent: 12, risePP: 18, hoursToEmpty: state == .runsOut ? 2.0 / 3 : nil,
                            resetsAt: resetsAt, state: state, severity: state == .runsOut ? .danger : .ok)
        var r = PlatformRisk(id: id, kind: below ? .belowThreshold : .quota(q), hours: state == .runsOut ? 2.0 / 3 : nil,
                             atRisk: state == .runsOut || below, severity: state == .runsOut ? .danger : .ok)
        r.quotaReading = q
        return r
    }

    test("agentAlertRunoutOncePerWindow") {
        var tr = PlatformAlertTracker()
        let reset1 = t0.addingTimeInterval(7200)
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1)], now: t0), [.claudePlan])
        // 同一个窗口（同一个重置时间）只提醒一次，即使中间一度够用
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .enough, resetsAt: reset1)], now: t0.addingTimeInterval(60)), [])
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1)], now: t0.addingTimeInterval(120)), [])
        // 2026-10-18 每 2 分钟重复推送：同一窗口的重置时间在两次读数之间会抖动（服务器带毫秒、桌面记录估算），
        // 差 1 小时以内都算同一个窗口
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1.addingTimeInterval(0.4))], now: t0.addingTimeInterval(130)), [])
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1.addingTimeInterval(-25 * 60))], now: t0.addingTimeInterval(140)), [])
        // 新窗口（重置时间变了）再提醒
        let reset2 = reset1.addingTimeInterval(5 * 3600)
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset2)], now: reset1.addingTimeInterval(60)), [.claudePlan])
        // 低于预警线时也看原始读数（quotaReading）
        try checkEqual(tr.runoutToFire([quotaRisk(.codexPlan, state: .runsOut, resetsAt: reset1, below: true)], now: t0), [.codexPlan])
        // 没有重置时间：一直在「会用完」里只提醒一次，恢复够用后重新武装
        try checkEqual(tr.runoutToFire([quotaRisk(.codexPlan, state: .runsOut, resetsAt: nil)], now: t0), [.codexPlan])
        try checkEqual(tr.runoutToFire([quotaRisk(.codexPlan, state: .runsOut, resetsAt: nil)], now: t0.addingTimeInterval(60)), [])
        _ = tr.runoutToFire([quotaRisk(.codexPlan, state: .enough, resetsAt: nil)], now: t0.addingTimeInterval(120))
        try checkEqual(tr.runoutToFire([quotaRisk(.codexPlan, state: .runsOut, resetsAt: nil)], now: t0.addingTimeInterval(180)), [.codexPlan])
        // 按量付费平台和没风险的不提醒
        let payg = PlatformRisk(id: .deepseek, kind: .payg(PaygRunway(hours: 1, basis: .recentSpike, severity: .danger)),
                                hours: 1, atRisk: true, severity: .danger)
        try checkEqual(tr.runoutToFire([payg], now: t0), [])
        // 发不出就不记
        var tr2 = PlatformAlertTracker()
        try checkEqual(tr2.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1)], now: t0, canFire: { _ in false }), [])
        try checkEqual(tr2.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1)], now: t0), [.claudePlan])
    }

    test("agentAlertNotificationCopy") {
        let n = StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: 5.6)
        try checkEqual(n.title, "DeepSeek 每小时花费超过 ¥2")
        try checkEqual(n.body, "每小时 ¥4.80，预计可用时间：5 小时 36 分")
        try checkEqual(StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: nil).body,
                       "每小时 ¥4.80")
        try checkEqual(StatusPresenter.hourlyNotification(name: "DeepSeek", perHour: 4.8, threshold: 2, currency: "CNY", runwayHours: 0.5).body,
                       "每小时 ¥4.80，预计可用时间：不到 1 小时")
        let r = quotaRisk(.claudePlan, state: .runsOut, resetsAt: t0.addingTimeInterval(7200))
        let q = r.quotaReading!
        let m = StatusPresenter.runoutNotification(name: "Claude 套餐", runway: q, now: t0, timeZone: utc)
        try checkEqual(m.title, "Claude 套餐 重置前会用完")
        try checkEqual(m.body, "预计可用时间：40 分钟，下次重置：\(Runway.resetClock(q, now: t0, timeZone: utc)!)")
        var nr = q; nr.resetsAt = nil
        try checkEqual(StatusPresenter.runoutNotification(name: "Claude 套餐", runway: nr, now: t0, timeZone: utc).body,
                       "预计可用时间：40 分钟")
    }

    test("agentAlertSettingsRows") {
        let s = SettingsLayout.sections(.alerts, added: [.deepseek, .siliconflow, .codexPlan], main: .deepseek, customOpen: [])
        try checkEqual(s[1].rows, [.alertHeader(quota: false), .alert(.deepseek), .alert(.siliconflow)])
        try checkEqual(s[2].rows, [.alertHeader(quota: true), .alert(.codexPlan), .runoutAlert])
        // 只有按量付费平台：没有「套餐重置前会用完」
        let m = SettingsLayout.sections(.alerts, added: [.deepseek], main: .deepseek, customOpen: [])
        try checkEqual(m[1].rows, [.alertHeader(quota: false), .alert(.deepseek)])
        try checkEqual(SettingsLayout.hourlyOptions(symbol: "¥").map(\.label), ["关", "¥1", "¥2", "¥5", "¥10"])
        try checkEqual(SettingsLayout.hourlySelection(nil), "0")
        try checkEqual(SettingsLayout.hourlySelection(5), "5")
    }
}
