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
    // 2026-11-06 用户选乙：套餐平台不再出顶部横幅；按量付费照旧，键最后一段恒为「-」
    test("banner keys payg and below, no quota banner") {
        let p = PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)
        try checkEqual(try bannerKey(p), "siliconflow|payg|1|-")
        let below = PlatformRisk(id: .siliconflow, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)
        try checkEqual(try bannerKey(below), "siliconflow|below|2|-")
        for r in [risk(.claudePlan, quota()), risk(.claudePlan, quota(100)),
                  PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger, quotaReading: quota())] {
            var d = data(); apply(&d, [r])
            try checkEqual(d.banner, nil)
        }
    }
    // 11/6 用户定 round7-scout 第 2 条乙：套餐低于预警线时主卡胶囊写「低于预警线」（红），重置时间放到说明里；
    // 原来写灰色「近 1 小时没用」或红色「够用到重置」，和侧栏「低于预警线」对不上。预计用完的照旧写剩多久（更具体）
    test("quota below line chip says below line") {
        for (q, muted) in [(quota(85, rise: 0), false), (quota(85, rise: 2), false)] {
            var d = data()
            apply(&d, [PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger, quotaReading: q)],
                  main: .claudePlan)
            try checkEqual(d.runway?.title, "低于预警线")
            try checkEqual(d.runway?.short, "低于预警线")
            try checkEqual(d.runway?.detail, "2 小时后重置")
            try checkEqual(d.runway?.severity, RunwaySeverity.danger.rawValue)
            try checkEqual(d.runway?.muted, muted)
        }
        var d = data()
        apply(&d, [PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger, quotaReading: quota(85, rise: 20))],
              main: .claudePlan)
        try check(d.runway?.title.hasPrefix("预计可用时间") == true, "\(d.runway?.title ?? "nil")")
    }
    // 套餐和按量付费同时有风险：横幅落到按量付费平台（以前会选排在前面的套餐平台）
    test("banner skips quota risk and picks payg") {
        var d = data()
        apply(&d, [risk(.claudePlan, quota(100)), PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)])
        try checkEqual(d.banner?.id, ProviderID.siliconflow.rawValue)
    }
    // 主平台是套餐且自己有风险：按量付费副平台的横幅照样显示；主平台是按量付费且有风险：仍不加横幅
    test("banner shows payg side when quota main at risk") {
        let sideRisk = PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)
        let quotaMain = risk(.claudePlan, quota()), paygMain = PlatformRisk(id: .deepseek, kind: .payg(payg()), hours: 3, atRisk: true, severity: .warn)
        try check(quotaMain.atRisk && paygMain.atRisk, "两种主平台都要有风险，才测得到这条分支")
        var d = data(); apply(&d, [quotaMain, sideRisk], main: .claudePlan)
        try checkEqual(d.banner?.id, ProviderID.siliconflow.rawValue)
        d = data(); apply(&d, [paygMain, sideRisk], main: .deepseek)
        try checkEqual(d.banner, nil)
    }
    test("banner keys ignore payg text but track severity") {
        var r = PlatformRisk(id: .siliconflow, kind: .payg(payg(3)), hours: 3, atRisk: true, severity: .warn)
        let first = try bannerKey(r)
        r.kind = .payg(payg(4))
        try checkEqual(try bannerKey(r), first)
        r.severity = .danger
        try check(try bannerKey(r) != first, "severity changes reminder")
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
        let suite = testSuiteName("banner-dismissal")
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
                // 低于预警线且没在快速用完：写「低于预警线」、不变灰（11/6 第 2 条乙）
                let belowChip = below && (short == "够用到重置" || short == "近 1 小时没用")
                try checkCompact(d.runway, short: belowChip ? "低于预警线" : short, muted: belowChip ? false : muted)
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
            try checkEqual(text.detail, title == "额度已用完" ? "2 小时后恢复" : "2 小时后重置")
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
    test("quota below threshold chip says below line") {
        let q = quota(95, rise: 0)
        let r = RiskRanker.risk(RiskInput(id: .claudePlan, status: .ok, payg: nil, quota: q, belowThreshold: true))
        var d = data(); apply(&d, [r], main: .claudePlan)
        try checkEqual(d.runway?.title, "低于预警线")
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
        var d = data(); let r = PlatformRisk(id: .siliconflow, kind: .payg(payg()), hours: 3, atRisk: true, severity: .danger)
        apply(&d, [r])
        try checkEqual(d.banner?.id, ProviderID.siliconflow.rawValue)
        try checkEqual(d.banner?.severity, 2)
        try checkEqual(d.banner?.text, "硅基流动 预计可用时间：3 小时")
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
        // 套餐平台低于预警线 / 用完 / 快用完：不出顶部横幅（系统通知和卡片红字照旧）
        apply(&d, [PlatformRisk(id: .claudePlan, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)])
        try checkEqual(d.banner, nil)
        apply(&d, [risk(.claudePlan, quota(100))])
        try checkEqual(d.banner, nil)
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
