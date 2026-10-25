import Foundation

@MainActor
func registerQuotaLevelTests() {
    // 防止阈值等号遗漏、百分比方向反转或越界值误判。
    test("quotaLevelUsedPercentBoundaries") {
        let cases: [(Double, RunwaySeverity)] = [
            (-10, .ok), (0, .ok), (79.9, .ok), (80, .warn),
            (94.9, .warn), (95, .danger), (100, .danger), (110, .danger)
        ]
        for (used, expected) in cases {
            try checkEqual(QuotaLevel.severity(usedPercent: used), expected)
        }
    }
    test("quotaLevelRemainingFractionBoundaries") {
        let cases: [(Double, RunwaySeverity)] = [
            (1.1, .ok), (1, .ok), (0.201, .ok), (0.2, .warn),
            (0.051, .warn), (0.05, .danger), (0, .danger), (-0.1, .danger)
        ]
        for (remaining, expected) in cases {
            try checkEqual(QuotaLevel.severity(remainingFraction: remaining), expected)
        }
    }
}
