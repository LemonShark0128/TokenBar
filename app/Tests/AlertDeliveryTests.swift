import Foundation

@MainActor
func registerAlertDeliveryTests() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let cal = calendar
    func date(_ day: Int = 5, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    func defaults() -> UserDefaults { UserDefaults(suiteName: testSuiteName("alert-delivery"))! }
    let a = PendingAlert(provider: .deepseek, title: "低余额", body: "余额 1 元", sound: false)

    test("AlertBatch empty and single preserve content") {
        try check(AlertBatch.merge([]) == nil)
        let one = AlertBatch.merge([a])!
        try checkEqual(one.title, a.title)
        try checkEqual(one.body, a.body)
        try check(!one.sound)
        try checkEqual(one.providers, [.deepseek])
    }
    test("AlertBatch multiple preserve provider order and any sound") {
        let b = PendingAlert(provider: .kimi, title: "额度", body: String(repeating: "长", count: 1000), sound: true)
        let unknown = PendingAlert(provider: nil, title: "通知", body: "正文", sound: false)
        let batch = AlertBatch.merge([a, b, a, unknown])!
        try checkEqual(batch.title, "4 条提醒")
        try checkEqual(batch.body, "低余额：余额 1 元\n额度：\(b.body)\n低余额：余额 1 元\n通知：正文")
        try check(batch.sound)
        try checkEqual(batch.providers, [.deepseek, .kimi])
    }
    test("QuietHours overnight boundaries") {
        let q = QuietHours(startHour: 23, endHour: 8)
        try check(q.contains(date(5, 23), calendar: cal))
        try check(q.contains(date(6, 7, 59), calendar: cal))
        try check(!q.contains(date(6, 8), calendar: cal))
        try check(!q.contains(date(5, 22, 59), calendar: cal))
    }
    test("QuietHours daytime midnight and equal hours") {
        let q = QuietHours(startHour: 13, endHour: 14)
        try check(q.contains(date(5, 13), calendar: cal))
        try check(!q.contains(date(5, 14), calendar: cal))
        try check(!q.contains(date(5, 12, 59), calendar: cal))
        try check(QuietHours(startHour: 0, endHour: 8).contains(date(5, 0), calendar: cal))
        try check(!QuietHours(startHour: 8, endHour: 8).contains(date(5, 8), calendar: cal))
    }
    test("QuietHours persistence defaults off and rejects invalid input") {
        let d = defaults()
        defer { d.removeObject(forKey: QuietHours.key) }
        try check(QuietHours.load(d) == nil)
        let q = QuietHours(startHour: 23, endHour: 8)
        QuietHours.save(q, d)
        try checkEqual(d.string(forKey: QuietHours.key), "23-8")
        try checkEqual(QuietHours.load(d), q)
        QuietHours.save(nil, d)
        try checkEqual(d.string(forKey: QuietHours.key), "off")
        for value in ["bad", "24-8", "-1-8", "23-99"] {
            d.set(value, forKey: QuietHours.key)
            try check(QuietHours.load(d) == nil)
        }
    }
    test("AlertMute local day expiry union and rollover") {
        let d = defaults()
        defer { d.removeObject(forKey: AlertMute.key) }
        AlertMute.mute([.deepseek, .deepseek], now: date(5, 0), d: d, calendar: cal)
        AlertMute.mute([.kimi], now: date(5, 1), d: d, calendar: cal)
        try check(AlertMute.isMuted(.deepseek, now: date(5, 23, 59), d: d, calendar: cal))
        try check(AlertMute.isMuted(.kimi, now: date(5, 23), d: d, calendar: cal))
        try check(!AlertMute.isMuted(.deepseek, now: date(6, 0), d: d, calendar: cal))
        try check(d.string(forKey: AlertMute.key)!.contains("2026-11-05"))
        AlertMute.mute([.kimi], now: date(6, 0), d: d, calendar: cal)
        try check(!AlertMute.isMuted(.deepseek, now: date(6, 1), d: d, calendar: cal))
        try check(AlertMute.isMuted(.kimi, now: date(6, 1), d: d, calendar: cal))
    }
    test("QuietBacklog retains newest 20 persists summarizes five and clears") {
        let d = defaults()
        defer { d.removeObject(forKey: QuietBacklog.key) }
        var backlog = QuietBacklog()
        backlog.append((0..<25).map { PendingAlert(provider: .deepseek, title: "\($0)", body: "正文", sound: $0 == 24) })
        backlog.save(d)
        backlog = QuietBacklog.load(d)
        try checkEqual(backlog.alerts.count, 20)
        try checkEqual(backlog.alerts.first?.title, "5")
        let summary = backlog.drain()!
        try checkEqual(summary.alert.title, "安静时段内有 20 条提醒")
        try checkEqual(summary.alert.body, "5：正文\n6：正文\n7：正文\n8：正文\n9：正文\n…还有 15 条")
        try check(summary.alert.sound)
        try checkEqual(summary.providers, [.deepseek])
        try check(backlog.drain() == nil)
        backlog.save(d)
        try check(QuietBacklog.load(d).alerts.isEmpty)
    }
    test("QuietBacklog single summary and English plurals") {
        L10n.lang = .en
        defer { L10n.lang = .zh }
        var backlog = QuietBacklog()
        backlog.append([a])
        let single = backlog.drain()!
        try checkEqual(single.alert.title, "1 alert during quiet hours")
        try checkEqual(single.alert.body, "低余额：余额 1 元")
        try checkEqual(AlertBatch.merge([a, a])!.title, "2 alerts")
        backlog.append(Array(repeating: a, count: 6))
        try check(backlog.drain()!.alert.body.hasSuffix("…and 1 more"))
    }
    test("QuietHours setting follows spike for empty and populated platforms") {
        for added: [ProviderID] in [[], [.deepseek, .codexPlan]] {
            let rows = SettingsLayout.sections(.alerts, added: added, main: added.first, customOpen: []).last!.rows
            try checkEqual(Array(rows.suffix(2)), [.spikeAlert, .quietHours])
        }
    }
}
