/// 套餐额度按已用百分比分级；不影响按量付费的余额规则。
enum QuotaLevel {
    static let warnUsed = 80.0
    static let dangerUsed = 95.0

    static func severity(usedPercent: Double) -> RunwaySeverity {
        let used = max(0, min(100, usedPercent))
        if used >= dangerUsed { return .danger }
        if used >= warnUsed { return .warn }
        return .ok
    }

    static func severity(remainingFraction: Double) -> RunwaySeverity {
        severity(usedPercent: (1 - max(0, min(1, remainingFraction))) * 100)
    }
}
