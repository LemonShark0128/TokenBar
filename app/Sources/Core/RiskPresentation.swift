import Foundation

extension Runway {
    /// 重置时刻按调用方时区显示；跨日补日期，估算保留「约」。
    static func resetClock(_ r: QuotaRunway, now: Date, timeZone: TimeZone) -> String? {
        guard let at = r.resetsAt else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: at)
        let date = cal.isDate(at, inSameDayAs: now) ? "" : "\(c.month ?? 1)/\(c.day ?? 1) "
        return (r.window.resetIsEstimated ? L("quota.approxPrefix") : "") + date + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func quotaChip(_ r: QuotaRunway, now: Date, timeZone: TimeZone) -> (title: String, detail: String?) {
        // 用完时写「…后恢复」（同横幅、菜单栏），没用完写「…后重置」
        let reset = r.resetsAt.map {
            L(r.state == .exhausted ? "runway.chipBack" : "runway.chipReset",
              r.window.resetIsEstimated ? L("quota.approxPrefix") : "", durationText(hours: $0.timeIntervalSince(now) / 3600))
        }
        switch r.state {
        case .idle: return (L("runway.idle"), reset)
        case .enough: return (L("runway.enough"), reset)
        case .exhausted: return (L("runway.exhausted"), reset)
        case .runsOut:
            let hours = r.hoursToEmpty ?? 0
            let usage = L("runway.usedLastHour", Int(r.risePP.rounded()))
            let early = r.resetsAt.flatMap { at in
                resetClock(r, now: now, timeZone: timeZone).map {
                    L("runway.earlyBy", $0, durationText(hours: at.timeIntervalSince(now) / 3600 - hours))
                }
            } ?? ""
            return (L("runway.timeLeft", durationText(hours: hours)), early + usage)
        }
    }
}

extension AppDataMapping {
    /// risks 已由 RiskRanker 排序；只移动有风险的行，其余沿用活跃度 / 调用方顺序。
    static func orderSidesByRisk(_ d: inout AppData, risks: [PlatformRisk]) {
        let ids = risks.filter(\.atRisk).map { $0.id.rawValue }
        let risky = ids.compactMap { id in d.sides.first { $0.id == id } }
        d.sides = risky + d.sides.filter { !ids.contains($0.id) }
        d.sidesByRisk = !risky.isEmpty
    }

    static func applyRisks(_ d: inout AppData, main: ProviderID, risks: [PlatformRisk], now: Date,
                           timeZone: TimeZone, currency: String?) {
        d.runway = nil
        d.banner = nil
        let mainRisk = risks.first { $0.id == main }
        if let r = mainRisk {
            var text: (title: String, detail: String?)?
            var short: String?
            var muted = false
            func quotaText(_ q: QuotaRunway) -> (title: String, detail: String?) {
                let text = Runway.quotaChip(q, now: now, timeZone: timeZone)
                short = q.state == .runsOut ? L("runway.timeLeft", Runway.durationText(hours: q.hoursToEmpty ?? 0)) : text.title
                muted = q.state == .idle
                return text
            }
            func paygText(_ p: PaygRunway) -> (title: String, detail: String?) {
                short = L("runway.left", Runway.spanText(hours: p.hours))
                return Runway.paygText(p, currency: currency)
            }
            switch r.kind {
            case .payg(let p): text = paygText(p)
            case .quota(let q): text = quotaText(q)
            case .belowThreshold:
                if let q = r.quotaReading {
                    text = quotaText(q)
                    // 套餐低于预警线：没在快速用完时胶囊写「低于预警线」（红），重置时间留在说明里
                    //（11/6 用户定 round7-scout 第 2 条乙；原来写「近 1 小时没用」「够用到重置」，和侧栏对不上）
                    if q.state != .runsOut {
                        text = (L("runway.belowLine"), text?.detail)
                        short = L("runway.belowLine")
                        muted = false
                    }
                } else if let p = r.paygReading { text = paygText(p) }
            case .none, .noData: break
            }
            if let text {
                d.runway = AppData.RunwayChip(title: text.title, detail: text.detail,
                    severity: r.kind == .belowThreshold ? RunwaySeverity.danger.rawValue : r.severity.rawValue, short: short, muted: muted)
            }
        }
        for i in d.sides.indices {
            d.sides[i].riskText = nil
            d.sides[i].riskSeverity = nil
            guard let r = risks.first(where: { $0.id.rawValue == d.sides[i].id }) else { continue }
            var text: String?
            switch r.kind {
            case .belowThreshold: text = L("runway.belowLine")
            case .payg(let p) where r.atRisk: text = L("runway.timeLeft", Runway.spanText(hours: p.hours))
            case .quota(let q):
                switch q.state {
                case .runsOut where r.atRisk: text = L("runway.timeLeft", Runway.durationText(hours: q.hoursToEmpty ?? 0))
                case .exhausted where r.atRisk: text = L("quota.usedUp")
                case .enough where !r.atRisk: text = L("runway.enough")
                default: break
                }
            default: break
            }
            d.sides[i].riskText = text
            d.sides[i].riskSeverity = text == nil ? nil : r.severity.rawValue
        }
        orderSidesByRisk(&d, risks: risks)
        // 套餐平台的提醒不再占顶部横幅（用户 2026-11-06 选乙：系统通知和卡片红字已经提醒，横幅让面板忽高忽低）；按量付费的余额预警照旧
        // 主平台自己有风险时不再加横幅（主卡已写着）；主平台是套餐时例外：套餐不占顶部，按量付费副平台的横幅照样显示（用户 2026-11-06）
        guard mainRisk?.atRisk != true || ProviderRegistry.meter(main) == .quota,
              let r = risks.first(where: { risk in risk.id != main && risk.atRisk && ProviderRegistry.meter(risk.id) != .quota
                  && d.sides.contains(where: { $0.id == risk.id.rawValue }) }) else { return }
        let message: String, kind: String
        switch r.kind {
        case .belowThreshold:
            // 金额是 Key 剩余上限（OpenRouter）：写「Key 剩余额度低于预警线」
            let keyLimit = d.sides.first { $0.id == r.id.rawValue }?.tankIsKeyLimit == true
            kind = "below"; message = L(keyLimit ? "banner.keyLimitBelow" : "banner.balanceBelow")
        case .payg(let p):
            kind = "payg"; message = L("runway.timeLeft", Runway.spanText(hours: p.hours))
        default: return
        }
        // 键的最后一段原来是套餐窗口的重置分钟；只剩按量付费后恒为「-」，格式不变（已存的「关掉」记录仍认得）
        let key = "\(r.id.rawValue)|\(kind)|\(r.severity.rawValue)|-"
        d.banner = AppData.RiskBanner(id: r.id.rawValue, text: "\(ProviderRegistry.displayName(r.id))\(kind == "below" ? L("banner.colon") : L("banner.space"))\(message)", severity: r.severity.rawValue, key: key)
    }
}
