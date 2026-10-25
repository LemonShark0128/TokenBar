import Foundation

/// 花得多快、还能用几天（纯计算，不碰网络和存储）
struct BurnStats: Equatable {
    /// 近 1 小时时速；窗口 < 45 分钟或采样 < 6 个时为 nil（短窗口会被平台批量扣费放大）
    var perHourRecent: Decimal?
    /// 近 24 小时窗口的平均时速
    var perHourDay: Decimal?
    /// 近 7 天日均
    var avgPerDayWeek: Decimal
    /// 油箱剩余 ÷ 7 天日均
    var runwayDays: Decimal?
    /// 近 1 小时时速 × 24 > 7 天日均 × 3
    var spike: Bool
}

enum BurnCalculator {
    static let recentMinSpan: TimeInterval = 45 * 60
    static let recentMinPoints = 6

    static func stats(samples: [Sample], now: Date, tankRemaining: Decimal?, weekCostByDay: [Decimal]) -> BurnStats {
        let sorted = samples.sorted { $0.t < $1.t }
        let recent = sorted.filter { $0.t >= now.addingTimeInterval(-3600) }
        let day = sorted.filter { $0.t >= now.addingTimeInterval(-86400) }

        var perHourRecent: Decimal?
        if recent.count >= recentMinPoints, let a = recent.first, let b = recent.last,
           b.t.timeIntervalSince(a.t) >= recentMinSpan {
            perHourRecent = rate(recent)
        }
        let perHourDay: Decimal? = day.count >= 2 && day.last!.t > day.first!.t ? rate(day) : nil

        let avg = weekCostByDay.reduce(0, +) / 7
        let runway: Decimal? = (tankRemaining != nil && avg > 0) ? tankRemaining! / avg : nil
        // 没有 7 天日均（如只有余额）就无从比较「比平时快」，不判定异常
        let spike = avg > 0 && (perHourRecent.map { $0 * 24 > avg * 3 } ?? false)
        return BurnStats(perHourRecent: perHourRecent, perHourDay: perHourDay, avgPerDayWeek: avg,
                         runwayDays: runway, spike: spike)
    }

    /// 窗口内每小时花费
    private static func rate(_ w: [Sample]) -> Decimal {
        let hours = Decimal(w.last!.t.timeIntervalSince(w.first!.t) / 3600)
        return hours > 0 ? spent(w) / hours : 0
    }

    /// 窗口内花了多少：优先逐对累计花费差值（月初清零时加新值）；没有累计花费就用余额下降量，余额上升（充值）不计
    static func spent(_ w: [Sample]) -> Decimal {
        if w.allSatisfy({ $0.cumulativeCost != nil }) {
            return zip(w, w.dropFirst()).reduce(0) { total, pair in
                let a = pair.0.cumulativeCost!, b = pair.1.cumulativeCost!
                return total + (b >= a ? b - a : b)
            }
        }
        var total: Decimal = 0
        for (prev, next) in zip(w, w.dropFirst()) {
            if let p = prev.balance, let n = next.balance, n < p { total += p - n }
        }
        return total
    }
}
