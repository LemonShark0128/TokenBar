import Foundation

@MainActor
func registerRiskPresentationTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    let tz = TimeZone(secondsFromGMT: 0)!
    func quota(_ used: Double = 88, rise: Double = 18, reset: Date? = nil, estimated: Bool = false) -> QuotaRunway {
        let w = QuotaWindow(kind: .session, usedPercent: used, resetsAt: reset ?? now.addingTimeInterval(7200),
                            windowMinutes: 300, resetIsEstimated: estimated)
        return Runway.quota(Quota(plan: nil, windows: [w], observedAt: now), risePP: rise, now: now)!
    }
    func payg(_ hours: Double = 3) -> PaygRunway {
        PaygRunway(hours: hours, basis: .recentSpike, severity: Runway.severity(hours: hours), perHourRecent: 4.8, multiple: 21)
    }
    func risk(_ id: ProviderID, _ q: QuotaRunway) -> PlatformRisk {
        RiskRanker.risk(RiskInput(id: id, status: .ok, payg: nil, quota: q, belowThreshold: false))
    }
    func data() -> AppData {
        var d = AppData(nowLocal: "", balance: .init(cny: 27.07, source: "平台", status: "可用", ageS: 0),
                        today: .init(costCny: 0, tokens: 0), month: .init(costCny: 0, tokens: 0),
                        models: [], trend7: [])
        d.sides = [ProviderID.siliconflow, .codexPlan, .claudePlan].map {
            AppData.Side(id: $0.rawValue, name: ProviderRegistry.displayName($0), tank: nil, currency: "CNY", todayCost: nil, status: "正常")
        }
        return d
    }
    func apply(_ d: inout AppData, _ risks: [PlatformRisk], main: ProviderID = .deepseek) {
        AppDataMapping.applyRisks(&d, main: main, risks: risks, now: now, timeZone: tz, currency: "CNY")
    }
    func bannerKey(_ r: PlatformRisk) throws -> String? {
        var d = data(); apply(&d, [r])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d.banner)) as! [String: Any]
        return json["key"] as? String
    }
    test("banner dismissal survives noData until fresh risk resolution") {
        for status: PlatformStatus in [.offline, .stale(minutes: 20), .schemaChanged, .credentialInvalid] {
            var dismissal = BannerDismissal(dismissed: ["deepseek": "closed"])
            let missing = RiskRanker.risk(RiskInput(id: .deepseek, status: status, payg: nil, quota: nil, belowThreshold: false))
            dismissal.prune(risks: [missing])
            try checkEqual(dismissal.dismissed["deepseek"], "closed")
            let fresh = RiskRanker.risk(RiskInput(id: .deepseek, status: .ok, payg: payg(100), quota: nil, belowThreshold: false))
            dismissal.prune(risks: [fresh])
            try checkEqual(dismissal.dismissed["deepseek"], nil)
        }
    }
    test("banner keys identify four kinds and reset minute") {
        let q = quota()
        let minute = Int(q.resetsAt!.timeIntervalSince1970 / 60)
        let below = PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger, quotaReading: q)
        try checkEqual(try bannerKey(below), "claudePlan|below|2|\(minute)")
        try checkEqual(try bannerKey(risk(.claudePlan, q)), "claudePlan|runsOut|2|\(minute)")
        try checkEqual(try bannerKey(risk(.claudePlan, quota(100))), "claudePlan|exhausted|2|\(minute)")
        let p = PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)
        try checkEqual(try bannerKey(p), "siliconflow|payg|1|-")
        var noReset = below; noReset.quotaReading = nil
        try checkEqual(try bannerKey(noReset), "claudePlan|below|2|-")
    }
    test("banner keys ignore payg text but track severity and reset minute") {
        var r = PlatformRisk(id: .siliconflow, kind: .payg(payg(3)), hours: 3, atRisk: true, severity: .warn)
        let first = try bannerKey(r)
        r.kind = .payg(payg(4))
        try checkEqual(try bannerKey(r), first)
        r.severity = .danger
        try check(try bannerKey(r) != first, "severity changes reminder")
        let q = quota(); let initial = try bannerKey(risk(.claudePlan, q))
        var changed = q; changed.resetsAt = q.resetsAt!.addingTimeInterval(30)
        try checkEqual(try bannerKey(risk(.claudePlan, changed)), initial)
        changed.resetsAt = q.resetsAt!.addingTimeInterval(60)
        try check(try bannerKey(risk(.claudePlan, changed)) != initial, "new reset changes reminder")
        changed.resetsAt = nil
        try checkEqual(try bannerKey(risk(.claudePlan, changed)), "claudePlan|runsOut|2|-")
    }
    test("legacy banner key defaults to empty") {
        let legacy = Data(#"{"id":"siliconflow","text":"旧提醒","severity":1}"#.utf8)
        let b = try JSONDecoder().decode(AppData.RiskBanner.self, from: legacy)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        try checkEqual(json["key"] as? String, "")
    }
    test("dismissal matches platform and key and replaces previous reminder") {
        let b = AppData.RiskBanner(id: "siliconflow", text: "提醒", severity: 1, key: "old")
        var state = BannerDismissal(dismissed: [:])
        try check(!state.hides(b))
        state.dismiss(b)
        try check(state.hides(b))
        var changed = b; changed.text = "新数字"
        try check(state.hides(changed))
        changed.key = "new"
        try check(!state.hides(changed))
        state.dismiss(changed)
        try check(!state.hides(b))
        changed.id = "claudePlan"
        try check(!state.hides(changed))
    }
    test("dismissal prunes recovered and missing platforms then allows recurrence") {
        let b = AppData.RiskBanner(id: "siliconflow", text: "提醒", severity: 1, key: "same")
        var state = BannerDismissal(dismissed: ["siliconflow": "same", "claudePlan": "removed"])
        var r = PlatformRisk(id: .siliconflow, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)
        state.prune(risks: [r])
        try checkEqual(state.dismissed, ["siliconflow": "same"])
        r.atRisk = false; state.prune(risks: [r])
        r.atRisk = true; state.prune(risks: [r])
        try check(!state.hides(b))
        state.dismiss(b); state.prune(risks: [])
        try checkEqual(state.dismissed, [:])
    }
    // 2026-10-18 重启后关掉的风险横幅又出现：启动时平台还没读数（pending），不能当成「恢复了」把关掉的记录删掉
    test("dismissal kept while platform has no reading yet") {
        var state = BannerDismissal(dismissed: ["deepseek": "k", "claudePlan": "removed"])
        state.prune(risks: [], pending: [.deepseek])
        try checkEqual(state.dismissed, ["deepseek": "k"])
        state.prune(risks: [], pending: [])
        try checkEqual(state.dismissed, [:])
    }
    test("dismissal persists a dictionary in isolated defaults") {
        let suite = "TokenBarTests.BannerDismissal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try checkEqual(BannerDismissal.load(defaults).dismissed, [:])
        let state = BannerDismissal(dismissed: ["siliconflow": "key"])
        state.save(defaults)
        try checkEqual(defaults.dictionary(forKey: "riskBanner.dismissed") as? [String: String], state.dismissed)
        try checkEqual(BannerDismissal.load(defaults), state)
        BannerDismissal(dismissed: [:]).save(defaults)
        try checkEqual(BannerDismissal.load(defaults).dismissed, [:])
    }
    // 检查实际编码结果，使旧实现缺字段时表现为断言失败。
    func checkCompact(_ chip: AppData.RunwayChip?, short: String, muted: Bool) throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chip)) as! [String: Any]
        try checkEqual(json["short"] as? String, short)
        try checkEqual(json["muted"] as? Bool, muted)
    }
    test("compact quota states and muted only for idle including threshold") {
        for below in [false, true] {
            for (q, short, muted) in [(quota(), "预计可用时间：40 分钟", false), (quota(100), "额度已用完", false),
                                     (quota(20, rise: 2), "够用到重置", false), (quota(20, rise: 0), "近 1 小时没用", true)] {
                var d = data()
                let r = RiskRanker.risk(RiskInput(id: .claudePlan, status: .ok, payg: nil, quota: q, belowThreshold: below))
                apply(&d, [r], main: .claudePlan)
                try checkCompact(d.runway, short: short, muted: muted)
                let decoded = try JSONDecoder().decode(AppData.RunwayChip.self, from: JSONEncoder().encode(d.runway))
                try checkEqual(decoded, d.runway)
            }
        }
    }
    test("compact payg duration and threshold never muted") {
        for below in [false, true] {
            for (hours, short) in [(0.5, "还能用 不到 1 小时"), (3.0, "还能用 3 小时"), (24.0, "还能用 1 天")] {
                var d = data()
                apply(&d, [RiskRanker.risk(RiskInput(id: .deepseek, status: .ok, payg: payg(hours), quota: nil, belowThreshold: below))])
                try checkCompact(d.runway, short: short, muted: false)
            }
        }
    }
    test("legacy chip defaults short to title and muted to false") {
        let legacy = Data(#"{"title":"旧标题","severity":1}"#.utf8)
        let chip = try JSONDecoder().decode(AppData.RunwayChip.self, from: legacy)
        try checkCompact(chip, short: "旧标题", muted: false)
    }
    test("estimated reset duration has no space before suffix") {
        let q = quota(20, rise: 0, reset: now.addingTimeInterval(7980), estimated: true)
        try checkEqual(Runway.quotaChip(q, now: now, timeZone: tz).detail, "约 2 小时 13 分后重置")
    }
    test("quota chip states and reset details") {
        let r = quota()
        let text = Runway.quotaChip(r, now: now, timeZone: tz)
        try checkEqual(text.title, "预计可用时间：40 分钟")
        try checkEqual(text.detail, "比 \(Runway.resetClock(r, now: now, timeZone: tz)!) 重置早 1 小时 20 分 · 近 1 小时用了 18%")
        for (q, title) in [(quota(20, rise: 2), "够用到重置"), (quota(20, rise: 0), "近 1 小时没用"), (quota(100), "额度已用完")] {
            let text = Runway.quotaChip(q, now: now, timeZone: tz)
            try checkEqual(text.title, title)
            try checkEqual(text.detail, "2 小时后重置")
        }
    }
    test("quota chip missing reset estimated cross day and rounded rise") {
        var q = quota(); q.resetsAt = nil; q.risePP = 17.6
        try checkEqual(Runway.quotaChip(q, now: now, timeZone: tz).detail, "近 1 小时用了 18%")
        for state in [QuotaRunway.State.idle, .enough, .exhausted] {
            q.state = state
            try checkEqual(Runway.quotaChip(q, now: now, timeZone: tz).detail, nil)
        }
        q = quota(20, rise: 0, reset: now.addingTimeInterval(86400), estimated: true)
        try checkEqual(Runway.quotaChip(q, now: now, timeZone: tz).detail, "约 1 天后重置")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "M/d HH:mm"
        try checkEqual(Runway.resetClock(q, now: now, timeZone: tz), "约 " + f.string(from: q.resetsAt!))
    }
    test("payg chip and below threshold retain reading") {
        for below in [false, true] {
            let r = RiskRanker.risk(RiskInput(id: .deepseek, status: .ok, payg: payg(), quota: nil, belowThreshold: below))
            var d = data(); apply(&d, [r])
            try checkEqual(d.runway?.title, Runway.paygText(payg(), currency: "CNY").title)
            try checkEqual(d.runway?.detail, Runway.paygText(payg(), currency: "CNY").detail)
            try checkEqual(d.runway?.severity, below ? 2 : 1)
        }
    }
    test("quota below threshold retains quota chip") {
        let q = quota(95, rise: 0)
        let r = RiskRanker.risk(RiskInput(id: .claudePlan, status: .ok, payg: nil, quota: q, belowThreshold: true))
        var d = data(); apply(&d, [r], main: .claudePlan)
        try checkEqual(d.runway?.title, "近 1 小时没用")
        try checkEqual(d.runway?.severity, 2)
    }
    test("side ordering keeps stable tail and risk order after activity reorder") {
        let risks = [risk(.claudePlan, quota()), PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)]
        var d = data(); apply(&d, risks)
        try checkEqual(d.sides.map(\.id), [ProviderID.claudePlan, .siliconflow, .codexPlan].map(\.rawValue))
        try checkEqual(d.sidesByRisk, true)
        d.sides.reverse(); AppDataMapping.orderSidesByRisk(&d, risks: risks)
        try checkEqual(d.sides.first?.id, ProviderID.claudePlan.rawValue)
        apply(&d, [])
        try checkEqual(d.sidesByRisk, false)
        try checkEqual(d.sides.map(\.riskText), [nil, nil, nil])
    }
    test("banner appears only when main has no risk and clears on refresh") {
        var d = data(); let r = risk(.claudePlan, quota())
        apply(&d, [r])
        try checkEqual(d.banner?.id, ProviderID.claudePlan.rawValue)
        try checkEqual(d.banner?.severity, 2)
        try checkEqual(d.banner?.text, "Claude 套餐 预计可用时间：40 分钟，下次重置：\(Runway.resetClock(quota(), now: now, timeZone: tz)!)")
        apply(&d, [r, PlatformRisk(id: .deepseek, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)])
        try checkEqual(d.banner, nil)
        apply(&d, [])
        try checkEqual(d.banner, nil)
        try checkEqual(d.runway, nil)
    }
    test("quotaRunwayUsesSameDurationInSideAndMenuCard") {
        let q = quota(71, rise: 12, reset: now.addingTimeInterval(4 * 3600))
        var d = data()
        apply(&d, [risk(.claudePlan, q)])
        try checkEqual(d.sides.first { $0.id == ProviderID.claudePlan.rawValue }?.riskText, "预计可用时间：2 小时 25 分")
        apply(&d, [risk(.claudePlan, q)], main: .claudePlan)
        try checkEqual(d.runway?.short, "预计可用时间：2 小时 25 分")
    }
    test("side quota text states") {
        for (q, expected) in [(quota(), "预计可用时间：40 分钟"), (quota(100), "已用完"), (quota(20, rise: 2), "够用到重置"), (quota(20, rise: 0), nil)] {
            var d = data(); apply(&d, [risk(.claudePlan, q)])
            try checkEqual(d.sides.first { $0.id == ProviderID.claudePlan.rawValue }?.riskText, expected)
        }
    }
    test("side payg threshold and no data text") {
        for (kind, atRisk, expected) in [(PlatformRisk.Kind.payg(payg(0.5)), true, "预计可用时间：不到 1 小时"), (.payg(payg()), true, "预计可用时间：3 小时"), (.belowThreshold, true, "低于预警线"), (.payg(payg(24)), false, nil), (.noData, false, nil), (.none, false, nil)] {
            var d = data()
            apply(&d, [PlatformRisk(id: .siliconflow, kind: kind, hours: nil, atRisk: atRisk, severity: .warn)])
            try checkEqual(d.sides.first { $0.id == ProviderID.siliconflow.rawValue }?.riskText, expected)
        }
    }
    test("banner payg below threshold and exhausted without reset") {
        var d = data()
        apply(&d, [PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)])
        try checkEqual(d.banner?.text, "硅基流动 预计可用时间：3 小时")
        apply(&d, [PlatformRisk(id: .siliconflow, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)])
        try checkEqual(d.banner?.text, "硅基流动：余额低于预警线")
        apply(&d, [PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)])
        try checkEqual(d.banner?.text, "Claude 套餐：额度低于预警线")
        var q = quota(100); q.resetsAt = nil
        apply(&d, [risk(.claudePlan, q)])
        try checkEqual(d.banner?.text, "Claude 套餐 额度已用完")
        q = quota(); q.resetsAt = nil
        apply(&d, [risk(.claudePlan, q)])
        try checkEqual(d.banner?.text, "Claude 套餐 预计可用时间：40 分钟")
    }
    test("quota main maps all states and severity") {
        for q in [quota(), quota(100), quota(20, rise: 2), quota(20, rise: 0)] {
            var d = data()
            apply(&d, [risk(.claudePlan, q)], main: .claudePlan)
            let expected = Runway.quotaChip(q, now: now, timeZone: tz)
            try checkEqual(d.runway?.title, expected.title)
            try checkEqual(d.runway?.detail, expected.detail)
            try checkEqual(d.runway?.severity, q.severity.rawValue)
            try checkEqual(d.banner, nil)
        }
    }
    test("risk sorting preserves multiple neutral rows and neutral order") {
        var d = data()
        apply(&d, [risk(.claudePlan, quota())])
        try checkEqual(d.sides.map(\.id), [ProviderID.claudePlan, .siliconflow, .codexPlan].map(\.rawValue))
        d = data()
        apply(&d, [risk(.claudePlan, quota(20, rise: 2)), risk(.codexPlan, quota(20, rise: 0))])
        try checkEqual(d.sides.map(\.id), [ProviderID.siliconflow, .codexPlan, .claudePlan].map(\.rawValue))
        try checkEqual(d.sidesByRisk, false)
        try checkEqual(d.banner, nil)
    }
    test("reset clock honors caller timezone and local day boundary") {
        let base = Date(timeIntervalSince1970: 0)
        var q = quota(); q.resetsAt = base.addingTimeInterval(3600)
        try checkEqual(Runway.resetClock(q, now: base, timeZone: tz), "01:00")
        try checkEqual(Runway.resetClock(q, now: base, timeZone: TimeZone(secondsFromGMT: -3600)!), "1/1 00:00")
        q.window.resetIsEstimated = true
        try checkEqual(Runway.resetClock(q, now: base, timeZone: tz), "约 01:00")
    }
    test("risk presentation survives Codable round trip") {
        var d = data()
        let normal = PlatformRisk(id: .deepseek, kind: .payg(payg(120)), hours: 120, atRisk: false, severity: .ok)
        apply(&d, [risk(.claudePlan, quota()), normal])
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(d))
        try checkEqual(decoded.runway, d.runway)
        try checkEqual(decoded.banner, d.banner)
        try checkEqual(decoded.sides, d.sides)
        try checkEqual(decoded.sidesByRisk, true)
    }
    test("main no data clears chip and decoding legacy fields defaults") {
        var d = data(); apply(&d, [risk(.claudePlan, quota())], main: .claudePlan)
        for kind in [PlatformRisk.Kind.noData, .none] {
            apply(&d, [PlatformRisk(id: .claudePlan, kind: kind, hours: nil, atRisk: false, severity: .ok)], main: .claudePlan)
            try checkEqual(d.runway, nil)
        }
        let encoded = try JSONEncoder().encode(d)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "sidesByRisk"); json.removeValue(forKey: "runway"); json.removeValue(forKey: "banner")
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        try checkEqual(decoded.sidesByRisk, false)
        try checkEqual(decoded.runway, nil)
        try checkEqual(decoded.banner, nil)
    }
}
