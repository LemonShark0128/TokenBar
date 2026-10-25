import Foundation

struct PlatformRisk: Equatable {
    enum Kind: Equatable {
        case belowThreshold
        case payg(PaygRunway)
        case quota(QuotaRunway)
        case noData
        case none
    }
    var id: ProviderID
    var kind: Kind
    var hours: Double?
    var atRisk: Bool
    var severity: RunwaySeverity
    // 预警线优先决定风险类型，但展示仍需要原始续航（尤其是套餐涨幅和重置时间）。
    var paygReading: PaygRunway? = nil
    var quotaReading: QuotaRunway? = nil
}

struct RiskInput: Equatable {
    var id: ProviderID
    var status: PlatformStatus
    var payg: PaygRunway?
    var quota: QuotaRunway?
    var belowThreshold: Bool
}

/// 先排紧迫风险，再排无数据；同级沿用平台顺序。
enum RiskRanker {
    static func risk(_ i: RiskInput) -> PlatformRisk {
        var r = PlatformRisk(id: i.id, kind: .none, hours: nil, atRisk: false, severity: .ok)
        switch i.status {
        case .offline, .credentialInvalid, .schemaChanged, .stale:
            r.kind = .noData
            return r
        case .loading, .notAdded: return r
        default: break
        }
        r.paygReading = i.payg
        r.quotaReading = i.quota
        if i.belowThreshold {
            r.kind = .belowThreshold
            r.hours = 0
            r.atRisk = true
            r.severity = .danger
        } else if let payg = i.payg {
            r.kind = .payg(payg)
            r.hours = payg.hours
            r.atRisk = payg.hours < Runway.warnHours
            r.severity = payg.severity
        } else if let quota = i.quota {
            r.kind = .quota(quota)
            if quota.state == .runsOut || quota.state == .exhausted {
                r.hours = quota.hoursToEmpty
                r.atRisk = true
                r.severity = quota.severity
            }
        }
        return r
    }

    static func rank(_ inputs: [RiskInput]) -> [PlatformRisk] {
        inputs.filter { $0.status != .notAdded }.map { risk($0) }.sorted {
            if $0.atRisk != $1.atRisk { return $0.atRisk }
            if $0.atRisk {
                let a = $0.hours ?? .infinity, b = $1.hours ?? .infinity
                if a != b { return a < b }
            }
            let aNoData = $0.kind == .noData, bNoData = $1.kind == .noData
            if aNoData != bNoData { return aNoData }
            return order($0.id) < order($1.id)
        }
    }

    static func mostAtRisk(_ inputs: [RiskInput]) -> PlatformRisk? {
        rank(inputs).first { $0.atRisk }
    }

    private static func order(_ id: ProviderID) -> Int { ProviderID.allCases.firstIndex(of: id) ?? 0 }
}
