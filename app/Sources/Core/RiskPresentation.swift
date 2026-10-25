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
        let reset = r.resetsAt.map {
            L("runway.chipReset", r.window.resetIsEstimated ? L("quota.approxPrefix") : "", durationText(hours: $0.timeIntervalSince(now) / 3600))
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
                short = L("runway.left", paygDuration(p))
                return Runway.paygText(p, currency: currency)
            }
            switch r.kind {
            case .payg(let p): text = paygText(p)
            case .quota(let q): text = quotaText(q)
            case .belowThreshold:
                if let q = r.quotaReading { text = quotaText(q) }
                else if let p = r.paygReading { text = paygText(p) }
            case .none, .noData: break
            }
            if let text {
                d.runway = AppData.RunwayChip(title: text.title, detail: text.detail,
                    severity: r.kind == .belowThreshold ? max(r.severity.rawValue, RunwaySeverity.danger.rawValue) : r.severity.rawValue, short: short, muted: muted)
            }
        }
        for i in d.sides.indices {
            d.sides[i].riskText = nil
            d.sides[i].riskSeverity = nil
            guard let r = risks.first(where: { $0.id.rawValue == d.sides[i].id }) else { continue }
            var text: String?
            switch r.kind {
            case .belowThreshold: text = L("runway.belowLine")
            case .payg(let p) where r.atRisk: text = L("runway.timeLeft", paygDuration(p))
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
        guard mainRisk?.atRisk != true,
              let r = risks.first(where: { risk in risk.id != main && risk.atRisk && d.sides.contains(where: { $0.id == risk.id.rawValue }) }) else { return }
        let message: String, kind: String
        let resetsAt: Date?
        switch r.kind {
        case .belowThreshold:
            kind = "below"; resetsAt = r.quotaReading?.resetsAt
            message = ProviderRegistry.meter(r.id) == .quota ? L("banner.quotaBelow") : L("banner.balanceBelow")
        case .payg(let p):
            kind = "payg"; resetsAt = nil
            message = L("runway.timeLeft", paygDuration(p))
        case .quota(let q):
            kind = q.state == .exhausted ? "exhausted" : "runsOut"
            resetsAt = q.resetsAt
            let head = q.state == .exhausted ? L("runway.exhausted") : L("runway.timeLeft", Runway.durationText(hours: q.hoursToEmpty ?? 0))
            message = head + (Runway.resetClock(q, now: now, timeZone: timeZone).map { L("alert.runout.reset", $0) } ?? "")
        default: return
        }
        let reset = resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
        let key = "\(r.id.rawValue)|\(kind)|\(r.severity.rawValue)|\(reset)"
        d.banner = AppData.RiskBanner(id: r.id.rawValue, text: "\(ProviderRegistry.displayName(r.id))\(kind == "below" ? L("banner.colon") : L("banner.space"))\(message)", severity: r.severity.rawValue, key: key)
    }

    private static func paygDuration(_ p: PaygRunway) -> String {
        p.hours < 1 ? L("common.underOneHour") : Runway.durationText(hours: p.hours)
    }
}
