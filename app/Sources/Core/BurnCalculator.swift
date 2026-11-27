import Foundation

/// 花得多快、还能用几天（纯计算，不碰网络和存储）
struct BurnStats: Equatable {
    /// 近 1 小时时速；窗口 < 45 分钟或采样 < 6 个时为 nil（短窗口会被平台批量扣费放大）
    var perHourRecent: Decimal?
    /// 近 24 小时窗口的平均时速
    var perHourDay: Decimal?
    /// 近 7 天日均：近 7 天花费 ÷ 有数据的天数（不满 7 天的新账号 / 新平台按实际天数）
    var avgPerDayWeek: Decimal
    /// 油箱剩余 ÷ 7 天日均；数据不足 1 天时为 nil
    var runwayDays: Decimal?
    /// 近 1 小时时速 × 24 > 7 天日均 × 3，且时速 ≥ spikeMinPerHour；数据不足 1 天时不判
    var spike: Bool
    /// false = 刚开始记、账单里也只有今天有花费：日均只是今天的数，不写续航、不判异常
    var enoughData: Bool = true
    /// 日均来自平台给的周 / 月累计时覆盖了几天（OpenRouter）；按近 7 天账单算的为 nil
    var avgDays: Int? = nil
}

enum BurnCalculator {
    static let recentMinSpan: TimeInterval = 45 * 60
    static let recentMinPoints = 6
    /// 判「异常增加」的最低时速（元/时）：平时几乎不花的账号，¥0.03/时也会是平均的几十倍，不值得提醒
    /// 美元平台 $0.03（约 ¥0.21，同一量级；按原数 0.2 算会是 7 倍门槛）
    static func spikeMinPerHour(_ currency: Currency) -> Decimal {
        currency == .usd ? Decimal(string: "0.03")! : Decimal(string: "0.2")!
    }

    /// observedSince：TokenBar 最早开始记这个平台的时间（nil = 不知道，按满 7 天算）
    /// billHistory：weekCostByDay 来自平台账单（false = 用 TokenBar 自己的余额采样估算，开始记之前的日子不算数）
    /// dailyAverage：平台直接给的日均（没有逐日账单时）；给了就用它，覆盖不到 2 天时和「账单只有今天」一样不写续航
    static func stats(samples: [Sample], now: Date, tankRemaining: Decimal?, weekCostByDay: [Decimal],
                      observedSince: Date? = nil, billHistory: Bool = true, timeZone: TimeZone = .current,
                      dailyAverage: DailyAverage? = nil, currency: Currency = .cny) -> BurnStats {
        let sorted = samples.sorted { $0.t < $1.t }
        let recent = sorted.filter { $0.t >= now.addingTimeInterval(-3600) }
        let day = sorted.filter { $0.t >= now.addingTimeInterval(-86400) }

        var perHourRecent: Decimal?
        if recent.count >= recentMinPoints, let a = recent.first, let b = recent.last,
           b.t.timeIntervalSince(a.t) >= recentMinSpan {
            perHourRecent = rate(recent, timeZone)
        }
        let perHourDay: Decimal? = day.count >= 2 && day.last!.t > day.first!.t ? rate(day, timeZone) : nil

        let avg: Decimal, enough: Bool
        if let dailyAverage {
            (avg, enough) = (dailyAverage.perDay, dailyAverage.days > 1)
        } else {
            let (days, ok) = dataDays(weekCostByDay, now: now, observedSince: observedSince, billHistory: billHistory)
            (avg, enough) = (weekCostByDay.reduce(0, +) / Decimal(days), ok)
        }
        let runway: Decimal? = (enough && tankRemaining != nil && avg > 0) ? tankRemaining! / avg : nil
        // 没有 7 天日均（如只有余额）就无从比较「比平时快」，不判定异常；时速太小、数据不足 1 天也不算
        let spike = enough && avg > 0 && (perHourRecent.map { $0 >= spikeMinPerHour(currency) && $0 * 24 > avg * 3 } ?? false)
        return BurnStats(perHourRecent: perHourRecent, perHourDay: perHourDay, avgPerDayWeek: avg,
                         runwayDays: runway, spike: spike, enoughData: enough, avgDays: dailyAverage?.days)
    }

    /// 日均的分母（1…7 天）和数据够不够 1 天。
    /// 各平台没花钱的日子都补 0，分不清「没用」和「还没数据」，所以取两者较大：
    /// 第一笔花费到今天的天数（账单平台刚添加时账单里有历史）、TokenBar 开始记这个平台的天数（余额估算平台在那之前都是 0）。
    /// 估算平台的「花费天数」只是观测刚好跨了零点（23:30 加、0:30 已有两天），不算历史，只看开始记的时长
    static func dataDays(_ week: [Decimal], now: Date, observedSince: Date?, billHistory: Bool = true) -> (days: Int, enough: Bool) {
        let spendDays = billHistory ? week.firstIndex { $0 > 0 }.map { week.count - $0 } ?? 0 : 0
        guard let observedSince else { return (7, true) }
        let observed = max(0, now.timeIntervalSince(observedSince))
        let observedDays = max(1, Int((observed / 86400).rounded(.up)))
        let days = min(7, max(spendDays, observedDays, 1))
        return (days, observed >= 86400 || spendDays > 1)
    }

    /// 窗口内每小时花费
    private static func rate(_ w: [Sample], _ timeZone: TimeZone) -> Decimal {
        let hours = Decimal(w.last!.t.timeIntervalSince(w.first!.t) / 3600)
        return hours > 0 ? spent(w, timeZone: timeZone) / hours : 0
    }

    /// 窗口内花了多少：优先逐对累计花费差值；没有累计花费就用余额下降量，余额上升（充值）不计。
    /// 两次采样跨了月（按账单所用时区）：本月累计已清零重算，加新值（上月很少、新月已超过它时也是）；
    /// 同一个月里变少（退款、账单修正、接口返回旧缓存）记 0——原来一律当清零，¥100.00 → ¥99.80 被算成花了 ¥99.80
    static func spent(_ w: [Sample], timeZone: TimeZone = .current) -> Decimal {
        if w.allSatisfy({ $0.cumulativeCost != nil }) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            return zip(w, w.dropFirst()).reduce(0) { total, pair in
                let a = pair.0.cumulativeCost!, b = pair.1.cumulativeCost!
                guard cal.isDate(pair.0.t, equalTo: pair.1.t, toGranularity: .month) else { return total + b }
                return total + max(0, b - a)
            }
        }
        var total: Decimal = 0
        for (prev, next) in zip(w, w.dropFirst()) {
            if let p = prev.balance, let n = next.balance, n < p { total += p - n }
        }
        return total
    }
}
